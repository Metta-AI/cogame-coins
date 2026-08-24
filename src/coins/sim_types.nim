## Coins wire types and constants.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`: the same split (consts,
## wire types, error type) and the same discipline — FIELD ORDER IS SACRED,
## because the replay pins these shapes and the wasm viewer re-reads them.
##
## Every sim quantity here is an INTEGER. Cell coordinates, facings, scores,
## tick counts and every RNG draw are whole numbers, so one seed reproduces
## one episode bit-exactly on any host (`tests/test_sim.nim` determinism).

import std/[hashes, strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (coins): the first rules — 7x7 open room, +1 per coin, -2 to the
    ## victim of a theft, one intent per 20-tick beat, random end after
    ## `minBeats`.

  TargetFps* = 24
    ## Ticks per second of replay video (paintbot's `fps`).
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## The replay transport's speed chips (chrome_common reads these).

  RoomW* = 9
  RoomH* = 9
  InteriorLo* = 1
  InteriorHi* = 7
  InteriorCells* = (InteriorHi - InteriorLo + 1) * (InteriorHi - InteriorLo + 1)

  CellPx* = 56
    ## Board pixels per cell. 9 x 56 = 504, a 1:1 board that always fits the
    ## frame — which is why the viewer drops `#viewpanel`.
  BoardW* = RoomW * CellPx
  BoardH* = RoomH * CellPx

  MapLayerId* = 0
  MapLayerType* = 0
  ZoomableFlag* = 1

  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 sprite whose LABEL carries the broadcast chrome JSON.
    ## broadcast_core.js routes it to `onText` and never draws it.

  RoomSpriteId* = 10
  CoinSpriteBase* = 20        ## + colourIndex * CoinSpinFrames + phase
  CoinSpinFrames* = 4
  CoinSpinTicks* = 6          ## ticks per idle-spin frame
  CogSpriteBase* = 30         ## +(slot * 4 + facing)
  FxSpriteBase* = 50          ## +0 pickup spark, +1 theft burst, +2 decline

  RoomObjectId* = 40
    ## In broadcast_core.js's STATIC BAND (ids 40..99 at z = StaticBandZ), so
    ## the baked room floor is composited once and cached for the whole
    ## replay instead of re-blitting 504x504 pixels every frame.
  StaticBandZ* = -32768
  CoinObjectBase* = 100
  CogObjectBase* = 200
  FxObjectBase* = 300
  MaxFxObjects* = 8

  MaxSayLen* = 48
    ## Rune cap on a seat's spectator-only `say`.
  MaxNotesLen* = 300
    ## Rune cap on a seat's private notebook.
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 64

  Seats* = 2
    ## Coins is a dyad. Every variant and the certification fixture carry
    ## `num_agents: 2`; there is no other seat count.

  CoinRngSalt* = 0x00C0_1147
  MoveRngSalt* = 0x004D_4F56
  EndRngSalt* = 0x00C0_1175

type
  CoinsError* = object of CatchableError

  Colour* = enum
    ccCopper = "copper"
    ccCobalt = "cobalt"

  Intent* = enum
    inTakeMine = "take_mine"
    inTakeAny = "take_any"
    inTakeTheirs = "take_theirs"
    inGuard = "guard"
    inHold = "hold"

  OrderSource* = enum
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"
    osScripted = "scripted"

  BlockReason* = enum
    brRestraint = "restraint"
    brContested = "contested"
    brOccupied = "occupied"

  EndReason* = enum
    erRandomEnd = "random_end"
    erBeatCap = "beat_cap"
    erDeadline = "deadline"
    erForfeit = "forfeit"

  Cog* = object
    ## Field order is sacred.
    x*, y*: int
    facing*: int              ## 0 = N, 1 = E, 2 = S, 3 = W
    stepCd*: int
    score*: int
    pickups*: int
    thefts*: int
    stolenFrom*: int
    intent*: Intent
    source*: OrderSource
    say*: string
    notes*: string
    latencyMs*: int
    connected*: bool

  Coin* = object
    x*, y*: int
    colour*: Colour

  Rng* = object
    ## Paintbot's seeded integer stream: xorshift64, drawn as a 30-bit
    ## non-negative integer. No float ever enters sim state.
    state*: uint64

const
  Aliases*: array[Seats, string] = ["Copper", "Cobalt"]
  OwnColour*: array[Seats, Colour] = [ccCopper, ccCobalt]
  TeamKeys*: array[Seats, string] = ["red", "blue"]
    ## chrome_common.js already knows `red` and `blue` (TEAM_COLOR /
    ## TEAM_ORDER), so the scorebug plates, the momentum legend and the
    ## endcard get their colours with ZERO edits to that file.
  TeamHex*: array[Seats, string] = ["#e0523a", "#3f7cc4"]
  SpawnCells*: array[Seats, tuple[x, y: int]] = [(1, 1), (7, 7)]
  MoveNames* = ["north", "east", "south", "west"]
  MoveDx* = [0, 1, 0, -1]
  MoveDy* = [-1, 0, 1, 0]

proc initRng*(seed: int): Rng =
  ## A seeded integer stream. The state is forced non-zero: xorshift64
  ## stalls forever on zero, which would silently freeze every draw.
  var s = uint64(seed) xor 0x9E3779B97F4A7C15'u64
  if s == 0'u64:
    s = 0x9E3779B97F4A7C15'u64
  Rng(state: s)

proc next*(rng: var Rng): int =
  ## The next draw, 0 .. 2^30 - 1.
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  int(x and 0x3FFF_FFFF'u64)

proc otherSlot*(slot: int): int =
  1 - slot

proc colourIndex*(colour: Colour): int =
  ord(colour)

proc parseColour*(text: string): Colour =
  case text.strip().toLowerAscii()
  of "copper": ccCopper
  of "cobalt": ccCobalt
  else: raise newException(CoinsError, "unknown coin colour: " & text)

proc parseIntent*(text: string): Intent =
  ## Case-insensitive, per the reply schema.
  case text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  of "take_mine": inTakeMine
  of "take_any": inTakeAny
  of "take_theirs": inTakeTheirs
  of "guard": inGuard
  of "hold": inHold
  else: raise newException(CoinsError, "unknown intent: " & text)

proc cleanText*(text: string, limit: int): string =
  ## Truncation is on RUNE boundaries, NEVER bytes. A byte cut once put
  ## invalid UTF-8 into a replay and only a strict parser found it (the
  ## bullwhip bug), so every string that lands in the replay comes through
  ## here.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc cleanSay*(text: string): string =
  ## Newlines in `say` become spaces; the cap is MaxSayLen runes.
  cleanText(text.replace("\n", " ").replace("\r", " "), MaxSayLen)

proc cleanNotes*(text: string): string =
  cleanText(text, MaxNotesLen)

proc manhattan*(ax, ay, bx, by: int): int =
  abs(ax - bx) + abs(ay - by)

proc hash*(cog: Cog): Hash =
  var h: Hash = 0
  h = h !& cog.x !& cog.y !& cog.facing !& cog.stepCd
  h = h !& cog.score !& cog.pickups !& cog.thefts !& cog.stolenFrom
  !$h

proc hash*(coin: Coin): Hash =
  var h: Hash = 0
  h = h !& coin.x !& coin.y !& ord(coin.colour)
  !$h
