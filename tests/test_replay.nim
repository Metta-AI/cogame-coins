## tests/test_replay.nim — end-to-end plus a STRICT UTF-8 parse.
##
## Plays a full scripted episode headless, writes `results.json` and the
## replay, then re-reads the replay BYTES: `validateUtf8 == -1` (strict),
## parses as JSON, and every structural invariant the viewer depends on.
##
## A seat is then fed a `say`/`notes` of multi-byte runes exactly at the
## 48 / 300 caps and the recorded strings are asserted valid UTF-8 and <= the
## cap in RUNES — the bullwhip byte-truncation bug, which put invalid UTF-8
## into a replay and was only ever found by a strict parser.

import std/[json, os, strutils, unicode]
import coins/[sim_types, sim, scripted, replays]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

proc certConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.minBeats = 16
  result.maxBeats = 16
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

# ---------------------------------------------------------------------------
echo "--- rune truncation, at the cap and past it"
block:
  ## Two-rune-wide characters: a byte cut lands mid-sequence and produces
  ## invalid UTF-8; a rune cut cannot.
  let wide = "\u00e9"                 ## e-acute: 2 bytes, 1 rune
  let sayAtCap = wide.repeat(MaxSayLen)
  let notesAtCap = wide.repeat(MaxNotesLen)
  check(sayAtCap.runeLen == MaxSayLen, "the fixture say is exactly at the cap")
  check(cleanSay(sayAtCap) == sayAtCap, "text at the cap is untouched")
  check(cleanNotes(notesAtCap) == notesAtCap, "notes at the cap are untouched")
  let sayOver = wide.repeat(MaxSayLen + 40)
  let notesOver = wide.repeat(MaxNotesLen + 90)
  check(cleanSay(sayOver).runeLen <= MaxSayLen,
    "an over-cap say is cut to the cap IN RUNES")
  check(cleanNotes(notesOver).runeLen <= MaxNotesLen,
    "an over-cap notes is cut to the cap IN RUNES")
  check(validateUtf8(cleanSay(sayOver)) == -1,
    "the truncated say is still valid UTF-8")
  check(validateUtf8(cleanNotes(notesOver)) == -1,
    "the truncated notes is still valid UTF-8")
  check(cleanSay("a\nb") == "a b", "newlines in say become spaces")

# ---------------------------------------------------------------------------
echo "--- a full episode, written and re-read"
let wide = "\u4e2d"                   ## 3 bytes, 1 rune
let sayFixture = wide.repeat(MaxSayLen + 12)
let notesFixture = wide.repeat(MaxNotesLen + 25)

var episode = initSim(certConfig(7))
block:
  proc now(): float {.closure.} = 0.0
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    let kinds = [skGreedy, skReciprocator]
    for slot in seats:
      result.add(Decision(
        intent: scriptedIntent(kinds[slot], view.buildObservation(slot),
          view.config.punishThreshold, view.config.punishBeats),
        source: (if slot == 0: osLlm else: osScripted),
        # Both free-text fields arrive already rune-truncated, exactly as
        # `parseDecision` produces them.
        say: cleanSay(sayFixture),
        notes: cleanNotes(notesFixture)))
  episode.policyNames = ["coins-truce", "coins-reciprocator"]
  episode.runEpisode(decide, now)

let bytes = replayBytes(episode)
let resultsBytes = $episode.resultsJson()
let dir = getTempDir() / "coins-test-replay"
createDir(dir)
writeFile(dir / "replay.json", bytes)
writeFile(dir / "results.json", resultsBytes)
let readBack = readFile(dir / "replay.json")
removeDir(dir)

check(validateUtf8(readBack) == -1,
  "the replay bytes are STRICT valid UTF-8 (validateUtf8 == -1)")
check(readBack.len < 4 * 1024 * 1024,
  "the replay is under 4 MiB, got " & $readBack.len & " bytes")
echo "replay size: ", readBack.len, " bytes"

