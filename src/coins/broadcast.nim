## The broadcast chrome frame — `buildStateJson`.
##
## Forked from `coworld-ctf/src/ctf/broadcast.nim`: `BroadcastTracker` +
## `buildStateJson` keep their SHAPE and their KEY NAMES, because
## `chrome_common.js` is copied byte-for-byte and its clock, transport,
## scrubber, beat markers, lull spans, momentum curve, spoilers gate and
## endcard machinery run unmodified against exactly these keys:
##
##   t, mt, ph, pl, sp, mx, st, lp, sk, ff, en, mm, bs, pov,
##   teams, roster, events, lead, beats, lulls, over, hold
##
## `teams` carries exactly two keys, `red` (Copper) and `blue` (Cobalt) —
## the two names `chrome_common.js`'s TEAM_COLOR / TEAM_ORDER already know.
## ONE game key is added, `cn`, read only by the appended game block.

import std/[algorithm, json]
import sim_types, sim, replays

const ChromeKeys* = [
  "t", "mt", "ph", "pl", "sp", "mx", "st", "lp", "sk", "ff", "en", "mm",
  "bs", "pov", "teams", "roster", "events", "lead", "beats", "lulls",
  "over", "hold"
]

proc teamStateJson(player: ReplayPlayer, slot: int,
    frame: Frame): JsonNode =
  let indices = player.data.indices
  %*{
    "lives": frame.sc[slot],          ## the score, in the key the chrome's
                                      ## momentum/plate machinery already reads
    "score": frame.sc[slot],
    "thefts": frame.th[slot],
    "pickups": (if indices != nil: indices{"pickups"}[slot].getInt() else: 0),
    "stolenFrom": (if indices != nil: indices{"stolenFrom"}[slot].getInt()
                   else: 0),
    "policies": [player.data.policyNames[slot]]
  }

proc rosterJson(player: ReplayPlayer, frame: Frame): JsonNode =
  result = newJArray()
  for slot in 0 ..< Seats:
    result.add(%*{
      "s": slot,
      "team": TeamKeys[slot],
      "name": player.data.names[slot],
      "pol": player.data.policyNames[slot],
      "alias": player.data.names[slot],
      "colour": player.data.colours[slot],
      "score": frame.sc[slot],
      "thefts": frame.th[slot],
      "alive": true,
      "lives": 0
    })

