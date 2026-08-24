# Coins

**Two cogs, one small room, and every coin a choice.**

Coins is a real-time grid coworld: a 7 × 7 open floor inside a wall ring,
shared by exactly two cogs. Coins of two colours spawn at random. Copper owns
copper, Cobalt owns cobalt.

- Picking up **any** coin is **+1 to you**, whatever its colour.
- Picking up the **other cog's** colour additionally costs that cog **−2**.
  The thief keeps its +1, so a theft is +1 to you and −2 to them: **net −1 to
  the pair**.
- The room is deliberately **coin-starved** — supply, not walking speed, is
  the binding constraint — so taking the other cog's coin is a real gain
  rather than a redistribution.
- The episode **ends at random** after beat 12 and always by beat 24. That
  shadow of the future is the whole point: taking a coin is always
  individually +1, so greed is the dominant *one-shot* move, and only the
  prospect of meeting this cog again makes restraint rational.

It is a spatial repeated Prisoner's Dilemma, ported from Melting Pot's
`coins` substrate. `T > R > P > S` and `2R > T + S` are asserted in CI
(`tests/test_dilemma.nim`), not assumed.

Higher score wins. Scores are whole integers and can go negative.

## A policy is just a prompt

Both policy kinds ship in **one image**, env-switched:

```bash
coworld upload-policy <coins-image> --name my-coins \
  --run /bin/coins-player \
  --secret-env PLAYER_PROMPT="<your strategy>" \
  --secret-env USE_BEDROCK=true
```

`PLAYER_SCRIPTED=honest|greedy|reciprocator|tit-for-tat` registers the seat
as a built-in baseline instead; the game plays those deterministically with no
LLM at all.

`/bin/coins-player` is a thin process: it connects, delivers its prompt, and
then only listens. **Every decision is made inside the game container**, which
is what makes one parallel batch per beat possible — both seats decide
*simultaneously*, so both requests go out together (`curly.makeRequests`),
never one seat waiting on the other.

### One intent per beat

A beat is 20 ticks. A seat submits one intent and a deterministic kernel walks
its cog for the rest of the beat:

| intent | what the kernel does |
|---|---|
| `take_mine` | walk to the nearest coin of **your** colour; never step onto one of theirs |
| `take_any` | walk to the nearest coin of either colour (own colour wins a tie); nothing is off limits |
| `take_theirs` | walk to the nearest coin of the **other** colour; nothing is off limits |
| `guard` | walk to whichever of your coins is nearest to the **other cog** — bank the coin most at risk |
| `hold` | stand still; never step onto one of theirs |

**Restraint is a movement rule, not a pickup rule.** A cog whose intent
forbids a colour never *steps onto* a coin of that colour, so the other cog
(and the spectator) literally watches it walk around the coin it will not
take. The sim emits a `blocked` `why: "restraint"` event when it does.

### The reply schema

```json
{"intent":"take_mine","say":"your coins are yours","notes":"Cobalt stole 2 in beat 5; watching now"}
```

`say` is capped at **48 runes** and is **spectator-only** — it goes into the
replay and the viewer's feed, and the other seat *never* reads it. `notes` is
capped at **300 runes** and comes back to you, and only you, next beat. Both
caps are counted in runes and truncated on rune boundaries.

There is **no inter-seat channel**. Melting Pot's coins has none, restraint has
to be *shown* rather than promised, and a silent room is the anti-collusion
property the ladder needs with only two seats.

## The scripted baselines

| baseline | algorithm | the Melting Pot bot it reproduces |
|---|---|---|
| `honest` | `take_mine` while a coin of your colour exists, else `hold`. Never steals, ever. | always-cooperate |
| `greedy` | `take_any`, every beat, unconditionally. | always-defect |
| `reciprocator` | Honest until they have stolen 2; then `take_theirs` for 4 beats; then honest again with the trigger re-armed at 2 more thefts. | the reciprocating bot that starts punishing after N thefts, N = 2 — forgiving rather than grim, so a truce can re-form and be watched |
| `tit-for-tat` | Beat 1 `take_mine`; thereafter `take_any` if they stole in the previous beat, else `take_mine`. | conditional resident |

Every baseline reads the same observation object an LLM seat receives and
**never raw sim state** — that is what makes a baseline a legitimate policy,
and `tests/test_baseline.nim` asserts it by running each against a frozen
observation. `reciprocator` is also the move every failure path lands on: an
unparseable reply, a timeout, a 401, a seat that never connected.

## Watching

