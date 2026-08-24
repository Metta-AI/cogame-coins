## The Coins game server: the Coworld game contract over mummy.
##
## Forked from `coworld-ctf/src/ctf/server.nim`'s route/artifact/shutdown
## skeleton; the player protocol is bullwhip's JSON frames. Hosted
## certification probes exactly these routes BEFORE the player pods start
## (the lantern learning), so all of them answer from process start:
##
##   GET /healthz                    200 ok
##   GET /client/player?slot&token   the seat's HTML shell (never opens the
##                                   player websocket)
##   GET /client/global              the broadcast client
##   GET /client/<asset>             chrome_common.js, broadcast_core.js, art
##   WS  /player?slot=N&token=T      the seat socket
##   WS  /global                     live spectator: the sprite protocol plus
##                                   the chrome TextMessage
##
## Both `/client/` routes are registered BEFORE any catch-all asset route.
##
## Decisions are made HERE, not in the player container: the Bedrock sidecar
## credentials and the `anthropic_api_key` secret are injected into the GAME
## pod, and "one parallel batch per beat" is a game-server property.

import std/[json, locks, os, sets, strutils, tables, times, unicode]
import bitworld/runtime
import bitworld/spriteprotocol
import curly
import mummy
import mummy/routers
import sim_types, sim, scripted, llm, broadcast, global, replays

const
  PlayerProtocol = "coins.player.v1"
  DoneBroadcastSeconds = 3.0

type
  ServerState = object
    prompts: seq[string]
    scripted: seq[ScriptKind]
    policies: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    globalViewers: Table[WebSocket, ViewerState]
    seats: int
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  gameServer: Server
  clientRoot: string
  runtimeCfg: RuntimeConfig

initLock(stateLock)

proc clientDir(): string =
  if clientRoot.len > 0:
    return clientRoot
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      clientRoot = candidate
      return clientRoot
  clientRoot = "client"
  clientRoot

# ---------------------------------------------------------------------------
# artifacts
# ---------------------------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc declarePlayerFailure(slot: int, message: string) =
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "coins: player-failure declaration failed: ", error.msg

# ---------------------------------------------------------------------------
# broadcasting
# ---------------------------------------------------------------------------

proc pushGlobalLocked(events: JsonNode) =
  ## The board rides as a binary sprite packet, the chrome as a text frame —
  ## exactly what `client/broadcast_core.js` expects on either transport.
  if shared.globalSockets.len == 0:
    return
  let frame = gameSim.currentFrame()
  let chrome = liveChromeJson(gameSim, events)
  for socket in shared.globalSockets:
    var viewer = shared.globalViewers.getOrDefault(socket, initViewerState())
    var packet = buildBoardPacket(frame, viewer, events)
    packet.addChrome(chrome)
    shared.globalViewers[socket] = viewer
    try:
      socket.send(blobFromBytes(packet), BinaryMessage)
    except CatchableError:
      discard

proc pushStateFrames() =
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= Seats:
      continue
    try:
      socket.send($gameSim.buildObservation(slot))
    except CatchableError:
      discard

proc broadcastFinal(results: JsonNode) =
  let scores = results{"scores"}
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += DoneBroadcastSeconds
    if epochTime() > allowance:
      echo "coins: final broadcast past budget; skipping slot ", slot
      continue
    try:
      socket.send($ %*{
        "type": "final", "done": true, "slot": slot, "scores": scores,
        "names": [Aliases[0], Aliases[1]],
        "beats": gameSim.beatsPlayed, "reason": $gameSim.reason
      })
    except CatchableError as error:
      echo "coins: final frame to slot ", slot, " failed: ", error.msg

