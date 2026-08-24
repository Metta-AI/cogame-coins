## The Coins gameplay core: the eight numbered tick rules, the beat close,
## the random end, and the observation each seat gets.
##
## Forked from `coworld-ctf/src/ctf/sim.nim` + `sim_state.nim` (tick loop,
## `gameHash`, event emission, the seeded RNG streams). The CTF gameplay core
## is replaced wholesale by the rules in `docs/plans/2026-08-24-coins-design.md`.
##
## Every tick runs these eight steps in this order. Within a step, all reads
## use the state as it stood at the START of that step, so no hidden ordering
## can change an outcome; the one place where two seats genuinely contend
## (step 3d) is settled by a seeded coin flip, not by slot order.

import std/[hashes, json, strutils]
import sim_types, room, sim_config, events, kernel, indices

export sim_types, sim_config, events, kernel, indices, room

type
  Decision* = object
    intent*: Intent
    say*: string
    notes*: string
    source*: OrderSource
    latencyMs*: int

  BeatRecord* = object
    beat*: int
    intent*: array[Seats, Intent]
    source*: array[Seats, OrderSource]
    pickups*: array[Seats, int]   ## in this beat
    thefts*: array[Seats, int]    ## in this beat
    score*: array[Seats, int]     ## running score after this beat

  Frame* = object
    t*: int
    c*: seq[int]     ## flat (x, y, facing) per seat
    k*: seq[int]     ## flat (x, y, colourIndex) per coin
    sc*: array[Seats, int]
    th*: array[Seats, int]

  Sim* = object
    config*: GameConfig
    seed*: int
    coinRng*, moveRng*, endRng*: Rng
    cogs*: array[Seats, Cog]
    coins*: seq[Coin]
    tick*: int
    beat*: int                    ## 1-based; the beat currently being played
    beatsPlayed*: int
    endBeat*: int
    finished*: bool
    reason*: EndReason
    leader*: int
    events*: EventLog
    frames*: seq[Frame]
    scoreSeries*: seq[array[3, int]]   ## [t, score0, score1] per tick
    beatThefts*: seq[array[3, int]]    ## [beat, thefts0InBeat, thefts1InBeat]
    beatLog*: seq[BeatRecord]
    beatStartPickups: array[Seats, int]
    beatStartThefts: array[Seats, int]
    firstTheftBeat*: array[Seats, int] ## 0 = never stole
    lastTheftBeat*: array[Seats, int]
    trucePending*: array[Seats, bool]
    policyNames*: array[Seats, string]
    policyKinds*: array[Seats, string]
    connected*: array[Seats, bool]

# ---------------------------------------------------------------------------
# construction
# ---------------------------------------------------------------------------

proc coinAt*(sim: Sim, x, y: int): int =
  ## Index of the coin on (x, y), or -1. At most one coin per cell.
  result = -1
  for i, coin in sim.coins:
    if coin.x == x and coin.y == y:
      return i

proc cogAt*(sim: Sim, x, y: int): int =
  result = -1
  for slot in 0 ..< Seats:
    if sim.cogs[slot].x == x and sim.cogs[slot].y == y:
      return slot

proc freeCells(sim: Sim): seq[tuple[x, y: int]] =
  for cell in interiorCells():
    if sim.coinAt(cell.x, cell.y) >= 0: continue
    if sim.cogAt(cell.x, cell.y) >= 0: continue
    result.add(cell)

proc placeOpeningCoins(sim: var Sim) =
  ## `initialCoins` coins at tick 0, half copper half cobalt (copper takes
  ## the odd one), at cells drawn uniformly from the interior cells that are
  ## not the two spawn cells and not already holding a coin.
  let total = sim.config.initialCoins
  for index in 0 ..< total:
    let free = sim.freeCells()
    if free.len == 0:
      break
    let pick = sim.coinRng.next() mod free.len
    let colour = if index mod 2 == 0: ccCopper else: ccCobalt
    sim.coins.add(Coin(x: free[pick].x, y: free[pick].y, colour: colour))

