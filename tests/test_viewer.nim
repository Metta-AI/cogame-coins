## tests/test_viewer.nim — the chrome frame and the appended game block.
##
## `buildStateJson` emits exactly the inherited chrome key set plus `cn`;
## `teams` keys are exactly `red` and `blue`; `lead.pts` rows are
## `[t, score0, score1]`; the roster carries the policy name, colour and
## score; `over` is present on the terminal frame; a `.beat-marker` CSS rule
## exists for EVERY beat kind emitted and the kinds emitted are exactly those
## four; the beat markers are `<button>` elements with an `aria-label`; the
## `.plate-name` rule and the `.tiny` rules are present; `#viewpanel`, `#fpv`,
## `#povBadge` and `#mmwarn` are absent from the page; `chrome_common.js` is
## carried into the bundle verbatim; and NO game-block top-level identifier
## collides with the chrome alias list (the tandem hoisting bug, where a
## game-block `function markBeat` is hoisted over the chrome alias block's
## `var markBeat = C.markBeat` and the scrubber silently renders unlabeled,
## unclickable divs).

import std/[algorithm, json, os, sets, strutils]
import coins/[sim_types, sim, scripted, replays, broadcast, events]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

let root = currentSourcePath().parentDir().parentDir()
let page = readFile(root / "client" / "replay_broadcast.html")
let chromeCommon = readFile(root / "client" / "chrome_common.js")
let viewerDockerfile = readFile(root / "Dockerfile.replay-viewer")

const BannerMarker = "COINS additions to the inherited coworld-ctf chrome"

# ---------------------------------------------------------------------------
echo "--- provenance: the starter's page with a game block appended"
check(BannerMarker in page,
  "the game block is appended under its banner comment")
let bannerAt = page.find(BannerMarker)
check("window.ChromeCommon" in chromeCommon,
  "client/chrome_common.js is the shared chrome module")
check("var WIRE = window.CTF_WIRE" in chromeCommon,
  "chrome_common.js is byte-for-byte the starter's — including the wire " &
  "constants object name it reads, which is why wire_constants.js emits " &
  "BOTH window.CTF_WIRE and the window.COINS_WIRE alias")
check("cp client/chrome_common.js replay-viewer/dist/chrome_common.js" in
  viewerDockerfile,
  "the bundle copies chrome_common.js verbatim — no sed, no rewrite")
check("cp client/broadcast_core.js replay-viewer/dist/broadcast_core.js" in
  viewerDockerfile, "and broadcast_core.js verbatim")

echo "--- the removed starter elements are gone"
for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
           "zoom-in", "zoom-slider", "zoom-read", "fpv", "fpv-canvas",
           "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear", "fpv-map",
           "fpv-map-canvas", "fpv-cap", "fpv-grip", "povBadge", "mmwarn"]:
  check("id=\"" & id & "\"" notin page,
    "#" & id & " markup is removed (a fixed arena has no zoom, no minimap, " &
    "no POV lens; a state-frame replay has no hash mismatch)")
  check("#" & id & " {" notin page, "#" & id & " CSS is removed")

echo "--- the transport rules"
check("--hudscale" in page and "--band" in page and "--topband" in page,
  "relayout() still sets --hudscale and --band on :root")
check("root.style.setProperty('--hudscale'" in page,
  "the fixed-point relayout is the starter's, unedited")
check("bottom: var(--band, 0px);" in page,
  "the endcard stops at the transport band")
let gameBlock = page[bannerAt .. ^1]
check("var(--band" in gameBlock or "--topband" in gameBlock,
  "the game block's overlays are positioned relative to the reserved bands")
check("#transport" notin gameBlock,
  "NO game-block overlay sits inside the transport band")

echo "--- scrubber beats: one CSS rule per kind, and they are buttons"
for kind in BeatKinds:
  check(".beat-marker." & kind in page,
    "a .beat-marker CSS rule exists for the '" & kind & "' beat kind")
check("button.beat-marker" in page,
  "the game block styles the markers as buttons")
check("createElement('button')" in gameBlock,
  "the game block CREATES buttons, never bare divs")
check("setAttribute('aria-label', label)" in gameBlock,
  "every beat marker carries an aria-label")
check("CH.seek(tick)" in gameBlock, "and seeks to its tick on click")

echo "--- the 360 px rules"
check(".plate-name" in page, "the plates use .plate-name")
check("flex: 1 1 auto;" in gameBlock and "min-width: 3.2em;" in gameBlock,
  ".plate-name { flex: 1 1 auto; min-width: 3.2em } so a policy name never " &
  "collapses to a bare ellipsis in the ~360 px featured-match iframe")
check("#stage.tiny .plate .cn-restraint { display: none; }" in gameBlock,
  "under .tiny a plate drops the restraint percentage")
