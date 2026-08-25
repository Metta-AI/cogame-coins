## tests/test_dilemma.nim — the game-shape oracle.
##
## A coins room whose payoffs are not a Prisoner's Dilemma is a dead coworld,
## so the ordering is ASSERTED here rather than assumed. Any constant change
## that turns Coins into a Chicken game, or into a room where nothing happens,
## fails here rather than in a dead replay.
##
## Gates, over seeds 1..8 at certification length (16 beats x 20 ticks):
##   (a) honest vs honest: both scores strictly positive, both thefts 0.
##   (b) greedy vs greedy: the mutual-harm trap — well under mutual restraint.
##   (c) greedy vs honest: temptation beats restraint AND the sucker payoff is
##       strictly negative.
##   (d) greedy vs reciprocator: punishment beats pacifism.
##   (e) liveness: >= 20 total pickups, both cogs >= 1, and at least one theft
##       and one truce in the greedy-vs-reciprocator sweep.
##   (f) the score identity holds at EVERY tick.

import std/json
import coins/[sim_types, sim, scripted]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

proc certConfig(seed: int): GameConfig =
  ## Exactly the certification fixture: minBeats == maxBeats == 16 disables
  ## the random-end draw, so every gate below is a fixed-length measurement.
  result = defaultGameConfig()
  result.seed = seed
  result.minBeats = 16
  result.maxBeats = 16
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

proc play(seed: int, a, b: ScriptKind): Sim =
  var sim = initSim(certConfig(seed))
  proc now(): float {.closure.} = 0.0
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    let kinds = [a, b]
    for slot in seats:
      result.add(Decision(
        intent: scriptedIntent(kinds[slot], view.buildObservation(slot),
          view.config.punishThreshold, view.config.punishBeats),
        source: osScripted))
  sim.runEpisode(decide, now)
  sim

proc mean(values: seq[int]): float =
  if values.len == 0: return 0.0
  var total = 0
  for value in values:
    total += value
  total.float / values.len.float

const Seeds = 1 .. 8

var rr: seq[int]          ## R: both honest
var pp: seq[int]          ## P: both greedy
var tt: seq[int]          ## T: greedy's score against honest
var ss: seq[int]          ## S: honest's score against greedy
var recip: seq[int]       ## the reciprocator's score against greedy
var recipThefts = 0
var recipTruces = 0
var minTotalPickups = high(int)
var minPerCogPickups = high(int)

for seed in Seeds:
  block gateA:
    let sim = play(seed, skHonest, skHonest)
    check(sim.cogs[0].score > 0 and sim.cogs[1].score > 0,
      "(a) mutual restraint pays both cogs (seed " & $seed & "): " &
      $sim.cogs[0].score & "/" & $sim.cogs[1].score)
    check(sim.cogs[0].thefts == 0 and sim.cogs[1].thefts == 0,
      "(a) honest never steals (seed " & $seed & ")")
    rr.add(sim.cogs[0].score)
    rr.add(sim.cogs[1].score)
    let total = sim.cogs[0].pickups + sim.cogs[1].pickups
    if total < minTotalPickups: minTotalPickups = total
    for slot in 0 ..< Seats:
      if sim.cogs[slot].pickups < minPerCogPickups:
        minPerCogPickups = sim.cogs[slot].pickups

  block gateB:
    let sim = play(seed, skGreedy, skGreedy)
    pp.add(sim.cogs[0].score)
    pp.add(sim.cogs[1].score)
    let total = sim.cogs[0].pickups + sim.cogs[1].pickups
    if total < minTotalPickups: minTotalPickups = total
    for slot in 0 ..< Seats:
      if sim.cogs[slot].pickups < minPerCogPickups:
        minPerCogPickups = sim.cogs[slot].pickups

  block gateC:
    let sim = play(seed, skGreedy, skHonest)
    tt.add(sim.cogs[0].score)
    ss.add(sim.cogs[1].score)
    check(sim.cogs[1].score < 0,
      "(c) the sucker payoff is strictly negative (seed " & $seed & "): " &
      $sim.cogs[1].score)
    check(sim.cogs[1].thefts == 0, "(c) the honest seat still never steals")
    let total = sim.cogs[0].pickups + sim.cogs[1].pickups
    if total < minTotalPickups: minTotalPickups = total

  block gateD:
    let sim = play(seed, skGreedy, skReciprocator)
    recip.add(sim.cogs[1].score)
    for record in sim.events.records:
      case record{"k"}.getStr()
      of "theft": recipThefts.inc
      of "truce": recipTruces.inc
      else: discard
    let total = sim.cogs[0].pickups + sim.cogs[1].pickups
    if total < minTotalPickups: minTotalPickups = total
    for slot in 0 ..< Seats:
      if sim.cogs[slot].pickups < minPerCogPickups:
        minPerCogPickups = sim.cogs[slot].pickups