proc initSim*(config: GameConfig): Sim =
  config.validate()
  result.config = config
  result.seed = config.seed
  result.coinRng = initRng(config.seed xor CoinRngSalt)
  result.moveRng = initRng(config.seed xor MoveRngSalt)
  result.endRng = initRng(config.seed xor EndRngSalt)
  result.tick = 0
  result.beat = 1
  result.leader = 0
  result.reason = erBeatCap
  for slot in 0 ..< Seats:
    result.cogs[slot] = Cog(
      x: SpawnCells[slot].x, y: SpawnCells[slot].y,
      facing: (if slot == 0: 2 else: 0),
      intent: inTakeMine, source: osScripted
    )
    result.policyNames[slot] = Aliases[slot]
    result.policyKinds[slot] = "scripted"
  result.placeOpeningCoins()

# ---------------------------------------------------------------------------
# hashing / determinism
# ---------------------------------------------------------------------------

proc gameHash*(sim: Sim): int =
  ## A whole-state digest. The determinism test asserts two runs of one seed
  ## with one intent script agree here after 480 ticks.
  var h: Hash = 0
  h = h !& sim.tick !& sim.beat
  for slot in 0 ..< Seats:
    h = h !& hash(sim.cogs[slot])
  for coin in sim.coins:
    h = h !& hash(coin)
  int(!$h)

# ---------------------------------------------------------------------------
# recording
# ---------------------------------------------------------------------------

proc recordFrame(sim: var Sim) =
  var frame = Frame(t: sim.tick)
  for slot in 0 ..< Seats:
    frame.c.add(sim.cogs[slot].x)
    frame.c.add(sim.cogs[slot].y)
    frame.c.add(sim.cogs[slot].facing)
    frame.sc[slot] = sim.cogs[slot].score
    frame.th[slot] = sim.cogs[slot].thefts
  for coin in sim.coins:
    frame.k.add(coin.x)
    frame.k.add(coin.y)
    frame.k.add(colourIndex(coin.colour))
  sim.frames.add(frame)
  sim.scoreSeries.add([sim.tick, sim.cogs[0].score, sim.cogs[1].score])

proc cogsOf*(frame: Frame): seq[tuple[x, y, facing: int]] =
  var index = 0
  while index + 2 < frame.c.len:
    result.add((frame.c[index], frame.c[index + 1], frame.c[index + 2]))
    index += 3

proc coinsOf*(frame: Frame): seq[Coin] =
  var index = 0
  while index + 2 < frame.k.len:
    result.add(Coin(x: frame.k[index], y: frame.k[index + 1],
      colour: (if frame.k[index + 2] == 0: ccCopper else: ccCobalt)))
    index += 3

proc scoreArray*(sim: Sim): array[Seats, int] =
  for slot in 0 ..< Seats:
    result[slot] = sim.cogs[slot].score

proc pickupArray*(sim: Sim): array[Seats, int] =
  for slot in 0 ..< Seats:
    result[slot] = sim.cogs[slot].pickups

proc theftArray*(sim: Sim): array[Seats, int] =
  for slot in 0 ..< Seats:
    result[slot] = sim.cogs[slot].thefts

# ---------------------------------------------------------------------------
# rule 3: movement
# ---------------------------------------------------------------------------

proc legalStep(sim: Sim, slot, dir: int, forbid: set[Colour],
    otherX, otherY: int): tuple[ok: bool, x, y: int, why: BlockReason] =
  let nx = sim.cogs[slot].x + MoveDx[dir]
  let ny = sim.cogs[slot].y + MoveDy[dir]
  if not isInterior(nx, ny):
    return (false, nx, ny, brOccupied)
  ## No follow-through: a cog never steps into a cell that was occupied when
  ## the tick began, even if its occupant is also moving away.
  if nx == otherX and ny == otherY:
    return (false, nx, ny, brOccupied)
  let ci = sim.coinAt(nx, ny)
  if ci >= 0 and sim.coins[ci].colour in forbid:
    return (false, nx, ny, brRestraint)
  (true, nx, ny, brOccupied)