let node = parseJson(readBack)
check(node{"protocol"}.getStr() == "coins.replay.v1", "protocol")
check(node{"game"}.getStr() == "coins", "game name")
check(node.hasKey("seed") and node{"seed"}.getInt() == 7, "the seed is pinned")
check(node.hasKey("config"), "the whole config is pinned")
check(node{"config"}{"ticksPerBeat"}.getInt() == 20, "config carries the beat")
check(node{"room"}{"walls"}.len == 9, "room.walls is present, 9 rows")
check(node{"names"}.len == 2 and node{"policyNames"}.len == 2,
  "names.len == policyNames.len == 2")
check(node{"policyNames"}[0].getStr() == "coins-truce",
  "the replay carries POLICY names alongside the aliases")
check(node{"names"}[0].getStr() == "Copper", "and the anonymous aliases")

let ticksPlayed = node{"ticksPlayed"}.getInt()
check(ticksPlayed == 16 * 20, "320 ticks at the cert fixture")
check(node{"frames"}.len == ticksPlayed,
  "frames.len == ticksPlayed: " & $node{"frames"}.len)
check(node{"series"}{"score"}.len == ticksPlayed,
  "series.score.len == ticksPlayed")
check(node{"series"}{"beatThefts"}.len == node{"beats"}.getInt(),
  "series.beatThefts.len == beats")

var kinds: seq[string]
var beatCloses = 0
var ends = 0
var spawns = 0
var pickups = 0
var thefts = 0
var orders = 0
var recordedSay = ""
var recordedNotes = ""
for record in node{"events"}:
  let kind = record{"k"}.getStr()
  if kind notin kinds: kinds.add(kind)
  let t = record{"t"}.getInt()
  check(t >= 0 and t <= ticksPlayed,
    "every event tick is inside 0..ticksPlayed, got " & $t)
  case kind
  of "beatclose": beatCloses.inc
  of "end": ends.inc
  of "spawn": spawns.inc
  of "pickup": pickups.inc
  of "theft": thefts.inc
  of "order":
    orders.inc
    recordedSay = record{"say"}.getStr()
    recordedNotes = record{"notes"}.getStr()
  else: discard

check(spawns >= 1, "at least one spawn")
check(pickups >= 1, "at least one pickup")
check(thefts >= 1, "at least one theft")
check(orders == node{"beats"}.getInt() * 2,
  "one order per seat per beat: " & $orders)
check(beatCloses == node{"beats"}.getInt(),
  "exactly `beats` beatclose events: " & $beatCloses)
check(ends == 1, "exactly one end event")
for kind in kinds:
  check(kind in ["order", "spawn", "pickup", "theft", "blocked", "truce",
    "leadchange", "beatclose", "end"],
    "the event vocabulary is closed, saw " & kind)

check(validateUtf8(recordedSay) == -1, "the recorded say is valid UTF-8")
check(validateUtf8(recordedNotes) == -1, "the recorded notes is valid UTF-8")
check(recordedSay.runeLen <= MaxSayLen,
  "the recorded say is <= " & $MaxSayLen & " RUNES, got " &
  $recordedSay.runeLen)
check(recordedNotes.runeLen <= MaxNotesLen,
  "the recorded notes is <= " & $MaxNotesLen & " RUNES, got " &
  $recordedNotes.runeLen)

let results = node{"results"}
check(results{"scores"}.len == 2, "results.scores.len == 2")
check(results{"names"}.len == 2, "results.names.len == 2")
check(results{"reason"}.getStr() in
  ["random_end", "beat_cap", "deadline", "forfeit"],
  "results.reason is one of the four legal values, got " &
  results{"reason"}.getStr())
check(results{"reason"}.getStr() == "beat_cap",
  "minBeats == maxBeats ends with beat_cap")
check(results{"win"}.len == 2, "results.win.len == 2")
check(results{"restraint"}.len == 2, "results.restraint.len == 2")

check($parseJson(resultsBytes) == $episode.resultsJson(),
  "results.json round-trips")

