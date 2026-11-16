#!/usr/bin/env python3
"""Validate notify coexistence using synthetic config, events and a local notifier."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import tomllib
import traceback


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
    with tempfile.TemporaryDirectory(prefix="tide-island-notify-", dir=args.temporary_root) as temporary:
        root = Path(temporary).resolve()
        app = root / "潮汐岛 '$(touch injected) `literal`.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        info = {"CFBundleIdentifier": "dev.kevinljb.tide-island", "CFBundlePackageType": "APPL", "CFBundleExecutable": "TideIsland",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        embedded = subprocess.run([sys.executable, str(ROOT / "scripts/embed-bridge.py"), "--binary", str(binary), "--app", str(app)],
                                  capture_output=True, text=True, timeout=20)
        assert embedded.returncode == 0, embedded.stderr
        config = root / "Codex/config.toml"
        backups, inbox = root / "backups", root / "Events"
        receipt = root / "notifier-receipt.json"
        notifier = root / "notifier.py"
        notifier.write_text("import hashlib,json,os,sys\nfrom pathlib import Path\n" +
                            "Path(" + repr(str(receipt)) + ").write_text(json.dumps({'payload_sha256':hashlib.sha256(sys.argv[-1].encode()).hexdigest(), 'arguments':sys.argv[1:-1], 'cwd':os.getcwd()}))\n")

        def invoke(action, *options, target=config, application=app, destination=inbox, success=True):
            command = [str(binary), "notify-config", action, "--config", str(target)]
            if action == "install":
                command += ["--app", str(application), "--inbox", str(destination)]
            result = subprocess.run(command + list(options), capture_output=True, text=True, timeout=20, cwd=root)
            assert (result.returncode == 0) == success, result.stderr
            assert "fixture-private" not in result.stdout + result.stderr
            if success:
                return json.loads(result.stdout)
            assert not result.stdout
            return result

        def apply(action, plan, **kwargs):
            return invoke(action, "--apply", "--expect", plan["plan_fingerprint"], "--backup-dir", str(backups), **kwargs)

        def callback(command, payload, environment=None):
            result = subprocess.run(command + [payload], capture_output=True, text=True, timeout=20, cwd=root, env=environment)
            assert result.returncode == 0 and not result.stdout
            assert "fixture-private" not in result.stderr
            return result

        preview = invoke("install")
        assert preview["mode"] == "preview" and not config.parent.exists() and not backups.exists()
        missing = invoke("uninstall")
        assert apply("uninstall", missing)["mode"] == "unchanged" and not config.parent.exists()
        checks += 1

        config.parent.mkdir()
        original_argv = [sys.executable, str(notifier), "fixed value", "", "--payload", "$(touch injected) `literal`", "🌊"]
        prefix = '# retain header\ninstructions="""\nnotify=["string-trap"]\n"""\nnotify = '
        suffix = ' # retained trailing comment\nmodel="fixture-private-model"\n[profiles.dev]\nnotify=["profile-tool"]\n'
        original = (prefix + json.dumps(original_argv, ensure_ascii=False) + suffix).encode()
        config.write_bytes(original); config.chmod(0o640)
        original_document = tomllib.loads(original.decode())
        plan = invoke("install")
        assert plan["forwards_existing_command"] and not plan["managed_before"] and plan["managed_after"]
        installed = apply("install", plan)
        backup = Path(installed["backup_path"])
        assert (backup / "config.toml.before").read_bytes() == original
        assert stat.S_IMODE(backup.stat().st_mode) == 0o700 and stat.S_IMODE((backup / "config.toml.before").stat().st_mode) == 0o600
        assert stat.S_IMODE(config.stat().st_mode) == 0o640
        document = tomllib.loads(config.read_text())
        assert {k: v for k, v in document.items() if k != "notify"} == {k: v for k, v in original_document.items() if k != "notify"}
        assert config.read_bytes().startswith(prefix.encode()) and config.read_bytes().endswith(suffix.encode())
        checks += 1

        before = config.read_bytes(), config.stat().st_mtime_ns, set(backups.iterdir())
        unchanged = invoke("install")
        assert apply("install", unchanged)["mode"] == "unchanged" and unchanged["managed_before"]
        assert before == (config.read_bytes(), config.stat().st_mtime_ns, set(backups.iterdir()))
        checks += 1

        payload = json.dumps({"type": "agent-turn-complete", "thread-id": "b5f6c1c2-1111-2222-3333-444455556666", "turn-id": "turn-1",
                              "cwd": "/fixture-private/project", "input-messages": ["fixture-private-prompt"], "last-assistant-message": "fixture-private-reply"})
        result = callback(document["notify"], payload)
        assert not result.stderr
        report = json.loads(receipt.read_text())
        assert report["arguments"] == original_argv[2:] and report["cwd"] == str(root)
        assert report["payload_sha256"] == hashlib.sha256(payload.encode()).hexdigest()
        events = [json.loads(path.read_text()) for path in inbox.glob("*.json") if path.name[0] != "."]
        assert len(events) == 1 and events[0]["phase"] == "completed" and events[0]["context"]["source"] == "codexNotify"
        assert "fixture-private" not in json.dumps(events)
        assert not (root / "injected").exists()
        checks += 1

        # The already configured notifier still gets opaque malformed payloads.
        malformed = "fixture-private-opaque-invalid-json"
        result = callback(document["notify"], malformed)
        assert result.stderr == "tide-island-bridge: Notify callback incomplete.\n"
        assert json.loads(receipt.read_text())["payload_sha256"] == hashlib.sha256(malformed.encode()).hexdigest()
        checks += 1

        blocked = root / "blocked-inbox"
        blocked.write_text("keep")
        command = list(document["notify"]); command[4] = str(blocked)
        result = callback(command, payload)
        assert result.stderr == "tide-island-bridge: Notify callback incomplete.\n"
        assert json.loads(receipt.read_text())["payload_sha256"] == hashlib.sha256(payload.encode()).hexdigest()
        assert blocked.read_text() == "keep"
        checks += 1

        def fresh_callback(name, existing_argv, environment=None):
            target = root / name / "config.toml"
            target.parent.mkdir()
            target.write_text("notify=" + json.dumps(existing_argv))
            destination = root / (name + "-events")
            preview = invoke("install", target=target, destination=destination)
            apply("install", preview, target=target, destination=destination)
            configured = tomllib.loads(target.read_text())["notify"]
            result = callback(configured, payload, environment)
            assert len([p for p in destination.glob("*.json") if p.name[0] != "."]) == 1
            return result

        assert fresh_callback("foreign-failure", ["/usr/bin/false"]).stderr == "tide-island-bridge: Notify callback incomplete.\n"
        assert fresh_callback("foreign-missing", ["missing-fixture-notifier"], {"PATH": "/usr/bin:/bin"}).stderr == "tide-island-bridge: Notify callback incomplete.\n"
        checks += 1

        path_directory = root / "bin"
        path_directory.mkdir()
        bare = path_directory / "notifier=literal"
        bare.write_text("#!" + sys.executable + "\n" + notifier.read_text())
        bare.chmod(0o700)
        result = fresh_callback("path-lookup", [bare.name, "path argument"], {"PATH": str(path_directory)})
        assert not result.stderr and json.loads(receipt.read_text())["arguments"] == ["path argument"]
        checks += 1

        stale = invoke("uninstall")
        edited = config.read_bytes() + b"\n[later]\nvalue=7\n"
        config.write_bytes(edited)
        apply("uninstall", stale, success=False)
        assert config.read_bytes() == edited
        checks += 1
        current = invoke("uninstall")
        with (config.parent / ".tide-island-notify.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            apply("uninstall", current, success=False)
        assert config.read_bytes() == edited
        checks += 1

        removed = apply("uninstall", current)
        restored = tomllib.loads(config.read_text())
        assert restored["notify"] == original_argv and restored["later"] == {"value": 7}
        assert (Path(removed["backup_path"]) / "config.toml.before").read_bytes() == edited
        assert apply("uninstall", invoke("uninstall"))["mode"] == "unchanged"
        checks += 1

        new = root / "missing/config.toml"
        created = apply("install", invoke("install", target=new), target=new)
        new_receipt = Path(created["backup_path"])
        assert json.loads((new_receipt / "receipt.json").read_text())["original_existed"] is False
        assert not (new_receipt / "config.toml.before").exists()
        apply("uninstall", invoke("uninstall", target=new), target=new)
        assert tomllib.loads(new.read_text()) == {}
        checks += 1

        for name, kind in [("linked", "symlink"), ("special", "fifo")]:
            target = root / name / "config.toml"
            target.parent.mkdir()
            if kind == "symlink":
                target.symlink_to(config)
            else:
                os.mkfifo(target)
            invoke("uninstall", target=target, success=False)
        checks += 1

        other = root / "invalid/config.toml"
        other.parent.mkdir()
        for text in ['notify=["unterminated]', 'notify=["one"]\n"notify"=[]', '[notify]\nvalue=1', 'notify=["\\u0000"]', ' ' * (1024 * 1024 + 1)]:
            other.write_text(text)
            invoke("install", target=other, success=False)
            assert other.read_text() == text
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "isolated-notify-tomllib-coexistence-callback-backup-restore", "live_config_modified": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Notify integration checks::" + diagnostic)
        raise
