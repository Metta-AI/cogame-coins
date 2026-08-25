## tests/test_manifest.nim — packaging.
##
## `num_agents == 2` in ALL FIVE variants and in `certification.game_config`;
## the image placeholder derived from `compose.yaml`'s service name; the
## static replay bundle and no `/client/replay` viewer; docs and protocols in
## the shapes the platform validator demands; the secret URI on the game
## runnable; every array property in `config_schema` bounded; every declared
## `player[]` id seated in the certification fixture; a description on every
## variant; and the wall-clock budget, checked from the manifest itself.

import std/[json, os, strutils]
import coins/[sim_types, sim_config]

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

let root = currentSourcePath().parentDir().parentDir()
let manifest = parseJson(readFile(root / "coworld_manifest_template.json"))
let compose = readFile(root / "compose.yaml")

# ---------------------------------------------------------------------------
echo "--- the image placeholder is derived from the compose service name"
var serviceName = ""
block:
  var inServices = false
  for rawLine in compose.splitLines():
    let line = rawLine.strip(leading = false)
    if line.startsWith("services:"):
      inServices = true
      continue
    if inServices and line.len > 2 and line[0] == ' ' and line[1] == ' ' and
        line[2] != ' ' and line.strip().endsWith(":"):
      serviceName = line.strip().strip(chars = {':'})
      break
check(serviceName == "coins",
  "the compose service is the coworld name, got '" & serviceName & "'")
let expectedPlaceholder = "{{" & serviceName.toUpperAscii() & "_IMAGE}}"
check(manifest{"game"}{"runnable"}{"image"}.getStr() == expectedPlaceholder,
  "the manifest image placeholder equals the one derived from compose: " &
  manifest{"game"}{"runnable"}{"image"}.getStr() & " vs " &
  expectedPlaceholder)
check("cogame-coins:latest" in compose,
  "compose pins the image tag the release workflow builds")
check("platform: linux/amd64" in compose, "compose pins linux/amd64")
check("network: host" in compose, "compose builds with network: host")

# ---------------------------------------------------------------------------
echo "--- num_agents is 2 in EVERY variant and in the certification fixture"
let variants = manifest{"variants"}
check(variants.len == 5, "five variants, got " & $variants.len)
var variantIds: seq[string]
for variant in variants:
  let id = variant{"id"}.getStr()
  variantIds.add(id)
  check(variant{"game_config"}{"num_agents"}.getInt() == Seats,
    "variant " & id & " declares num_agents " & $Seats)
  check(variant{"description"}.getStr().len > 0,
    "variant " & id & " carries a description")
  check(variant{"name"}.getStr().len > 0,
    "variant " & id & " carries a name")
  check(not variant.hasKey("default"),
    "variant " & id & " carries no 'default' key (the schema forbids it)")
  check(variant{"game_config"}{"players"}.len == Seats,
    "variant " & id & " seats exactly " & $Seats & " players")
check("standard" in variantIds and "long-shadow" in variantIds and
      "short-fuse" in variantIds and "harsh" in variantIds and
      "scarce" in variantIds, "the five pinned variant ids are present")
check(variantIds[0] == "standard",
  "'standard' is listed first, so it is the variant the platform seats by default")

let cert = manifest{"certification"}
check(cert{"game_config"}{"num_agents"}.getInt() == Seats,
  "certification.game_config.num_agents == " & $Seats)
check(cert{"players"}.len == Seats,
  "certification.players seats " & $Seats)
check(cert{"game_config"}{"players"}.len == Seats,
  "certification.game_config.players names " & $Seats & " seats")
check(cert{"game_config"}{"minBeats"}.getInt() ==
      cert{"game_config"}{"maxBeats"}.getInt(),
  "the fixture disables the random-end draw (minBeats == maxBeats)")

# ---------------------------------------------------------------------------
echo "--- every declared player[] id is seated in the fixture"
var seated: seq[string]
for entry in cert{"players"}:
  seated.add(entry{"player_id"}.getStr())
