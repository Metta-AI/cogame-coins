## The board: paintbot's sprite protocol, heavily reduced.
##
## Forked from `coworld-ctf/src/ctf/global.nim` — the sprite-protocol
## emitter, layer/object pooling, the chrome `TextMessage` smuggling and the
## board render scale are kept; fog-of-war/FOV, the first-person PiP,
## articulated rigs, the grenade/spray/shield/barrier families, endzone
## bakes, perks and handicaps are all DELETED. Coins has one fixed 9 x 9
## room, two cogs and a handful of coins.
##
## The board draws NO TEXT. Every string in the chrome (scorebug, clock,
## feed, endcard) is DOM, which is what lets `viewer_smoke.mjs` run with
## `--strict-text-bounds` on a fixed arena and expect zero never-inside
## canvas strings.

import std/[json, math, strutils, tables]
import bitworld/spriteprotocol
import pixie
import sim_types, sim

const
  RoomFloorPng = staticRead("../../data/room_floor.png")
  CoinPng: array[8, string] = [
    staticRead("../../data/coin_copper_spin_0.png"),
    staticRead("../../data/coin_copper_spin_1.png"),
    staticRead("../../data/coin_copper_spin_2.png"),
    staticRead("../../data/coin_copper_spin_3.png"),
    staticRead("../../data/coin_cobalt_spin_0.png"),
    staticRead("../../data/coin_cobalt_spin_1.png"),
    staticRead("../../data/coin_cobalt_spin_2.png"),
    staticRead("../../data/coin_cobalt_spin_3.png")
  ]
  CogPng: array[8, string] = [
    staticRead("../../data/rig_coins/copper/cog_n.png"),
    staticRead("../../data/rig_coins/copper/cog_e.png"),
    staticRead("../../data/rig_coins/copper/cog_s.png"),
    staticRead("../../data/rig_coins/copper/cog_w.png"),
    staticRead("../../data/rig_coins/cobalt/cog_n.png"),
    staticRead("../../data/rig_coins/cobalt/cog_e.png"),
    staticRead("../../data/rig_coins/cobalt/cog_s.png"),
    staticRead("../../data/rig_coins/cobalt/cog_w.png")
  ]
  FxPng: array[3, string] = [
    staticRead("../../data/pickup_spark.png"),
    staticRead("../../data/theft_burst.png"),
    staticRead("../../data/decline_glyph.png")
  ]
  FxLifeTicks = 8

type
  SpriteBlob = object
    width, height: int
    pixels: seq[uint8]

  FxItem* = object
    x*, y*, sprite*, life*: int

  ViewerState* = object
    initialized*: bool
    coinsPlaced*: int
    fxPlaced*: int
    fx*: seq[FxItem]
    leadSent*: bool
    seekTick*: int
    commands*: seq[char]

var spriteCache: Table[int, SpriteBlob]

proc imageToStraightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the sprite protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc blobOf(spriteId: int, png: string): SpriteBlob =
  if spriteCache.hasKey(spriteId):
    return spriteCache[spriteId]
  let image = decodeImage(png)
  result = SpriteBlob(width: image.width, height: image.height,
    pixels: imageToStraightRgba(image))
  spriteCache[spriteId] = result

proc initViewerState*(): ViewerState =
  result.seekTick = -1

# ---------------------------------------------------------------------------
# client -> viewer messages
# ---------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var ViewerState, message: string) =
  ## The transport commands broadcast_core.js sends as SpriteClientChat.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.len > 2 and item.text[0] == 's' and item.text[1] == ':':
        var tick = -1
        try:
          tick = parseInt(item.text[2 .. ^1])
        except ValueError:
          tick = -1
        if tick >= 0:
          state.seekTick = tick
      elif item.text.len > 2 and item.text[0] == 'v' and item.text[1] == ':':
        ## Coins has no POV lens (`#povBadge` is removed): ignore.
        discard
      else:
        for ch in item.text:
          state.commands.add(ch)
    else:
      discard

# ---------------------------------------------------------------------------
# sprite definitions (sent once)
# ---------------------------------------------------------------------------

proc addSpriteFrom(packet: var seq[uint8], spriteId: int, png: string) =
  let blob = blobOf(spriteId, png)
  packet.addSprite(spriteId, blob.width, blob.height, blob.pixels)