check("#stage.tiny #cn-recip .cn-cell" in gameBlock,
  "under .tiny the reciprocity strip halves its cell height")
check("@media (max-width: 640px)" in gameBlock,
  "labels are hidden under 640 px")

echo "--- the LLM remark rides a reserved band, and CI renders it"
block:
  ## The one string in this viewer an LLM writes is `say` (MaxSayLen runes).
  ## The inherited `.feed-row` is `max-width: none; white-space: nowrap`,
  ## sized for the starter's pre-bounded 10-char name, so the remark gets a
  ## band of its own — the feed's own width, wrapping inside it, never
  ## ellipsized. The geometry is measured by tools/ci/text_fixture.js; these
  ## are the shape checks that keep the two in step.
  check("class=\"glyph cn-say\"" in gameBlock,
    "the LLM remark is drawn into its own .cn-say span")
  check("'cn-order'" in gameBlock,
    "and the row carrying it is tagged .cn-order")
  let cssFrom = gameBlock.find(".feed-row.cn-order {")
  let cssTo = gameBlock.find("/* ---- 360 px")
  check(cssFrom >= 0 and cssTo > cssFrom, "the .cn-order rules are present")
  let orderCss = gameBlock[max(cssFrom, 0) .. max(cssTo, 0)]
  check("max-width: 100%;" in orderCss,
    ".feed-row.cn-order is bounded by the feed's own width — the band is " &
    "sized from the cap the server enforces on `say`, not by eye")
  check("white-space: normal;" in orderCss and
      "overflow-wrap: anywhere;" in orderCss,
    "and the remark WRAPS inside that band: an ellipsized sentence means " &
    "the box is too small, so widen the band, never shorten the text")
  check("text-overflow: ellipsis" notin orderCss,
    "no ellipsis rule reaches the remark")
  let fixture = readFile(root / "tools" / "ci" / "text_fixture.js")
  check("MaxSayLen" in fixture and "data-replay-error" in fixture and
      "data-replay-loaded" in fixture,
    "tools/ci/text_fixture.js renders full-cap remarks and signals both " &
    "markers viewer_smoke.mjs reads")
  check("cn-say" in fixture,
    "the fixture measures the span the game block actually draws")
  let ci = readFile(root / ".github" / "workflows" / "ci.yml")
  check("tools/ci/build_text_fixture.sh" in ci and
      "--bundle dist/text-fixture" in ci,
    "ci.yml drives the fixture in its own step")
  check(ci.count("--strict-text-bounds") >= 2,
    "and that step carries --strict-text-bounds, so a remark that outgrows " &
    "its band is a red job rather than a line in a log")

echo "--- no game-block top-level name collides with the chrome alias list"
block:
  ## The chrome alias block is `var X = C.Y, ...` at the top of the page's
  ## IIFE. Collect every alias, then collect every top-level name the game
  ## block declares, and assert the two sets are disjoint.
  var aliases: HashSet[string]
  for rawLine in page[0 ..< bannerAt].splitLines():
    let line = rawLine.strip()
    if not line.startsWith("var ") or "C." notin line:
      continue
    for piece in line[4 .. ^1].split(','):
      let bits = piece.split('=')
      if bits.len != 2: continue
      if "C." notin bits[1]: continue
      aliases.incl(bits[0].strip())
  check(aliases.len > 10, "the chrome alias list was found (" &
    $aliases.len & " names)")
  check("markBeat" in aliases and "renderClock" in aliases,
    "and it contains the names the tandem bug shadowed")

  ## TOP-LEVEL only: the game block's own IIFE indents its declarations by
  ## exactly two spaces, so anything deeper is a local and cannot be hoisted
  ## over a chrome alias.
  var declared: HashSet[string]
  for rawLine in gameBlock.splitLines():
    if rawLine.startsWith("   "):
      continue
    if rawLine.startsWith("  function "):
      declared.incl(rawLine["  function ".len .. ^1].split('(')[0].strip())
    elif rawLine.startsWith("  var "):
      declared.incl(rawLine[6 .. ^1].split({'=', ',', ';', ' '})[0].strip())
  check(declared.len > 5, "the game block declares names (" &
    $declared.len & ")")
  for name in declared:
    check(name notin aliases,
      "game-block name '" & name & "' would be hoisted over the chrome " &
      "alias of the same name")
    check(name.startsWith("cn") or name.startsWith("CH") or
          name in ["s"],
      "every game-block top-level name is `cn`-prefixed, got '" & name & "'")

