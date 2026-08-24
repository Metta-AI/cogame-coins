## The four scripted baselines — all fieldable, all env-switched.
##
## **Every baseline reads the same `buildObservation(slot)` object an LLM seat
## receives — never raw sim state.** That is what makes a baseline a
## legitimate policy, and `tests/test_baseline.nim` asserts it by running each
## against a frozen observation with the sim inaccessible.
##
## Each returns ONE intent per beat. Everything they need is derived from the
## observation: `theirThefts` (the coins of YOUR colour they have taken,
## cumulatively), `theirTheftsInBeat(b)` from `beatLog`, and
## `ownCoinExists` / `theirCoinExists` from `coins`.
##
## `reciprocator` is also the FALLBACK move used whenever an LLM seat's
## decision fails, the policy a never-connected seat plays, and the baseline
## the offline certification fixture leans on.

import std/[json, strutils]
import sim_types

type
  ScriptKind* = enum
    skNone = "none"
    skHonest = "honest"
    skGreedy = "greedy"
    skReciprocator = "reciprocator"
    skTitForTat = "tit-for-tat"

const ScriptedNames* = ["honest", "greedy", "reciprocator", "tit-for-tat"]

proc parseScriptKind*(text: string): ScriptKind =
  ## `PLAYER_SCRIPTED` values. "1"/"true"/"yes" pick the strongest baseline.
  case text.strip().toLowerAscii()
  of "honest", "cooperate", "always-cooperate": skHonest
  of "greedy", "defect", "always-defect": skGreedy
  of "1", "true", "yes", "reciprocator", "recip": skReciprocator
  of "tit-for-tat", "titfortat", "tit_for_tat", "tft": skTitForTat
  else: skNone

# ---------------------------------------------------------------------------
# observation helpers — the ONLY thing a baseline may read
# ---------------------------------------------------------------------------

proc ownColour(obs: JsonNode): string =
  obs{"colour"}.getStr("copper")

proc theirColour(obs: JsonNode): string =
  obs{"them"}{"colour"}.getStr("cobalt")

proc coinExists(obs: JsonNode, colour: string): bool =
  let coins = obs{"coins"}
  if coins == nil or coins.kind != JArray:
    return false
  for coin in coins:
    if coin{"colour"}.getStr() == colour:
      return true
  false

proc ownCoinExists*(obs: JsonNode): bool =
  coinExists(obs, ownColour(obs))

proc theirCoinExists*(obs: JsonNode): bool =
  coinExists(obs, theirColour(obs))

proc theirThefts*(obs: JsonNode): int =
  ## Cumulative coins of YOUR colour the other cog has taken.
  obs{"them"}{"thefts"}.getInt(0)

proc beatLogRows(obs: JsonNode): JsonNode =
  result = obs{"beatLog"}
  if result == nil or result.kind != JArray:
    result = newJArray()

proc theirTheftsInBeat*(obs: JsonNode, beat: int): int =
  for row in beatLogRows(obs):
    if row{"beat"}.getInt() == beat:
      return row{"them"}{"thefts"}.getInt(0)
  0

proc currentBeat*(obs: JsonNode): int =
  obs{"beat"}.getInt(1)

proc mineOrHold(obs: JsonNode): Intent =
  if ownCoinExists(obs): inTakeMine else: inHold

# ---------------------------------------------------------------------------
# the baselines
# ---------------------------------------------------------------------------

proc honestIntent*(obs: JsonNode): Intent =
  ## Always-cooperate. Never steals, ever — an invariant, not a tendency.
  mineOrHold(obs)

proc greedyIntent*(obs: JsonNode): Intent =
  ## Always-defect: take_any, every beat, unconditionally.
  inTakeAny

proc reciprocatorIntent*(obs: JsonNode, punishThreshold, punishBeats: int):
    Intent =
  ## Stay honest until they have stolen `punishThreshold` coins; then take
  ## their coins for `punishBeats` beats; then go back to honest with the
  ## trigger re-armed at `punishThreshold` more thefts. Forgiving rather than
  ## grim, so a truce can re-form and be watched.
  ##
  ## Its state (`armed`, `punishUntil`) is re-derived from the beat log every
  ## beat rather than carried, so the baseline is a pure function of the
  ## observation — which is exactly what `tests/test_baseline.nim` asserts.
  let beat = currentBeat(obs)
  var cumulative: seq[int]        ## thefts they had taken BEFORE beat k
  var running = 0
  cumulative.add(0)               ## index 0 is unused (beats are 1-based)
  for k in 1 .. beat:
    cumulative.add(running)
    running += theirTheftsInBeat(obs, k)
  var armed = punishThreshold
  var punishUntil = 0
  for k in 1 ..< beat:
    if k <= punishUntil:
      continue
    if cumulative[k] >= armed:
      punishUntil = k + punishBeats - 1
      armed = cumulative[k] + punishThreshold
  if beat <= punishUntil:
    return inTakeTheirs
  if cumulative[beat] >= armed:
    return inTakeTheirs
  mineOrHold(obs)

proc titForTatIntent*(obs: JsonNode): Intent =
  ## Beat-local mirror — the idea's "tit-for-tat in coin-space".
  let beat = currentBeat(obs)
  if beat <= 1:
    return inTakeMine
  if theirTheftsInBeat(obs, beat - 1) >= 1:
    return inTakeAny
  mineOrHold(obs)

proc scriptedIntent*(kind: ScriptKind, obs: JsonNode,
    punishThreshold = 2, punishBeats = 4): Intent =
  ## The intent for one seat, from its observation alone.
  case kind
  of skHonest: honestIntent(obs)
  of skGreedy: greedyIntent(obs)
  of skTitForTat: titForTatIntent(obs)
  else: reciprocatorIntent(obs, punishThreshold, punishBeats)
