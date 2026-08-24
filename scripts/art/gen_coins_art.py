#!/usr/bin/env python3
"""Bake the Coins board art from the committed nano-banana source sheets.

Deterministic and re-runnable: same inputs, same bytes out. CI does not
regenerate art — the derived PNGs under `data/` are committed — so this
script exists to make the assets reproducible rather than mysterious.

    python3 scripts/art/split_cog_sheet.py     # key + split the sheets
    python3 scripts/art/gen_coins_art.py       # bake data/

Sources (all `scripts/art/source/*.png`, all nano-banana renders of the
Softmax cog / its props, all committed):
  cogs_sheet.png   two cog liveries, copper and cobalt, on flat chroma green
  coins_sheet.png  the two struck coin faces, on flat chroma green
  floor_tile.png   the seamless worn vault floor

What this script OWNS (and what nothing else may write):
  data/rig_coins/{copper,cobalt}/cog_{n,e,s,w}.png   the two cog liveries,
      one sprite per facing: the nano-banana cog on its livery ground ring
      with a heading chevron, so the facing reads at 56 px without a label.
  data/coin_{copper,cobalt}_spin_{0..3}.png          the idle coin spin
  data/coin_{copper,cobalt}.png                      = spin frame 0
  data/room_floor.png                                the whole 504x504 room
      bake: the tiled vault floor, a chalk grid, and the wall ring cut from
      the shipped client/art/walls/{wall_h,wall_v}.jpg
  data/pickup_spark.png, data/theft_burst.png, data/decline_glyph.png

There is no procedural cog rig in this repo: the characters are renders.
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CUT = os.path.join(HERE, "cut")
SOURCE = os.path.join(HERE, "source")
DATA = os.path.join(REPO, "data")
WALLS = os.path.join(REPO, "client", "art", "walls")

CELL = 56
ROOM_W = 9
ROOM_H = 9
BOARD = CELL * ROOM_W

COPPER = (224, 82, 58)
COBALT = (63, 124, 196)
PAPER = (242, 232, 216)
INK = (26, 19, 14)

LIVERY = {"copper": COPPER, "cobalt": COBALT}
FACINGS = ["n", "e", "s", "w"]


def ensure(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def despill(image: Image.Image, tint: tuple[int, int, int]) -> Image.Image:
    """Repaint chroma spill.

    The backdrop is keyed by flood fill, but the model also paints a green
    belt or strap here and there, and a green accent on a copper cog reads as
    a keying bug even when it is not one. Any strongly-green pixel becomes the
    livery tint at the same luminance.
    """
    image = image.convert("RGBA")
    pixels = image.load()
    width, height = image.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            if g > r * 1.25 and g > b * 1.25 and g > 90:
                lum = (r * 299 + g * 587 + b * 114) // 1000
                scale = max(60, min(255, lum)) / 255.0
                pixels[x, y] = (
                    int(tint[0] * scale),
                    int(tint[1] * scale),
                    int(tint[2] * scale),
                    a,
                )
    return image


def ground_ring(size: int, tint: tuple[int, int, int]) -> Image.Image:
    """A livery-tinted ellipse under the wheels.

    The raid learning: a ring around the BODY hides the kit, so the role tint
    goes on the ground instead, where it reads at board scale and never
    fights the sprite.
    """
    scale = 4
    plate = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    pad = int(size * scale * 0.14)
    top = int(size * scale * 0.66)
    draw.ellipse(
        (pad, top, size * scale - pad, size * scale - int(size * scale * 0.06)),
        fill=tint + (105,),
        outline=tint + (190,),
        width=scale * 2,
    )
    return plate.resize((size, size), Image.LANCZOS)


def chevron(size: int, facing: str, tint: tuple[int, int, int]) -> Image.Image:
    """The heading pip, on the cell edge the cog is walking toward."""
    scale = 4
    plate = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    s = size * scale
    arm = int(s * 0.15)
    inset = int(s * 0.04)
    mid = s // 2
    if facing == "n":
        points = [(mid, inset), (mid - arm, inset + arm), (mid + arm, inset + arm)]
    elif facing == "s":
        points = [(mid, s - inset), (mid - arm, s - inset - arm),
                  (mid + arm, s - inset - arm)]
    elif facing == "e":
        points = [(s - inset, mid), (s - inset - arm, mid - arm),
                  (s - inset - arm, mid + arm)]
    else:
        points = [(inset, mid), (inset + arm, mid - arm), (inset + arm, mid + arm)]
    draw.polygon(points, fill=tint + (235,), outline=INK + (200,))
    return plate.resize((size, size), Image.LANCZOS)


def bake_cogs() -> None:
    for colour, tint in LIVERY.items():
        source = despill(Image.open(os.path.join(CUT, f"cog_{colour}.png")), tint)
        body = source.resize((int(CELL * 0.86), int(CELL * 0.86)), Image.LANCZOS)
        out_dir = os.path.join(DATA, "rig_coins", colour)
        ensure(out_dir)
        for facing in FACINGS:
            plate = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
            plate.alpha_composite(ground_ring(CELL, tint))
            # Anchored at the FEET: the ring is the contact point, the cog
            # stands on it, and the heading pip rides the cell edge.
            plate.alpha_composite(
                body, ((CELL - body.width) // 2, CELL - body.height - 2)
            )
            plate.alpha_composite(chevron(CELL, facing, tint))
            plate.save(os.path.join(out_dir, f"cog_{facing}.png"))
            print("wrote", os.path.join(out_dir, f"cog_{facing}.png"))


def bake_coins() -> None:
    """Four spin frames per colour: face, 60% squash, edge-on, 60% squash.

    The renderer picks a frame from the tick (`(t div 6) mod 4`), so the idle
    spin needs no state and survives a seek.
    """
    ensure(DATA)
    for colour, tint in LIVERY.items():
        face = despill(Image.open(os.path.join(CUT, f"coin_{colour}.png")), tint)
        face = face.resize((int(CELL * 0.72), int(CELL * 0.72)), Image.LANCZOS)
        for index, squash in enumerate((1.0, 0.6, 0.16, 0.6)):
            plate = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
            width = max(3, int(face.width * squash))
            frame = face.resize((width, face.height), Image.LANCZOS)
            if squash < 0.3:
                # Edge-on: a struck coin seen from the rim is a bright bar of
                # milled metal, not a squashed face.
                edge = Image.new("RGBA", frame.size, (0, 0, 0, 0))
                draw = ImageDraw.Draw(edge)
                draw.rounded_rectangle(
                    (0, 1, frame.width - 1, frame.height - 2),
                    radius=max(1, frame.width // 2),
                    fill=tuple(int(c * 0.82) for c in tint) + (255,),
                    outline=INK + (255,),
                )
                frame = edge
            plate.alpha_composite(
                frame,
                ((CELL - frame.width) // 2, (CELL - frame.height) // 2),
            )
            plate.save(os.path.join(DATA, f"coin_{colour}_spin_{index}.png"))
            if index == 0:
                plate.save(os.path.join(DATA, f"coin_{colour}.png"))
        print("wrote", os.path.join(DATA, f"coin_{colour}*.png"))


def bake_room() -> None:
    """The whole 504x504 room: floor, chalk grid, wall ring."""
    tile = Image.open(os.path.join(SOURCE, "floor_tile.png")).convert("RGB")
    # Two board cells per source tile keeps the flagstones bigger than a coin,
    # so the grid never reads as the floor pattern.
    tile = tile.resize((CELL * 2, CELL * 2), Image.LANCZOS)
    room = Image.new("RGBA", (BOARD, BOARD), (0, 0, 0, 255))
    for y in range(0, BOARD, tile.height):
        for x in range(0, BOARD, tile.width):
            room.paste(tile, (x, y))

    grid = Image.new("RGBA", (BOARD, BOARD), (0, 0, 0, 0))
    draw = ImageDraw.Draw(grid)
    for index in range(ROOM_W + 1):
        pos = index * CELL
        draw.line((pos, 0, pos, BOARD), fill=PAPER + (26,), width=1)
        draw.line((0, pos, BOARD, pos), fill=PAPER + (26,), width=1)
    room.alpha_composite(grid)

    wall_h = Image.open(os.path.join(WALLS, "wall_h.jpg")).convert("RGBA")
    wall_v = Image.open(os.path.join(WALLS, "wall_v.jpg")).convert("RGBA")
    top = wall_h.resize((BOARD, CELL), Image.LANCZOS)
    bottom = top.transpose(Image.FLIP_TOP_BOTTOM)
    left = wall_v.resize((CELL, BOARD), Image.LANCZOS)
    right = left.transpose(Image.FLIP_LEFT_RIGHT)
    room.paste(top, (0, 0))
    room.paste(bottom, (0, BOARD - CELL))
    room.paste(left, (0, 0))
    room.paste(right, (BOARD - CELL, 0))

    # A soft inner shadow where the wall meets the floor, so the ring reads as
    # a wall rather than a border.
    shade = Image.new("RGBA", (BOARD, BOARD), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    sd.rectangle(
        (CELL, CELL, BOARD - CELL - 1, BOARD - CELL - 1),
        outline=INK + (150,),
        width=6,
    )
    room.alpha_composite(shade.filter(ImageFilter.GaussianBlur(4)))
    ensure(DATA)
    room.save(os.path.join(DATA, "room_floor.png"))
    print("wrote", os.path.join(DATA, "room_floor.png"))


def burst(size: int, tint: tuple[int, int, int], spikes: int,
          cracked: bool) -> Image.Image:
    scale = 4
    plate = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    s = size * scale
    mid = s // 2
    outer = int(s * 0.42)
    inner = int(s * 0.14)
    points = []
    import math

    for step in range(spikes * 2):
        angle = math.pi * step / spikes - math.pi / 2
        radius = outer if step % 2 == 0 else inner
        points.append((mid + radius * math.cos(angle),
                       mid + radius * math.sin(angle)))
    draw.polygon(points, fill=tint + (215,), outline=PAPER + (230,))
    if cracked:
        draw.line((mid - outer // 2, mid - outer // 2,
                   mid + outer // 2, mid + outer // 2),
                  fill=INK + (235,), width=scale * 3)
        draw.line((mid + outer // 3, mid - outer // 2,
                   mid - outer // 3, mid + outer // 2),
                  fill=INK + (235,), width=scale * 2)
    return plate.resize((size, size), Image.LANCZOS)


def bake_fx() -> None:
    ensure(DATA)
    burst(CELL, PAPER, 8, False).save(os.path.join(DATA, "pickup_spark.png"))
    burst(CELL, COPPER, 6, True).save(os.path.join(DATA, "theft_burst.png"))
    # The restraint hand-off: an open ring with a bar through it, drawn over
    # the coin a cog refused to step on.
    scale = 4
    s = CELL * scale
    plate = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    pad = int(s * 0.22)
    draw.ellipse((pad, pad, s - pad, s - pad), outline=PAPER + (235,),
                 width=scale * 3)
    draw.line((pad + scale * 4, s - pad - scale * 4,
               s - pad - scale * 4, pad + scale * 4),
              fill=PAPER + (235,), width=scale * 3)
    plate.resize((CELL, CELL), Image.LANCZOS).save(
        os.path.join(DATA, "decline_glyph.png"))
    print("wrote", os.path.join(DATA, "pickup_spark.png"),
          os.path.join(DATA, "theft_burst.png"),
          os.path.join(DATA, "decline_glyph.png"))


def main() -> None:
    bake_cogs()
    bake_coins()
    bake_room()
    bake_fx()


if __name__ == "__main__":
    main()
