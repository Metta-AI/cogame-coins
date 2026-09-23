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
