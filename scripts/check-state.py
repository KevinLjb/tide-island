#!/usr/bin/env python3
"""Exercise metadata-state inspection and reviewed clear in isolated folders."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import traceback


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/tide-island-bridge")
    parser.add_argument("--temporary-root")
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve(strict=True))
    if args.temporary_root:
        Path(args.temporary_root).mkdir(parents=True, exist_ok=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tide-island-state-", dir=args.temporary_root) as temporary:
        root = Path(temporary)
        inbox = root / "Events"
        state = root / "State"

        def run(command, *options):
            result = subprocess.run([binary, "state", command, "--inbox", str(inbox), *options],
                                    capture_output=True, text=True, timeout=20)
            assert "private-" not in result.stdout + result.stderr
            return result

        absent = run("inspect")
        assert absent.returncode == 0 and not absent.stderr
        assert json.loads(absent.stdout)["exists"] is False and not inbox.exists() and not state.exists()
        checks += 1

        def emit(session):
            result = subprocess.run([binary, "emit", "--inbox", str(inbox), "--session", session,
                                     "--project", "project", "--phase", "working"],
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr

        emit("one")
        notes = inbox / "transcript.jsonl"
        notes.write_bytes(b"private-provider-chat-and-token")

        def contents():
            return {path.name: path.read_bytes() for path in inbox.iterdir()}

        before = contents()
        preview = run("clear")
        assert preview.returncode == 0 and not preview.stderr, preview.stderr
        first = json.loads(preview.stdout)
        assert first["mode"] == "preview" and first["preview"]["eventFiles"] == 1
        assert contents() == before and not state.exists()
        assert json.loads(run("clear").stdout)["preview"]["fingerprint"] == first["preview"]["fingerprint"]
        checks += 1
        wrong = run("clear", "--apply", "--expect", "wrong")
        assert wrong.returncode == 1 and not wrong.stdout and not state.exists() and contents() == before
        checks += 1
        emit("two")
        changed = contents()
        stale = run("clear", "--apply", "--expect", first["preview"]["fingerprint"])
        assert stale.returncode == 1 and not stale.stdout and not state.exists() and contents() == changed
        checks += 1
        refreshed = json.loads(run("clear").stdout)["preview"]
        applied = run("clear", "--apply", "--expect", refreshed["fingerprint"])
        assert applied.returncode == 0 and not applied.stderr, applied.stderr
        report = json.loads(applied.stdout)
        assert report["mode"] == "cleared" and report["result"]["sessions"] == 0
        assert report["result"]["preferences"] == 0 and report["result"]["importedFiles"] == 2
        assert contents() == changed
        state_files = list(state.glob("*.json"))
        assert len(state_files) == 1 and state_files[0].stat().st_mode & 0o777 == 0o600
        checkpoint = state_files[0]
        assert b"private-" not in checkpoint.read_bytes()
        checks += 1
        original = checkpoint.read_bytes()
        inspected = run("inspect")
        assert inspected.returncode == 0 and not inspected.stderr
        counts = json.loads(inspected.stdout)
        assert counts["exists"] and counts["sessions"] == 0 and counts["importedFiles"] == 2
        assert "sessionID" not in inspected.stdout and checkpoint.read_bytes() == original
        checks += 1
        for command, options in [
            ("clear", ("--apply",)), ("clear", ("--expect", "anything")),
            ("clear", ("--apply", "--apply", "--expect", "anything")),
            ("clear", ("--scan-limit", "0")), ("clear", ("--read-budget-bytes", "0")),
            ("inspect", ("--apply",)), ("inspect", ("--expect", "anything")),
            ("inspect", ("--unknown", "1")), ("inspect", ("--state-directory", "relative")),
        ]:
            result = run(command, *options)
            assert result.returncode == 1 and not result.stdout and contents() == changed
            assert checkpoint.read_bytes() == original
            checks += 1
        future = b'{"version":999,"future":"private-unknown-format"}'
        checkpoint.write_bytes(future)
        failure = run("inspect")
        assert failure.returncode == 1 and not failure.stdout and checkpoint.read_bytes() == future
        checks += 1
        preview = json.loads(run("clear").stdout)["preview"]
        replaced = run("clear", "--apply", "--expect", preview["fingerprint"])
        assert replaced.returncode == 0 and checkpoint.read_bytes() != future and contents() == changed
        checks += 1
        preserved_state = root / "kept-state"
        state.rename(preserved_state)
        provider = root / "provider"
        provider.mkdir()
        secret = provider / "chat.jsonl"
        secret.write_bytes(b"private-external-chat")
        state.symlink_to(provider, target_is_directory=True)
        unsafe = run("inspect")
        assert unsafe.returncode == 1 and not unsafe.stdout
        assert secret.read_bytes() == b"private-external-chat" and list(provider.iterdir()) == [secret]
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "isolated-session-state-preview-clear-and-preservation"}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Session state checks::" + diagnostic)
        raise
