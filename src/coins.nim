## Coins entrypoint.
##
## Forked from `coworld-ctf/src/ctf.nim`: the seed is randomised HERE, BEFORE
## `config.update`, so every seed-derived draw — all three RNG streams
## (`coinRng`, `moveRng`, `endRng`) — follows the FINAL seed. Same sentinel
## handling: a config that pins `seed` is honoured verbatim, which is what
## makes the certification fixture reproducible.

import std/[json, strutils, sysrand]
import bitworld/runtime
import coins/[sim_types, sim_config, server]

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(CoinsError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("coins: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.config.strip().len == 0:
    quit("coins: COGAME_CONFIG_URI is required (no game config was given)", 2)

  var config = defaultGameConfig()
  try:
    config.update(runtimeConfig.config)
  except CatchableError as error:
    quit("coins: invalid game config: " & error.msg, 2)

  if not seedPinned(runtimeConfig.config):
    config.seed = randomSeed()
    echo "coins: seed not pinned; randomized to ", config.seed

  if config.tokens.len == 0:
    quit("coins: the game config must carry one token per seat", 2)
  if config.players.len != config.numAgents:
    quit("coins: the game config must name " & $config.numAgents &
      " players", 2)

  echo "coins: seats=", config.numAgents,
    " variant=", config.variant,
    " beats=", config.minBeats, "..", config.maxBeats,
    " endChance=", config.endChancePermille,
    " coinCap=", config.coinCap,
    " theftPenalty=", config.theftPenalty,
    " seed=", config.seed
  try:
    runGameServer(config, runtimeConfig)
  except CatchableError as error:
    quit("coins: " & error.msg, 2)
