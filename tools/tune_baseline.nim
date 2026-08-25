## tools/tune_baseline.nim — the grid the reciprocator's parameters come from.
##
## Run by ci.yml's `test` job, so the sweep is in the log of every run:
##
##   nim c -r --hints:off --path:src -d:release tools/tune_baseline.nim
##
## `punishThreshold`, `punishBeats` and `truceBeats` are the three knobs that
## decide how the strongest baseline — the one every LLM failure path falls
## back to, the one a never-connected seat plays, and the one the offline
## certification fixture leans on — answers theft. This harness plays the
## whole grid rather than asserting the shipped point in isolation: every
## combination meets all four baselines over seeds 1..8 at certification
## length, and the table below is what the shipped `defaultGameConfig()`
## values are chosen from.
##
## The objective is the design note's, not a bare score maximum. The
## reciprocator has to be
##   (1) STRONG: it must beat the honest baseline's payoff against greed
##       ("punishment beats pacifism"), and hold up across the four
##       opponents; and
##   (2) LEGIBLE: it is "forgiving rather than grim, so a truce can re-form
##       and be watched" — a point that never emits a truce leaves the
##       reciprocity strip empty and the replay without its story.
## The harness ranks the grid on (1), reports (2) for every point, and fails
## if the shipped point breaks either. The ranking is printed so the choice
## can be read rather than taken on trust.

import std/[algorithm, json, strutils]
import coins/[sim_types, sim, scripted]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

const
  SeedCount = 8
  ThresholdLo = 1
  ThresholdHi = 3
  PunishLo = 2
  PunishHi = 6
  TruceLo = 2
  TruceHi = 4

proc gridConfig(seed, punishThreshold, punishBeats, truceBeats: int):
    GameConfig =
  ## The certification fixture: minBeats == maxBeats == 16 disables the
  ## random-end draw, so every number below is a fixed-length measurement.
  result = defaultGameConfig()
  result.seed = seed
  result.minBeats = 16
  result.maxBeats = 16
  result.punishThreshold = punishThreshold
  result.punishBeats = punishBeats
  result.truceBeats = truceBeats
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

proc play(config: GameConfig, a, b: ScriptKind): Sim =
  var sim = initSim(config)
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

type Row = object
  punishThreshold, punishBeats, truceBeats: int
  vsGreedy, vsHonest, vsTft, vsSelf, mean: float
  truces, thefts: int

proc pad(text: string, width: int): string =
  align(text, width)

proc f2(value: float): string =
  let scaled = int(value * 100.0 + (if value < 0: -0.5 else: 0.5))
  let whole = scaled div 100
  var frac = scaled mod 100
  if frac < 0: frac = -frac
  (if value < 0 and whole == 0: "-" else: "") & $whole & "." &
    (if frac < 10: "0" else: "") & $frac

## The honest baseline's payoff against greed — the number "punishment beats
## pacifism" is measured against. It does not depend on the grid.
var sucker = 0.0
block:
  var total = 0
  for seed in 1 .. SeedCount:
    let sim = play(gridConfig(seed, 2, 4, 3), skGreedy, skHonest)
    total += sim.cogs[1].score
  sucker = total.float / SeedCount.float
echo "the sucker payoff (honest vs greedy, seeds 1..8): ", f2(sucker)

var rows: seq[Row]
var episodes = 0
for punishThreshold in ThresholdLo .. ThresholdHi:
  for punishBeats in PunishLo .. PunishHi:
    for truceBeats in TruceLo .. TruceHi:
      var row = Row(punishThreshold: punishThreshold, punishBeats: punishBeats,
        truceBeats: truceBeats)
      var totals = [0, 0, 0, 0]
      for seed in 1 .. SeedCount:
        let config = gridConfig(seed, punishThreshold, punishBeats, truceBeats)
        for index, opponent in [skGreedy, skHonest, skTitForTat,
            skReciprocator]:
          ## The reciprocator always takes slot 1.
          let sim = play(config, opponent, skReciprocator)
          episodes.inc
          totals[index] += sim.cogs[1].score
          if index == 0:
            for record in sim.events.records:
              case record{"k"}.getStr()
              of "truce":
                if record{"seat"}.getInt() == 1: row.truces.inc
              of "theft":
                if record{"seat"}.getInt() == 1: row.thefts.inc
              else: discard
      let n = SeedCount.float
      row.vsGreedy = totals[0].float / n
      row.vsHonest = totals[1].float / n
      row.vsTft = totals[2].float / n
      row.vsSelf = totals[3].float / n
      row.mean = (row.vsGreedy + row.vsHonest + row.vsTft + row.vsSelf) / 4.0
      rows.add(row)

