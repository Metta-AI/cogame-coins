## Prompt and Jev decision making for Coins. The GAME server composes each
## seat's observation and asks Claude for a full action or Jev to rank intents.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim`. Decisions are
## SIMULTANEOUS by rule, so both seats' requests go out as ONE parallel batch
## (`curly.makeRequests`) at every beat close — never sequentially, never one
## seat waiting on the other. An invalid reply is retried ONCE, in the same
## beat, with a hint; anything still failing falls back to the scripted
## `reciprocator` move.
##
## Claude credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## Jev uses the hosted Bedrock sidecar, the Metta capture proxy, or a direct
## TypeSafe key. Without either provider, prompt and Jev seats use the scripted
## reciprocator, which keeps offline certification deterministic.

import
  std/[json, os, strutils, times],
  bitworld/runtime,
  curly,
  sim, scripted

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    jevEndpoint: string
    jevKey: string
    jevModel: string
    jevTrajectoryId: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    minBeatSeconds: int
    lastBatchAt*: float           ## epochTime of the previous batch start
    batchStarts*: seq[float]      ## every batch start, for the cadence test
    disabled*: bool

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "coins llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds*(): seq[string] =
  ## Haiku ONLY (the raid learning): the sonnet fallback times out on every
  ## sidecar call and turns one throttle into a cascade. `BEDROCK_MODEL`
  ## pins a single id.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "coins llm: rotating bedrock model (", why, ")"
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    minBeatSeconds: config.minBeatSeconds,
    lastBatchAt: 0.0
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  let captureUrl = getEnv("METTA_CAPTURE_URL").strip()
  let typesafeKey = getEnv("TYPESAFE_API_KEY").strip()
  if bedrockEndpoint.len > 0:
    result.jevEndpoint = bedrockEndpoint.strip(chars = {'/'}, leading = false)
    result.jevModel = "typesafe/jev-1.13"
  elif captureUrl.len > 0:
    result.jevEndpoint = captureUrl.strip(chars = {'/'}, leading = false)
    result.jevKey = getEnv("METTA_CAPTURE_KEY").strip()
    if result.jevKey.len == 0:
      raise newException(CoinsError, "METTA_CAPTURE_KEY is required")
    result.jevModel = "typesafe/jev-1.13"
    result.jevTrajectoryId = "coins-jev-" & $config.seed
  elif typesafeKey.len > 0:
    result.jevEndpoint = getEnv("TYPESAFE_BASE_URL",
      "https://api.typesafe.ai").strip(chars = {'/'}, leading = false)
    result.jevKey = typesafeKey
    result.jevModel = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "coins llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "coins llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    if result.jevEndpoint.len > 0:
      result.curl = newCurly()
    echo "coins llm: no Claude credentials; prompt seats play reciprocator"

# ---------------------------------------------------------------------------
# text hygiene
# ---------------------------------------------------------------------------

## `cleanText` / `cleanSay` / `cleanNotes` live in `sim_types` (no transport
## dependency) and are re-exported through `sim`, so a test can exercise the
## rune caps without linking curl.

# ---------------------------------------------------------------------------
# prompts
# ---------------------------------------------------------------------------

