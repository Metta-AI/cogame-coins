## The per-tick intent kernel.
##
## A seat submits ONE intent per beat; this deterministic kernel executes it
## for the next `ticksPerBeat` ticks, producing the per-tick grid actions the
## idea's policy interface asks for. Its whole job each tick is to answer two
## questions — where is this cog walking, and which coin colour will it
## refuse to step on — and step 2/3 of the tick order does the rest.
##
## "Nearest" is Manhattan distance from the cog's current cell, ties broken
## lowest `y` then lowest `x`.
##
## **Forbidden is a MOVEMENT rule, not a pickup rule**: a cog whose intent
## forbids a colour never steps onto a coin of that colour, so restraint is
## something a spectator literally watches (the cog walks around the coin it
## will not take, and the sim emits `blocked` `why: "restraint"`).

import sim_types

type
  Kernel* = object
    hasTarget*: bool
    tx*, ty*: int
    forbid*: set[Colour]

const RoomCentre* = (4, 4)

proc better(candX, candY, bestX, bestY, fromX, fromY: int): bool =
  ## Nearest, then lowest y, then lowest x.
  let d = manhattan(candX, candY, fromX, fromY)
  let b = manhattan(bestX, bestY, fromX, fromY)
  if d != b: return d < b
  if candY != bestY: return candY < bestY
  candX < bestX

proc nearestOfColour(coins: seq[Coin], colour: Colour, fromX, fromY: int):
    tuple[found: bool, x, y: int] =
  result = (false, 0, 0)
  for coin in coins:
    if coin.colour != colour: continue
    if not result.found or
        better(coin.x, coin.y, result.x, result.y, fromX, fromY):
      result = (true, coin.x, coin.y)

proc nearestAny(coins: seq[Coin], own: Colour, fromX, fromY: int):
    tuple[found: bool, x, y: int] =
  ## Ties broken OWN COLOUR FIRST, then lowest y, then lowest x.
  var bestOwn = false
  result = (false, 0, 0)
  for coin in coins:
    let isOwn = coin.colour == own
    if not result.found:
      result = (true, coin.x, coin.y)
      bestOwn = isOwn
      continue
    let d = manhattan(coin.x, coin.y, fromX, fromY)
    let b = manhattan(result.x, result.y, fromX, fromY)
    var wins = false
    if d != b:
      wins = d < b
    elif isOwn != bestOwn:
      wins = isOwn
    elif coin.y != result.y:
      wins = coin.y < result.y
    else:
      wins = coin.x < result.x
    if wins:
      result = (true, coin.x, coin.y)
      bestOwn = isOwn

proc nearestOwnToThem(coins: seq[Coin], own: Colour, themX, themY: int):
    tuple[found: bool, x, y: int] =
  ## The coin of your OWN colour nearest to the OTHER cog — bank the coins
  ## most at risk first. Ties lowest y, then lowest x.
  nearestOfColour(coins, own, themX, themY)

proc kernelFor*(intent: Intent, coins: seq[Coin], own: Colour,
    meX, meY, themX, themY: int): Kernel =
  ## The target cell and forbidden-colour set for one cog on one tick.
  let other = if own == ccCopper: ccCobalt else: ccCopper
  case intent
  of inTakeMine:
    result.forbid = {other}
    let hit = nearestOfColour(coins, own, meX, meY)
    if hit.found:
      result.hasTarget = true
      result.tx = hit.x
      result.ty = hit.y
  of inTakeAny:
    result.forbid = {}
    let hit = nearestAny(coins, own, meX, meY)
    if hit.found:
      result.hasTarget = true
      result.tx = hit.x
      result.ty = hit.y
    else:
      ## Nothing to take: walk to the room centre and wait there.
      result.hasTarget = true
      result.tx = RoomCentre[0]
      result.ty = RoomCentre[1]
  of inTakeTheirs:
    result.forbid = {}
    let hit = nearestOfColour(coins, other, meX, meY)
    if hit.found:
      result.hasTarget = true
      result.tx = hit.x
      result.ty = hit.y
    else:
      ## Fall back to take_mine's target; if that is also empty, hold.
      let mine = nearestOfColour(coins, own, meX, meY)
      if mine.found:
        result.hasTarget = true
        result.tx = mine.x
        result.ty = mine.y
  of inGuard:
    result.forbid = {other}
    let hit = nearestOwnToThem(coins, own, themX, themY)
    if hit.found:
      result.hasTarget = true
      result.tx = hit.x
      result.ty = hit.y
  of inHold:
    result.forbid = {other}

proc reducingDirections*(kernel: Kernel, meX, meY: int): seq[int] =
  ## Those of N, E, S, W (in that order) that strictly reduce the Manhattan
  ## distance to the target.
  if not kernel.hasTarget:
    return @[]
  let here = manhattan(meX, meY, kernel.tx, kernel.ty)
  for dir in 0 .. 3:
    let nx = meX + MoveDx[dir]
    let ny = meY + MoveDy[dir]
    if manhattan(nx, ny, kernel.tx, kernel.ty) < here:
      result.add(dir)
