## Coins player: a policy is just a prompt.
##
## Forked from `cogame-bullwhip/src/bullwhip_player.nim`. This process
## connects, sends `{"type":"prompt","prompt":…,"scripted":…}` and then only
## LISTENS. Every decision is made inside the game container
## (`src/coins/llm.nim`), which is what makes one parallel batch per beat
## possible and why the coworld secret must be declared on the GAME runnable.
##
## `PLAYER_SCRIPTED=honest|greedy|reciprocator|tit-for-tat` registers the
## seat as a built-in baseline instead; the server plays those
## deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <coins-image> --name my-coins \
##     --run /bin/coins-player --secret-env PLAYER_PROMPT="<your strategy>" \
##     --secret-env USE_BEDROCK=true

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Take only your own colour and let the other cog's coins sit, even when one is
closer than yours: every coin is +1 to whoever takes it, but a coin of THEIR
colour also costs them 2, so a room where you both grab everything is worth
far less to both of you than a room where you each take your own. The only way
to say so is to walk past their coins where they can see you do it. Watch
their theft counter every beat, not their words. If it does not move, keep
playing take_mine. If it moves twice, play take_theirs for exactly two beats
so the cost is unmistakable, then go straight back to take_mine and give them
a clean beat to reciprocate. Never punish for longer than they stole. Late in
the episode, when the end could come at any beat, keep the truce anyway.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  var policy = getEnv("COWORLD_POLICY_NAME").strip()
  if policy.len == 0:
    policy = getEnv("PLAYER_NAME").strip()
  if policy.len == 0 and scripted.len > 0:
    policy = "coins-" & scripted.replace("-", "")

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted,
         "policy": policy}

  echo "coins player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "coins player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## The receive loop is wrapped so a closed or truncated frame exits 0 (the
  ## raid learning): whisky's `receiveMessage` RAISES on a close frame, and
  ## mummy's `send` only queues, so the game's `quit(0)` can outrun the
  ## flushed `final` frame. Without this the smoke passes and hosted
  ## certification fails intermittently.
  var running = true
  while running:
    try:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "coins player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "coins player: seated at slot ", payload{"slot"}.getInt(),
          " as ", payload{"alias"}.getStr(),
          " (", payload{"colour"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "state":
        discard
      of "final":
        echo "coins player: final scores ", payload{"scores"},
          " reason ", payload{"reason"}.getStr()
        running = false
      else:
        discard
    except CatchableError as error:
      echo "coins player: socket ended (", error.msg, "), exiting"
      running = false
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