proc recipRows(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for row in player.data.beatThefts:
    result.add(%*[row[0], row[1], row[2]])

proc truceRows(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for record in player.data.events:
    if record{"k"}.getStr() == "truce":
      result.add(%*[record{"beat"}.getInt(), record{"seat"}.getInt()])

proc leadSeries(player: ReplayPlayer): JsonNode =
  var pts = newJArray()
  for row in player.data.scoreSeries:
    pts.add(%*[row[0], row[1], row[2]])
  %*{"teams": [TeamKeys[0], TeamKeys[1]], "pts": pts}

proc lullSpansJson(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for span in player.data.lulls:
    result.add(%*[span[0], span[1]])

proc overJson(player: ReplayPlayer): JsonNode =
  ## The endcard is STATE, not an event: present on every terminal frame so a
  ## viewer who seeks straight to the end still sees the verdict.
  let results = player.data.results
  let a = results{"scores"}[0].getFloat()
  let b = results{"scores"}[1].getFloat()
  let draw = a == b
  let winner = if draw: "" else: (if a > b: TeamKeys[0] else: TeamKeys[1])
  %*{
    "winner": winner,
    "draw": draw,
    "t": player.maxTick(),
    "reason": results{"reason"}.getStr(),
    "beats": player.data.beats,
    "endBeat": player.data.endBeat,
    "scores": [a, b],
    "policies": [player.data.policyNames[0], player.data.policyNames[1]],
    "pickups": results{"pickups"},
    "thefts": results{"thefts"},
    "stolenFrom": results{"stolenFrom"},
    "restraint": results{"restraint"}
  }

proc buildStateJson*(player: ReplayPlayer, events: JsonNode,
    sendLead: bool): string =
  let frame = player.frame()
  let atEnd = player.tick >= player.maxTick()
  var teams = newJObject()
  for slot in 0 ..< Seats:
    teams[TeamKeys[slot]] = teamStateJson(player, slot, frame)
  var coinsOnBoard = 0
  var index = 0
  while index + 2 < frame.k.len:
    coinsOnBoard.inc
    index += 3
  var state = %*{
    "t": player.tick,
    "mt": player.maxTick(),
    "ph": (if atEnd: "gameover" else: "playing"),
    "pl": player.playing,
    "sp": player.speed,
    "mx": player.maxTick(),
    "st": 0,
    "lp": player.looping,
    "sk": player.skipLulls,
    "ff": player.fastForwarding,
    "en": true,
    "mm": -1,
    "bs": 1,
    "pov": -1,
    "teams": teams,
    "roster": rosterJson(player, frame),
    "events": (if events.isNil: newJArray() else: events),
    ## The Coins game key. Everything the appended game block draws — the
    ## reciprocity strip, the theft headline, the beat timeline — comes from
    ## here and from nowhere else.
    "cn": %*{
      "beat": player.beatOfTick(player.tick),
      "beats": player.data.beats,
      "endBeat": player.data.endBeat,
      "variant": player.data.variant,
      "recip": recipRows(player),
      "truce": truceRows(player),
      "coinsOnBoard": coinsOnBoard,
      "score": [frame.sc[0], frame.sc[1]],
      "thefts": [frame.th[0], frame.th[1]],
      "policies": [player.data.policyNames[0], player.data.policyNames[1]],
      "aliases": [Aliases[0], Aliases[1]],
      "colours": [$OwnColour[0], $OwnColour[1]],
      "indices": player.data.indices,
      "results": player.data.results
    }
  }
  if sendLead:
    ## Shipped WHOLE on the first HUD frame so the momentum curve draws its
    ## full width immediately (paintbot's `lead` trick), together with the
    ## lull spans and the beat timeline.
    state["lead"] = leadSeries(player)
    state["lulls"] = lullSpansJson(player)
    state["beats"] = player.data.beatsTimeline
  if atEnd:
    state["over"] = overJson(player)
    state["hold"] = %player.endHoldSecondsLeft()
  $state

proc chromeKeySet*(chrome: string): seq[string] =
  ## Used by `tests/test_viewer.nim` to assert the emitted key set.
  let node = parseJson(chrome)
  for key, value in node:
    discard value
    result.add(key)
  result.sort(cmp)

# ---------------------------------------------------------------------------
# the live spectator frame
# ---------------------------------------------------------------------------

proc liveTeamJson(sim: Sim, slot: int): JsonNode =
  %*{
    "lives": sim.cogs[slot].score,
    "score": sim.cogs[slot].score,
    "thefts": sim.cogs[slot].thefts,
    "pickups": sim.cogs[slot].pickups,
    "stolenFrom": sim.cogs[slot].stolenFrom,
    "policies": [sim.policyNames[slot]]
  }

proc liveChromeJson*(sim: Sim, events: JsonNode): string =
  ## `WS /global` carries the same chrome key set the replay does, so the
  ## live spectator page and the static bundle run one client.
  var teams = newJObject()
  for slot in 0 ..< Seats:
    teams[TeamKeys[slot]] = liveTeamJson(sim, slot)
  var roster = newJArray()
  for slot in 0 ..< Seats:
    roster.add(%*{
      "s": slot, "team": TeamKeys[slot], "name": Aliases[slot],
      "pol": sim.policyNames[slot], "alias": Aliases[slot],
      "colour": $OwnColour[slot], "score": sim.cogs[slot].score,
      "thefts": sim.cogs[slot].thefts, "alive": true, "lives": 0
    })
  var recip = newJArray()
  for row in sim.beatThefts:
    recip.add(%*[row[0], row[1], row[2]])
  let maxTick = sim.config.maxBeats * sim.config.ticksPerBeat
  var state = %*{
    "t": sim.tick, "mt": maxTick, "ph": (if sim.finished: "gameover"
                                         else: "playing"),
    "pl": true, "sp": 1, "mx": maxTick, "st": 0, "lp": false, "sk": false,
    "ff": false, "en": false, "mm": -1, "bs": 1, "pov": -1,
    "teams": teams, "roster": roster,
    "events": (if events.isNil: newJArray() else: events),
    "cn": %*{
      "beat": sim.beat, "beats": sim.beatsPlayed, "endBeat": sim.endBeat,
      "variant": sim.config.variant, "recip": recip, "truce": newJArray(),
      "coinsOnBoard": sim.coins.len,
      "score": [sim.cogs[0].score, sim.cogs[1].score],
      "thefts": [sim.cogs[0].thefts, sim.cogs[1].thefts],
      "policies": [sim.policyNames[0], sim.policyNames[1]],
      "aliases": [Aliases[0], Aliases[1]],
      "colours": [$OwnColour[0], $OwnColour[1]],
      "live": true
    }
  }
  if sim.finished:
    let wins = sim.winFlags()
    let draw = wins[0] and wins[1]
    state["over"] = %*{
      "winner": (if draw: "" elif wins[0]: TeamKeys[0] else: TeamKeys[1]),
      "draw": draw, "t": max(sim.tick - 1, 0),
      "reason": $sim.reason,
      "scores": [sim.cogs[0].score.float, sim.cogs[1].score.float],
      "policies": [sim.policyNames[0], sim.policyNames[1]]
    }
    state["hold"] = %0
  $state