# ---------------------------------------------------------------------------
echo "--- the chrome frame"
proc buildReplay(): ReplayData =
  var config = defaultGameConfig()
  config.seed = 21
  config.minBeats = 8
  config.maxBeats = 8
  config.tokens = @["t0", "t1"]
  config.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]
  var sim = initSim(config)
  sim.policyNames = ["coins-truce", "coins-reciprocator"]
  proc now(): float {.closure.} = 0.0
  proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
    let kinds = [skGreedy, skReciprocator]
    for slot in seats:
      result.add(Decision(
        intent: scriptedIntent(kinds[slot], view.buildObservation(slot),
          view.config.punishThreshold, view.config.punishBeats),
        source: osScripted, say: "your coins are yours"))
  sim.runEpisode(decide, now)
  parseReplayBytes(replayBytes(sim))

let data = buildReplay()
var player = initReplayPlayer(data)

var seenKeys: HashSet[string]
block:
  player.seek(0)
  var frames = 0
  var sendLead = true
  while true:
    let chrome = buildStateJson(player, player.pendingEvents, sendLead)
    sendLead = false
    for key in chromeKeySet(chrome):
      seenKeys.incl(key)
    frames.inc
    if player.tick >= player.maxTick() or frames > 2000:
      break
    player.advance()
  ## The terminal frame carries `over` and `hold`.
  player.seek(player.maxTick())
  let last = parseJson(buildStateJson(player, newJArray(), false))
  check(last.hasKey("over"), "`over` is present on the terminal frame")
  check(last{"over"}{"winner"}.getStr() in ["red", "blue", ""],
    "the verdict names a chrome team key")
  check(last.hasKey("hold"), "and the end-hold countdown")
  for key in chromeKeySet($last):
    seenKeys.incl(key)

var expected = @["t", "mt", "ph", "pl", "sp", "mx", "st", "lp", "sk", "ff",
  "en", "mm", "bs", "pov", "teams", "roster", "events", "lead", "beats",
  "lulls", "over", "hold", "cn"]
sort(expected)
var seenList: seq[string]
for key in seenKeys:
  seenList.add(key)
sort(seenList)
check(seenList == expected,
  "buildStateJson emits exactly the inherited chrome key set plus `cn`.\n" &
  "  expected: " & expected.join(",") & "\n  got:      " & seenList.join(","))

block:
  player.seek(0)
  let first = parseJson(buildStateJson(player, player.pendingEvents, true))
  var teamKeys: seq[string]
  for key, value in first{"teams"}:
    discard value
    teamKeys.add(key)
  sort(teamKeys)
  check(teamKeys == @["blue", "red"],
    "`teams` keys are exactly red and blue — the two names chrome_common's " &
    "TEAM_COLOR / TEAM_ORDER already know, which is what gets the plates, " &
    "the momentum legend and the endcard their colours with ZERO edits to " &
    "that file")
  check(first{"roster"}.len == Seats, "the roster has two entries")
  for entry in first{"roster"}:
    check(entry{"pol"}.getStr().startsWith("coins-"),
      "a roster seat carries its POLICY name")
    check(entry{"colour"}.getStr() in ["copper", "cobalt"],
      "and its coin colour")
    check(entry.hasKey("score"), "and its score")
    check(entry{"name"}.getStr() in ["Copper", "Cobalt"],
      "and the anonymous in-game alias")
  check(first{"lead"}{"teams"}[0].getStr() == "red",
    "lead.teams is the chrome team order")
  check(first{"lead"}{"pts"}.len == data.frames.len,
    "the whole score series ships on the FIRST HUD frame so the momentum " &
    "curve draws its full width immediately")
  for row in first{"lead"}{"pts"}:
    check(row.len == 3, "lead.pts rows are [t, score0, score1]")
  check(first{"bs"}.getInt() == 1, "the board render scale")
  check(first{"mm"}.getInt() == -1,
    "there is no hash mismatch to report: Coins records STATE, so playback " &
    "never re-simulates")
  check(first{"cn"}{"recip"}.len == data.beats,
    "cn.recip carries one row per beat")
  for row in first{"cn"}{"recip"}:
    check(row.len == 3, "cn.recip rows are [beat, thefts0, thefts1]")
  check(first{"cn"}{"policies"}.len == Seats, "cn carries the policy names")

echo "--- the beat kinds emitted are exactly the four the CSS covers"
block:
  var kinds: HashSet[string]
  for row in data.beatsTimeline:
    kinds.incl(row{"k"}.getStr())
    check(row{"team"}.getStr() in ["red", "blue"],
      "every beat row names a chrome team key")
    check(row{"t"}.getInt() >= 0, "and a real tick")
  var kindList: seq[string]
  for kind in kinds:
    kindList.add(kind)
  sort(kindList)
  var allowed = @BeatKinds
  sort(allowed)
  for kind in kindList:
    check(kind in allowed, "beat kind '" & kind & "' has a CSS rule")
  check("over" in kinds, "the final tick is always marked")
  check("theft" in kinds,
    "a greedy-versus-reciprocator episode marks its thefts")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_viewer OK"
