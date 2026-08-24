## GameConfig lifecycle: defaults, the runtime JSON overlay, validation and
## the resolved config document pinned verbatim into every replay.
##
## Forked from `coworld-ctf/src/ctf/sim_config.nim` (same `defaultGameConfig`
## / `update` / `validate` split); the fields are the config schema declared
## in `coworld_manifest_template.json`.

import std/[json, strutils]
import sim_types

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    variant*: string
    ticksPerBeat*: int
    minBeats*: int
    maxBeats*: int
    endChancePermille*: int
    coinCap*: int
    coinSpawnIntervalTicks*: int
    initialCoins*: int
    pickupReward*: int
    theftPenalty*: int
    stepCooldownTicks*: int
    punishThreshold*: int
    punishBeats*: int
    truceBeats*: int
    llmTimeoutSeconds*: int
    minBeatSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: Seats,
    variant: "standard",
    ticksPerBeat: 20,
    minBeats: 12,
    maxBeats: 24,
    endChancePermille: 120,
    coinCap: 8,
    coinSpawnIntervalTicks: 12,
    initialCoins: 6,
    pickupReward: 1,
    theftPenalty: 2,
    stepCooldownTicks: 3,
    punishThreshold: 2,
    punishBeats: 4,
    truceBeats: 3,
    llmTimeoutSeconds: 12,
    minBeatSeconds: 5,
    maxOutputTokens: 500,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 180,
    shutdownGraceSeconds: 20
  )

proc playDeadlineSeconds*(config: GameConfig): float =
  ## 60% of `episodeTimeoutSeconds` (720 s at the default 1200). The game
  ## container is NOT given `COWORLD_TIMEOUT_SECONDS`, so 1200 is assumed
  ## unless the config supplies otherwise. Crossing this at a beat close
  ## settles the episode with `reason: "deadline"` rather than overrunning.
  0.6 * config.episodeTimeoutSeconds.float

proc worstCaseBeatSeconds*(config: GameConfig): int =
  ## One batch plus one retry, both at the batch timeout.
  2 * config.llmTimeoutSeconds

