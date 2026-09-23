## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:coins-train-bridge tools/train_bridge.nim
## coins-train-bridge coworld_manifest_template.json [VARIANT]

import std/[json, os]
import coins/[llm, scripted, sim, sim_types]

const OperatorPrompt = "Maximize your score using only your own observation."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, seat, id: int): JsonNode =
  let state = buildObservation(game, seat)
  %*{
    "kind": "decision",
    "game": "coins",
    "decision_id": id,
    "seat": seat,
    "engine_seat": seat,
    "turn": game.beat,
    "semantic_view": state,
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(state)},
      {"role": "user", "content": userPrompt(state, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["intent"]},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, seat, id: int): JsonNode =
  let state = buildObservation(game, seat)
  var values = newJArray()
  values.add(%(if seat == 0: 1 else: 0))
  values.add(%(if seat == 1: 1 else: 0))
  for key in ["beat", "minBeats", "maxBeats", "endChancePermille",
      "ticksPerBeat", "tick"]:
    values.add(state[key])
  for key in ["pickupReward", "theftPenalty", "coinCap",
      "coinSpawnIntervalTicks", "stepCooldownTicks"]:
    values.add(state["rules"][key])
  for actor in [state["you"], state["them"]]:
    for key in ["x", "y", "score", "pickups", "thefts", "stolenFrom"]:
      values.add(actor[key])
  values.add(state["you"]["facing"])
  for colour in Colour:
    var count = 0
    var nearest = high(int)
    var x = -1
    var y = -1
    for coin in state["coins"]:
      if coin["colour"].getStr() == $colour:
        inc count
        let dist = abs(coin["x"].getInt() - state["you"]["x"].getInt()) +
          abs(coin["y"].getInt() - state["you"]["y"].getInt())
        if dist < nearest:
          nearest = dist
          x = coin["x"].getInt()
          y = coin["y"].getInt()
    values.add(%count)
    values.add(%x)
    values.add(%y)
  var actions = newJArray()
  for intent in Intent:
    actions.add(%*{"intent": $intent})
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: coins-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var seat = 0
  var id = 0
  var decisions: array[Seats, Decision]
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = initSim(config)
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.finished
      response = game.encoding(seat, id)
    of "teacher":
      doAssert not game.finished
      let intent = scriptedIntent(skReciprocator, buildObservation(game, seat),
        game.config.punishThreshold, game.config.punishBeats)
      response = %*{"response": $(%*{"intent": $intent})}
    of "step":
      doAssert not game.finished and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      decisions[seat] = parseDecision(action)
      inc seat
      if seat == Seats:
        game.applyDecisions(decisions)
        for _ in 0 ..< game.config.ticksPerBeat:
          game.stepTick()
        if not game.closeBeat():
          game.endEpisode(game.reason)
        seat = 0
      inc id
      var observation: JsonNode
      if game.finished:
        let outcome = game.resultsJson()
        var scores = newJObject()
        for slot in 0 ..< Seats:
          scores[$slot] = outcome["scores"][slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