# ---------------------------------------------------------------------------
echo "--- the recorded frames come back FRAME BY FRAME, element by element"
block:
  ## Coins records STATE, not inputs: there is no re-simulation, so the
  ## property the checklist's "replaying reproduces the recorded per-tick
  ## state frame by frame" guards — a display fed by a parallel recording —
  ## becomes this: the bytes the viewer parses carry the sim's own frames
  ## exactly, every tick, every field. Nothing else the viewer draws can be
  ## right if this is wrong, and nothing before this asserted more than the
  ## frame COUNT, the config and the terminal frame.
  let roundTrip = parseReplayBytes(readBack)
  check(roundTrip.frames.len == episode.frames.len,
    "the parsed replay carries one frame per recorded frame")
  var mismatched = -1
  for index in 0 ..< min(roundTrip.frames.len, episode.frames.len):
    let want = episode.frames[index]
    let got = roundTrip.frames[index]
    if got.t != want.t or got.c != want.c or got.k != want.k or
        got.sc != want.sc or got.th != want.th:
      mismatched = index
      break
  check(mismatched < 0,
    "every frame matches the sim's own, element by element (first " &
    "mismatch at tick " & $mismatched & ")")
  for index in 0 ..< roundTrip.frames.len:
    check(roundTrip.frames[index].t == index,
      "frame " & $index & " is the state at tick " & $index)
  ## And the viewer's own re-derivation runs off exactly those frames: the
  ## player's frame at tick i IS frame i (tests/test_viewer.nim then walks
  ## every one of them through buildStateJson, the same proc the live server
  ## calls).
  var framePlayer = initReplayPlayer(roundTrip)
  for index in 0 ..< roundTrip.frames.len:
    framePlayer.seek(index)
    let frame = framePlayer.frame()
    if frame.t != episode.frames[index].t or
        frame.sc != episode.frames[index].sc or
        frame.c != episode.frames[index].c:
      check(false, "the playhead at tick " & $index &
        " does not return the sim's frame " & $index)
      break

# ---------------------------------------------------------------------------
echo "--- an episode that ends before its first tick still writes a LOADABLE replay"
block:
  ## `forfeit` — neither seat connected — settles without ever calling
  ## stepTick. A replay whose `frames` array is empty is rejected by the
  ## parser ("replay carries no frames"), so the artifact the platform stores
  ## would set data-replay-error instead of rendering.
  var stillborn = initSim(certConfig(11))
  stillborn.endEpisode(erForfeit)
  let forfeitBytes = replayBytes(stillborn)
  check(validateUtf8(forfeitBytes) == -1, "the forfeit replay is valid UTF-8")
  let forfeitData = parseReplayBytes(forfeitBytes)
  check(forfeitData.frames.len == 1,
    "it carries the opening position as its one frame")
  let forfeitNode = parseJson(forfeitBytes)
  check(forfeitNode{"ticksPlayed"}.getInt() == forfeitData.frames.len,
    "ticksPlayed and frames stay in step")
  check(forfeitNode{"series"}{"score"}.len == forfeitData.frames.len,
    "and so does the score series")
  check(forfeitNode{"results"}{"reason"}.getStr() == "forfeit",
    "the reason is still forfeit")
  check(forfeitData.results{"scores"}[0].getFloat() == 0.0 and
      forfeitData.results{"scores"}[1].getFloat() == 0.0,
    "with both scores zero")
  var forfeitPlayer = initReplayPlayer(forfeitData)
  check(forfeitPlayer.maxTick() == 0,
    "the playhead has exactly one tick to show")

# ---------------------------------------------------------------------------
echo "--- the replay parses back into a playable playhead"
block:
  let data = parseReplayBytes(readBack)
  check(data.frames.len == ticksPlayed, "the parser recovers every frame")
  check(data.config.ticksPerBeat == 20, "and the config")
  var player = initReplayPlayer(data)
  check(player.maxTick() == ticksPlayed - 1, "maxTick")
  player.seek(player.maxTick())
  check(player.tick == ticksPlayed - 1, "a seek is an array index")
  let frame = player.frame()
  check(frame.sc[0] == episode.cogs[0].score and frame.sc[1] == episode.cogs[1].score,
    "the last frame carries the final scores")
  player.seek(0)
  var advanced = 0
  for _ in 0 ..< ticksPlayed + 10:
    let before = player.tick
    player.advance()
    if player.tick != before: advanced.inc
  check(advanced > 0, "playback advances")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_replay OK"