proc addOpening(packet: var seq[uint8]) =
  packet.addViewport(MapLayerId, BoardW, BoardH)
  packet.addLayer(MapLayerId, MapLayerType, ZoomableFlag)
  packet.addSpriteFrom(RoomSpriteId, RoomFloorPng)
  for index in 0 .. 7:
    packet.addSpriteFrom(CoinSpriteBase + index, CoinPng[index])
  for index in 0 .. 7:
    packet.addSpriteFrom(CogSpriteBase + index, CogPng[index])
  for index in 0 .. 2:
    packet.addSpriteFrom(FxSpriteBase + index, FxPng[index])
  packet.addObject(RoomObjectId, 0, 0, StaticBandZ, MapLayerId, RoomSpriteId)

# ---------------------------------------------------------------------------
# the per-frame packet
# ---------------------------------------------------------------------------

proc ingestFx(state: var ViewerState, events: JsonNode) =
  ## Board flourishes fed by the events this frame crossed. A `blocked`
  ## `why: "restraint"` plants the hand-off glyph on the coin the cog
  ## refused, so the restraint is SEEN and not merely counted.
  for record in events:
    case record{"k"}.getStr()
    of "pickup":
      state.fx.add(FxItem(x: record{"x"}.getInt(), y: record{"y"}.getInt(),
        sprite: FxSpriteBase + 0, life: FxLifeTicks))
    of "theft":
      state.fx.add(FxItem(x: record{"x"}.getInt(), y: record{"y"}.getInt(),
        sprite: FxSpriteBase + 1, life: FxLifeTicks))
    of "blocked":
      if record{"why"}.getStr() == "restraint":
        state.fx.add(FxItem(x: record{"x"}.getInt(), y: record{"y"}.getInt(),
          sprite: FxSpriteBase + 2, life: FxLifeTicks))
    else:
      discard
  var alive: seq[FxItem]
  for item in state.fx:
    if item.life > 1:
      alive.add(FxItem(x: item.x, y: item.y, sprite: item.sprite,
        life: item.life - 1))
  state.fx = alive
  if state.fx.len > MaxFxObjects:
    state.fx = state.fx[state.fx.len - MaxFxObjects .. ^1]

proc buildBoardPacket*(frame: Frame, state: var ViewerState,
    events: JsonNode): seq[uint8] =
  ## The board half of one presentation frame. Retained mode: an object keeps
  ## its placement until it is replaced or deleted, so only the moving parts
  ## are re-described.
  if not state.initialized:
    state.initialized = true
    result.addOpening()
  state.ingestFx(events)
  let coins = frame.coinsOf()
  let cogs = frame.cogsOf()
  ## The idle spin is a pure function of the tick, so it needs no state and
  ## survives a seek: (t div CoinSpinTicks) mod CoinSpinFrames.
  let phase = (frame.t div CoinSpinTicks) mod CoinSpinFrames
  for index, coin in coins:
    result.addObject(CoinObjectBase + index, coin.x * CellPx, coin.y * CellPx,
      coin.y * 2, MapLayerId,
      CoinSpriteBase + colourIndex(coin.colour) * CoinSpinFrames + phase)
  for index in coins.len ..< state.coinsPlaced:
    result.addDeleteObject(CoinObjectBase + index)
  state.coinsPlaced = coins.len
  for slot, cog in cogs:
    if slot >= Seats: break
    let facing = clamp(cog.facing, 0, 3)
    result.addObject(CogObjectBase + slot, cog.x * CellPx, cog.y * CellPx,
      cog.y * 2 + 1, MapLayerId, CogSpriteBase + slot * 4 + facing)
  for index, item in state.fx:
    result.addObject(FxObjectBase + index, item.x * CellPx, item.y * CellPx,
      RoomH * 2 + 4, MapLayerId, item.sprite)
  for index in state.fx.len ..< state.fxPlaced:
    result.addDeleteObject(FxObjectBase + index)
  state.fxPlaced = state.fx.len

proc addChrome*(packet: var seq[uint8], chromeJson: string) =
  ## The broadcast chrome rides as the LABEL of the reserved 1x1 sprite
  ## broadcast_core.js routes straight to `onText` and never draws.
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chromeJson)