proc resolveMovement(sim: var Sim, kernels: array[Seats, Kernel]) =
  var wantX: array[Seats, int]
  var wantY: array[Seats, int]
  var wantDir: array[Seats, int]
  var moving: array[Seats, bool]
  var blockedWhy: array[Seats, BlockReason]
  var blockedSeen: array[Seats, bool]
  var startX: array[Seats, int]
  var startY: array[Seats, int]
  for slot in 0 ..< Seats:
    startX[slot] = sim.cogs[slot].x
    startY[slot] = sim.cogs[slot].y

  for slot in 0 ..< Seats:
    let other = otherSlot(slot)
    moving[slot] = false
    if sim.cogs[slot].stepCd > 0:
      continue
    ## A cog already standing on its target waits: `take_any`'s centre
    ## fallback parks there instead of wandering off it and back.
    if not kernels[slot].hasTarget or
        (kernels[slot].tx == startX[slot] and kernels[slot].ty == startY[slot]):
      continue
    let reducing = reducingDirections(kernels[slot], startX[slot], startY[slot])
    var chosen = -1
    var sawRestraint = false
    for dir in reducing:
      let step = sim.legalStep(slot, dir, kernels[slot].forbid,
        startX[other], startY[other])
      if step.ok:
        chosen = dir
        break
      if step.why == brRestraint:
        sawRestraint = true
    if chosen < 0:
      ## Sidestep: the first legal cell among ALL of N, E, S, W, which may
      ## increase the distance. This is what guarantees a restrained cog can
      ## never deadlock behind a coin it refuses to take.
      for dir in 0 .. 3:
        let step = sim.legalStep(slot, dir, kernels[slot].forbid,
          startX[other], startY[other])
        if step.ok:
          chosen = dir
          break
        if step.why == brRestraint:
          sawRestraint = true
    if chosen >= 0:
      moving[slot] = true
      wantDir[slot] = chosen
      wantX[slot] = startX[slot] + MoveDx[chosen]
      wantY[slot] = startY[slot] + MoveDy[chosen]
    else:
      blockedSeen[slot] = true
      blockedWhy[slot] = if sawRestraint: brRestraint else: brOccupied

  ## c. Swap: cogs never swap through each other.
  if moving[0] and moving[1] and
      wantX[0] == startX[1] and wantY[0] == startY[1] and
      wantX[1] == startX[0] and wantY[1] == startY[0]:
    for slot in 0 ..< Seats:
      moving[slot] = false
      blockedSeen[slot] = true
      blockedWhy[slot] = brOccupied

  ## d. Same-target contest: ONE flip from moveRng names the winner's slot.
  ## This is the rule that settles a simultaneous pickup conflict — two cogs
  ## can never occupy one cell, so they can never both take one coin.
  if moving[0] and moving[1] and
      wantX[0] == wantX[1] and wantY[0] == wantY[1]:
    let winner = sim.moveRng.next() mod Seats
    let loser = otherSlot(winner)
    moving[loser] = false
    blockedSeen[loser] = true
    blockedWhy[loser] = brContested

  ## e. Commit. The loser of a contest is NOT charged its cooldown.
  for slot in 0 ..< Seats:
    if moving[slot]:
      sim.cogs[slot].x = wantX[slot]
      sim.cogs[slot].y = wantY[slot]
      sim.cogs[slot].facing = wantDir[slot]
      sim.cogs[slot].stepCd = sim.config.stepCooldownTicks
    elif blockedSeen[slot]:
      sim.events.add(blockedEvent(sim.tick, slot, startX[slot], startY[slot],
        blockedWhy[slot]))

# ---------------------------------------------------------------------------
# rules 4-7
# ---------------------------------------------------------------------------

