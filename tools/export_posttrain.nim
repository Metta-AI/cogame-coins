## Export complete native Coins episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import coins/[sim, sim_types, scripted, llm]

const OperatorPrompt = "Maximize your score using only your own observation."
const Variants = ["standard", "long-shadow", "short-fuse", "harsh", "scarce"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "standard"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %["t0", "t1"]
    config.update($runtimeConfig)
    config.seed = seed
    var sim = initSim(config)
    var rows: seq[string]
    proc now(): float {.closure.} = 0.0
    proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
      for slot in seats:
        let obs = view.buildObservation(slot)
        let teacher = scriptedIntent(skReciprocator, obs,
          view.config.punishThreshold, view.config.punishBeats)
        let completion = %*{"intent": $teacher, "say": "", "notes": ""}
        let parsed = parseDecision(completion)
        doAssert parsed.intent == teacher
        rows.add($(%*{
          "episode_id": "coins-" & variant & "-" & $seed,
          "seed": "coins-" & variant & "-" & $seed,
          "decision_id": (view.beat - 1) * Seats + slot,
          "prompt": [
            {"role": "system", "content": systemPrompt(obs)},
            {"role": "user", "content": userPrompt(obs, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "coins",
          "action_schema_revision": "coins-intent-v1"
        }))
        result.add(parsed)
    sim.runEpisode(decide, now)
    doAssert sim.finished and rows.len > 0 and sim.reason != erDeadline
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "win": outcome["win"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "coins",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-reciprocator",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