proc finishEpisode() =
  ## Shutdown order (bullwhip's `finishEpisode` plus lantern's grace):
  ## final frames -> last global frame -> 500 ms -> results.json -> the
  ## replay -> keep /healthz and /global answering for
  ## `shutdownGraceSeconds` -> quit(0).
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = gameSim.resultsJson()
    replayData = replayBytes(gameSim)
    broadcastFinal(results)
    pushGlobalLocked(newJArray())
  sleep(500)
  echo "coins: writing results and replay (", replayData.len, " bytes)"
  writeArtifact(runtimeCfg.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeCfg.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  echo "coins: episode complete (", gameSim.reason, ") after ",
    gameSim.tick, " ticks, ", gameSim.beatsPlayed, " beats, score ",
    gameSim.cogs[0].score, "-", gameSim.cogs[1].score

# ---------------------------------------------------------------------------
# the episode thread
# ---------------------------------------------------------------------------

proc runGame(cfg: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let connectDeadline =
      gameStart + config.playerConnectTimeoutSeconds.float
    while epochTime() < connectDeadline:
      var connected = 0
      withLock stateLock:
        connected = shared.playerSockets.len
      if connected >= shared.seats:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its prompt frame.
    let registerDeadline = min(epochTime() + 3.0, connectDeadline + 3.0)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var connectedCount = 0
    var noShow = -1
    withLock stateLock:
      connectedCount = shared.playerSockets.len
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## A seat that never connects does not end the episode: it plays
          ## `reciprocator` for every remaining beat.
          shared.scripted[slot] = skReciprocator
        gameSim.policyKinds[slot] =
          if shared.scripted[slot] != skNone: "scripted" else: "llm"
        if shared.policies[slot].len > 0:
          gameSim.policyNames[slot] = shared.policies[slot]
      echo "coins: starting with ", connectedCount, "/", shared.seats,
        " players connected"

    if connectedCount == 0:
      ## `forfeit` is reserved for the case where NEITHER seat connected.
      withLock stateLock:
        for slot in 0 ..< Seats:
          gameSim.cogs[slot].score = 0
      gameSim.endEpisode(erForfeit)
      declarePlayerFailure(0, "no seat connected within " &
        $config.playerConnectTimeoutSeconds & "s")
      finishEpisode()
      sleep(config.shutdownGraceSeconds * 1000)
      quit(0)
    if noShow >= 0:
      declarePlayerFailure(noShow, "player slot " & $noShow &
        " never registered; the seat played the reciprocator baseline")

    let client = newLlmClient(config)

    proc now(): float {.closure.} = epochTime() - gameStart

    proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
      var prompts: seq[string]
      var kinds: seq[ScriptKind]
      withLock stateLock:
        prompts = shared.prompts
        kinds = shared.scripted
        for slot in 0 ..< Seats:
          if not shared.playerSockets.hasKey(slot) and
              kinds[slot] == skNone:
            ## Disconnected mid-episode: play the reciprocator baseline for
            ## every remaining beat. The episode never waits on it.
            kinds[slot] = skReciprocator
      client.decideAll(view, seats, prompts, kinds,
        proc (seconds: float) {.closure.} = sleep(int(seconds * 1000.0)))

    proc onBeat(view: Sim) {.closure.} =
      withLock stateLock:
        pushStateFrames()
        pushGlobalLocked(newJArray())
      echo "coins: beat ", view.beatsPlayed, " tick ", view.tick,
        " score ", view.cogs[0].score, "-", view.cogs[1].score,
        " thefts ", view.cogs[0].thefts, "/", view.cogs[1].thefts,
        " at ", int(now()), "s"

    runEpisode(gameSim, decide, now, onBeat)
    withLock stateLock:
      pushStateFrames()
    finishEpisode()
    ## Hosted certification pings the global websocket AFTER the player pods
    ## start, so keep answering for a bounded grace before exiting.
    echo "coins: holding /healthz and /global for ",
      config.shutdownGraceSeconds, "s"
    sleep(config.shutdownGraceSeconds * 1000)
    quit(0)

var gameThread: Thread[RuntimeConfig]

# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------

proc contentTypeFor(name: string): string =
  if name.endsWith(".js"): "application/javascript; charset=utf-8"
  elif name.endsWith(".css"): "text/css; charset=utf-8"
  elif name.endsWith(".html"): "text/html; charset=utf-8"
  elif name.endsWith(".png"): "image/png"
  elif name.endsWith(".jpg"): "image/jpeg"
  elif name.endsWith(".webp"): "image/webp"
  elif name.endsWith(".ttf"): "font/ttf"
  else: "application/octet-stream"

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

const PlayerPage = staticRead("../../client/player.html")

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## The seat's HTML shell. It NEVER opens the player websocket — the
  ## certifier fetches this before the player pods start.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, PlayerPage)

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "replay_broadcast.html",
      "text/html; charset=utf-8")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    serveFile(request, clientDir() / name, contentTypeFor(name))

proc clientArtHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let dir = request.pathParams["dir"]
    let name = request.pathParams["name"]
    for part in [dir, name]:
      if "/" in part or "\\" in part or part.startsWith("."):
        request.respond(404)
        return
    serveFile(request, clientDir() / "art" / dir / name, contentTypeFor(name))

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var slot = -1
    try:
      slot = parseInt(request.queryParams["slot"])
    except ValueError:
      discard
    let token = request.queryParams["token"]
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      ## A bad token is refused, never left hanging.
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "coins: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": PlayerProtocol, "slot": slot,
        "alias": Aliases[slot], "colour": $OwnColour[slot],
        "opponent": Aliases[otherSlot(slot)],
        "ticksPerBeat": gameSim.config.ticksPerBeat,
        "minBeats": gameSim.config.minBeats,
        "maxBeats": gameSim.config.maxBeats
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      shared.globalViewers[websocket] = initViewerState()
      pushGlobalLocked(newJArray())

proc handleRegister(slot: int, payload: JsonNode) =
  var prompt = payload{"prompt"}.getStr()
  if prompt.runeLen > MaxPromptRunes:
    prompt = prompt.runeSubStr(0, MaxPromptRunes)
  let node = payload{"scripted"}
  var kind =
    if node == nil or node.kind == JNull: skNone
    elif node.kind == JBool: (if node.getBool(): skReciprocator else: skNone)
    else: parseScriptKind(node.getStr())
  if prompt.strip().len == 0 and kind == skNone:
    ## Registered with neither field: play the default baseline.
    kind = skReciprocator
  var policy = payload{"policy"}.getStr()
  if policy.runeLen > MaxPolicyLabelRunes:
    policy = policy.runeSubStr(0, MaxPolicyLabelRunes)
  withLock stateLock:
    shared.prompts[slot] = prompt
    shared.scripted[slot] = kind
    if policy.len > 0:
      shared.policies[slot] = policy
    shared.registered[slot] = true
    shared.everRegistered[slot] = true
  echo "coins: slot ", slot, " registered (", prompt.len, " prompt chars",
    (if kind != skNone: ", scripted " & $kind else: ", llm"), ")"

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind == BinaryMessage:
        withLock stateLock:
          if websocket in shared.globalViewers:
            var viewer = shared.globalViewers[websocket]
            viewer.applyGlobalViewerMessage(message.data)
            shared.globalViewers[websocket] = viewer
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() != "prompt":
          echo "coins: ignoring player frame of type ",
            payload{"type"}.getStr()
          return
        handleRegister(slot, payload)
      except CatchableError as error:
        echo "coins: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
        shared.globalSockets.excl(websocket)
        shared.globalViewers.del(websocket)

proc buildRouter(): Router =
  ## Both `/client/` routes are registered BEFORE the catch-all asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/art/@dir/@name", clientArtHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, cfg: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(CoinsError, "tokens must name exactly num_agents seats")
  runtimeCfg = cfg
  gameSim = initSim(config)
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scripted = newSeq[ScriptKind](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    shared.policies[slot] = Aliases[slot]
  let router = buildRouter()
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, cfg)
  echo "coins: serving on ", cfg.host, ":", cfg.port
  gameServer.serve(Port(cfg.port), cfg.host)