proc validate*(config: GameConfig) =
  if config.numAgents != Seats:
    raise newException(CoinsError,
      "num_agents must be " & $Seats & " (Coins is a dyad), got " &
      $config.numAgents)
  if config.ticksPerBeat < 1:
    raise newException(CoinsError, "ticksPerBeat must be positive")
  if config.minBeats < 1 or config.maxBeats < config.minBeats:
    raise newException(CoinsError,
      "maxBeats must be at least minBeats and both positive")
  if config.endChancePermille < 0 or config.endChancePermille > 1000:
    raise newException(CoinsError, "endChancePermille must be 0..1000")
  if config.coinCap < 1:
    raise newException(CoinsError, "coinCap must be positive")
  if config.coinSpawnIntervalTicks < 1:
    raise newException(CoinsError, "coinSpawnIntervalTicks must be positive")
  if config.initialCoins < 0 or config.initialCoins > InteriorCells - Seats:
    raise newException(CoinsError,
      "initialCoins must fit the interior minus the two spawn cells")
  if config.pickupReward < 1:
    raise newException(CoinsError, "pickupReward must be positive")
  if config.theftPenalty < 0:
    raise newException(CoinsError, "theftPenalty must not be negative")
  if config.stepCooldownTicks < 1:
    raise newException(CoinsError, "stepCooldownTicks must be positive")
  if config.punishThreshold < 1 or config.punishBeats < 1 or
      config.truceBeats < 1:
    raise newException(CoinsError,
      "punishThreshold, punishBeats and truceBeats must be positive")
  if config.llmTimeoutSeconds < 1:
    raise newException(CoinsError, "llmTimeoutSeconds must be positive")
  ## The budget assertion, stated in the sim as well as in the manifest test:
  ## the worst case (every beat paying a batch AND a retry) must sit inside
  ## 60% of episodeTimeoutSeconds.
  if (config.maxBeats * config.worstCaseBeatSeconds()).float >
      config.playDeadlineSeconds() + 1e-9:
    raise newException(CoinsError,
      "maxBeats x (2 x llmTimeoutSeconds) must be inside 60% of " &
      "episodeTimeoutSeconds (" & $config.maxBeats & " x " &
      $config.worstCaseBeatSeconds() & " > " &
      $config.playDeadlineSeconds() & ")")

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults, then validates.
  if configJson.strip().len > 0:
    let node = parseJson(configJson)
    if node.kind != JObject:
      raise newException(CoinsError, "config must be a JSON object")
    if node.hasKey("tokens"):
      config.tokens = @[]
      for token in node["tokens"]:
        config.tokens.add(token.getStr())
    if node.hasKey("players"):
      config.players = @[]
      for player in node["players"]:
        config.players.add(PlayerConfig(name: player{"name"}.getStr()))
    if node.hasKey("seed"): config.seed = node["seed"].getInt()
    if node.hasKey("num_agents"): config.numAgents = node["num_agents"].getInt()
    if node.hasKey("variant"): config.variant = node["variant"].getStr()
    if node.hasKey("ticksPerBeat"):
      config.ticksPerBeat = node["ticksPerBeat"].getInt()
    if node.hasKey("minBeats"): config.minBeats = node["minBeats"].getInt()
    if node.hasKey("maxBeats"): config.maxBeats = node["maxBeats"].getInt()
    if node.hasKey("endChancePermille"):
      config.endChancePermille = node["endChancePermille"].getInt()
    if node.hasKey("coinCap"): config.coinCap = node["coinCap"].getInt()
    if node.hasKey("coinSpawnIntervalTicks"):
      config.coinSpawnIntervalTicks = node["coinSpawnIntervalTicks"].getInt()
    if node.hasKey("initialCoins"):
      config.initialCoins = node["initialCoins"].getInt()
    if node.hasKey("pickupReward"):
      config.pickupReward = node["pickupReward"].getInt()
    if node.hasKey("theftPenalty"):
      config.theftPenalty = node["theftPenalty"].getInt()
    if node.hasKey("stepCooldownTicks"):
      config.stepCooldownTicks = node["stepCooldownTicks"].getInt()
    if node.hasKey("punishThreshold"):
      config.punishThreshold = node["punishThreshold"].getInt()
    if node.hasKey("punishBeats"):
      config.punishBeats = node["punishBeats"].getInt()
    if node.hasKey("truceBeats"): config.truceBeats = node["truceBeats"].getInt()
    if node.hasKey("llmTimeoutSeconds"):
      config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
    if node.hasKey("minBeatSeconds"):
      config.minBeatSeconds = node["minBeatSeconds"].getInt()
    if node.hasKey("maxOutputTokens"):
      config.maxOutputTokens = node["maxOutputTokens"].getInt()
    if node.hasKey("model"): config.model = node["model"].getStr()
    if node.hasKey("episodeTimeoutSeconds"):
      config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
    if node.hasKey("playerConnectTimeoutSeconds"):
      config.playerConnectTimeoutSeconds =
        node["playerConnectTimeoutSeconds"].getInt()
    if node.hasKey("shutdownGraceSeconds"):
      config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt()
  config.validate()

proc configJson*(config: GameConfig): JsonNode =
  ## The whole constant set the viewer and the replay need. Pinned verbatim
  ## into the replay, so playback never re-derives a rule.
  %*{
    "ticksPerBeat": config.ticksPerBeat,
    "minBeats": config.minBeats,
    "maxBeats": config.maxBeats,
    "endChancePermille": config.endChancePermille,
    "coinCap": config.coinCap,
    "coinSpawnIntervalTicks": config.coinSpawnIntervalTicks,
    "initialCoins": config.initialCoins,
    "pickupReward": config.pickupReward,
    "theftPenalty": config.theftPenalty,
    "stepCooldownTicks": config.stepCooldownTicks,
    "punishThreshold": config.punishThreshold,
    "punishBeats": config.punishBeats,
    "truceBeats": config.truceBeats,
    "fps": TargetFps
  }
