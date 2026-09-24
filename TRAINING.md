# Metta post-training data

The native simulator and published `reciprocator` policy export supervised
examples for all five certified variants:

```sh
nimby sync nimby.lock
for variant in standard long-shadow short-fuse harsh scarce; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/coins-$variant" 10 1 "$variant"
done
```

Each run reads the manifest variant config, adds the per-seat tokens supplied
by the hosted platform, and plays complete seeded episodes. Examples contain
the hosted system and user prompts, each seat's observation, and a
`reciprocator` action accepted by the game's reply parser. Parsed actions drive
the simulator. Entire episodes stay in one split. The manifest records source
revision, variant, scores, wins, and row counts. Existing output directories
are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/coins-standard \
  --output /tmp/coins-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete episodes yielded 268 training and 74 validation examples for
standard, 356 and 86 for long-shadow, 130 and 42 for short-fuse, 268 and 74
for harsh, and 268 and 74 for scarce. All 1,640 examples fit a 4,096-token
context with the Qwen2.5-0.5B-Instruct tokenizer (maximum: 1,738 tokens).
One CPU optimizer step per dataset with a local tiny model verifies the Metta
post-training path. These examples distill the scripted teacher; they do not
establish stronger league play.

For reinforcement learning, compile the persistent bridge and test all five
certified variants:

```sh
nim c -d:release --path:src -o:coins-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py ./coins-train-bridge
```

From Metta, use `recipes.external.coworld.train` for native PufferLib or
`recipes.external.coworld_metta_rl.train` for Metta RL. Pass a command with
absolute bridge and manifest paths, the variant ID, `players=2`, and a
timestep limit. The bridge exposes 32 player-visible numeric values and the
five native intents. The published `reciprocator` policy supplies opponents
and optional teacher labels. Metta support is stacked in #24679 above #24573.

## Local reinforcement learning proof

Metta RL completed 512 timesteps per certified variant through the numeric
bridge. Native PufferLib trained 4,096 CUDA timesteps per variant, then
reloaded each checkpoint for held-out seeds 101 and 102:

| Variant | Seed 101 score / performance / games | Seed 102 score / performance / games | Checkpoint SHA-256 |
| --- | --- | --- | --- |
| standard | -1 / 0.6 / 5 | 0 / 0.75 / 4 | `b5c1e620112483e6d21a8863e06317921428389dc1031d483f60707cbbfb6c32` |
| long-shadow | 20.5 / 0.25 / 4 | 19.5 / 0.25 / 4 | `cf44fe9cde4926f7676adde73c4052fa69146ee0add8c045dace023c12d50241` |
| short-fuse | 8 / 1 / 7 | 6.833333 / 1 / 6 | `a833472ec5ea3a57a459e85646d4acf0893603893b52a2b82782e69afbf19234` |
| harsh | 16.799999 / 0.4 / 5 | 11.5 / 0.25 / 4 | `49c9e582cfb2d8c2888b0515e497f48a4de0c36c62982818b440062c843013cf` |
| scarce | 8.4 / 1 / 5 | 9.25 / 1 / 4 | `39dcce3f16a001db93618cb48820b7489e4c4c233faf496efa141213aaa7de8c` |

These short pilots verify training, checkpoint reload, and evaluation. They do
not establish competitive policies.