proc collectCoins(sim: var Sim) =
  ## Rules 4 + 5. Step 3 guarantees the two cogs are on different cells, so
  ## no coin is ever collected twice.
  for slot in 0 ..< Seats:
    let index = sim.coinAt(sim.cogs[slot].x, sim.cogs[slot].y)
    if index < 0:
      continue
    let coin = sim.coins[index]
    sim.coins.delete(index)
    sim.cogs[slot].pickups.inc
    sim.cogs[slot].score += sim.config.pickupReward
    if coin.colour == OwnColour[slot]:
      sim.events.add(pickupEvent(sim.tick, slot, coin.x, coin.y, coin.colour,
        sim.scoreArray()))
    else:
      let victim = otherSlot(slot)
      sim.cogs[slot].thefts.inc
      sim.cogs[victim].stolenFrom.inc
      sim.cogs[victim].score -= sim.config.theftPenalty
      if sim.firstTheftBeat[slot] == 0:
        sim.firstTheftBeat[slot] = sim.beat
      sim.lastTheftBeat[slot] = sim.beat
      sim.trucePending[slot] = true
      sim.events.add(theftEvent(sim.tick, slot, victim, coin.x, coin.y,
        coin.colour, sim.config.theftPenalty, sim.scoreArray()))

proc spawnCoin(sim: var Sim) =
  ## Rule 6: at every tick t with `t mod coinSpawnIntervalTicks == 0` and
  ## `t > 0`, if the board holds fewer than `coinCap` coins, ONE coin spawns.
  if sim.tick <= 0: return
  if sim.tick mod sim.config.coinSpawnIntervalTicks != 0: return
  if sim.coins.len >= sim.config.coinCap: return
  let colour = if sim.coinRng.next() mod 2 == 0: ccCopper else: ccCobalt
  let free = sim.freeCells()
  if free.len == 0: return
  let pick = sim.coinRng.next() mod free.len
  sim.coins.add(Coin(x: free[pick].x, y: free[pick].y, colour: colour))
  sim.events.add(spawnEvent(sim.tick, free[pick].x, free[pick].y, colour))

proc updateLeader(sim: var Sim) =
  ## Rule 7: argmax score, ties -> slot 0.
  let next = if sim.cogs[1].score > sim.cogs[0].score: 1 else: 0
  if next != sim.leader:
    sim.leader = next
    sim.events.add(leadChangeEvent(sim.tick, next, sim.scoreArray()))

# ---------------------------------------------------------------------------
# the tick
# ---------------------------------------------------------------------------

proc stepTick*(sim: var Sim) =
  ## One tick: the eight numbered steps, in order.
  ## 1. Timers.
  for slot in 0 ..< Seats:
    sim.cogs[slot].stepCd = max(sim.cogs[slot].stepCd - 1, 0)
  ## 2. Intent evaluation.
  var kernels: array[Seats, Kernel]
  for slot in 0 ..< Seats:
    let other = otherSlot(slot)
    kernels[slot] = kernelFor(sim.cogs[slot].intent, sim.coins,
      OwnColour[slot], sim.cogs[slot].x, sim.cogs[slot].y,
      sim.cogs[other].x, sim.cogs[other].y)
  ## 3. Movement, both cogs resolved simultaneously.
  sim.resolveMovement(kernels)
  ## 4 + 5. Pickup and scoring.
  sim.collectCoins()
  ## 6. Spawn.
  sim.spawnCoin()
  ## 7. Counters.
  sim.updateLeader()
  ## 8. Record.
  sim.recordFrame()
  sim.tick.inc

proc isBeatClose*(sim: Sim): bool =
  ## The last tick of every beat.
  sim.tick > 0 and sim.tick mod sim.config.ticksPerBeat == 0

# ---------------------------------------------------------------------------
# the beat close
# ---------------------------------------------------------------------------

