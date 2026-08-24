#!/usr/bin/env python3
"""Key, split and pad the nano-banana source sheets.

The worked example is `Metta-AI/cogame-raid` PR #2
(`scripts/art/source/cogs_sheet.png` + `scripts/art/split_cog_sheet.py`);
this is that script with Coins' two liveries and the coin sheet added.

Gemini does not return alpha, and the "pure green" the prompt asks for comes
back as *some* green with a tinted edge. So: flood-fill from the image border
(green accents INSIDE a character survive), take the backdrop colour as the
MEDIAN of the border pixels (corners sometimes carry a smudge), split the row
on empty columns, and pad each part to a square.

    python3 scripts/art/split_cog_sheet.py

Writes `scripts/art/cut/<name>.png` (keyed, trimmed, padded, RGBA). The
per-asset bake — facings, spin frames, the room, the fx — is
`scripts/art/gen_coins_art.py`, which reads these cuts.

Pillow is the only dependency:
    python3 -c 'import PIL' || python3 -m pip install --user pillow
"""

from __future__ import annotations

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
CUT = os.path.join(HERE, "cut")

# sheet file -> the names of the parts, left to right
SHEETS = {
    "cogs_sheet.png": ["cog_copper", "cog_cobalt"],
    "coins_sheet.png": ["coin_copper", "coin_cobalt"],
}

TOLERANCE = 60          # how far from the backdrop colour still counts as backdrop
EDGE_TOLERANCE = 96     # a second, looser pass that eats the anti-aliased fringe
OUT_SIZE = 256


def median_border(image: Image.Image) -> tuple[int, int, int]:
    """The backdrop colour, as the median of the image border."""
    width, height = image.size
    reds, greens, blues = [], [], []
    for x in range(width):
        for y in (0, height - 1):
            r, g, b = image.getpixel((x, y))[:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    for y in range(height):
        for x in (0, width - 1):
            r, g, b = image.getpixel((x, y))[:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    reds.sort()
    greens.sort()
    blues.sort()
    mid = len(reds) // 2
    return reds[mid], greens[mid], blues[mid]


def key_backdrop(image: Image.Image) -> Image.Image:
    """Flood-fill the backdrop from the border, so inner green survives."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    key = median_border(image)

    def near(colour, tolerance):
        return (
            abs(colour[0] - key[0]) <= tolerance
            and abs(colour[1] - key[1]) <= tolerance
            and abs(colour[2] - key[2]) <= tolerance
        )

    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()
    for x in range(width):
        for y in (0, height - 1):
            queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        seen[index] = 1
        if not near(pixels[x, y], TOLERANCE):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

    # Second pass: any pixel that is still backdrop-ish AND touches a
    # transparent one is the anti-aliased fringe. Two sweeps eat the halo
    # without biting into the character.
    for _ in range(2):
        edge = []
        for y in range(height):
            for x in range(width):
                if pixels[x, y][3] == 0:
                    continue
                if not near(pixels[x, y], EDGE_TOLERANCE):
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height and pixels[nx, ny][3] == 0:
                        edge.append((x, y))
                        break
        for x, y in edge:
            pixels[x, y] = (0, 0, 0, 0)
    return image


def column_runs(image: Image.Image) -> list[tuple[int, int]]:
    """Contiguous columns that hold any opaque pixel."""
    width, height = image.size
    pixels = image.load()
    filled = []
    for x in range(width):
        hit = False
        for y in range(height):
            if pixels[x, y][3] > 8:
                hit = True
                break
        filled.append(hit)
    runs = []
    start = None
    for x, hit in enumerate(filled):
        if hit and start is None:
            start = x
        elif not hit and start is not None:
            runs.append((start, x - 1))
            start = None
    if start is not None:
        runs.append((start, width - 1))
    # Drop specks: anything under 2% of the sheet width is keying noise.
    return [run for run in runs if run[1] - run[0] > width * 0.02]


def pad_square(image: Image.Image, size: int) -> Image.Image:
    box = image.getbbox()
    if box:
        image = image.crop(box)
    side = max(image.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    return square.resize((size, size), Image.LANCZOS)


def main() -> int:
    os.makedirs(CUT, exist_ok=True)
    for sheet, names in SHEETS.items():
        path = os.path.join(SOURCE, sheet)
        if not os.path.exists(path):
            print(f"missing source sheet: {path}", file=sys.stderr)
            return 1
        keyed = key_backdrop(Image.open(path))
        runs = column_runs(keyed)
        if len(runs) != len(names):
            print(
                f"{sheet}: found {len(runs)} parts, expected {len(names)} "
                f"({runs})",
                file=sys.stderr,
            )
            return 1
        for name, (x0, x1) in zip(names, runs):
            part = keyed.crop((x0, 0, x1 + 1, keyed.height))
            out = os.path.join(CUT, f"{name}.png")
            pad_square(part, OUT_SIZE).save(out)
            print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
