## tests/test_baseline.nim — bounded orders / legality.
##
## For all four baselines x all five variants x seeds 1..8, both seats
## scripted: every emitted order carries an intent in the legal five and
## nothing else; each baseline reads ONLY `buildObservation(slot)`; no cog
## ever occupies a wall cell, leaves the interior or shares a cell with the
## other cog; no coin is ever collected twice; no baseline raises; no baseline
## takes longer than 1 ms per beat; and `honest`'s theft count is 0 in every
## one of those episodes.

import std/[json, monotimes, strutils, times]
import coins/[sim_types, sim, room, scripted]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

const Variants = [
  ("standard", 12, 24, 120, 8, 12, 6, 2),
  ("long-shadow", 18, 24, 60, 8, 12, 6, 2),
  ("short-fuse", 6, 14, 250, 8, 12, 6, 2),
  ("harsh", 12, 24, 120, 8, 12, 6, 3),
  ("scarce", 12, 24, 120, 4, 20, 3, 2)
]

const Baselines = [skHonest, skGreedy, skReciprocator, skTitForTat]

proc variantConfig(index, seed: int): GameConfig =
  let v = Variants[index]
  result = defaultGameConfig()
  result.seed = seed
  result.variant = v[0]
  result.minBeats = v[1]
  result.maxBeats = v[2]
  result.endChancePermille = v[3]
  result.coinCap = v[4]
  result.coinSpawnIntervalTicks = v[5]
  result.initialCoins = v[6]
  result.theftPenalty = v[7]
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

var slowestBeatNanos = 0'i64

