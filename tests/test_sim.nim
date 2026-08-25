## tests/test_sim.nim — the sim units.
##
## The scoring formula in both directions, the score identity, every movement
## rule, the coin spawn cadence and cap, the five intents' target selection
## and tie-breaks, the truce rule, the random end, and determinism.

import std/json
import coins/[sim_types, sim, room, kernel, scripted]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

proc fixture(seed = 1, minB = 4, maxB = 4): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.minBeats = minB
  result.maxBeats = maxB
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

proc quietFixture(seed = 1): GameConfig =
  ## No opening coins and no spawns: the micro-tests place their own coins so
  ## a rule can be observed in isolation.
  result = fixture(seed)
  result.initialCoins = 0
  result.coinSpawnIntervalTicks = 100_000

proc runScripted(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  var sim = initSim(config)
  proc now(): float {.closure.} = 0.0
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    for slot in seats:
      result.add(Decision(
        intent: scriptedIntent(kinds[slot], view.buildObservation(slot),
          view.config.punishThreshold, view.config.punishBeats),
        source: osScripted))
  sim.runEpisode(decide, now)
  sim

proc hasEvent(sim: Sim, kind, field, value: string): bool =
  for record in sim.events.records:
    if record{"k"}.getStr() == kind and record{field}.getStr() == value:
      return true
  false

# ---------------------------------------------------------------------------
echo "--- the room"
check(isWall(0, 0) and isWall(8, 8) and isWall(4, 0), "the ring is wall")
check(isInterior(1, 1) and isInterior(7, 7) and isInterior(4, 4),
  "the interior is walkable")
check(not isInterior(0, 4) and not isInterior(8, 4), "walls are not interior")
block:
  var count = 0
  for cell in interiorCells():
    count.inc
  check(count == 49, "49 interior cells, got " & $count)

# ---------------------------------------------------------------------------
echo "--- scoring, both directions, including a negative score"
block:
  var sim = initSim(quietFixture())
  sim.coins = @[Coin(x: 3, y: 4, colour: ccCopper)]
  sim.cogs[0].x = 3
  sim.cogs[0].y = 3
  sim.cogs[1].x = 7
  sim.cogs[1].y = 7
  sim.cogs[0].intent = inTakeMine
  sim.cogs[1].intent = inHold
  for _ in 0 .. 8:
    sim.stepTick()
  check(sim.cogs[0].score == 1, "own pickup is +1, got " & $sim.cogs[0].score)
  check(sim.cogs[1].score == 0, "the other cog is untouched by an own pickup")
  check(sim.cogs[0].pickups == 1 and sim.cogs[0].thefts == 0, "counters")
  check(sim.hasEvent("pickup", "colour", "copper"), "a pickup event fires")

block:
  var sim = initSim(quietFixture())
  sim.coins = @[Coin(x: 3, y: 4, colour: ccCobalt)]
  sim.cogs[0].x = 3
  sim.cogs[0].y = 3
  sim.cogs[1].x = 7
  sim.cogs[1].y = 7
  sim.cogs[0].intent = inTakeTheirs
  sim.cogs[1].intent = inHold
  for _ in 0 .. 8:
    sim.stepTick()
  check(sim.cogs[0].score == 1, "the thief keeps its +1")
  check(sim.cogs[1].score == -2,
    "the victim loses theftPenalty and goes NEGATIVE, got " &
    $sim.cogs[1].score)
  check(sim.cogs[0].thefts == 1 and sim.cogs[1].stolenFrom == 1,
    "theft counters")
  check(sim.scoreIdentityHolds(), "the score identity holds after a theft")
  check(sim.hasEvent("theft", "colour", "cobalt"), "a theft event fires")

# ---------------------------------------------------------------------------
echo "--- the score identity after a full 480-tick episode"
block:
  let sim = runScripted(fixture(seed = 5, minB = 24, maxB = 24),
    [skGreedy, skGreedy])
  check(sim.tick == 480, "480 ticks at 24 beats, got " & $sim.tick)
  check(sim.scoreIdentityHolds(), "score == pickups - 2 * stolenFrom")

# ---------------------------------------------------------------------------
echo "--- movement rules"
block:
  ## Walls and out-of-bounds are rejected, and take_any with an empty board
  ## parks at the room centre rather than wandering.
  var sim = initSim(quietFixture())
  sim.cogs[0].x = 1
  sim.cogs[0].y = 1
  sim.cogs[1].x = 7
  sim.cogs[1].y = 7
  sim.cogs[0].intent = inTakeAny
  sim.cogs[1].intent = inHold
  for _ in 0 .. 80:
    sim.stepTick()
    check(isInterior(sim.cogs[0].x, sim.cogs[0].y), "cog 0 stays interior")
    check(isInterior(sim.cogs[1].x, sim.cogs[1].y), "cog 1 stays interior")
  check(sim.cogs[0].x == 4 and sim.cogs[0].y == 4,
    "take_any parks at the centre, got " & $sim.cogs[0].x & "," &
    $sim.cogs[0].y)
  check(sim.cogs[1].x == 7 and sim.cogs[1].y == 7, "hold never moves")

block:
  ## No follow-through: a cog never steps into the cell the other occupied at
  ## the START of the tick, and the sidestep still gets it moving.
  var sim = initSim(quietFixture())
  sim.coins = @[Coin(x: 5, y: 4, colour: ccCopper)]
  sim.cogs[0].x = 3
  sim.cogs[0].y = 4
  sim.cogs[1].x = 4
  sim.cogs[1].y = 4
  sim.cogs[0].intent = inTakeMine
  sim.cogs[1].intent = inHold
  sim.stepTick()
  check(not (sim.cogs[0].x == 4 and sim.cogs[0].y == 4),
    "the occupied cell is never entered")
  check(sim.cogs[1].x == 4 and sim.cogs[1].y == 4, "the holder is undisturbed")
  check(sim.cogs[0].x != 3 or sim.cogs[0].y != 4,
    "the blocked cog sidesteps rather than deadlocking")

block:
  ## Boxed in on every side: the cog waits and emits blocked/occupied.
  var sim = initSim(quietFixture())
  sim.coins = @[Coin(x: 4, y: 4, colour: ccCopper),
                Coin(x: 1, y: 2, colour: ccCobalt),
                Coin(x: 2, y: 1, colour: ccCobalt)]
  sim.cogs[0].x = 1
  sim.cogs[0].y = 1
  sim.cogs[1].x = 7
  sim.cogs[1].y = 7
  sim.cogs[0].intent = inTakeMine     ## forbids cobalt; walls on N and W
  sim.cogs[1].intent = inHold
  sim.stepTick()
  check(sim.cogs[0].x == 1 and sim.cogs[0].y == 1,
    "a cog with no legal step waits")
  check(sim.hasEvent("blocked", "why", "restraint"),
    "and reports the restraint that pinned it")

block:
  ## Same-target contest: the flip is drawn from moveRng and the LOSER keeps
  ## its cooldown. Pinned seed, pinned winner.
  var sim = initSim(quietFixture(seed = 11))
  sim.coins = @[Coin(x: 4, y: 3, colour: ccCopper)]
  sim.cogs[0].x = 3
  sim.cogs[0].y = 3
  sim.cogs[1].x = 5
  sim.cogs[1].y = 3
  sim.cogs[0].intent = inTakeAny
  sim.cogs[1].intent = inTakeAny
  var probe = sim
  let expected = probe.moveRng.next() mod Seats
  sim.stepTick()
  let moved0 = sim.cogs[0].x == 4
  let moved1 = sim.cogs[1].x == 4
  check(moved0 != moved1, "exactly one cog reaches the contested cell")
  check((if moved0: 0 else: 1) == expected,
    "the moveRng flip names the winner (expected slot " & $expected & ")")
  let loser = otherSlot(expected)
  check(sim.cogs[loser].stepCd == 0,
    "the loser of a contest is NOT charged its cooldown")
  check(sim.cogs[expected].stepCd == sim.config.stepCooldownTicks,
    "the winner is charged its cooldown")
  check(sim.hasEvent("blocked", "why", "contested"),
    "the contest emits blocked/contested")
  check(sim.cogs[0].pickups + sim.cogs[1].pickups == 1,
    "no coin is ever collected twice")

block:
  ## Restraint blocks the step; the sidestep guarantees the restrained cog
  ## still reaches its own coin without ever stealing.
  var sim = initSim(quietFixture())
  sim.coins = @[Coin(x: 4, y: 3, colour: ccCobalt),
                Coin(x: 6, y: 3, colour: ccCopper)]
  sim.cogs[0].x = 3
  sim.cogs[0].y = 3
  sim.cogs[1].x = 7
  sim.cogs[1].y = 7
  sim.cogs[0].intent = inTakeMine
  sim.cogs[1].intent = inHold
  var landedOnForbidden = false
  for _ in 0 .. 80:
    sim.stepTick()
    if sim.cogs[0].x == 4 and sim.cogs[0].y == 3:
      landedOnForbidden = true
  check(not landedOnForbidden, "a forbidden colour is never stepped onto")
  check(sim.cogs[0].pickups == 1 and sim.cogs[0].thefts == 0,
    "the restrained cog reaches its own coin without stealing")
  check(sim.hasEvent("blocked", "why", "restraint"),
    "restraint emits blocked/restraint")

block:
  ## stepCooldownTicks is charged only on an actual move.
  var sim = initSim(quietFixture())
  sim.cogs[0].intent = inHold
  sim.cogs[1].intent = inHold
  sim.stepTick()
  check(sim.cogs[0].stepCd == 0, "hold never charges the cooldown")

# ---------------------------------------------------------------------------
echo "--- coin spawn cadence, cap and placement"
block:
  var config = fixture(seed = 3, minB = 24, maxB = 24)
  config.initialCoins = 0
  var sim = initSim(config)
  sim.cogs[0].intent = inHold
  sim.cogs[1].intent = inHold
  check(sim.coins.len == 0, "initialCoins 0 opens empty")
  ## The first spawn lands on tick `coinSpawnIntervalTicks` itself (t > 0
  ## and t mod interval == 0), which is the interval-plus-first stepTick.
  for _ in 0 .. config.coinSpawnIntervalTicks:
    sim.stepTick()
  check(sim.coins.len == 1,
    "one coin per coinSpawnIntervalTicks, got " & $sim.coins.len)
  for _ in 0 ..< config.coinSpawnIntervalTicks * 40:
    sim.stepTick()
    check(sim.coins.len <= config.coinCap, "the cap is never exceeded")
    var seen: seq[string]
    for coin in sim.coins:
      check(isInterior(coin.x, coin.y), "coins spawn on interior cells")
      check(sim.cogAt(coin.x, coin.y) < 0, "a coin never spawns under a cog")
      let key = $coin.x & "," & $coin.y
      check(key notin seen, "at most one coin per cell")
      seen.add(key)

# ---------------------------------------------------------------------------
echo "--- the five intents, every tie-break, every empty fallback"
block:
  let coins = @[
    Coin(x: 2, y: 2, colour: ccCopper),
    Coin(x: 6, y: 2, colour: ccCopper),
    Coin(x: 4, y: 6, colour: ccCobalt)
  ]
  var k = kernelFor(inTakeMine, coins, ccCopper, 5, 2, 7, 7)
  check(k.hasTarget and k.tx == 6 and k.ty == 2, "take_mine picks the nearest")
  check(ccCobalt in k.forbid and ccCopper notin k.forbid,
    "take_mine forbids the OTHER colour only")

  k = kernelFor(inTakeAny, coins, ccCobalt, 4, 5, 7, 7)
  check(k.hasTarget and k.tx == 4 and k.ty == 6, "take_any picks the nearest")
  check(k.forbid == {}, "take_any forbids nothing")

  let tie = @[Coin(x: 3, y: 3, colour: ccCobalt),
              Coin(x: 5, y: 3, colour: ccCopper)]
  k = kernelFor(inTakeAny, tie, ccCopper, 4, 3, 7, 7)
  check(k.tx == 5 and k.ty == 3, "take_any breaks a tie OWN COLOUR FIRST")
  k = kernelFor(inTakeAny, tie, ccCobalt, 4, 3, 7, 7)
  check(k.tx == 3 and k.ty == 3, "and the other way round for cobalt")

  let ySplit = @[Coin(x: 1, y: 4, colour: ccCopper),
                 Coin(x: 4, y: 1, colour: ccCopper)]
  k = kernelFor(inTakeMine, ySplit, ccCopper, 4, 4, 7, 7)
  check(k.tx == 4 and k.ty == 1, "an equidistant tie breaks on the lowest y")
  let xSplit = @[Coin(x: 2, y: 2, colour: ccCopper),
                 Coin(x: 6, y: 2, colour: ccCopper)]
  k = kernelFor(inTakeMine, xSplit, ccCopper, 4, 2, 7, 7)
  check(k.tx == 2 and k.ty == 2, "then on the lowest x")

  k = kernelFor(inTakeAny, @[], ccCopper, 1, 1, 7, 7)
  check(k.hasTarget and k.tx == 4 and k.ty == 4,
    "take_any with no coin walks to the room centre")

  k = kernelFor(inTakeTheirs, coins, ccCopper, 4, 5, 7, 7)
  check(k.hasTarget and k.tx == 4 and k.ty == 6, "take_theirs picks theirs")
  check(k.forbid == {}, "take_theirs forbids nothing")

  let mineOnly = @[Coin(x: 2, y: 2, colour: ccCopper)]
  k = kernelFor(inTakeTheirs, mineOnly, ccCopper, 5, 5, 7, 7)
  check(k.hasTarget and k.tx == 2 and k.ty == 2,
    "take_theirs falls back to take_mine's target")
  k = kernelFor(inTakeTheirs, @[], ccCopper, 5, 5, 7, 7)
  check(not k.hasTarget, "take_theirs with nothing at all holds")

  k = kernelFor(inGuard, coins, ccCopper, 1, 1, 7, 1)
  check(k.hasTarget and k.tx == 6 and k.ty == 2,
    "guard banks the own coin nearest the OTHER cog")
  check(ccCobalt in k.forbid, "guard forbids the other colour")
  k = kernelFor(inGuard, @[], ccCopper, 4, 4, 7, 7)
  check(not k.hasTarget, "guard with no own coin holds")

  k = kernelFor(inHold, coins, ccCopper, 4, 4, 7, 7)
  check(not k.hasTarget, "hold has no target")
  check(ccCobalt in k.forbid, "hold forbids the other colour")

  k = kernelFor(inTakeMine, @[], ccCopper, 4, 4, 7, 7)
  check(not k.hasTarget, "take_mine with no own coin holds")

# ---------------------------------------------------------------------------
echo "--- the truce rule"
block:
  let config = fixture(seed = 2, minB = 12, maxB = 12)
  let sim = runScripted(config, [skGreedy, skReciprocator])
  var truces: seq[tuple[beat, seat, since: int]]
  var thefts: seq[tuple[beat, seat: int]]
  for record in sim.events.records:
    if record{"k"}.getStr() == "truce":
      truces.add((record{"beat"}.getInt(), record{"seat"}.getInt(),
        record{"sinceBeat"}.getInt()))
    elif record{"k"}.getStr() == "theft":
      thefts.add((record{"t"}.getInt() div config.ticksPerBeat + 1,
        record{"seat"}.getInt()))
  check(truces.len > 0, "a greedy-versus-reciprocator episode has truces")
  for truce in truces:
    check(truce.beat - truce.since >= config.truceBeats,
      "a truce fires at least truceBeats after the arming theft (beat " &
      $truce.beat & ", since " & $truce.since & ")")
    var laterTheft = false
    for theft in thefts:
      if theft.seat == truce.seat and theft.beat > truce.since and
          theft.beat <= truce.beat:
        laterTheft = true
    check(not laterTheft, "no theft between the arming theft and the truce")
    check(truce.since > 0, "a truce is only earned by a cog that has stolen")

# ---------------------------------------------------------------------------
echo "--- the random end"
block:
  ## minBeats == maxBeats SKIPS the draw entirely: the episode always runs
  ## exactly that many beats and ends with beat_cap. This is what makes the
  ## certification fixture deterministic.
  for seed in 1 .. 6:
    let sim = runScripted(fixture(seed = seed, minB = 9, maxB = 9),
      [skHonest, skHonest])
    check(sim.beatsPlayed == 9, "minBeats == maxBeats runs exactly 9 beats")
    check(sim.reason == erBeatCap, "and ends with beat_cap")
    check(sim.tick == 9 * 20, "and 180 ticks, got " & $sim.tick)

block:
  ## With a pinned seed the drawn end beat is a fixed value.
  let a = runScripted(fixture(seed = 41, minB = 3, maxB = 24),
    [skHonest, skGreedy])
  let b = runScripted(fixture(seed = 41, minB = 3, maxB = 24),
    [skHonest, skGreedy])
  check(a.beatsPlayed == b.beatsPlayed,
    "a pinned seed draws the same end beat twice: " & $a.beatsPlayed &
    " vs " & $b.beatsPlayed)
  check(a.reason == b.reason, "and the same reason")
  check(a.beatsPlayed >= 3 and a.beatsPlayed <= 24, "inside [minBeats, maxBeats]")

block:
  ## The end stream is SEPARATE from the coin-spawn stream: changing only
  ## coinSpawnIntervalTicks must not shift which beat the episode ends on.
  var slow = fixture(seed = 17, minB = 3, maxB = 24)
  slow.coinSpawnIntervalTicks = 30
  var fast = fixture(seed = 17, minB = 3, maxB = 24)
  fast.coinSpawnIntervalTicks = 6
  let slowSim = runScripted(slow, [skHonest, skHonest])
  let fastSim = runScripted(fast, [skHonest, skHonest])
  check(slowSim.beatsPlayed == fastSim.beatsPlayed,
    "the end stream is unaffected by coin spawns: " & $slowSim.beatsPlayed &
    " vs " & $fastSim.beatsPlayed)

# ---------------------------------------------------------------------------
echo "--- the play deadline reserves the next beat"
block:
  ## The deadline is tested at beat closes, so whatever it lets start it must
  ## also let FINISH: a beat pays up to a batch and a retry
  ## (worstCaseBeatSeconds = 2 x llmTimeoutSeconds = 24 s at the defaults).
  ## A clock parked inside that reserve must settle NOW, not one beat later.
  var config = fixture(seed = 5, minB = 1, maxB = 24)
  config.endChancePermille = 0        ## no random end: this measures the clock
  check(config.worstCaseBeatSeconds() == 24, "24 s of worst case per beat")
  var sim = initSim(config)
  let inReserve = config.playDeadlineSeconds() -
    config.worstCaseBeatSeconds().float / 2.0
  proc clock(): float {.closure.} = inReserve
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    for slot in seats:
      result.add(Decision(intent: inTakeMine, source: osScripted))
  sim.runEpisode(decide, clock)
  check(sim.reason == erDeadline,
    "a clock inside the last beat's reserve settles with `deadline`, got " &
    $sim.reason)
  check(sim.beatsPlayed == 1,
    "and settles at the first beat close, not one beat past the deadline")
  check(inReserve + config.worstCaseBeatSeconds().float >
      config.playDeadlineSeconds(),
    "the fixture clock really is inside the reserve")

block:
  ## And a clock clear of the reserve plays the whole episode.
  var config = fixture(seed = 5, minB = 24, maxB = 24)
  config.endChancePermille = 0
  var sim = initSim(config)
  let clear = config.playDeadlineSeconds() -
    config.worstCaseBeatSeconds().float - 1.0
  proc clock(): float {.closure.} = clear
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    for slot in seats:
      result.add(Decision(intent: inTakeMine, source: osScripted))
  sim.runEpisode(decide, clock)
  check(sim.reason == erBeatCap and sim.beatsPlayed == 24,
    "clear of the reserve, the episode runs to its beat cap, got " &
    $sim.reason & " after " & $sim.beatsPlayed & " beats")

# ---------------------------------------------------------------------------
echo "--- determinism"
block:
  let a = runScripted(fixture(seed = 99, minB = 24, maxB = 24),
    [skReciprocator, skGreedy])
  let b = runScripted(fixture(seed = 99, minB = 24, maxB = 24),
    [skReciprocator, skGreedy])
  check(a.tick == 480 and b.tick == 480, "480 ticks each")
  check(a.gameHash() == b.gameHash(),
    "the same seed and intent script produce one gameHash")
  check($a.resultsJson() == $b.resultsJson(), "and identical results")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_sim OK"
