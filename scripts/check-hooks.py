#!/usr/bin/env python3
"""Check configuration management using only an isolated Codex directory."""
from pathlib import Path
import argparse
import fcntl
import json
import os
import shutil
import stat
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
    with tempfile.TemporaryDirectory(prefix="tide-island-hooks-", dir=args.temporary_root) as directory:
        root = Path(directory).resolve()
        config = root / "codex/hooks.json"
        backups = root / "retained-backups"
        stable = root / "Stable '$(touch injected-dollar) `touch injected-backtick`/bridge"
        stable.parent.mkdir()
        shutil.copy2(binary, stable)
        stable.chmod(0o700)
        inbox = root / "Events '$(touch injected-inbox)"

        def invoke(action, *options, target=config, bridge=stable, success=True):
            command = [binary, "hooks", action, "--config", str(target)]
            if action == "install":
                command += ["--bridge", str(bridge), "--inbox", str(inbox)]
            result = subprocess.run(command + list(options), capture_output=True, text=True, timeout=15)
            assert (result.returncode == 0) == success, (action, result.stderr)
            assert "fixture-private" not in result.stdout + result.stderr
            if success:
                return json.loads(result.stdout)
            assert not result.stdout
            return result

        preview = invoke("install")
        assert preview["mode"] == "preview" and preview["owned_hooks_after"] == 6
        assert not config.parent.exists() and not backups.exists()
        checks += 1
        no_op = invoke("uninstall")
        no_op_result = invoke("uninstall", "--apply", "--expect", no_op["plan_fingerprint"], "--backup-dir", str(backups))
        assert no_op_result["mode"] == "unchanged" and not config.parent.exists() and not backups.exists()
        checks += 1

        config.parent.mkdir()
        original = {
            "description": "fixture-private-description",
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo fixture-private-command"}]}],
                "Stop": [{"hooks": [{"type": "command", "command": "echo tide-island-other-owner"}]}],
            },
        }
        original_bytes = json.dumps(original, ensure_ascii=False).encode()
        config.write_bytes(original_bytes)
        config.chmod(0o640)
        toml = config.parent / "config.toml"
        toml_bytes = b'notify = ["existing-notifier", "fixture-private-notify"]\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype="command"\ncommand="echo fixture-private-inline"\n'
        toml.write_bytes(toml_bytes)
        preview = invoke("install")
        assert config.read_bytes() == original_bytes and not backups.exists()
        assert preview["config_toml"] == preview["codex_trust"] == "unchanged"
        checks += 1

        def apply(action, plan, **kwargs):
            return invoke(action, "--apply", "--expect", plan["plan_fingerprint"], "--backup-dir", str(backups), **kwargs)

        installed = apply("install", preview)
        backup = Path(installed["backup_path"])
        assert installed["mode"] == "applied" and installed["config_written"]
        assert (backup / "hooks.json.before").read_bytes() == original_bytes
        assert stat.S_IMODE(backup.stat().st_mode) == 0o700
        assert stat.S_IMODE((backup / "hooks.json.before").stat().st_mode) == 0o600
        assert stat.S_IMODE(config.stat().st_mode) == 0o640
        document = json.loads(config.read_text())
        assert document["description"] == original["description"]
        assert document["hooks"]["PreToolUse"][0] == original["hooks"]["PreToolUse"][0]
        assert document["hooks"]["Stop"] == original["hooks"]["Stop"]
        assert toml.read_bytes() == toml_bytes
        checks += 1

        # Exercise the generated shell command with hostile-looking literal paths.
        fixture = Path(__file__).resolve().parent.parent / "Tests/TideIslandCoreTests/Fixtures/Codex/lifecycle.json"
        payload = json.loads(fixture.read_text())["fixtures"][0]["payload"]
        observed = subprocess.run(["/bin/sh", "-c", preview["observer_command"]], input=json.dumps(payload),
                                  capture_output=True, text=True, timeout=15, cwd=root)
        assert observed.returncode == 0 and not observed.stdout and not observed.stderr
        assert len(list(inbox.glob("*.json"))) == 1
        assert not any((root / name).exists() for name in ["injected-dollar", "injected-backtick", "injected-inbox"])
        checks += 1

        before = config.read_bytes(), config.stat().st_mtime_ns, set(backups.iterdir())
        repeated = apply("install", invoke("install"))
        assert repeated["mode"] == "unchanged" and "backup_path" not in repeated
        assert (config.read_bytes(), config.stat().st_mtime_ns, set(backups.iterdir())) == before
        checks += 1

        replacement = root / "Stable replacement/bridge"
        replacement.parent.mkdir()
        shutil.copy2(binary, replacement)
        replacement.chmod(0o700)
        upgraded = invoke("install", bridge=replacement)
        invoke("install", "--apply", "--expect", preview["plan_fingerprint"], "--backup-dir", str(backups),
               bridge=replacement, success=False)
        assert config.read_bytes() == before[0]
        apply("install", upgraded, bridge=replacement)
        document = json.loads(config.read_text())
        for event in upgraded["events"]:
            owned = [h for g in document["hooks"][event] for h in g["hooks"]
                     if h.get("statusMessage") == "TideIsland lifecycle observer v1"]
            assert len(owned) == 1 and str(replacement) in owned[0]["command"]
        checks += 1

        stale = invoke("uninstall")
        edited = config.read_bytes() + b"\n"
        config.write_bytes(edited)
        apply("uninstall", stale, success=False)
        assert config.read_bytes() == edited
        checks += 1

        current = invoke("uninstall")
        with (config.parent / ".tide-island-hooks.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            apply("uninstall", current, success=False)
        assert config.read_bytes() == edited
        checks += 1

        blocked = root / "blocked-backups"
        blocked.write_text("do not overwrite")
        invoke("uninstall", "--apply", "--expect", current["plan_fingerprint"], "--backup-dir", str(blocked), success=False)
        assert config.read_bytes() == edited and blocked.read_text() == "do not overwrite"
        checks += 1

        removed = apply("uninstall", current)
        assert (Path(removed["backup_path"]) / "hooks.json.before").read_bytes() == edited
        document = json.loads(config.read_text())
        assert document["hooks"]["PreToolUse"][0] == original["hooks"]["PreToolUse"][0]
        assert document["hooks"]["Stop"] == original["hooks"]["Stop"]
        assert not any(h.get("statusMessage") == "TideIsland lifecycle observer v1"
                       for groups in document["hooks"].values() for group in groups for h in group["hooks"])
        assert toml.read_bytes() == toml_bytes
        checks += 1
        assert apply("uninstall", invoke("uninstall"))["mode"] == "unchanged"
        checks += 1

        # An unavailable observer cannot turn into a blocking shell exit code.
        broken = invoke("install", bridge=root / "missing-bridge")
        missing = subprocess.run(["/bin/sh", "-c", broken["observer_command"]], input=json.dumps(payload),
                                 capture_output=True, text=True, timeout=15, cwd=root)
        assert missing.returncode == 0 and not missing.stdout
        apply("install", broken, bridge=root / "missing-bridge", success=False)
        checks += 1

        # A preview for another target with identical content is still different.
        other = root / "other/hooks.json"
        other.parent.mkdir()
        other.write_bytes(config.read_bytes())
        first_target = invoke("install")
        invoke("install", "--apply", "--expect", first_target["plan_fingerprint"], "--backup-dir", str(backups), target=other, success=False)
        assert other.read_bytes() == config.read_bytes()
        checks += 1

        for text in ['', '{"hooks":{},"hooks":{},"description":"fixture-private"}',
                     '{"hooks":{"PreToolUse":[{"hooks":42}]}}', '[]', ' ' * (1024 * 1024 + 1)]:
            other.write_text(text)
            invoke("install", target=other, success=False)
            assert other.read_text() == text
            checks += 1

        linked = root / "linked/hooks.json"
        linked.parent.mkdir()
        linked.symlink_to(config)
        invoke("uninstall", target=linked, success=False)
        checks += 1
        fifo = root / "fifo/hooks.json"
        fifo.parent.mkdir()
        os.mkfifo(fifo)
        invoke("uninstall", target=fifo, success=False)
        checks += 1

        invoke("install", bridge=root / ".build/release/bridge", success=False)
        checks += 1
        invoke("install", "--apply", success=False)
        checks += 1

        # New-file backups explicitly record absence, not a made-up empty file.
        new = root / "new/hooks.json"
        applied = apply("install", invoke("install", target=new), target=new)
        new_backup = Path(applied["backup_path"])
        assert json.loads((new_backup / "receipt.json").read_text())["original_existed"] is False
        assert not (new_backup / "hooks.json.before").exists()
        assert stat.S_IMODE(new.stat().st_mode) == 0o600
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "isolated-hooks-preview-merge-backup-uninstall"}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Hook configuration checks::" + diagnostic)
        raise