proc closeBeat*(sim: var Sim): bool =
  ## Emits `beatclose`, any earned `truce` beats, then runs the random-end
  ## draw. Returns true when the episode should keep playing.
  let t = sim.tick - 1
  var beatPickups: array[Seats, int]
  var beatThefts: array[Seats, int]
  for slot in 0 ..< Seats:
    beatPickups[slot] = sim.cogs[slot].pickups - sim.beatStartPickups[slot]
    beatThefts[slot] = sim.cogs[slot].thefts - sim.beatStartThefts[slot]
  sim.events.add(beatCloseEvent(t, sim.beat, sim.scoreArray(),
    sim.pickupArray(), sim.theftArray()))
  sim.beatThefts.add([sim.beat, beatThefts[0], beatThefts[1]])
  var record = BeatRecord(beat: sim.beat)
  for slot in 0 ..< Seats:
    record.intent[slot] = sim.cogs[slot].intent
    record.source[slot] = sim.cogs[slot].source
    record.pickups[slot] = beatPickups[slot]
    record.thefts[slot] = beatThefts[slot]
    record.score[slot] = sim.cogs[slot].score
  sim.beatLog.add(record)

  ## The truce beat — the idea's headline moment, defined so a test can
  ## assert it.
  for slot in 0 ..< Seats:
    if truceDue(sim.cogs[slot].thefts, sim.lastTheftBeat[slot], sim.beat,
        sim.config.truceBeats, sim.trucePending[slot]):
      sim.trucePending[slot] = false
      sim.events.add(truceEvent(t, sim.beat, slot, sim.lastTheftBeat[slot]))

  sim.beatsPlayed = sim.beat
  for slot in 0 ..< Seats:
    sim.beatStartPickups[slot] = sim.cogs[slot].pickups
    sim.beatStartThefts[slot] = sim.cogs[slot].thefts

  ## The random end, exactly. When minBeats == maxBeats the draw is SKIPPED
  ## entirely, which is how the certification fixture is deterministic.
  if sim.config.maxBeats > sim.config.minBeats and
      sim.beat >= sim.config.minBeats and sim.beat < sim.config.maxBeats:
    if (sim.endRng.next() mod 1000) < sim.config.endChancePermille:
      sim.reason = erRandomEnd
      return false
  if sim.beat >= sim.config.maxBeats:
    sim.reason = erBeatCap
    return false
  sim.beat.inc
  true

proc endEpisode*(sim: var Sim, reason: EndReason) =
  if sim.finished:
    return
  sim.finished = true
  sim.reason = reason
  sim.endBeat = sim.beatsPlayed
  sim.events.add(endEvent(max(sim.tick - 1, 0), sim.endBeat, reason,
    sim.scoreArray()))

proc applyDecisions*(sim: var Sim, decisions: openArray[Decision]) =
  ## One intent per seat per beat, recorded on an `order` event at the beat
  ## boundary. Both free-text fields arrive already rune-truncated.
  for slot in 0 ..< Seats:
    if slot >= decisions.len: continue
    sim.cogs[slot].intent = decisions[slot].intent
    sim.cogs[slot].source = decisions[slot].source
    sim.cogs[slot].say = decisions[slot].say
    sim.cogs[slot].notes = decisions[slot].notes
    sim.cogs[slot].latencyMs = decisions[slot].latencyMs
    sim.events.add(orderEvent(sim.tick, sim.beat, slot,
      decisions[slot].intent, decisions[slot].source, decisions[slot].say,
      decisions[slot].notes, decisions[slot].latencyMs))

# ---------------------------------------------------------------------------
# the observation
# ---------------------------------------------------------------------------

proc coinsJson*(sim: Sim): JsonNode =
  result = newJArray()
  for coin in sim.coins:
    result.add(%*{"x": coin.x, "y": coin.y, "colour": $coin.colour})