The replay is a **static wasm bundle**, never a pod:
`index.html?replay=<url>`. The viewer re-derives every frame from the replay
bytes alone — aliases, policy names, colours, the variant, the whole config,
the seed, the room, per-tick state frames, both series, the index summary,
every event and the full results object are all in the file.

The chrome is `Metta-AI/coworld-ctf`'s, inherited: `client/chrome_common.js`
is copied byte-for-byte and `client/replay_broadcast.html` is the starter's
page with a Coins block appended under a banner comment. What Coins adds:

- **scorebug plates** — a colour chip, the **policy** name, the score, and
  `STOLE n`, the per-cog theft counter, which flashes on every theft;
- **the clock** — `BEAT 7 / 18`, with `tick 140 of 360 · 2 coins on the board`;
- **the reciprocity timeline** — two rows, one narrow cell per beat, dim for
  no thefts, amber for one, the cog's own colour for two or more, with a white
  flag notch on a truce beat. Read left to right it is the whole social
  history of the episode in one object: who started it, how fast the other
  answered, and where one cog stopped;
- **the theft headline** — `COPPER STOLE 2 · COBALT STOLE 5` with each cog's
  running restraint percentage;
- **the feed** — plain language, one row per event that matters;
- **scrubber beats** — labelled, clickable buttons for every theft, truce,
  lead change and the final tick.

`#viewpanel` (the zoom bar and minimap) is dropped: the room is a fixed 9 × 9
arena, 504 × 504 px, that always fits the frame.

## Layout

```
src/coins.nim              entrypoint; the seed is randomised BEFORE config.update
src/coins_player.nim       the thin prompt-carrying seat process
src/coins/sim_types.nim    consts, wire types, the seeded RNG, the rune caps
src/coins/room.nim         the fixed 9x9 ASCII room
src/coins/sim_config.nim   GameConfig lifecycle + validation (incl. the budget)
src/coins/kernel.nim       the five intents' per-tick target/forbidden kernel
src/coins/sim.nim          the eight numbered tick rules, the beat close, the end
src/coins/scripted.nim     the four baselines, pure functions of the observation
src/coins/indices.nim      restraint, reciprocity lag, the truce rule
src/coins/events.nim       the closed event vocabulary
src/coins/llm.nim          the batched decision layer (one batch per beat)
src/coins/broadcast.nim    the inherited chrome frame + the `cn` game key
src/coins/global.nim       the sprite-protocol board emitter
src/coins/replays.nim      coins.replay.v1: writer, parser and playhead
src/coins/server.nim       the Coworld game contract over mummy
replay-viewer/             the wasm entry, the emscripten config, the JS shell
client/                    chrome_common.js (verbatim), broadcast_core.js
                           (verbatim), replay_broadcast.html (+ the game block)
scripts/art/               the nano-banana source sheets and the bake scripts
tests/                     sim units, baselines, the dilemma oracle, the replay,
                           the decision layer, packaging, the viewer
```

## Art

The characters are **nano-banana renders of the Softmax cog**, one livery per
role, not procedural rigs. `scripts/art/source/` holds the committed source
sheets; `scripts/art/split_cog_sheet.py` keys and splits them and
`scripts/art/gen_coins_art.py` bakes everything under `data/`: the two cog
liveries with their heading chevrons and livery ground rings, the four-frame
idle coin spin for each colour, the whole 504 × 504 room (the tiled vault
floor, the chalk grid and the wall ring cut from the shipped wall art), and
the pickup / theft / restraint flourishes. Both scripts are deterministic and
re-runnable; CI does not regenerate art, so the derived PNGs are committed.

## Building and testing

The sandbox that authored this repo has no Docker, no Nim and no emsdk:
`.github/workflows/ci.yml` is the harness. It runs every `tests/*.nim` twice
(debug and `-d:release`), builds the production image and plays a real 2-seat
episode in raw Docker from the certification fixture
(`tools/ci/docker_smoke.sh`), then builds the static replay bundle and
**opens it in headless Chromium** against that episode's replay
(`tools/ci/viewer_smoke.mjs`).

Locally, with Nim 2.2.4 and the nimby lock synced:

```bash
nimby --global sync nimby.lock
nim r --path:src tests/test_sim.nim
docker build -t cogame-coins:ci .
tools/ci/docker_smoke.sh cogame-coins:ci
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

The design note this repo implements is
[`docs/plans/2026-08-24-coins-design.md`](docs/plans/2026-08-24-coins-design.md).