## (1) STRONG first, and among equals the more forgiving point (the smaller
## punishBeats, then the smaller punishThreshold): the note asks for
## forgiving rather than grim.
rows.sort(proc (a, b: Row): int =
  if a.vsGreedy != b.vsGreedy:
    return (if a.vsGreedy > b.vsGreedy: -1 else: 1)
  if a.mean != b.mean:
    return (if a.mean > b.mean: -1 else: 1)
  if a.punishBeats != b.punishBeats:
    return (if a.punishBeats < b.punishBeats: -1 else: 1)
  if a.punishThreshold != b.punishThreshold:
    return (if a.punishThreshold < b.punishThreshold: -1 else: 1)
  0)

let shipped = defaultGameConfig()
echo "grid: punishThreshold ", ThresholdLo, "..", ThresholdHi,
  " x punishBeats ", PunishLo, "..", PunishHi, " x truceBeats ", TruceLo,
  "..", TruceHi, " x seeds 1..", SeedCount, " x 4 opponents = ", episodes,
  " episodes"
echo "  rank  thr  pun  tru | vs greedy  vs honest  vs t4t  vs self  " &
  "  mean | truces thefts"
var shippedRank = -1
for index, row in rows:
  let isShipped = row.punishThreshold == shipped.punishThreshold and
    row.punishBeats == shipped.punishBeats and
    row.truceBeats == shipped.truceBeats
  if isShipped:
    shippedRank = index + 1
  echo pad($(index + 1), 6), pad($row.punishThreshold, 5),
    pad($row.punishBeats, 5), pad($row.truceBeats, 5), " |",
    pad(f2(row.vsGreedy), 10), pad(f2(row.vsHonest), 11),
    pad(f2(row.vsTft), 8), pad(f2(row.vsSelf), 9), pad(f2(row.mean), 7),
    " |", pad($row.truces, 7), pad($row.thefts, 7),
    (if isShipped: "   <- shipped (defaultGameConfig)" else: "")

echo "shipped: punishThreshold=", shipped.punishThreshold, " punishBeats=",
  shipped.punishBeats, " truceBeats=", shipped.truceBeats, " -> rank ",
  shippedRank, " of ", rows.len
echo "best by `vs greedy`: thr=", rows[0].punishThreshold, " pun=",
  rows[0].punishBeats, " tru=", rows[0].truceBeats, " (",
  f2(rows[0].vsGreedy), ")"

block:
  var row: Row
  var found = false
  for candidate in rows:
    if candidate.punishThreshold == shipped.punishThreshold and
        candidate.punishBeats == shipped.punishBeats and
        candidate.truceBeats == shipped.truceBeats:
      row = candidate
      found = true
  check(found, "the shipped point is inside the swept grid")
  if found:
    ## (1) strong: punishment beats pacifism, by the note's own measure.
    check(row.vsGreedy > sucker,
      "the shipped point beats the sucker payoff against greed: " &
      f2(row.vsGreedy) & " vs " & f2(sucker))
    ## (2) legible: truces still form and can be watched.
    check(row.truces >= SeedCount,
      "the shipped point still emits at least one truce per episode " &
      "against greed, got " & $row.truces & " over " & $SeedCount &
      " episodes")
    check(row.thefts >= 1,
      "and it does punish — a point that never takes their coin is the " &
      "honest baseline under another name")
    ## And it is competitive: no grid point beats it against greed by more
    ## than a coin's worth of score.
    check(rows[0].vsGreedy - row.vsGreedy <= 1.0,
      "the shipped point is within one coin of the grid's best against " &
      "greed: " & f2(row.vsGreedy) & " vs " & f2(rows[0].vsGreedy))

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "tune_baseline OK"
