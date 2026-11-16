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
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tide-island-cli-", dir=args.temporary_root) as directory:
        def invoke(*arguments, payload=None, inbox=None):
            return subprocess.run(
                [binary, *arguments, "--inbox", str(inbox or directory)],
                input=payload, capture_output=True, text=True, timeout=15,
            )

        emitted = invoke("emit", "--session", "smoke-session", "--project", "tide-island",
                         "--phase", "working", "--wave-block", "block-1")
        assert emitted.returncode == 0, emitted.stderr
        event = json.loads(emitted.stdout)
        assert event["phase"] == "working" and event["waveBlockID"] == "block-1"
        assert event["version"] == 2 and event["context"]["source"] == "manual"
        assert json.loads((Path(directory) / (event["id"] + ".json")).read_text()) == event
        checks += 1

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
        checks += 1

        invalid = invoke("emit", "--session", "smoke-session", "--project", "tide-island", "--phase", "invalid")
        assert invalid.returncode != 0 and not invalid.stdout
        assert len(list(Path(directory).glob("*.json"))) == 2
        checks += 1
        rejected = invoke("notify", "--payload", '{"private-do-not-store":')
        assert rejected.returncode != 0
        assert "private-do-not-store" not in rejected.stdout + rejected.stderr
        assert len(list(Path(directory).glob("*.json"))) == 2
        checks += 1

        capability = subprocess.run([binary, "capabilities"], capture_output=True, text=True, timeout=15)
        assert capability.returncode == 0, capability.stderr
        supported = json.loads(capability.stdout)
        assert supported["event_protocol_versions"] == [1, 2]
        assert supported["contract_cli_version"] == "0.169.0"
        assert supported["hook_stdout"] == "empty"
        checks += 1

        fixture_path = Path(__file__).resolve().parent.parent / "Tests/TideIslandCoreTests/Fixtures/Codex/lifecycle.json"
        fixtures = json.loads(fixture_path.read_text())["fixtures"]
        for fixture in fixtures:
            before = set(Path(directory).glob("*.json"))
            result = invoke("hook", payload=json.dumps(fixture["payload"]))
            assert result.returncode == 0 and not result.stdout, fixture["name"]
            assert not result.stderr, fixture["name"]
            added = set(Path(directory).glob("*.json")) - before
            if fixture["kind"] is None:
                assert not added, fixture["name"]
            else:
                assert len(added) == 1, fixture["name"]
                observed = json.loads(next(iter(added)).read_text())
                assert observed["phase"] == fixture["phase"]
                assert observed["context"]["kind"] == fixture["kind"]
                assert observed["context"]["source"] == "codexHook"
                assert "fixture-private" not in json.dumps(observed)
            checks += 1

        # A pipe can deliver multiple chunks; accepting only the first read
        # would truncate this valid payload, while an unbounded read could grow.
        large = dict(fixtures[0]["payload"])
        large["prompt"] = "fixture-private-prompt" * 10000
        before = set(Path(directory).glob("*.json"))
        result = invoke("hook", payload=json.dumps(large))
        assert result.returncode == 0 and not result.stdout and not result.stderr
        added = set(Path(directory).glob("*.json")) - before
        assert len(added) == 1
        assert "fixture-private" not in next(iter(added)).read_text()
        checks += 1

        for body in ["", '{"fixture-private":', " " * (1024 * 1024 + 1)]:
            before = set(Path(directory).glob("*.json"))
            result = invoke("hook", payload=body)
            assert result.returncode == 0 and not result.stdout
            assert "fixture-private" not in result.stderr
            assert set(Path(directory).glob("*.json")) == before
            checks += 1

        blocked = Path(directory) / "not-a-directory"
        blocked.write_text("fixture-private")
        result = invoke("hook", payload=json.dumps(fixtures[0]["payload"]), inbox=blocked)
        assert result.returncode == 0 and not result.stdout
        assert "fixture-private" not in result.stderr
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "bridge-cli-isolated-inbox-and-hooks"}))


if __name__ == "__main__":
    main()
