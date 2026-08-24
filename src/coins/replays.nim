## The replay file (`coins.replay.v1`) — writer, parser and playhead.
##
## Rewritten rather than forked: Coins records **state frames**, not inputs,
## so playback never re-simulates and a seek is an array index. That is why
## there is no replay-hash mismatch mode, no `--mismatch-quit` and no
## `#mmwarn` in the viewer.
##
## Strict UTF-8 JSON, one document. Everything the viewer needs — aliases,
## POLICY names, colours, the variant, the whole config, the seed, the room,
## per-tick state, the beat and end-beat, both series, the index summary,
## every event and the full `results` object — is in the file, so the viewer
## contacts no server except S3 for the `.replay` bytes.

import std/[json, math, strutils]
import sim_types, sim_config, sim, indices, room

const ReplayProtocol* = "coins.replay.v1"

type
  ReplayData* = object
    protocol*: string
    seed*: int
    variant*: string
    names*: seq[string]
    policyNames*: seq[string]
    colours*: seq[string]
    config*: GameConfig
    configJson*: JsonNode
    walls*: seq[string]
    beats*: int
    endBeat*: int
    ticksPlayed*: int
    frames*: seq[Frame]
    scoreSeries*: seq[array[3, int]]
    beatThefts*: seq[array[3, int]]
    indices*: JsonNode
    events*: JsonNode
    results*: JsonNode
    lulls*: seq[array[2, int]]
    beatsTimeline*: JsonNode

proc framesJson(sim: Sim): JsonNode =
  result = newJArray()
  for frame in sim.frames:
    var c = newJArray()
    for value in frame.c: c.add(%value)
    var k = newJArray()
    for value in frame.k: k.add(%value)
    result.add(%*{
      "t": frame.t, "c": c, "k": k,
      "sc": [frame.sc[0], frame.sc[1]],
      "th": [frame.th[0], frame.th[1]]
    })

proc seriesJson(sim: Sim): JsonNode =
  var score = newJArray()
  for row in sim.scoreSeries:
    score.add(%*[row[0], row[1], row[2]])
  var thefts = newJArray()
  for row in sim.beatThefts:
    thefts.add(%*[row[0], row[1], row[2]])
  %*{"score": score, "beatThefts": thefts}

proc indicesJson(sim: Sim): JsonNode =
  %*{
    "pickups": [sim.cogs[0].pickups, sim.cogs[1].pickups],
    "thefts": [sim.cogs[0].thefts, sim.cogs[1].thefts],
    "stolenFrom": [sim.cogs[0].stolenFrom, sim.cogs[1].stolenFrom],
    "restraint": [restraintOf(sim.cogs[0].pickups, sim.cogs[0].thefts),
                  restraintOf(sim.cogs[1].pickups, sim.cogs[1].thefts)],
    "firstTheftBeat": [beatOrNull(sim.firstTheftBeat[0]),
                       beatOrNull(sim.firstTheftBeat[1])],
    "reciprocityLagBeats": [reciprocityLag(sim.firstTheftBeat, 0),
                            reciprocityLag(sim.firstTheftBeat, 1)]
  }

proc replayJson*(sim: Sim): JsonNode =
  var lulls = newJArray()
  for span in sim.lullSpans():
    lulls.add(%*[span[0], span[1]])
  %*{
    "protocol": ReplayProtocol,
    "game": "coins",
    "gameVersion": GameVersion,
    "variant": sim.config.variant,
    "seed": sim.seed,
    "names": [Aliases[0], Aliases[1]],
    "policyNames": [sim.policyNames[0], sim.policyNames[1]],
    "colours": [$OwnColour[0], $OwnColour[1]],
    "config": sim.config.configJson(),
    "room": {"w": RoomW, "h": RoomH, "walls": roomWalls()},
    "beats": sim.beatsPlayed,
    "endBeat": sim.endBeat,
    "ticksPlayed": sim.tick,
    "frames": framesJson(sim),
    "series": seriesJson(sim),
    "indices": indicesJson(sim),
    "lulls": lulls,
    "beatsTimeline": sim.beatsTimeline(),
    "events": sim.events.toJson(),
    "results": sim.resultsJson()
  }

proc replayBytes*(sim: Sim): string =
  $replayJson(sim)

# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------