proc systemPrompt*(obs: JsonNode): string =
  let alias = obs{"alias"}.getStr().toUpperAscii()
  let colour = obs{"colour"}.getStr().toUpperAscii()
  let them = obs{"them"}{"alias"}.getStr().toUpperAscii()
  let theirColour = obs{"them"}{"colour"}.getStr().toUpperAscii()
  let rules = obs{"rules"}
  let beat = obs{"beat"}.getInt()
  let minBeats = obs{"minBeats"}.getInt()
  let maxBeats = obs{"maxBeats"}.getInt()
  let permille = obs{"endChancePermille"}.getInt()
  let penalty = rules{"theftPenalty"}.getInt()
  result =
    "You are " & alias & ", the " & colour & " cog, in a small square room " &
    "with one other cog, " & them & " (" & theirColour & ").\n\n" &
    "THE ROOM: a 7x7 open floor inside a wall ring. Moves are 4-way (north, " &
    "east, south, west); there are no diagonals. After every step you wait " &
    $rules{"stepCooldownTicks"}.getInt() & " ticks before you can step " &
    "again. Coins of both colours appear on empty cells: one new coin every " &
    $rules{"coinSpawnIntervalTicks"}.getInt() & " ticks while fewer than " &
    $rules{"coinCap"}.getInt() & " are on the board. The room is " &
    "deliberately coin-starved — supply, not walking speed, is what limits " &
    "you.\n\n" &
    "THE BEAT: you do not steer tick by tick. Once per BEAT of " &
    $obs{"ticksPerBeat"}.getInt() & " ticks you choose ONE intent, and a " &
    "deterministic kernel walks your cog for the whole beat:\n" &
    "- take_mine: walk to the nearest " & colour & " coin. You will NOT step " &
    "onto a " & theirColour & " coin.\n" &
    "- take_any: walk to the nearest coin of EITHER colour (your own colour " &
    "wins a tie). Nothing is off limits.\n" &
    "- take_theirs: walk to the nearest " & theirColour & " coin. Nothing is " &
    "off limits.\n" &
    "- guard: walk to whichever " & colour & " coin is nearest to " & them &
    ", banking the coin most at risk. You will NOT step onto a " &
    theirColour & " coin.\n" &
    "- hold: stand still. You will NOT step onto a " & theirColour & " coin.\n" &
    "RESTRAINT IS A MOVEMENT RULE, NOT A PICKUP RULE: an intent that forbids " &
    "a colour never steps onto a coin of that colour, so " & them & " can " &
    "literally watch you walk around its coins.\n\n" &
    "SCORING. Every coin you pick up is +1 to you, whatever its colour. If " &
    "the coin was " & theirColour & " — your opponent's colour — your " &
    "opponent additionally loses " & $penalty & ". You keep the +1 either " &
    "way. Your score is `pickups - " & $penalty & " x (coins of your colour " &
    "your opponent took)`. Higher is better. Scores can go negative.\n\n" &
    "THE SHADOW OF THE FUTURE: the episode has run " & $beat & " beats; from " &
    "beat " & $minBeats & " on, each beat close ends it with probability " &
    formatFloat(permille.float / 1000.0, ffDecimal, 3) & ", and it always " &
    "ends by beat " & $maxBeats & " — so on average there are several beats " &
    "left, and you will meet this cog again in each of them.\n\n" &
    "THE OTHER COG is another policy deciding AT THE SAME MOMENT as you. " &
    "Nothing you write is ever read by it. It can see your position, your " &
    "score and your theft counter exactly as you can see its own.\n\n" &
    "OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no " &
    "analysis, no explanation, no markdown fences, no text before or after " &
    "the object. Your reply must begin with the character { and end with }."

proc operatorBlock(prompt: string): string =
  if prompt.strip().len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(obs: JsonNode, prompt: string): string =
  let alias = obs{"alias"}.getStr()
  let colour = obs{"colour"}.getStr()
  let them = obs{"them"}{"alias"}.getStr()
  let theirColour = obs{"them"}{"colour"}.getStr()
  let you = obs{"you"}
  let they = obs{"them"}
  result.add("BEAT " & $obs{"beat"}.getInt() & " (ends by beat " &
    $obs{"maxBeats"}.getInt() & ")\n")
  result.add("YOU " & alias & " (" & colour & ") at (" &
    $you{"x"}.getInt() & "," & $you{"y"}.getInt() & ") · score " &
    $you{"score"}.getInt() & " · took " & $you{"pickups"}.getInt() &
    " coins, " & $you{"thefts"}.getInt() & " of them " & them & "'s · " &
    them & " has taken " & $you{"stolenFrom"}.getInt() & " of yours\n")
  result.add("THEM " & them & " (" & theirColour & ") at (" &
    $they{"x"}.getInt() & "," & $they{"y"}.getInt() & ") · score " &
    $they{"score"}.getInt() & " · took " & $they{"pickups"}.getInt() &
    " coins, " & $they{"thefts"}.getInt() & " of them yours\n")
  var coinBits: seq[string]
  for coin in obs{"coins"}:
    coinBits.add(coin{"colour"}.getStr() & " at (" & $coin{"x"}.getInt() &
      "," & $coin{"y"}.getInt() & ")")
  result.add("COINS ON THE BOARD: " &
    (if coinBits.len > 0: coinBits.join(" · ") else: "(none)") & "\n\n")
  var history: seq[string]
  for row in obs{"beatLog"}:
    history.add("beat " & $row{"beat"}.getInt() & " · you " &
      row{"you"}{"intent"}.getStr() & ": " &
      $row{"you"}{"pickups"}.getInt() & " coins, " &
      $row{"you"}{"thefts"}.getInt() & " thefts · " & them & ": " &
      $row{"them"}{"pickups"}.getInt() & " coins, " &
      $row{"them"}{"thefts"}.getInt() & " thefts · score " &
      $row{"score"}[0].getInt() & "–" & $row{"score"}[1].getInt())
  result.add("EVERY BEAT SO FAR:\n" &
    (if history.len > 0: history.join("\n") else: "(this is the first beat)") &
    "\n\n")
  let notes = obs{"notes"}.getStr()
  result.add("YOUR NOTES FROM LAST BEAT:\n" &
    (if notes.len > 0: notes else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"intent\": \"take_mine\", \"say\": \"…\", " &
    "\"notes\": \"…\"} — intent must be exactly one of take_mine, take_any, " &
    "take_theirs, guard, hold; say at most " & $MaxSayLen &
    " characters (spectators read it, the other cog never does); notes at " &
    "most " & $MaxNotesLen & " characters, returned to you next beat.")

const RetryHint* =
  "\nYour previous reply was invalid. Respond with ONLY the requested JSON " &
  "object. `intent` must be exactly one of take_mine, take_any, " &
  "take_theirs, guard, hold."

# ---------------------------------------------------------------------------
# reply parsing
# ---------------------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences,
  ## a prose preamble and trailing prose after the closing brace.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(CoinsError,
      "no JSON object in response: " & head.replace("\n", " "))
  parseJson(text[start .. stop])