proc buildObservation*(sim: Sim, slot: int): JsonNode =
  ## Everything this seat sees, and NOTHING else. The other cog's intent for
  ## the coming beat, its `say`/`notes`, its policy name, the RNG seed and
  ## the drawn end beat are all absent by construction.
  let other = otherSlot(slot)
  var log = newJArray()
  for record in sim.beatLog:
    log.add(%*{
      "beat": record.beat,
      "you": {"intent": $record.intent[slot], "pickups": record.pickups[slot],
              "thefts": record.thefts[slot]},
      "them": {"pickups": record.pickups[other],
               "thefts": record.thefts[other]},
      "score": [record.score[slot], record.score[other]]
    })
  %*{
    "type": "state", "protocol": "coins.player.v1", "slot": slot,
    "alias": Aliases[slot], "colour": $OwnColour[slot],
    "beat": sim.beat, "minBeats": sim.config.minBeats,
    "maxBeats": sim.config.maxBeats,
    "endChancePermille": sim.config.endChancePermille,
    "ticksPerBeat": sim.config.ticksPerBeat,
    "tick": sim.tick, "ticksPlayed": sim.tick,
    "room": {"w": RoomW, "h": RoomH,
             "interior": [InteriorLo, InteriorLo, InteriorHi, InteriorHi]},
    "rules": {
      "pickupReward": sim.config.pickupReward,
      "theftPenalty": sim.config.theftPenalty,
      "coinCap": sim.config.coinCap,
      "coinSpawnIntervalTicks": sim.config.coinSpawnIntervalTicks,
      "stepCooldownTicks": sim.config.stepCooldownTicks,
      "moves": MoveNames,
      "intents": ["take_mine", "take_any", "take_theirs", "guard", "hold"],
      "restraint": "an intent that forbids a colour never steps onto a coin " &
        "of that colour",
      "endRule": "after beat " & $sim.config.minBeats & " each beat close " &
        "ends the episode with probability " &
        $(sim.config.endChancePermille.float / 1000.0) &
        "; it always ends by beat " & $sim.config.maxBeats
    },
    "you": {"x": sim.cogs[slot].x, "y": sim.cogs[slot].y,
            "facing": sim.cogs[slot].facing, "score": sim.cogs[slot].score,
            "pickups": sim.cogs[slot].pickups,
            "thefts": sim.cogs[slot].thefts,
            "stolenFrom": sim.cogs[slot].stolenFrom},
    "them": {"alias": Aliases[other], "colour": $OwnColour[other],
             "x": sim.cogs[other].x, "y": sim.cogs[other].y,
             "score": sim.cogs[other].score,
             "pickups": sim.cogs[other].pickups,
             "thefts": sim.cogs[other].thefts,
             "stolenFrom": sim.cogs[other].stolenFrom},
    "coins": sim.coinsJson(),
    "beatLog": log,
    "notes": sim.cogs[slot].notes
  }

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------

proc winFlags*(sim: Sim): array[Seats, bool] =
  let best = max(sim.cogs[0].score, sim.cogs[1].score)
  for slot in 0 ..< Seats:
    result[slot] = sim.cogs[slot].score == best

proc resultsJson*(sim: Sim): JsonNode =
  ## `names` are POLICY names (platform side); aliases go to the players and
  ## into the replay's `names[]`. Every array is indexed by slot and is
  ## always length 2. Sign: HIGHER IS BETTER.
  let wins = sim.winFlags()
  %*{
    "names": [sim.policyNames[0], sim.policyNames[1]],
    "scores": [sim.cogs[0].score.float, sim.cogs[1].score.float],
    "win": [wins[0], wins[1]],
    "aliases": [Aliases[0], Aliases[1]],
    "colours": [$OwnColour[0], $OwnColour[1]],
    "pickups": [sim.cogs[0].pickups, sim.cogs[1].pickups],
    "thefts": [sim.cogs[0].thefts, sim.cogs[1].thefts],
    "stolenFrom": [sim.cogs[0].stolenFrom, sim.cogs[1].stolenFrom],
    "restraint": [restraintOf(sim.cogs[0].pickups, sim.cogs[0].thefts),
                  restraintOf(sim.cogs[1].pickups, sim.cogs[1].thefts)],
    "firstTheftBeat": [beatOrNull(sim.firstTheftBeat[0]),
                       beatOrNull(sim.firstTheftBeat[1])],
    "reciprocityLagBeats": [reciprocityLag(sim.firstTheftBeat, 0),
                            reciprocityLag(sim.firstTheftBeat, 1)],
    "beats": sim.beatsPlayed,
    "endBeat": sim.endBeat,
    "ticks": sim.tick,
    "reason": $sim.reason
  }

proc scoreIdentityHolds*(sim: Sim): bool =
  ## `score[i] == pickups[i] * pickupReward - stolenFrom[i] * theftPenalty`.
  for slot in 0 ..< Seats:
    if sim.cogs[slot].score !=
        sim.cogs[slot].pickups * sim.config.pickupReward -
        sim.cogs[slot].stolenFrom * sim.config.theftPenalty:
      return false
  true

