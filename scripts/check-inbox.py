#!/usr/bin/env python3
"""Check cleanup and interrupted-write recovery in isolated metadata files."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import traceback
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/tide-island-bridge")
    parser.add_argument("--temporary-root")
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve(strict=True))
    if args.temporary_root:
        Path(args.temporary_root).mkdir(parents=True, exist_ok=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tide-island-inbox-", dir=args.temporary_root) as temporary:
        root = Path(temporary)
        inbox = root / "isolated inbox"
        emitted = subprocess.run([binary, "emit", "--session", "active", "--project", "project",
                                  "--phase", "working", "--inbox", str(inbox)],
                                 capture_output=True, text=True, timeout=15)
        assert emitted.returncode == 0, emitted.stderr
        active = json.loads(emitted.stdout)
        marker = inbox / ".tide-island-inbox"
        assert marker.read_bytes() == b"TideIsland event inbox v1\n"

        def write_event(phase, session, at="2020-01-01T00:00:00.000Z"):
            event = copy.deepcopy(active)
            event.update(id=str(uuid.uuid4()).upper(), sessionID=session, phase=phase, occurredAt=at)
            event["context"] = {"source": "manual", "kind": "status", "receivedAt": at}
            path = inbox / (event["id"] + ".json")
            path.write_text(json.dumps(event))
            return path

        old = write_event("completed", "expired")
        old_work = write_event("working", "long-task")
        notes = inbox / "transcript.jsonl"
        notes.write_bytes(b"private-provider-chat")
        corrupt = inbox / (str(uuid.uuid4()) + ".json")
        corrupt.write_bytes(b"private-corrupt-input")
        outside = root / "provider.jsonl"
        outside.write_bytes(b"private-external-chat")
        link = inbox / (str(uuid.uuid4()) + ".json")
        link.symlink_to(outside)

        def contents():
            return {p.name: ("symlink", str(p.readlink())) if p.is_symlink() else ("file", p.read_bytes())
                    for p in inbox.iterdir()}

        def cleanup(*options, target=inbox):
            result = subprocess.run([binary, "inbox", "cleanup", "--inbox", str(target), *options],
                                    capture_output=True, text=True, timeout=20)
            assert "private-" not in result.stdout + result.stderr
            return result

        original = contents()
        first = cleanup()
        assert first.returncode == 0 and not first.stderr, first.stderr
        preview = json.loads(first.stdout)
        plan = preview["plan"]
        assert preview["mode"] == "preview" and contents() == original
        assert [x["fileName"] for x in plan["removals"]] == [old.name]
        assert plan["protectedFiles"] == 2 and plan["rejectedFiles"] == 1 and plan["skippedFiles"] == 1
        checks += 1
        second = cleanup()
        assert json.loads(second.stdout)["plan"]["fingerprint"] == plan["fingerprint"]
        checks += 1
        wrong = cleanup("--apply", "--expect", "wrong")
        assert wrong.returncode == 1 and not wrong.stdout and contents() == original
        checks += 1
        changed = write_event("working", "new")
        changed_contents = contents()
        stale = cleanup("--apply", "--expect", plan["fingerprint"])
        assert stale.returncode == 1 and not stale.stdout and contents() == changed_contents
        checks += 1
        refreshed = json.loads(cleanup().stdout)["plan"]
        applied = cleanup("--apply", "--expect", refreshed["fingerprint"])
        assert applied.returncode == 0 and not applied.stderr, applied.stderr
        report = json.loads(applied.stdout)
        assert report["mode"] == "applied" and report["result"]["removedFiles"] == 1
        assert not old.exists() and old_work.exists() and changed.exists()
        assert contents() == {key: value for key, value in changed_contents.items() if key != old.name}
        assert outside.read_bytes() == b"private-external-chat"
        checks += 1
        pressure = cleanup("--max-files", "1", "--max-bytes", "1")
        pressure_plan = json.loads(pressure.stdout)["plan"]
        assert not pressure_plan["targetsMetAfterCleanup"] and not pressure_plan["removals"]
        checks += 1
        sentinel = contents()
        for options in [("--apply",), ("--expect", "anything"), ("--apply", "--apply", "--expect", "anything"),
                        ("--max-files", "0"), ("--max-bytes", "-1"), ("--max-age-days", "nan"),
                        ("--scan-limit", "0"), ("--read-budget-bytes", "0"), ("--unknown", "1")]:
            result = cleanup(*options)
            assert result.returncode == 1 and not result.stdout and contents() == sentinel
            checks += 1
        unmanaged = root / "unmanaged"
        unmanaged.mkdir()
        unmanaged_file = unmanaged / (str(uuid.uuid4()) + ".json")
        unmanaged_file.write_bytes(b"provider-file")
        result = cleanup(target=unmanaged)
        assert result.returncode == 1 and not result.stdout
        assert list(unmanaged.iterdir()) == [unmanaged_file] and unmanaged_file.read_bytes() == b"provider-file"
        checks += 1
        missing = root / "missing"
        result = cleanup(target=missing)
        assert result.returncode == 1 and not result.stdout and not missing.exists()
        checks += 1
        recovery_inbox = root / "recovery"
        initialized = subprocess.run([binary, "emit", "--session", "recovery", "--project", "project",
                                      "--phase", "working", "--inbox", str(recovery_inbox)],
                                     capture_output=True, text=True, timeout=15)
        assert initialized.returncode == 0, initialized.stderr
        staged_event = json.loads(initialized.stdout)
        staged_event["id"] = str(uuid.uuid4()).upper()
        staged_bytes = json.dumps(staged_event).encode()
        stage = recovery_inbox / (".tide-island-" + str(uuid.uuid4()).upper() + ".tmp")
        stage.write_bytes(staged_bytes)
        destination = recovery_inbox / (staged_event["id"] + ".json")

        def recover(*options, target=recovery_inbox):
            result = subprocess.run([binary, "inbox", "recover", "--inbox", str(target), *options],
                                    capture_output=True, text=True, timeout=20)
            assert "private-" not in result.stdout + result.stderr
            return result

        preview = recover()
        assert preview.returncode == 0 and not preview.stderr
        preview_data = json.loads(preview.stdout)
        assert preview_data["mode"] == "preview" and preview_data["report"]["interruptedStages"] == 1
        assert stage.read_bytes() == staged_bytes and not destination.exists()
        checks += 1
        recovered = recover("--apply")
        assert recovered.returncode == 0 and not recovered.stderr, recovered.stderr
        assert json.loads(recovered.stdout)["report"]["recoveredEvents"] == 1
        assert not stage.exists() and destination.read_bytes() == staged_bytes
        checks += 1
        # A process can die between publishing its link and unlinking its stage.
        stage.hardlink_to(destination)
        duplicate = recover("--apply")
        assert duplicate.returncode == 0 and not stage.exists() and destination.stat().st_nlink == 1
        assert json.loads(duplicate.stdout)["report"]["removedStages"] == 1
        checks += 1
        partial = recovery_inbox / (".tide-island-" + str(uuid.uuid4()).upper() + ".tmp")
        partial.write_bytes(b"private-incomplete-write")
        failed = recover("--apply")
        assert failed.returncode == 1
        failure = json.loads(failed.stdout)
        assert failure["mode"] == "partial" and failure["report"]["issues"][0]["reason"] == "invalidStagingEvent"
        assert partial.read_bytes() == b"private-incomplete-write" and destination.read_bytes() == staged_bytes
        checks += 1
        for options in [("--apply", "--apply"), ("--expect", "anything"), ("--scan-limit", "0"),
                        ("--read-budget-bytes", "0"), ("--unknown", "1")]:
            invalid = recover(*options)
            assert invalid.returncode == 1 and not invalid.stdout and partial.exists()
            checks += 1
        missing_recovery = root / "missing-recovery"
        result = recover(target=missing_recovery)
        assert result.returncode == 1 and not result.stdout and not missing_recovery.exists()
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "isolated-inbox-cleanup-and-recovery"}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Inbox checks::" + diagnostic)
        raise
