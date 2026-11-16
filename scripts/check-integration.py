#!/usr/bin/env python3
"""Exercise combined install, repair and uninstall using isolated app/Codex data."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import tomllib
import traceback
import unicodedata


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build/debug/tide-island-bridge")
    parser.add_argument("--temporary-root")
    args = parser.parse_args()
    binary = Path(args.binary).resolve(strict=True)
    if args.temporary_root:
        Path(args.temporary_root).mkdir(parents=True, exist_ok=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tide-island-integration-", dir=args.temporary_root) as temporary:
        root = Path(temporary).resolve()
        app = root / "TideIsland 'literal.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        info = {"CFBundleIdentifier": "dev.kevinljb.tide-island", "CFBundlePackageType": "APPL", "CFBundleExecutable": "TideIsland",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        staged = subprocess.run([sys.executable, str(ROOT / "scripts/embed-bridge.py"), "--binary", str(binary), "--app", str(app)],
                                capture_output=True, text=True, timeout=20)
        assert staged.returncode == 0, staged.stderr
        codex, backups, inbox = root / "Codex", root / "backups", root / "Events"
        hooks, notify = codex / "hooks.json", codex / "config.toml"

        def invoke(action, *options, directory=codex, application=app, destination=inbox, success=True, partial=False):
            command = [str(binary), "integration", action, "--codex-directory", str(directory)]
            if action == "install":
                command += ["--app", str(application)]
            if destination is not None:
                command += ["--inbox", str(destination)]
            result = subprocess.run(command + list(options), capture_output=True, text=True, timeout=20, cwd=root)
            assert (result.returncode == 0) == success, result.stderr
            assert "fixture-private" not in result.stdout + result.stderr
            if success or partial:
                report = json.loads(result.stdout)
                if partial:
                    assert report["mode"] == "incomplete" and not report["cross_file_transaction"]
                return report
            assert not result.stdout
            return result

        def apply(action, plan, *options, **kwargs):
            return invoke(action, *options, "--apply", "--expect", plan["plan_fingerprint"], "--backup-dir", str(backups), **kwargs)

        def snapshots():
            return hooks.read_bytes(), notify.read_bytes()

        def owned(document):
            return [h for groups in document["hooks"].values() for group in groups for h in group.get("hooks", [])
                    if h.get("statusMessage") == "TideIsland lifecycle observer v1"]

        first = invoke("install")
        assert first["mode"] == "preview" and first["hooks_would_change"] and first["notify_would_change"]
        assert first["data_action"] == "keep" and not codex.exists() and not backups.exists() and not inbox.exists()
        checks += 1
        codex.mkdir()
        foreign_hooks = {"future": "fixture-private-metadata", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "keep-other-tool"}]}]}}
        original_hooks = json.dumps(foreign_hooks).encode()
        original_notify = b'# retain\nnotify=["/usr/bin/true", "fixture-private-argument"]\nmodel="fixture-private-model"\n'
        hooks.write_bytes(original_hooks); notify.write_bytes(original_notify)
        hooks.chmod(0o640); notify.chmod(0o640)
        plan = invoke("install")
        installed = apply("install", plan)
        assert installed["mode"] == "applied" and installed["completed_steps"] == ["hooks", "notify"]
        assert set(installed["backups"]) == {"hooks", "notify"}
        assert (Path(installed["backups"]["hooks"]) / "hooks.json.before").read_bytes() == original_hooks
        assert (Path(installed["backups"]["notify"]) / "config.toml.before").read_bytes() == original_notify
        assert len(owned(json.loads(hooks.read_text()))) == 6
        assert tomllib.loads(notify.read_text())["notify"][1] == "notify-dispatch"
        assert stat.S_IMODE(hooks.stat().st_mode) == stat.S_IMODE(notify.stat().st_mode) == 0o640
        assert not inbox.exists()  # installing configuration never executes a callback
        checks += 1
        before = snapshots(), hooks.stat().st_mtime_ns, notify.stat().st_mtime_ns, set(backups.iterdir())
        current = invoke("install")
        assert apply("install", current)["mode"] == "unchanged"
        assert before == (snapshots(), hooks.stat().st_mtime_ns, notify.stat().st_mtime_ns, set(backups.iterdir()))
        checks += 1

        stale = invoke("install")
        notify.write_bytes(notify.read_bytes() + b"\n[later]\nvalue=7\n")
        edited = snapshots()
        apply("install", stale, success=False)
        assert snapshots() == edited
        checks += 1
        version_preview = invoke("install")
        info["CFBundleVersion"] = "2"
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        apply("install", version_preview, success=False)
        assert snapshots() == edited and apply("install", invoke("install"))["mode"] == "unchanged"
        checks += 1

        moved = root / "Moved TideIsland.app"
        app.rename(moved)
        repaired = apply("install", invoke("install", application=moved), application=moved)
        assert repaired["mode"] == "applied"
        assert all(str(moved) in h["command"] for h in owned(json.loads(hooks.read_text())))
        assert tomllib.loads(notify.read_text())["notify"][0] == str(moved / "Contents/Helpers/tide-island-bridge")
        checks += 1

        changed_inbox = root / "ChangedEvents"
        partial_plan = invoke("install", application=moved, destination=changed_inbox)
        notify_before = notify.read_bytes()
        with (codex / ".tide-island-notify.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            partial = apply("install", partial_plan, application=moved, destination=changed_inbox, success=False, partial=True)
        assert partial["completed_steps"] == ["hooks"] and partial["failed_step"] == "notify" and partial["failure_code"] == "notify-busy" and set(partial["backups"]) == {"hooks"}
        assert all(str(changed_inbox) in h["command"] for h in owned(json.loads(hooks.read_text())))
        assert notify.read_bytes() == notify_before
        resumed = invoke("install", application=moved, destination=changed_inbox)
        assert not resumed["hooks_would_change"] and resumed["notify_would_change"]
        finished = apply("install", resumed, application=moved, destination=changed_inbox)
        assert set(finished["backups"]) == {"notify"} and finished["completed_steps"] == ["hooks", "notify"]
        checks += 1

        def bridge(*words):
            result = subprocess.run([str(binary), *words], capture_output=True, text=True, timeout=20, cwd=root)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def emit(session):
            bridge("emit", "--session", session, "--project", "fixture", "--phase", "working", "--inbox", str(changed_inbox))

        emit("integration-data-a")
        state_plan = bridge("state", "clear", "--inbox", str(changed_inbox))
        bridge("state", "clear", "--inbox", str(changed_inbox), "--apply", "--expect", state_plan["preview"]["fingerprint"])
        state_files = {p: p.read_bytes() for p in (root / "State").glob("*.json")}
        event_files = {p: p.read_bytes() for p in changed_inbox.glob("*.json") if p.name[0] != "."}
        uninstall = invoke("uninstall", application=moved)
        removed = apply("uninstall", uninstall, application=moved)
        assert removed["completed_steps"] == ["notify", "hooks"] and removed["data_action"] == "keep" and removed["session_state"] == "preserved"
        assert not owned(json.loads(hooks.read_text()))
        restored = tomllib.loads(notify.read_text())
        assert restored["notify"] == ["/usr/bin/true", "fixture-private-argument"] and restored["later"] == {"value": 7}
        assert json.loads(hooks.read_text())["hooks"]["Stop"] == foreign_hooks["hooks"]["Stop"]
        assert all(p.read_bytes() == value for p, value in state_files.items()) and all(p.read_bytes() == value for p, value in event_files.items())
        assert apply("uninstall", invoke("uninstall"))["mode"] == "unchanged"
        checks += 1

        # A changed inbox must invalidate review before any configuration edit.
        clear_old = invoke("uninstall", "--data", "clear-state", destination=changed_inbox)
        emit("integration-data-b")
        baseline = snapshots()
        apply("uninstall", clear_old, "--data", "clear-state", destination=changed_inbox, success=False)
        assert snapshots() == baseline and all(p.read_bytes() == value for p, value in state_files.items())
        checks += 1

        clear = invoke("uninstall", "--data", "clear-state", destination=changed_inbox)
        slot = unicodedata.normalize("NFC", changed_inbox.name).lower().encode()
        lease = changed_inbox.parent / (".tide-island-receiver-" + hashlib.sha256(slot).hexdigest() + ".lock")
        with lease.open("a") as lock:
            lease.chmod(0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy = apply("uninstall", clear, "--data", "clear-state", destination=changed_inbox, success=False, partial=True)
        assert busy["completed_steps"] == [] and busy["failed_step"] == "session-state" and busy["failure_code"] == "inbox-receiver-in-use" and snapshots() == baseline
        assert all(p.read_bytes() == value for p, value in state_files.items())
        checks += 1
        all_events = {p: p.read_bytes() for p in changed_inbox.glob("*.json") if p.name[0] != "."}
        cleared = apply("uninstall", clear, "--data", "clear-state", destination=changed_inbox)
        assert cleared["session_state"] == "cleared" and cleared["event_files"] == "preserved" and cleared["display_preferences"] == "preserved"
        assert cleared["completed_steps"] == ["session-state", "notify", "hooks"]
        inspection = bridge("state", "inspect", "--inbox", str(changed_inbox))
        assert inspection["sessions"] == inspection["preferences"] == 0 and inspection["importedFiles"] == len(all_events)
        assert all(p.read_bytes() == value for p, value in all_events.items())
        checks += 1

        invalid = root / "invalid"
        invalid.mkdir()
        (invalid / "hooks.json").write_bytes(original_hooks)
        (invalid / "config.toml").write_bytes(b'notify="unsupported"\n')
        invoke("install", directory=invalid, application=moved, success=False)
        assert (invalid / "hooks.json").read_bytes() == original_hooks and (invalid / "config.toml").read_bytes() == b'notify="unsupported"\n'
        assert not (invalid / ".tide-island-hooks.lock").exists()
        invoke("uninstall", "--data", "clear-state", destination=None, success=False)
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "isolated-combined-integration-partial-recovery-data-choice", "live_config_modified": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Combined integration checks::" + diagnostic)
        raise