proc lullSpans*(sim: Sim, minRun = 40): seq[array[2, int]] =
  ## Every stretch of >= `minRun` ticks with no `pickup` and no `theft`, so
  ## the starter's auto-skip button has something real to skip.
  var busy: seq[bool] = newSeq[bool](max(sim.tick, 1))
  for record in sim.events.records:
    let kind = record{"k"}.getStr()
    if kind != "pickup" and kind != "theft": continue
    let t = record{"t"}.getInt()
    if t >= 0 and t < busy.len:
      busy[t] = true
  var run = 0
  for t in 0 ..< busy.len:
    if busy[t]:
      if run >= minRun:
        result.add([t - run, t - 1])
      run = 0
    else:
      run.inc
  if run >= minRun:
    result.add([busy.len - run, busy.len - 1])

proc beatsTimeline*(sim: Sim): JsonNode =
  ## The scrubber's beat timeline, shipped whole on the first HUD frame.
  ## Exactly four kinds: theft, truce, leadchange, over.
  result = newJArray()
  for record in sim.events.records:
    let kind = record{"k"}.getStr()
    case kind
    of "theft":
      let seat = record{"seat"}.getInt()
      result.add(%*{"t": record{"t"}.getInt(), "k": "theft", "seat": seat,
        "team": TeamKeys[seat]})
    of "truce":
      let seat = record{"seat"}.getInt()
      result.add(%*{"t": record{"t"}.getInt(), "k": "truce", "seat": seat,
        "team": TeamKeys[seat]})
    of "leadchange":
      let seat = record{"seat"}.getInt()
      result.add(%*{"t": record{"t"}.getInt(), "k": "leadchange", "seat": seat,
        "team": TeamKeys[seat]})
    else:
      discard
  let winner = if sim.cogs[1].score > sim.cogs[0].score: 1 else: 0
  result.add(%*{"t": max(sim.tick - 1, 0), "k": "over", "seat": winner,
    "team": TeamKeys[winner]})

# ---------------------------------------------------------------------------
# the episode driver
# ---------------------------------------------------------------------------

type
  DecideProc* = proc (view: Sim, seats: seq[int]): seq[Decision] {.closure.}
  ClockProc* = proc (): float {.closure.}
  BeatProc* = proc (view: Sim) {.closure.}

proc runEpisode*(sim: var Sim, decide: DecideProc, now: ClockProc,
    onBeat: BeatProc = nil) =
  ## Opening batch before tick 0, then: play `ticksPerBeat` ticks, close the
  ## beat, check the play deadline, and — if the episode continues — block
  ## for the next batched decision.
  var seats: seq[int]
  for slot in 0 ..< Seats:
    seats.add(slot)
  sim.applyDecisions(decide(sim, seats))
  while true:
    for _ in 0 ..< sim.config.ticksPerBeat:
      sim.stepTick()
    let keepPlaying = sim.closeBeat()
    if onBeat != nil:
      onBeat(sim)
    if not keepPlaying:
      break
    ## The play deadline is checked at BEAT CLOSES only. Crossing it settles
    ## with `reason: "deadline"` — the beats played are scored exactly as
    ## they happened and nothing is imputed for the beats not played.
    if now() >= sim.config.playDeadlineSeconds():
      sim.reason = erDeadline
      break
    sim.applyDecisions(decide(sim, seats))
  sim.endEpisode(sim.reason)

proc currentFrame*(sim: Sim): Frame =
  ## The frame just recorded — what a live spectator is looking at.
  if sim.frames.len == 0:
    result = Frame(t: 0)
    for slot in 0 ..< Seats:
      result.c.add(sim.cogs[slot].x)
      result.c.add(sim.cogs[slot].y)
      result.c.add(sim.cogs[slot].facing)
    for coin in sim.coins:
      result.k.add(coin.x)
      result.k.add(coin.y)
      result.k.add(colourIndex(coin.colour))
  else:
    result = sim.frames[^1]
