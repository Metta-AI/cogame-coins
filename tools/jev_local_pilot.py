"""Run one matched eight-beat Jev/reciprocator seed with local amd64 Docker.

Build `coins-jev:local`, set TYPESAFE_API_KEY in the process environment, then
run `python tools/jev_local_pilot.py 7`. Add `--include-claude` with
ANTHROPIC_API_KEY set to compare Haiku. Both model seats receive one space as
their operator prompt: it suppresses the player's default strategy, while the
server strips it from the model state. Artifacts stay in ignored `dist/`.
"""

import copy
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "coworld_manifest_template.json").read_text())
key = os.environ["TYPESAFE_API_KEY"]
image = "coins-jev:local"
seed = int(sys.argv[1])
include_claude = "--include-claude" in sys.argv[2:]


def docker(*args, env=None, timeout=300):
    return subprocess.run(
        ["docker", *args],
        check=True,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
    ).stdout.strip()


for arm in (("jev", "claude", "reciprocator") if include_claude
            else ("jev", "reciprocator")):
    out = root / "dist" / f"local-{arm}-seed-{seed}"
    out.mkdir(parents=True, exist_ok=True)
    config = copy.deepcopy(manifest["certification"]["game_config"])
    config["seed"] = seed
    config["minBeats"] = 8
    config["maxBeats"] = 8
    config["tokens"] = ["token-0", "token-1"]
    config["players"] = [{"name": arm}, {"name": "reciprocator"}]
    (out / "config.json").write_text(json.dumps(config))
    prefix = "coins-jev-" + uuid.uuid4().hex[:12]
    network = prefix + "-net"
    containers = []
    docker("network", "create", network)
    try:
        game_env = dict(os.environ)
        game_env.pop("TYPESAFE_API_KEY", None)
        provider_env = []
        if arm == "claude":
            game_env["ANTHROPIC_API_KEY"] = os.environ["ANTHROPIC_API_KEY"]
            provider_env.extend(["-e", "ANTHROPIC_API_KEY"])
        game = prefix + "-game"
        containers.append(game)
        docker(
            "run", "-d", "--name", game,
            "--network", network, "--network-alias", game,
            "-e", "COGAME_HOST=0.0.0.0", "-e", "COGAME_PORT=8080",
            "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
            "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
            "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
            "-e", "COGAME_PLAYER_FAILURE_URI=file:///coworld/player_failure.json",
            *provider_env,
            "-v", f"{out}:/coworld:rw", image, "/bin/coins",
            env=game_env,
        )
        for seat in range(2):
            player = prefix + f"-p{seat}"
            containers.append(player)
            policy_env = ["-e", "PLAYER_SCRIPTED=reciprocator"]
            if seat == 0 and arm == "jev":
                policy_env = ["-e", "PLAYER_JEV=1", "-e", "TYPESAFE_API_KEY"]
            elif seat == 0 and arm == "claude":
                policy_env = ["-e", "PLAYER_LLM=1", "-e", "PLAYER_PROMPT= "]
            docker(
                "run", "-d", "--name", player, "--network", network,
                "-e", f"COWORLD_PLAYER_WS_URL=ws://{game}:8080/player?slot={seat}&token=token-{seat}",
                "-e", f"COWORLD_POLICY_NAME={arm if seat == 0 else 'reciprocator'}",
                *policy_env, image, "/bin/coins-player",
                env=dict(os.environ, TYPESAFE_API_KEY=key),
            )
        exits = [docker("wait", name, timeout=240) for name in containers]
        assert exits == ["0", "0", "0"], exits
        results = json.loads((out / "results.json").read_text())
        replay = json.loads((out / "replay.json").read_text())
        if arm in ("jev", "claude"):
            log = docker("logs", prefix + "-p0" if arm == "jev" else game)
            orders = [event for event in replay["events"]
                      if event["k"] == "order" and event["seat"] == 0]
            if arm == "jev":
                calls = re.findall(
                    r"Coins Jev player: intent (\S+) model \S+ input_tokens (\d+) output_tokens (\d+)",
                    log,
                )
                assert len(calls) == len(orders) == 8
                assert all(call[0] == order["intent"] and order["source"] == "external"
                           for call, order in zip(calls, orders))
                token_counts = [(int(call[1]), int(call[2])) for call in calls]
            else:
                calls = re.findall(
                    r"coins llm: model \S+ input_tokens (\d+) output_tokens (\d+)", log
                )
                assert len(calls) == len(orders) == 8
                assert all(order["source"] == "llm" for order in orders)
                token_counts = [(int(call[0]), int(call[1])) for call in calls]
            print(
                arm, "model calls", len(calls), "input tokens",
                sum(count[0] for count in token_counts), "output tokens",
                sum(count[1] for count in token_counts), "mean latency ms",
                round(sum(order["latencyMs"] for order in orders) / len(orders)),
            )
        print(arm, "exit codes", exits)
        print(arm, "result", results)
        print(arm, "replay bytes", (out / "replay.json").stat().st_size)
    finally:
        for name in containers:
            log = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
            (out / f"{name.split('-')[-1]}.log").write_text(log.stdout + log.stderr)
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "network", "rm", network], capture_output=True)
