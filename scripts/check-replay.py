#!/usr/bin/env python3
"""Exercise deterministic replay without writing to a Codex config or inbox."""
from pathlib import Path
import argparse
import copy
import json
import os
import subprocess
import tempfile
import traceback


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/tide-island-bridge")
    parser.add_argument("--temporary-root")
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve(strict=True))
    fixtures = Path(__file__).resolve().parent.parent / "Tests/TideIslandCoreTests/Fixtures/Replay"
    fixture = fixtures / "lifecycle.json"
    document = json.loads(fixture.read_text())
    checks = 0
    if args.temporary_root:
        Path(args.temporary_root).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tide-island-replay-", dir=args.temporary_root) as directory:
        root = Path(directory)
        (root / "config.toml").write_text('notify = ["fixture-private-notifier"]\n')
        (root / "hooks.json").write_text('{"description":"fixture-private","hooks":{}}')
        alternate = root / "different working directory"
        alternate.mkdir()
        sentinels = {p.name: p.read_bytes() for p in root.iterdir() if p.is_file()}

        def invoke(*options, target=fixture, cwd=root, block="wave-replay-environment-one"):
            environment = os.environ.copy()
            environment["WAVETERM_BLOCKID"] = block
            result = subprocess.run([binary, "replay", "--file", str(target), *options],
                                    capture_output=True, text=True, timeout=20, cwd=cwd, env=environment)
            assert "fixture-private" not in result.stdout + result.stderr
            return result

        first = invoke()
        second = invoke(cwd=alternate, block="wave-replay-environment-two")
        assert first.returncode == second.returncode == 0, first.stderr + second.stderr
        assert not first.stderr and not second.stderr and first.stdout == second.stdout
        report = json.loads(first.stdout)
        assert report["passed"] and report["scenarioCount"] == 10 and report["stepCount"] == 44
        assert report["mismatchCount"] == 0 and report["scope"] == "in-memory-adapters-codec-registry"
        assert not any(text in first.stdout for text in ["/fixture/projects", "transcript_path", "tool_response", "fixture-model"])
        assert {p.name: p.read_bytes() for p in root.iterdir() if p.is_file()} == sentinels
        assert not list(alternate.iterdir())
        checks += 1

        for scenario in document["scenarios"]:
            result = invoke("--scenario", scenario["name"])
            assert result.returncode == 0 and not result.stderr
            selected = json.loads(result.stdout)
            assert selected["scenarioCount"] == 1 and selected["passed"]
            assert selected["scenarios"][0] == next(x for x in report["scenarios"] if x["name"] == scenario["name"])
            checks += 1

        changed = copy.deepcopy(document)
        changed["scenarios"][0]["steps"][0]["expect"] = {"disposition": "discarded", "sessions": []}
        mismatch = root / "mismatch.json"
        mismatch.write_text(json.dumps(changed))
        result = invoke(target=mismatch)
        assert result.returncode == 1 and result.stdout and result.stderr
        failed = json.loads(result.stdout)
        assert not failed["passed"] and failed["mismatchCount"] == 2
        assert failed["scenarios"][0]["steps"][0]["mismatches"] == ["disposition", "sessions"]
        checks += 1

        # Desired T006 behavior is kept as an explicit failing fixture. This
        # validates the diagnostic, not cross-turn correctness of the registry.
        pending = invoke(target=fixtures / "pending-turn-ordering.json")
        assert pending.returncode == 1 and pending.stdout and pending.stderr
        pending_report = json.loads(pending.stdout)
        assert not pending_report["passed"] and pending_report["mismatchCount"] > 0
        assert pending_report["scenarios"][0]["name"] == "late-previous-turn-notify"
        checks += 1

        missing = invoke("--scenario", "missing-scenario")
        assert missing.returncode == 1 and not missing.stdout
        checks += 1
        forbidden = invoke("--inbox", str(root / "must-not-create"))
        assert forbidden.returncode == 1 and not forbidden.stdout and not (root / "must-not-create").exists()
        checks += 1

        invalid = root / "invalid.json"
        malformed = ["", "[]", '{"fixture-private":', '{"schemaVersion":1,"scenarios":[]}',
                     '{"schemaVersion":1,"schemaVersion":1,"scenarios":[]}', " " * (1024 * 1024 + 1)]
        for body in malformed:
            invalid.write_text(body)
            result = invoke(target=invalid)
            assert result.returncode == 1 and not result.stdout and invalid.read_text() == body
            checks += 1

        for key in ["at", "id", "expect"]:
            changed = copy.deepcopy(document)
            changed["scenarios"][0]["steps"][0].pop(key)
            invalid.write_text(json.dumps(changed))
            result = invoke(target=invalid)
            assert result.returncode == 1 and not result.stdout
            checks += 1

        fifo = root / "input.fifo"
        os.mkfifo(fifo)
        result = invoke(target=fifo)
        assert result.returncode == 1 and not result.stdout
        checks += 1
        missing_file = invoke(target=root / "missing.json")
        assert missing_file.returncode == 1 and not missing_file.stdout
        checks += 1
        assert (root / "config.toml").read_bytes() == sentinels["config.toml"]
        assert (root / "hooks.json").read_bytes() == sentinels["hooks.json"]

    print(json.dumps({"status": "passed", "checks": checks, "scenarios": report["scenarioCount"],
                      "steps": report["stepCount"], "known_limits_reproduced": ["late-previous-turn-notify"],
                      "scope": "deterministic-in-memory-replay"}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Replay checks::" + diagnostic)
        raise
