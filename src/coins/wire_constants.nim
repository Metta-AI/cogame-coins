## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id).
##
## Forked from `coworld-ctf/src/ctf/wire_constants.nim`. Each HTML client
## used to re-type these as literals and nothing enforced agreement — a
## retuned PlaybackSpeeds would silently desync every client. This module
## renders them ONCE, from the same Nim consts the engine runs on;
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
## Clients read `window.COINS_WIRE` and keep their old literals only as
## fallbacks for raw file:// opens of the un-spliced sources.

import std/strutils
import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

# Emitted under BOTH names. `client/chrome_common.js` and
# `client/broadcast_core.js` are copied BYTE-FOR-BYTE from coworld-ctf and
# read `window.CTF_WIRE` — that literal is inside the files this repo is
# required not to touch — so `CTF_WIRE` is the canonical object and
# `COINS_WIRE` is the alias the appended Coins game block reads.
const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeed, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CTF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cellPx:" & $CellPx &
  ",boardW:" & $BoardW &
  ",boardH:" & $BoardH &
  ",ticksPerBeatDefault:20" &
  "};window.COINS_WIRE=window.CTF_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
