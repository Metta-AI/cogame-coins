## tests/test_llm.nim — the decision layer.
##
## `extractJsonObject` on fenced, prose-prefixed and trailing-prose replies;
## case-insensitive intent matching; an unknown intent is invalid; the
## reciprocator fallback; and ONE batch carrying every open seat with the
## inter-batch wall-clock floor honoured.

import std/[json, strutils, times, unicode]
import coins/[sim_types, sim, scripted, llm]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

proc raises(body: proc ()): bool =
  try:
    body()
    false
  except CatchableError:
    true

proc config(): GameConfig =
  result = defaultGameConfig()
  result.seed = 4
  result.minBeats = 6
  result.maxBeats = 6
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

# ---------------------------------------------------------------------------
echo "--- extractJsonObject tolerates what a model actually sends"
block:
  let plain = """{"intent": "take_mine"}"""
  check(extractJsonObject(plain){"intent"}.getStr() == "take_mine", "plain")

  let fenced = "```json\n{\"intent\": \"guard\", \"say\": \"mine\"}\n```"
  check(extractJsonObject(fenced){"intent"}.getStr() == "guard", "fenced")

  let prosePrefix = "Let me think about this.\n\n{\"intent\": \"hold\"}"
  check(extractJsonObject(prosePrefix){"intent"}.getStr() == "hold",
    "prose before the object")

  let trailing = "{\"intent\": \"take_any\"}\n\nThat should keep me even."
  check(extractJsonObject(trailing){"intent"}.getStr() == "take_any",
    "trailing prose after the closing brace")

  check(raises(proc () = discard extractJsonObject("no json at all here")),
    "a reply with no object at all is rejected")

echo "--- intent parsing is case-insensitive and closed"
block:
  check(parseIntent("TAKE_MINE") == inTakeMine, "upper case")
  check(parseIntent(" Take_Theirs ") == inTakeTheirs, "mixed case + spaces")
  check(parseIntent("take-any") == inTakeAny, "a hyphen is tolerated")
  check(raises(proc () = discard parseIntent("steal_everything")),
    "an intent outside the five is rejected")

echo "--- parseDecision applies the rune caps and rejects a bad intent"
block:
  let wide = "\u4e2d"
  let payload = %*{
    "intent": "Guard",
    "say": wide.repeat(MaxSayLen + 20),
    "notes": wide.repeat(MaxNotesLen + 40),
    "extraKeyNobodyAsksFor": 17
  }
  let decision = parseDecision(payload)
  check(decision.intent == inGuard, "the intent parses")
  check(decision.say.runeLen <= MaxSayLen, "say is capped in runes")
  check(decision.notes.runeLen <= MaxNotesLen, "notes is capped in runes")
  check(decision.source == osLlm, "a parsed decision is sourced llm")
  check(raises(proc () = discard parseDecision(%*{"say": "hi"})),
    "a reply with no intent is invalid")
  check(raises(proc () = discard parseDecision(%*{"intent": "sprint"})),
    "an unknown intent is invalid")
  check(parseDecision(%*{"intent": "hold"}).say == "",
    "say and notes are optional")

echo "--- the fallback move IS the reciprocator's"
block:
  var sim = initSim(config())
  for slot in 0 ..< Seats:
    let fallback = fallbackDecision(sim, slot, osFallback)
    let scripted = scriptedIntent(skReciprocator, sim.buildObservation(slot),
      sim.config.punishThreshold, sim.config.punishBeats)
    check(fallback.intent == scripted,
      "the fallback intent is the reciprocator's")
    check(fallback.source == osFallback,
      "and it is recorded with source fallback")
    check($fallback.source == "fallback", "which serialises as \"fallback\"")

echo "--- with no credentials the client disables itself and never raises"
block:
  ## No AWS sidecar and no ANTHROPIC_API_KEY in CI: the client must disable
  ## itself immediately and every seat must still get a legal intent, with no
  ## network wait at all. This is the path offline certification takes.
  let client = newLlmClient(config())
  var sim = initSim(config())
  let seats = @[0, 1]
  let prompts = @["be nice", "be nicer"]
  let kinds = @[skNone, skNone]
  var decisions: seq[Decision]
  let started = epochTime()
  check(not raises(proc () =
    decisions = client.decideAll(sim, seats, prompts, kinds)),
    "decideAll never raises")
  check(decisions.len == 2, "one decision per seat")
  for decision in decisions:
    check(decision.intent in [inTakeMine, inTakeAny, inTakeTheirs, inGuard,
      inHold], "every decision carries a legal intent")
  if client.disabled:
    check(epochTime() - started < 5.0,
      "a disabled client answers immediately, with no network wait")
    for decision in decisions:
      check(decision.source == osFallback,
        "a disabled client falls back rather than pretending")

echo "--- a scripted seat never enters the batch"
block:
  let client = newLlmClient(config())
  var sim = initSim(config())
  let before = client.batchStarts.len
  let decisions = client.decideAll(sim, @[0, 1], @["", ""],
    @[skHonest, skGreedy])
  check(decisions.len == 2, "two decisions")
  check(decisions[0].source == osScripted and decisions[1].source == osScripted,
    "both seats are scripted")
  check(client.batchStarts.len == before,
    "no batch is opened when every seat is scripted")

echo "--- one batch carries every open seat, and the inter-batch floor holds"
block:
  ## `decideAll` opens AT MOST ONE batch per beat, and that batch carries
  ## every open seat: it is never one request per seat in sequence, which is
  ## what blows the 720 s play budget.
  let client = newLlmClient(config())
  var sim = initSim(config())
  for beat in 0 .. 2:
    discard client.decideAll(sim, @[0, 1], @["a", "b"], @[skNone, skNone])
  if client.disabled:
    check(client.batchStarts.len == 0,
      "a disabled client opens no batches at all")
  else:
    check(client.batchStarts.len == 3, "one batch per beat, not one per seat")
    for index in 1 ..< client.batchStarts.len:
      check(client.batchStarts[index] - client.batchStarts[index - 1] >=
        sim.config.minBeatSeconds.float - 0.25,
        "consecutive batch starts are >= minBeatSeconds apart")

echo "--- the paced wait is the sidecar rate limit, stated"
block:
  ## The Bedrock sidecar caps 30 requests/minute PER EPISODE (the raid
  ## learning). Two seats per batch against a 5 s floor is 24 req/min.
  let cfg = config()
  check(60 div cfg.minBeatSeconds * Seats <= 30,
    "2 seats per batch at the minBeatSeconds floor stays under 30 req/min")
  let client = newLlmClient(cfg)
  check(client.pacedWait(epochTime()) == 0.0,
    "the first batch of an episode never waits")
  client.lastBatchAt = epochTime()
  let wait = client.pacedWait(epochTime())
  check(wait > 0.0 and wait <= cfg.minBeatSeconds.float + 0.01,
    "a second batch waits out the floor, got " & $wait)

echo "--- the wall-clock budget is inside 60% of episodeTimeoutSeconds"
block:
  let cfg = config()
  check(cfg.playDeadlineSeconds() == 720.0,
    "the play deadline is 720 s at the default 1200 s timeout")
  var worst = defaultGameConfig()
  check((worst.maxBeats * worst.worstCaseBeatSeconds()).float <=
    worst.playDeadlineSeconds(),
    "24 beats x (12 s batch + 12 s retry) = 576 s fits inside 720 s")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_llm OK"
