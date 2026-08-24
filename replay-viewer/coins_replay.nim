## Coins static replay viewer, wasm side.
##
## Forked from `coworld-ctf/replay-viewer/ctf_replay.nim` — same structure and
## the same safety furniture: the `stageNote` buffer plus its `stampStage`
## calls, the `ABORTING_MALLOC` rationale, and the
## `emscripten_exit_with_live_runtime()` epilogue.
##
## `ctf_mismatch_tick` is DROPPED: Coins records state, not inputs, so there
## is no re-simulation to mismatch (and therefore no `#mmwarn` in the page).
##
## JS hands the raw replay bytes to `coins_load_replay`; this module parses
## them and exposes one sprite-protocol packet per presentation frame, with
## the broadcast chrome smuggled as the label of the reserved 1x1 sprite.

import std/json
import coins/[sim_types, replays, broadcast, global]

var
  runtimeLoaded = false
  player: ReplayPlayer
  viewer: ViewerState
  packet: seq[uint8]
  lastError: string
  leadSent = false

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable
## from JS after the abort (aborting kills the call stack, not the linear
## memory), so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  packet = buildBoardPacket(player.frame(), viewer, events)
  packet.addChrome(buildStateJson(player, events, not leadSent))
  leadSent = true

proc coinsLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "coins_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay playhead")
    player = initReplayPlayer(replayData)
    viewer = initViewerState()
    leadSent = false
    runtimeLoaded = true
    let note = " (room " & $RoomW & "x" & $RoomH & ", " &
      $replayData.frames.len & " frames)"
    ## The 9 x 9 board is orders of magnitude under the wasm32 budget, so
    ## this check is kept for shape but never trips.
    stampStage("check viewer capacity" & note)
    let predicted = int64(BoardW) * int64(BoardH) * 4
    if predicted > 1_600_000_000'i64:
      raise newException(CoinsError,
        "replay board is too large for the browser viewer" & note)
    frameStage = "advance replay" & note
    stampStage("render first frame" & note)
    player.seek(0)
    renderCurrent(player.pendingEvents)
    return 1
  except Exception as error:
    ## Exception, not CatchableError: a Defect from the wasm build (an index
    ## or range check) must surface as a message in the shell, not as a
    ## silent zero with an empty error string.
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg
    if lastError.len == 0:
      lastError = "unknown failure while loading the replay"
    return 0

proc coinsInput(data: ptr uint8, length: cint) {.exportc: "coins_input",
    cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc coinsFrame(): cint {.exportc: "coins_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let before = player.tick
    if viewer.seekTick >= 0:
      player.seek(viewer.seekTick)
      viewer.seekTick = -1
    if viewer.commands.len > 0:
      for command in viewer.commands:
        player.applyCommand(command)
      viewer.commands = @[]
    if player.tick == before:
      player.advance()
    elif player.tick < before:
      ## A backward jump invents no motion: drop the board flourishes so a
      ## seek cannot leave a stale spark hanging over an empty cell.
      viewer.fx = @[]
    renderCurrent(player.pendingEvents)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg
    return -1

proc coinsPacketPointer(): ptr uint8 {.exportc: "coins_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc coinsPacketLength(): cint {.exportc: "coins_packet_len", cdecl.} =
  cint(packet.len)

proc coinsErrorPointer(): ptr uint8 {.exportc: "coins_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc coinsErrorLength(): cint {.exportc: "coins_error_len", cdecl.} =
  cint(lastError.len)

proc coinsStagePointer(): ptr uint8 {.exportc: "coins_stage_ptr", cdecl.} =
  ## Unlike coins_error_*, this stays valid after an allocation-failure
  ## abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc coinsStageLength(): cint {.exportc: "coins_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main runs every module-global destructor when it
  ## returns, freeing the packet, the parsed replay and the sprite cache
  ## while the wasm module stays alive and JS keeps calling in. Unwinding
  ## main through emscripten's live-runtime exit skips the destructor
  ## epilogue entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
