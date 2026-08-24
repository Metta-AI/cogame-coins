## The room: one fixed 9 x 9 arena with a one-cell wall ring.
##
## Replaces paintbot's `arena.nim` / `map_pool.nim` / `mapgen_styles.nim`
## entirely. There is no generator, no obstacle authoring and no `roomSize`
## knob: the room is a compile-time ASCII constant in every variant, which is
## exactly what lets the viewer drop `#viewpanel` and run
## `viewer_smoke --strict-text-bounds`.

import sim_types

const
  RoomAscii*: array[RoomH, string] = [
    "#########",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#.......#",
    "#########"
  ]

static:
  for row in RoomAscii:
    doAssert row.len == RoomW, "every room row must be " & $RoomW & " wide"

proc isWall*(x, y: int): bool =
  if x < 0 or y < 0 or x >= RoomW or y >= RoomH:
    return true
  RoomAscii[y][x] == '#'

proc isFloor*(x, y: int): bool =
  not isWall(x, y)

proc isInterior*(x, y: int): bool =
  ## The 7 x 7 walkable interior. Identical to `isFloor` for this room, and
  ## both are checked so a future room with an interior pillar cannot let a
  ## cog stand inside one.
  x >= InteriorLo and x <= InteriorHi and
    y >= InteriorLo and y <= InteriorHi and isFloor(x, y)

iterator interiorCells*(): tuple[x, y: int] =
  ## Row-major, so every "uniform among interior cells" draw is a single
  ## index into a deterministic order.
  for y in InteriorLo .. InteriorHi:
    for x in InteriorLo .. InteriorHi:
      if isFloor(x, y):
        yield (x, y)

proc roomWalls*(): seq[string] =
  for row in RoomAscii:
    result.add(row)
