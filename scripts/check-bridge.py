#!/usr/bin/env python3
"""Exercise the built CLI against an isolated inbox, without editing Codex config."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/tide-island-bridge")
    parser.add_argument("--temporary-root")
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve(strict=True))
    if args.temporary_root:
        Path(args.temporary_root).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tide-island-cli-", dir=args.temporary_root) as directory:
        def invoke(*arguments):
            return subprocess.run(
                [binary, *arguments, "--inbox", directory], capture_output=True, text=True, timeout=15
            )

        emitted = invoke("emit", "--session", "smoke-session", "--project", "tide-island",
                         "--phase", "working", "--wave-block", "block-1")
        assert emitted.returncode == 0, emitted.stderr
        event = json.loads(emitted.stdout)
        assert event["phase"] == "working" and event["waveBlockID"] == "block-1"
        assert json.loads((Path(directory) / (event["id"] + ".json")).read_text()) == event

        payload = json.dumps({
            "type": "agent-turn-complete", "thread-id": "smoke-session", "cwd": "/work/tide-island",
            "last-assistant-message": "private-do-not-store", "input-messages": ["private-do-not-store"],
        })
        notified = invoke("notify", "--payload", payload)
        assert notified.returncode == 0, notified.stderr
        assert json.loads(notified.stdout)["phase"] == "completed"
        assert "private-do-not-store" not in notified.stdout + notified.stderr
        for path in Path(directory).glob("*.json"):
            assert "private-do-not-store" not in path.read_text()

        invalid = invoke("emit", "--session", "smoke-session", "--project", "tide-island", "--phase", "invalid")
        assert invalid.returncode != 0 and not invalid.stdout
        assert len(list(Path(directory).glob("*.json"))) == 2
        rejected = invoke("notify", "--payload", '{"private-do-not-store":')
        assert rejected.returncode != 0
        assert "private-do-not-store" not in rejected.stdout + rejected.stderr
        assert len(list(Path(directory).glob("*.json"))) == 2
    print(json.dumps({"status": "passed", "checks": 4, "scope": "bridge-cli-isolated-inbox"}))


if __name__ == "__main__":
    main()
