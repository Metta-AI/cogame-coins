## The event vocabulary — the replay's `events[]`.
##
## Forked from `coworld-ctf/src/ctf/events.nim`: one JSON row per event, `t`
## = tick, seats are slot integers, colours are the strings `copper` /
## `cobalt`. THIS IS THE COMPLETE VOCABULARY; nothing else is emitted, which
## is what makes "one CSS rule per beat kind" a closed assertion in
## `tests/test_viewer.nim`.

import std/json
import sim_types

const
  EventKinds* = [
    "order", "spawn", "pickup", "theft", "blocked", "truce", "leadchange",
    "beatclose", "end"
  ]
  BeatKinds* = ["theft", "truce", "leadchange", "over"]
    ## The four scrubber beat-marker kinds. Exactly these four, so the game
    ## block can carry one `.beat-marker.<kind>` CSS rule per kind and the
    ## viewer test can assert the set is closed.

type
  EventLog* = object
    records*: seq[JsonNode]

proc add*(log: var EventLog, node: JsonNode) =
  log.records.add(node)

proc len*(log: EventLog): int =
  log.records.len

proc toJson*(log: EventLog): JsonNode =
  result = newJArray()
  for record in log.records:
    result.add(record)

proc orderEvent*(t, beat, seat: int, intent: Intent, source: OrderSource,
    say, notes: string, latencyMs: int): JsonNode =
  %*{"k": "order", "t": t, "beat": beat, "seat": seat, "intent": $intent,
     "source": $source, "say": say, "notes": notes, "latencyMs": latencyMs}

proc spawnEvent*(t, x, y: int, colour: Colour): JsonNode =
  %*{"k": "spawn", "t": t, "x": x, "y": y, "colour": $colour}

proc pickupEvent*(t, seat, x, y: int, colour: Colour,
    score: array[Seats, int]): JsonNode =
  %*{"k": "pickup", "t": t, "seat": seat, "x": x, "y": y, "colour": $colour,
     "score": [score[0], score[1]]}

proc theftEvent*(t, seat, victim, x, y: int, colour: Colour, penalty: int,
    score: array[Seats, int]): JsonNode =
  %*{"k": "theft", "t": t, "seat": seat, "victim": victim, "x": x, "y": y,
     "colour": $colour, "penalty": penalty, "score": [score[0], score[1]]}

proc blockedEvent*(t, seat, x, y: int, why: BlockReason): JsonNode =
  %*{"k": "blocked", "t": t, "seat": seat, "x": x, "y": y, "why": $why}

proc truceEvent*(t, beat, seat, sinceBeat: int): JsonNode =
  %*{"k": "truce", "t": t, "beat": beat, "seat": seat,
     "sinceBeat": sinceBeat}

proc leadChangeEvent*(t, seat: int, score: array[Seats, int]): JsonNode =
  %*{"k": "leadchange", "t": t, "seat": seat, "score": [score[0], score[1]]}

proc beatCloseEvent*(t, beat: int, score, pickups,
    thefts: array[Seats, int]): JsonNode =
  %*{"k": "beatclose", "t": t, "beat": beat,
     "score": [score[0], score[1]],
     "pickups": [pickups[0], pickups[1]],
     "thefts": [thefts[0], thefts[1]]}

proc endEvent*(t, beat: int, reason: EndReason,
    score: array[Seats, int]): JsonNode =
  %*{"k": "end", "t": t, "beat": beat, "reason": $reason,
     "score": [score[0], score[1]]}
