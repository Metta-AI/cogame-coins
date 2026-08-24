## Dumps two real sprite-protocol packets (the opening frame and one later
## frame) so `client/broadcast_core.js` can be run over them outside a
## browser — the cheapest way to prove the board pipeline end to end without
## emscripten:
##
##   nim c -r --path:src -o:/tmp/packet_harness tools/packet_harness.nim \
##     dist/smoke/replay.json /tmp/pkt
##
## then feed /tmp/pkt.0.bin and /tmp/pkt.1.bin to a Node script that shims a
## canvas and calls `BroadcastCore.create({...}).ingest(bytes)`. A packet the
## real core parses (sprites snappy-decoded, objects placed, the chrome JSON
## delivered through `onText`, the native board 504x504) is a packet the wasm
## viewer will draw.
import std/[json, os]
import coins/[sim_types, replays, broadcast, global]

when isMainModule:
  let data = parseReplayBytes(readFile(paramStr(1)))
  var player = initReplayPlayer(data)
  var viewer = initViewerState()
  player.seek(0)
  var first = buildBoardPacket(player.frame(), viewer, player.pendingEvents)
  first.addChrome(buildStateJson(player, player.pendingEvents, true))
  var bytes = newString(first.len)
  for i, b in first: bytes[i] = char(b)
  writeFile(paramStr(2) & ".0.bin", bytes)
  for _ in 0 ..< 40:
    player.advance()
  var later = buildBoardPacket(player.frame(), viewer, player.pendingEvents)
  later.addChrome(buildStateJson(player, player.pendingEvents, false))
  bytes = newString(later.len)
  for i, b in later: bytes[i] = char(b)
  writeFile(paramStr(2) & ".1.bin", bytes)
  echo "packet0=", first.len, " packet1=", later.len