proc parseDecision*(payload: JsonNode): Decision =
  ## `intent` is required and must be one of the five (case-insensitive).
  ## `say` and `notes` are optional and both carry a RUNE cap.
  result.say = cleanSay(payload{"say"}.getStr())
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let node = payload{"intent"}
  if node == nil or node.kind != JString:
    raise newException(CoinsError, "no intent in response")
  result.intent = parseIntent(node.getStr())
  result.source = osLlm

# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a
    ## 400 if it is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  if error.len > 0:
    raise newException(CoinsError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 300)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CoinsError, "bedrock model access denied: " & detail)
    ## 401/403 disables the client for the rest of the episode.
    client.disabled = true
    raise newException(CoinsError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    ## Logged, and that seat is retried in the NEXT beat's batch.
    raise newException(CoinsError, "llm throttled (429): " &
      response.body[0 .. min(response.body.high, 200)])
  if response.code < 200 or response.code >= 300:
    raise newException(CoinsError, "llm error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CoinsError, "llm refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CoinsError, "reply cut off at max_tokens before any " &
      "JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

# ---------------------------------------------------------------------------
# the batch
# ---------------------------------------------------------------------------

proc fallbackDecision*(view: Sim, slot: int, source: OrderSource): Decision =
  ## The scripted `reciprocator` move — the strongest of the four against an
  ## unknown opponent, and the move every failure path lands on.
  Decision(
    intent: scriptedIntent(skReciprocator, view.buildObservation(slot),
      view.config.punishThreshold, view.config.punishBeats),
    source: source
  )

proc scriptedDecision*(view: Sim, slot: int, kind: ScriptKind): Decision =
  Decision(
    intent: scriptedIntent(kind, view.buildObservation(slot),
      view.config.punishThreshold, view.config.punishBeats),
    source: osScripted
  )

proc jevCriteria*(): JsonNode =
  %*{
    "take_mine": "Walk to the nearest coin of your colour without stepping on the other's coins.",
    "take_any": "Walk to the nearest coin of either colour; taking the other's coin harms them by two points.",
    "take_theirs": "Walk to the nearest coin of the other's colour and take it.",
    "guard": "Walk to your coin nearest the other cog without stepping on their coins.",
    "hold": "Stand still without taking a coin."
  }

proc jevDecision*(payload, criteria: JsonNode): Decision =
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  let reported = answer["choice"].getStr()
  if answer["type"].getStr() != "choice" or
      not criteria.hasKey(reported) or probabilities.len != criteria.len:
    raise newException(CoinsError, "Jev returned the wrong choice set")
  let confidence = answer["confidence"].getFloat()
  if confidence < 0 or confidence > 1:
    raise newException(CoinsError, "Jev confidence is outside [0, 1]")
  var total = 0.0
  var best = -1.0
  var choice = ""
  for name, probability in probabilities.pairs:
    if not criteria.hasKey(name):
      raise newException(CoinsError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(CoinsError, "Jev probability is outside [0, 1]")
    total += value
    if value > best:
      best = value
      choice = name
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(CoinsError, "Jev probabilities do not sum to one")
  result.intent = parseIntent(choice)
  result.source = osJev
  echo "coins jev: intent ", choice, " reported ", reported,
    " confidence ", confidence, " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()

proc pacedWait*(client: LlmClient, nowSeconds: float): float =
  ## The seconds a batch must wait before it may start. The Bedrock sidecar
  ## caps 30 requests/minute PER EPISODE (the raid learning); with 2 seats
  ## per batch a `minBeatSeconds` floor of 5 lands at 24 req/min with margin.
  if client.lastBatchAt <= 0.0:
    return 0.0
  let due = client.lastBatchAt + client.minBeatSeconds.float
  if due > nowSeconds: due - nowSeconds else: 0.0

proc decideAll*(client: LlmClient, view: Sim, seats: seq[int],
    prompts: seq[string], scripted: seq[ScriptKind], jev: seq[bool],
    sleepFor: proc (seconds: float) {.closure.} = nil): seq[Decision] =
  ## One decision per seat in `seats`, in order. NEVER raises: any failure
  ## falls back to the scripted move so the episode always advances.
  result = newSeq[Decision](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = if seat < scripted.len: scripted[seat] else: skNone
    if kind != skNone:
      result[index] = scriptedDecision(view, seat, kind)
    elif (client.disabled and not jev[seat]) or
        (jev[seat] and client.jevEndpoint.len == 0):
      result[index] = fallbackDecision(view, seat, osFallback)
    else:
      open.add(index)
  if open.len == 0:
    return
  ## The inter-batch wall-clock floor, applied ONCE per beat before the
  ## single parallel batch that carries every open seat.
  let waitFor = client.pacedWait(epochTime())
  if waitFor > 0.0 and sleepFor != nil:
    sleepFor(waitFor)
  client.lastBatchAt = epochTime()
  client.batchStarts.add(client.lastBatchAt)

  for attempt in 0 .. 1:
    if client.disabled:
      var enabled: seq[int]
      for index in open:
        if jev[seats[index]]:
          enabled.add(index)
        else:
          result[index] = fallbackDecision(view, seats[index], osFallback)
      open = enabled
    if open.len == 0:
      break
    let started = epochTime()
    var stillOpen: seq[int]
    ## The per-seat `try` below covers everything Coins itself can raise
    ## (transport status, refusal, parse, unknown intent). This outer one
    ## covers the BATCH: building an observation or a request, and
    ## `makeRequests` raising rather than returning a per-request `.error`.
    ## `decideAll` never raises — a raise here would leave `runEpisode` on the
    ## episode thread, and the container would serve /healthz until the
    ## platform's own timeout instead of settling.
    try:
      var batch: RequestBatch
      for index in open:
        let seat = seats[index]
        let obs = view.buildObservation(seat)
        if jev[seat]:
          var headers: HttpHeaders
          headers["content-type"] = "application/json"
          if client.jevKey.len > 0:
            headers["authorization"] = "Bearer " & client.jevKey
          else:
            headers["x-coworld-player-slot"] = $seat
          if client.jevTrajectoryId.len > 0:
            headers["x-metta-trajectory-id"] =
              client.jevTrajectoryId & "-" & $seat
          let body = %*{
            "model": client.jevModel,
            "state": systemPrompt(obs) & "\n\n" &
              userPrompt(obs, prompts[seat]),
            "questions": {"decision": {
              "type": "choice",
              "instructions": "Choose the intent that gives you the best long-run score against this opponent. Balance your own score, retaliation, and the remaining beats.",
              "criteria": jevCriteria()
            }}
          }
          batch.post(client.jevEndpoint & "/v1/systemone", headers,
            $body, $index)
        else:
          var user = userPrompt(obs, prompts[seat])
          if attempt > 0:
            user.add(RetryHint)
          let request = client.requestFor(systemPrompt(obs), user)
          batch.post(request.url, request.headers, request.body, $index)
      let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
      let latency = int((epochTime() - started) * 1000.0)
      for position, index in open:
        let seat = seats[index]
        try:
          if position >= responses.len:
            raise newException(CoinsError, "no response for seat " & $seat)
          var decision: Decision
          if jev[seat]:
            let response = responses[position].response
            let error = responses[position].error
            if error.len > 0 or response.code < 200 or response.code >= 300:
              raise newException(CoinsError, "Jev transport failed: " &
                error & " HTTP " & $response.code)
            decision = jevDecision(parseJson(response.body), jevCriteria())
          else:
            let text = client.textOf(responses[position].response,
              responses[position].error, batch[position].url)
            decision = parseDecision(extractJsonObject(text))
            decision.source = if attempt == 0: osLlm else: osRetry
          decision.latencyMs = latency
          result[index] = decision
        except CatchableError as error:
          echo "coins llm: seat ", seat, " attempt ", attempt, " failed: ",
            error.msg
          stillOpen.add(index)
    except CatchableError as error:
      echo "coins llm: batch attempt ", attempt, " failed: ", error.msg
      stillOpen = open
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "coins llm: seat ", seat, " falling back to scripted intent"
    result[index] = fallbackDecision(view, seat, osFallback)
