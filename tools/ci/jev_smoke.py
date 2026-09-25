"""Run Jev in both Coins seats beside a scripted reciprocator in Docker."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class SystemOne(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        assert self.path == "/v1/systemone"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(
            body["state"].split("seat-private observation is all you may use:\n", 1)[1]
        )
        choices = body["questions"]["decision"]["criteria"]
        assert "take_mine" in choices
        self.calls.append((dict(self.headers), body["model"], observation))
        payload = json.dumps(
            {
                "model": body["model"],
                "answers": {
                    "decision": {
                        "type": "choice",
                        "confidence": 1.0,
                        "probabilities": {
                            choice: float(choice == "take_mine") for choice in choices
                        },
                    }
                },
                "usage": {"input_tokens": 100, "output_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True, timeout=90
    ).stdout.strip()


def episode(image, server, jev_slot):
    prefix = f"coins-jev-{os.getpid()}-s{jev_slot}"
    network = f"{prefix}-net"
    containers = [f"{prefix}-game", f"{prefix}-p0", f"{prefix}-p1"]
    with tempfile.TemporaryDirectory(prefix=f"{prefix}-") as directory:
        work = Path(directory)
        os.chmod(work, 0o777)
        (work / "config.json").write_text(
            json.dumps(
                {
                    "seed": 7,
                    "num_agents": 2,
                    "tokens": ["token-0", "token-1"],
                    "players": [{"name": "Copper"}, {"name": "Cobalt"}],
                    "minBeats": 4,
                    "maxBeats": 4,
                    "ticksPerBeat": 10,
                    "minBeatSeconds": 0,
                    "llmTimeoutSeconds": 3,
                    "episodeTimeoutSeconds": 120,
                    "playerConnectTimeoutSeconds": 10,
                    "shutdownGraceSeconds": 0,
                }
            )
        )
        docker("network", "create", network)
        passed = False
        try:
            docker(
                "run", "-d", "--name", containers[0], "--network", network,
                "--network-alias", "coins-game", "-e", "COGAME_HOST=0.0.0.0",
                "-e", "COGAME_PORT=8080",
                "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
                "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
                "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
                "-v", f"{work}:/coworld:rw", image, "/bin/coins",
            )
            time.sleep(1)
            for slot in range(2):
                args = [
                    "run", "-d", "--name", containers[slot + 1],
                    "--network", network,
                    "--add-host", "host.docker.internal:host-gateway",
                    "-e", f"COWORLD_PLAYER_WS_URL=ws://coins-game:8080/"
                    f"player?slot={slot}&token=token-{slot}",
                ]
                if slot == jev_slot:
                    args += [
                        "-e", "PLAYER_JEV=1", "-e",
                        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME="
                        f"http://host.docker.internal:{server.server_port}",
                    ]
                else:
                    args += ["-e", "PLAYER_SCRIPTED=reciprocator"]
                docker(*args, image, "/bin/coins-player")
            assert docker("wait", containers[0]) == "0"
            for container in containers[1:]:
                assert docker("wait", container) == "0"
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            orders = [event for event in replay["events"] if event["k"] == "order"]
            jev_orders = [event for event in orders if event["seat"] == jev_slot]
            scripted = [event for event in orders if event["seat"] != jev_slot]
            calls = [call for call in SystemOne.calls if call[2]["slot"] == jev_slot]
            assert results["reason"] == "beat_cap"
            assert results["beats"] == 4
            assert len(calls) == len(jev_orders) == len(scripted) == 4
            assert all(event["source"] == "external" and
                       event["intent"] == "take_mine" for event in jev_orders)
            assert all(event["source"] == "scripted" for event in scripted)
            for headers, model, observation in calls:
                assert headers["x-coworld-player-slot"] == str(jev_slot)
                assert "authorization" not in headers
                assert model == "typesafe/jev-1.13"
                assert observation["slot"] == jev_slot
                assert "seed" not in observation
                assert "endBeat" not in observation
                assert "notes" not in observation["them"]
            print(f"Coins seat {jev_slot}: 4 accepted Jev intents, 4 scripted intents")
            passed = True
        finally:
            if not passed:
                for container in containers:
                    logs = subprocess.run(
                        ["docker", "logs", container], capture_output=True, text=True
                    )
                    print(logs.stdout, logs.stderr, file=sys.stderr)
            for container in containers:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            subprocess.run(["docker", "network", "rm", network], capture_output=True)


if __name__ == "__main__":
    model = http.server.HTTPServer(("0.0.0.0", 0), SystemOne)
    worker = threading.Thread(target=model.serve_forever, daemon=True)
    worker.start()
    try:
        for slot in range(2):
            episode(sys.argv[1], model, slot)
    finally:
        model.shutdown()
        worker.join()