proc parseReplayBytes*(data: string): ReplayData =
  let node = parseJson(data)
  if node.kind != JObject:
    raise newException(CoinsError, "replay must be a JSON object")
  result.protocol = node{"protocol"}.getStr()
  if result.protocol != ReplayProtocol:
    raise newException(CoinsError,
      "unexpected replay protocol: " & result.protocol)
  result.seed = node{"seed"}.getInt()
  result.variant = node{"variant"}.getStr("standard")
  for value in node{"names"}: result.names.add(value.getStr())
  for value in node{"policyNames"}: result.policyNames.add(value.getStr())
  for value in node{"colours"}: result.colours.add(value.getStr())
  result.configJson = node{"config"}
  result.config = defaultGameConfig()
  if result.configJson != nil and result.configJson.kind == JObject:
    var overlay = newJObject()
    for key, value in result.configJson:
      if key == "fps": continue
      overlay[key] = value
    overlay["seed"] = %result.seed
    result.config.update($overlay)
  let room = node{"room"}
  if room != nil:
    for value in room{"walls"}: result.walls.add(value.getStr())
  result.beats = node{"beats"}.getInt()
  result.endBeat = node{"endBeat"}.getInt()
  result.ticksPlayed = node{"ticksPlayed"}.getInt()
  for entry in node{"frames"}:
    var frame = Frame(t: entry{"t"}.getInt())
    for value in entry{"c"}: frame.c.add(value.getInt())
    for value in entry{"k"}: frame.k.add(value.getInt())
    let sc = entry{"sc"}
    let th = entry{"th"}
    for slot in 0 ..< Seats:
      frame.sc[slot] = sc[slot].getInt()
      frame.th[slot] = th[slot].getInt()
    result.frames.add(frame)
  let series = node{"series"}
  if series != nil:
    for row in series{"score"}:
      result.scoreSeries.add([row[0].getInt(), row[1].getInt(),
        row[2].getInt()])
    for row in series{"beatThefts"}:
      result.beatThefts.add([row[0].getInt(), row[1].getInt(),
        row[2].getInt()])
  result.indices = node{"indices"}
  result.events = node{"events"}
  if result.events == nil: result.events = newJArray()
  result.results = node{"results"}
  if result.results == nil: result.results = newJObject()
  for row in node{"lulls"}:
    result.lulls.add([row[0].getInt(), row[1].getInt()])
  result.beatsTimeline = node{"beatsTimeline"}
  if result.beatsTimeline == nil: result.beatsTimeline = newJArray()
  if result.frames.len == 0:
    raise newException(CoinsError, "replay carries no frames")

# ---------------------------------------------------------------------------
# the playhead
# ---------------------------------------------------------------------------

type
  ReplayPlayer* = object
    data*: ReplayData
    tick*: int
    playing*: bool
    speed*: int
    looping*: bool
    skipLulls*: bool
    fastForwarding*: bool
    endHoldFrames*: int
    leadSent*: bool
    pendingEvents*: JsonNode
    eventsByTick*: seq[JsonNode]

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.tick = 0
  result.playing = true
  result.speed = 1
  result.looping = true
  result.pendingEvents = newJArray()
  result.eventsByTick = newSeq[JsonNode](max(data.frames.len, 1))
  for index in 0 ..< result.eventsByTick.len:
    result.eventsByTick[index] = newJArray()
  for record in data.events:
    let t = record{"t"}.getInt()
    if t >= 0 and t < result.eventsByTick.len:
      result.eventsByTick[t].add(record)

proc maxTick*(player: ReplayPlayer): int =
  max(player.data.frames.len - 1, 0)

proc isLullTick*(player: ReplayPlayer, tick: int): bool =
  for span in player.data.lulls:
    if tick >= span[0] and tick <= span[1]:
      return true
  false

proc collect(player: var ReplayPlayer, tick: int) =
  if tick >= 0 and tick < player.eventsByTick.len:
    for record in player.eventsByTick[tick]:
      player.pendingEvents.add(record)

proc seek*(player: var ReplayPlayer, tick: int) =
  player.tick = clamp(tick, 0, player.maxTick())
  player.pendingEvents = newJArray()
  player.endHoldFrames = 0
  player.collect(player.tick)

proc applyCommand*(player: var ReplayPlayer, command: char) =
  ## The transport vocabulary the starter's chrome sends.
  case command
  of ' ': player.playing = not player.playing
  of ',': player.seek(0); player.playing = true
  of 'b': player.seek(max(player.tick - 1, 0)); player.playing = false
  of '.': player.seek(player.tick + 5 * TargetFps)
  of 'e': player.seek(player.maxTick()); player.playing = false
  of 'r': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  of '+': player.speed = min(player.speed * 2, 16)
  of '-': player.speed = max(player.speed div 2, 1)
  of '1': player.speed = 1
  of '2': player.speed = 2
  of '3': player.speed = 3
  of '4': player.speed = 4
  of '8': player.speed = 8
  of '6': player.speed = 16
  else: discard

proc advance*(player: var ReplayPlayer) =
  ## One presentation frame. Returns with `pendingEvents` holding everything
  ## crossed since the last call.
  player.pendingEvents = newJArray()
  player.fastForwarding = false
  if not player.playing:
    return
  if player.tick >= player.maxTick():
    ## End hold, then loop (or stop).
    player.endHoldFrames.inc
    if player.looping and player.endHoldFrames > 3 * TargetFps:
      player.endHoldFrames = 0
      player.seek(0)
    return
  var steps = player.speed
  if player.skipLulls and player.isLullTick(player.tick):
    steps = min(player.speed * 8, 64)
    player.fastForwarding = true
  for _ in 0 ..< steps:
    if player.tick >= player.maxTick():
      break
    player.tick.inc
    player.collect(player.tick)

proc endHoldSecondsLeft*(player: ReplayPlayer): int =
  if player.tick < player.maxTick() or not player.looping:
    return 0
  max(0, 3 - player.endHoldFrames div TargetFps)

proc frame*(player: ReplayPlayer): Frame =
  player.data.frames[clamp(player.tick, 0, player.data.frames.high)]

proc beatOfTick*(player: ReplayPlayer, tick: int): int =
  let perBeat = max(player.data.config.ticksPerBeat, 1)
  min(tick div perBeat + 1, max(player.data.beats, 1))