check(manifest{"player"}.len == Seats,
  "exactly " & $Seats & " player entries: a third could not be seated in a " &
  "2-seat fixture and would fail players_missing")
for entry in manifest{"player"}:
  let id = entry{"id"}.getStr()
  check(id in seated,
    "player[] id '" & id & "' occupies a certification slot")
  check(entry{"image"}.getStr() == expectedPlaceholder,
    "player '" & id & "' runs the same image")
  check(entry{"run"}[0].getStr() == "/bin/coins-player",
    "player '" & id & "' runs the player entrypoint")
  check(entry{"description"}.getStr().len > 0,
    "player '" & id & "' carries a description")

# ---------------------------------------------------------------------------
echo "--- the static replay bundle, and no /client/replay pod viewer"
check(manifest{"game"}{"replay_viewer"}{"bundle"}.getStr() ==
  "static-replay-viewer", "replay_viewer.bundle is static-replay-viewer")
let manifestText = $manifest
check("/client/replay" notin manifestText,
  "no /client/replay live-server viewer is declared anywhere")

# ---------------------------------------------------------------------------
echo "--- the game runnable"
let runnable = manifest{"game"}{"runnable"}
check(runnable{"type"}.getStr() == "game", "game.runnable.type == 'game'")
check(runnable{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
  "secret://coworld/coins/anthropic_api_key",
  "ANTHROPIC_API_KEY_URI is on the GAME runnable — without it the hosted " &
  "game container never sees the coworld secret and every league episode " &
  "silently plays scripted")
check(runnable{"run"}[0].getStr() == "/bin/coins", "the game entrypoint")
check(manifest{"game"}{"name"}.getStr() == "coins",
  "game.name is the secret namespace")
check(manifest{"episode_timeout_minutes"}.getInt() == 20,
  "top-level episode_timeout_minutes")
check(manifest{"tags"}.len >= 3, "at least three tags")
check(manifest.hasKey("$schema"), "a top-level $schema")

# ---------------------------------------------------------------------------
echo "--- docs and protocols in the shapes the platform validator demands"
let docs = manifest{"game"}{"docs"}
check(docs{"readme"}{"type"}.getStr() == "text" and
      docs{"readme"}{"value"}.getStr().len > 200,
  "game.docs.readme is a {type:text, value} object with real prose")
check(docs{"pages"}.len > 0, "game.docs.pages is non-empty")
for page in docs{"pages"}:
  check(page{"id"}.getStr().len > 0, "a doc page has an id")
  check(page{"title"}.getStr().len > 0, "a doc page has a title")
  check(page{"content"}{"type"}.getStr() == "text",
    "a doc page's content is {type:text, value}")
  check(page{"content"}{"value"}.getStr().len > 100,
    "a doc page has real content")
let protocols = manifest{"game"}{"protocols"}
for name in ["player", "global"]:
  check(protocols.hasKey(name), "game.protocols carries " & name)
  check(protocols{name}.kind == JObject,
    "game.protocols." & name & " is an OBJECT, not a bare string (the " &
    "garble trap)")
  check(protocols{name}{"type"}.getStr() == "text",
    "game.protocols." & name & ".type == text")
  check(protocols{name}{"value"}.getStr().len > 100,
    "game.protocols." & name & " documents something")
check("48" in protocols{"player"}{"value"}.getStr() and
      "300" in protocols{"player"}{"value"}.getStr(),
  "the player protocol states the 48 / 300 rune caps")

# ---------------------------------------------------------------------------
echo "--- every ARRAY property in config_schema is bounded"
let schema = manifest{"game"}{"config_schema"}
check(schema{"additionalProperties"}.getBool() == false,
  "config_schema refuses unknown properties")
for name, prop in schema{"properties"}:
  if prop{"type"}.getStr() != "array":
    continue
  check(prop.hasKey("minItems") and prop.hasKey("maxItems"),
    "array property '" & name & "' declares minItems AND maxItems")
  check(prop{"minItems"}.getInt() == Seats and
        prop{"maxItems"}.getInt() == Seats,
    "array property '" & name & "' is bound to the seat count")
check(schema{"properties"}{"num_agents"}{"minimum"}.getInt() == Seats and
      schema{"properties"}{"num_agents"}{"maximum"}.getInt() == Seats,
  "num_agents is pinned to " & $Seats & " in the schema itself")

echo "--- results_schema"
let results = manifest{"game"}{"results_schema"}
for name in ["restraint", "firstTheftBeat", "reciprocityLagBeats"]:
  let items = results{"properties"}{name}{"items"}{"type"}
  check(items.kind == JArray, name & ".items.type is a list")
  var kinds: seq[string]
  for entry in items:
    kinds.add(entry.getStr())
  check("number" in kinds and "null" in kinds,
    name & " declares [\"number\", \"null\"]")
for name, prop in results{"properties"}:
  if prop{"type"}.getStr() != "array":
    continue
  check(prop{"minItems"}.getInt() == Seats and
        prop{"maxItems"}.getInt() == Seats,
    "results array '" & name & "' is length " & $Seats)

# ---------------------------------------------------------------------------
echo "--- the wall-clock budget, checked from the manifest itself"
block:
  let defaults = defaultGameConfig()
  for variant in variants:
    let gc = variant{"game_config"}
    var config = defaults
    if gc.hasKey("maxBeats"): config.maxBeats = gc{"maxBeats"}.getInt()
    if gc.hasKey("minBeats"): config.minBeats = gc{"minBeats"}.getInt()
    let worst = config.maxBeats * config.worstCaseBeatSeconds()
    check(worst.float < config.playDeadlineSeconds(),
      "variant " & variant{"id"}.getStr() & ": maxBeats x (2 x " &
      "llmTimeoutSeconds) = " & $worst & " s must be under " &
      $config.playDeadlineSeconds() & " s")
  let gc = cert{"game_config"}
  var certConfig = defaults
  certConfig.maxBeats = gc{"maxBeats"}.getInt()
  check((certConfig.maxBeats * certConfig.worstCaseBeatSeconds()).float <
    certConfig.playDeadlineSeconds(), "the fixture fits the budget too")

# ---------------------------------------------------------------------------
echo "--- tools/ci/policies.json: two prompt champions plus two fillers"
block:
  let policies = parseJson(readFile(root / "tools" / "ci" / "policies.json"))
  check(policies.len == 4, "four policies")
  var prompts = 0
  var scripted = 0
  var owned = 0
  var names: seq[string]
  for policy in policies:
    names.add(policy{"name"}.getStr())
    check(policy{"run"}.getStr() == "/bin/coins-player",
      "every policy runs the player entrypoint")
    if policy{"env"}.hasKey("PLAYER_PROMPT"):
      prompts.inc
      check(policy{"env"}{"USE_BEDROCK"}.getStr() == "true",
        "a prompt policy carries USE_BEDROCK=true or the player pod gets " &
        "no Bedrock sidecar and the seat silently plays scripted")
      check(policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200,
        "a champion prompt is a real strategy")
    if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
      scripted.inc
      check(policy{"env"}{"PLAYER_SCRIPTED"}.getStr() in
        ["honest", "greedy", "reciprocator", "tit-for-tat"],
        "a filler names a real baseline")
    if policy.hasKey("player"):
      owned.inc
      check(policy{"player"}.getStr() ==
        "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
        "champion #2 is uploaded as daveey-1")
  check(prompts == 2, "TWO LLM prompt champions")
  check(scripted == 2, "two scripted fillers")
  check(owned == 1, "exactly one policy is owned by daveey-1")
  check("coins-truce" in names and "coins-ledger" in names and
        "coins-reciprocator" in names and "coins-titfortat" in names,
    "the four pinned policy names")
  check(policies[0]{"env"}{"PLAYER_PROMPT"}.getStr() !=
        policies[1]{"env"}{"PLAYER_PROMPT"}.getStr(),
    "the two champions carry DIFFERENT prompts so they mint distinct versions")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_manifest OK"
