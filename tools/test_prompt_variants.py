"""Complete Coins bridge games, across all certified variants."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
templates = ["canonical", "plain", "numbered", "questions", "reordered"]
completed = 0


def request(process, value):
    process.stdin.write(json.dumps(value) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


for variant in json.loads(manifest.read_text())["variants"]:
    name = variant["id"]
    command = [binary, str(manifest), name, "--language"]
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )
    try:
        for seed in ("prompt-17",):
            canonical = None
            direct = []
            for selection, prompt_seed in [
                *(
                    (name, 0)
                    for name in templates + ["heldout-briefing", "heldout-reference"]
                ),
                ("mixed", 4),
            ]:
                selected = templates[prompt_seed] if selection == "mixed" else selection
                observation = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 2,
                        "split": "validation",
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                    },
                )
                transcript = []
                systems = {}
                while observation["kind"] == "decision":
                    view = observation["semantic_view"]
                    metadata = view.pop("prompt_template")
                    assert metadata["bank"] == "coins-rules-v2"
                    assert (
                        metadata["selection"],
                        metadata["seed"],
                        metadata["variant"],
                    ) == (selection, prompt_seed, selected)
                    messages = observation["messages"]
                    assert [message["role"] for message in messages] == [
                        "system",
                        "user",
                    ]
                    for message in messages:
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    seat = observation["seat"]
                    systems[observation["turn"], seat] = messages[0]["content"]
                    assert observation["inference_mode"] == "text_action"
                    for other in range(2):
                        if other != seat:
                            assert (
                                f"PRIVATE-NOTES-{other}" not in messages[1]["content"]
                                and f"SPECTATOR-SAY-{other}"
                                not in messages[1]["content"]
                                and f"SPECTATOR-SAY-{other}" not in json.dumps(view)
                            )
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    assert action["intent"] in {
                        "take_mine",
                        "take_any",
                        "take_theirs",
                        "guard",
                        "hold",
                    }
                    assert "say" in action and "notes" in action
                    action["notes"] = f"PRIVATE-NOTES-{seat}"
                    action["say"] = f"SPECTATOR-SAY-{seat}"
                    transcript.append((view, messages[1], action))
                    result = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": observation["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert result["kind"] == "accepted" and result["action"] == action
                    observation = result["observation"]
                    assert len(transcript) <= variant["game_config"]["maxBeats"] * 2
                assert (
                    observation["kind"] == "terminal"
                    and variant["game_config"]["minBeats"] * 2
                    <= len(transcript)
                    <= variant["game_config"]["maxBeats"] * 2
                )
                for owner in range(2):
                    assert (
                        len(
                            {
                                text
                                for (beat, seat), text in systems.items()
                                if seat == owner
                            }
                        )
                        == len(transcript) // 2
                    )
                outcome = transcript, observation
                if selection == "canonical":
                    canonical = outcome
                else:
                    assert outcome == canonical, (
                        "Wording changed state, user messages, actions, or scores"
                    )
                if selection == "mixed":
                    assert systems == direct[prompt_seed]
                else:
                    direct.append(systems)
                completed += 1
            for seat in range(2):
                assert len({system[1, seat] for system in direct}) == 7
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    for invalid in (
        {"promptVariant": "heldout-briefing"},
        {"promptVariant": "heldout-reference"},
        {"promptVariant": "mixed"},
        {"promptVariant": "mixed", "promptSeed": -1},
        {"promptVariant": "mixed", "promptSeed": True},
    ):
        result = subprocess.run(
            command,
            input=json.dumps(
                {"kind": "reset", "seed": "invalid", "players": 2} | invalid
            )
            + "\n",
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout

print(json.dumps({"complete_language_games": completed}))