let R = mean(rr)
let P = mean(pp)
let T = mean(tt)
let S = mean(ss)
let D = mean(recip)

echo "payoffs over seeds 1..8 at cert length:"
echo "  T (greedy vs honest)      = ", T
echo "  R (both honest)           = ", R
echo "  P (both greedy)           = ", P
echo "  S (honest vs greedy)      = ", S
echo "  reciprocator vs greedy    = ", D
echo "  min total pickups         = ", minTotalPickups
echo "  min per-cog pickups       = ", minPerCogPickups
echo "  thefts / truces in the reciprocator sweep = ",
  recipThefts, " / ", recipTruces

check(T > R, "T > R: temptation beats mutual restraint")
check(R > P, "R > P: mutual restraint beats the mutual-harm trap")
check(P > S, "P > S: the trap still beats being the sucker")
check(2.0 * R > T + S,
  "2R > T + S: mutual restraint is also the efficient outcome")
check(S < 0.0, "the sucker payoff is negative")
check(R > 0.0, "mutual restraint is worth playing")
check(P < R * 0.6,
  "(b) the mutual-harm trap is well below mutual restraint: " & $P &
  " vs " & $R)
check(D > S, "(d) punishment beats pacifism against greed: " & $D & " vs " & $S)

## The design note's ABSOLUTE floors, not just the ordering: mutual restraint
## has to be worth a real amount of score (a room where both cogs cooperate to
## a mean of 1 is technically a dilemma and dramatically nothing), and the
## mutual-harm trap has to be genuinely poor.
check(R >= 10.0,
  "(a) mutual restraint pays a mean of at least 10, got " & $R)
check(P < 5.0,
  "(b) the mutual-harm trap's mean is below 5, got " & $P)

## Gates (c) and (d) are asserted on the MEANS above. The per-seed picture is
## printed rather than gated: the reciprocator's edge over the honest seat
## against greed is real but thin (tools/tune_baseline.nim's grid puts the
## shipped punishThreshold/punishBeats at rank 29 of 45 for exactly this
## measure), so a per-seed gate would be asserting a strength the baseline
## does not have. Anyone retuning it should read these rows first.
block:
  var inversions = 0
  echo "per-seed (d) reciprocator vs honest, both against greedy:"
  for index in 0 ..< min(recip.len, ss.len):
    let flag = if recip[index] > ss[index]: "" else: "   <- inversion"
    if recip[index] <= ss[index]: inversions.inc
    echo "  seed ", index + 1, ": reciprocator ", recip[index],
      " vs honest ", ss[index], flag
  echo "  inversions: ", inversions, " of ", recip.len, " seeds"

check(minTotalPickups >= 20,
  "(e) every episode has at least 20 total pickups, got " &
  $minTotalPickups)
check(minPerCogPickups >= 1,
  "(e) both cogs pick up at least one coin, got " & $minPerCogPickups)
check(recipThefts >= 1,
  "(e) the reciprocator sweep contains at least one theft")
check(recipTruces >= 1,
  "(e) the reciprocator sweep contains at least one truce — otherwise the " &
  "replay has no story and the reciprocity timeline is empty")

echo "--- (f) the score identity at EVERY tick"
block:
  var sim = initSim(certConfig(3))
  sim.cogs[0].intent = inTakeAny
  sim.cogs[1].intent = inTakeAny
  for _ in 0 ..< 16 * 20:
    sim.stepTick()
    if not sim.scoreIdentityHolds():
      check(false, "the score identity broke at tick " & $sim.tick)
      break

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_dilemma OK"