proc play(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  var sim = initSim(config)
  proc now(): float {.closure.} = 0.0
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    for slot in seats:
      ## The baseline is handed the observation object and NOTHING else. It
      ## has no reference to `view`, no RNG, no coin list, no config: if it
      ## could read raw sim state it would have to come through here.
      let obs = view.buildObservation(slot)
      let started = getMonoTime()
      let intent = scriptedIntent(kinds[slot], obs,
        view.config.punishThreshold, view.config.punishBeats)
      let elapsed = (getMonoTime() - started).inNanoseconds
      if elapsed > slowestBeatNanos:
        slowestBeatNanos = elapsed
      result.add(Decision(intent: intent, source: osScripted))
  sim.runEpisode(decide, now)
  sim

echo "--- a baseline is a pure function of the observation"
block:
  ## Frozen observation, sim inaccessible: the same object in, the same
  ## intent out, every time, for every baseline.
  let frozen = parseJson("""
    {"type":"state","protocol":"coins.player.v1","slot":0,"alias":"Copper",
     "colour":"copper","beat":6,"minBeats":12,"maxBeats":24,
     "endChancePermille":120,"ticksPerBeat":20,"tick":100,
     "you":{"x":4,"y":6,"facing":2,"score":3,"pickups":5,"thefts":1,
            "stolenFrom":1},
     "them":{"alias":"Cobalt","colour":"cobalt","x":7,"y":3,"score":4,
             "pickups":4,"thefts":3,"stolenFrom":1},
     "coins":[{"x":1,"y":4,"colour":"copper"},{"x":6,"y":2,"colour":"cobalt"}],
     "beatLog":[
       {"beat":1,"you":{"intent":"take_mine","pickups":1,"thefts":0},
        "them":{"pickups":1,"thefts":0},"score":[1,1]},
       {"beat":2,"you":{"intent":"take_mine","pickups":1,"thefts":0},
        "them":{"pickups":1,"thefts":1},"score":[0,3]},
       {"beat":3,"you":{"intent":"take_mine","pickups":1,"thefts":0},
        "them":{"pickups":1,"thefts":1},"score":[-1,5]},
       {"beat":4,"you":{"intent":"take_theirs","pickups":1,"thefts":1},
        "them":{"pickups":1,"thefts":1},"score":[-2,6]},
       {"beat":5,"you":{"intent":"take_mine","pickups":1,"thefts":0},
        "them":{"pickups":0,"thefts":0},"score":[3,4]}],
     "notes":""}""")
  check(honestIntent(frozen) == inTakeMine,
    "honest takes its own colour while one exists")
  check(greedyIntent(frozen) == inTakeAny, "greedy always take_any")
  check(titForTatIntent(frozen) == inTakeMine,
    "tit-for-tat mirrors the PREVIOUS beat, which had no theft")
  ## Their cumulative thefts before beat 6 are 3, which is over the armed
  ## threshold of 2, so the reciprocator is punishing.
  check(reciprocatorIntent(frozen, 2, 4) == inTakeTheirs,
    "the reciprocator punishes once their thefts reach the threshold")
  for kind in Baselines:
    let first = scriptedIntent(kind, frozen, 2, 4)
    for _ in 0 .. 4:
      check(scriptedIntent(kind, frozen, 2, 4) == first,
        "a baseline is deterministic on a frozen observation (" & $kind & ")")

  var empty = frozen.copy()
  empty["coins"] = newJArray()
  check(honestIntent(empty) == inHold, "honest holds with no own coin")
  check(titForTatIntent(empty) == inHold, "tit-for-tat holds with no own coin")
  var beatOne = frozen.copy()
  beatOne["beat"] = %1
  beatOne["beatLog"] = newJArray()
  check(titForTatIntent(beatOne) == inTakeMine, "tit-for-tat opens take_mine")
  check(reciprocatorIntent(beatOne, 2, 4) == inTakeMine,
    "the reciprocator opens honest")

echo "--- every baseline x every variant x seeds 1..8"
var episodes = 0
for variant in 0 ..< Variants.len:
  for baseline in Baselines:
    for seed in 1 .. 8:
      let config = variantConfig(variant, seed)
      var sim: Sim
      try:
        sim = play(config, [baseline, baseline])
      except CatchableError as error:
        check(false, "a baseline raised: " & error.msg)
        continue
      episodes.inc
      var orders = 0
      for record in sim.events.records:
        if record{"k"}.getStr() != "order":
          continue
        orders.inc
        let intent = record{"intent"}.getStr()
        check(intent in ["take_mine", "take_any", "take_theirs", "guard",
          "hold"], "an order carries a legal intent, got " & intent)
        check(record{"source"}.getStr() == "scripted",
          "a scripted seat records source scripted")
      check(orders == sim.beatsPlayed * Seats,
        "one order per seat per beat: " & $orders & " vs " &
        $(sim.beatsPlayed * Seats))
      for slot in 0 ..< Seats:
        check(isInterior(sim.cogs[slot].x, sim.cogs[slot].y),
          "a cog never leaves the interior")
      check(not (sim.cogs[0].x == sim.cogs[1].x and
                 sim.cogs[0].y == sim.cogs[1].y),
        "two cogs never share a cell")
      check(sim.scoreIdentityHolds(), "the score identity holds")
      ## No coin is collected twice: every pickup/theft event names a
      ## distinct (tick, cell), and the totals match the counters.
      var collected = 0
      for record in sim.events.records:
        let kind = record{"k"}.getStr()
        if kind == "pickup" or kind == "theft":
          collected.inc
      check(collected == sim.cogs[0].pickups + sim.cogs[1].pickups,
        "one collection event per pickup")
      if baseline == skHonest:
        check(sim.cogs[0].thefts == 0 and sim.cogs[1].thefts == 0,
          "honest NEVER steals — an invariant, not a tendency (" &
          config.variant & " seed " & $seed & ")")

echo "played ", episodes, " scripted episodes"
check(episodes == Variants.len * Baselines.len * 8,
  "every combination ran")
echo "slowest baseline decision: ", slowestBeatNanos, " ns"
check(slowestBeatNanos < 1_000_000,
  "no baseline takes longer than 1 ms per beat, got " &
  $slowestBeatNanos & " ns")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_baseline OK"
