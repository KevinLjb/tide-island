#!/usr/bin/env python3
"""Check embedded bridge delivery / hook repair in isolated synthetic bundles."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
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
    with tempfile.TemporaryDirectory(prefix="tide-island-delivery-", dir=args.temporary_root) as temporary:
        root = Path(temporary).resolve()
        app = root / "潮汐岛 '$(touch injected-dollar) `touch injected-backtick`.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        info_path = contents / "Info.plist"
        info = {
            "CFBundleIdentifier": "dev.kevinljb.tide-island", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "TideIsland", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        }
        info_path.write_bytes(plistlib.dumps(info))
        config = root / "Codex/hooks.json"
        backups = root / "backups"

        def embed(application=app, source=binary, success=True):
            result = subprocess.run([sys.executable, str(ROOT / "scripts/embed-bridge.py"), "--binary", str(source), "--app", str(application)],
                                    capture_output=True, text=True, timeout=20)
            assert (result.returncode == 0) == success, result.stderr
            return json.loads(result.stdout) if success else result

        def invoke(*options, application=app, success=True):
            result = subprocess.run([str(binary), "hooks", "install", "--config", str(config), "--app", str(application), *options],
                                    capture_output=True, text=True, timeout=20, cwd=root)
            assert (result.returncode == 0) == success, result.stderr
            assert "fixture-private" not in result.stdout + result.stderr
            if success:
                return json.loads(result.stdout)
            assert not result.stdout
            return result

        def apply(plan, **kwargs):
            return invoke("--apply", "--expect", plan["plan_fingerprint"], "--backup-dir", str(backups), **kwargs)

        staged = embed()
        helper = contents / "Helpers/tide-island-bridge"
        manifest = contents / "Helpers/bridge-manifest.json"
        assert staged["status"] == "embedded" and not staged["hooks_installed"]
        assert helper.read_bytes() == binary.read_bytes()
        assert json.loads(manifest.read_text())["sha256"] == hashlib.sha256(binary.read_bytes()).hexdigest()
        assert stat.S_IMODE(helper.stat().st_mode) == 0o755
        assert not config.parent.exists() and not backups.exists()
        checks += 1

        # Execute the actual CI-built helper from its delivered path, not a stub.
        capabilities = subprocess.run([str(helper), "capabilities"], capture_output=True, text=True, timeout=20, cwd=root)
        assert capabilities.returncode == 0 and json.loads(capabilities.stdout)["hook_configuration"]["application_bundle_option"] == "--app"
        checks += 1
        preview = invoke()
        assert preview["mode"] == "preview" and preview["owned_hooks_after"] == 6
        assert preview["bridge_delivery"]["executable_path"] == str(helper)
        assert not config.parent.exists() and not backups.exists()
        checks += 1

        config.parent.mkdir()
        foreign = {"future": "fixture-private-field", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "keep-other-tool"}]}]}}
        original = json.dumps(foreign).encode()
        config.write_bytes(original)
        toml = config.parent / "config.toml"
        toml.write_bytes(b'notify=["fixture-private-notifier"]\n')
        toml_before = toml.read_bytes()
        installed = apply(invoke())
        assert (Path(installed["backup_path"]) / "hooks.json.before").read_bytes() == original
        assert json.loads(config.read_bytes())["hooks"]["Stop"] == foreign["hooks"]["Stop"]
        assert toml.read_bytes() == toml_before
        checks += 1
        current = invoke()
        before = config.read_bytes(), config.stat().st_mtime_ns, set(backups.iterdir())
        assert not current["would_change"] and apply(current)["mode"] == "unchanged"
        assert before == (config.read_bytes(), config.stat().st_mtime_ns, set(backups.iterdir()))
        checks += 1

        info["CFBundleVersion"] = "2"
        info_path.write_bytes(plistlib.dumps(info))
        upgraded = invoke()
        assert upgraded["plan_fingerprint"] != current["plan_fingerprint"] and not upgraded["would_change"]
        apply(current, success=False)
        assert apply(upgraded)["mode"] == "unchanged" and config.read_bytes() == before[0]
        checks += 1

        # A valid replacement at the same path invalidates the old fingerprint.
        # It is inspected by the original binary; modified bytes are never run.
        replacement = root / "replacement-helper"
        replacement.write_bytes(binary.read_bytes() + b"delivery-test-tail")
        replacement.chmod(0o700)
        embed(source=replacement)
        replaced = invoke()
        assert not replaced["would_change"] and replaced["plan_fingerprint"] != upgraded["plan_fingerprint"]
        apply(upgraded, success=False)
        checks += 1
        embed()

        moved = root / "Moved TideIsland.app"
        app.rename(moved)
        invoke(success=False)
        repair = invoke(application=moved)
        assert repair["would_change"] and repair["owned_hooks_before"] == repair["owned_hooks_after"] == 6
        apply(upgraded, application=moved, success=False)
        apply(repair, application=moved)
        installed_document = json.loads(config.read_bytes())
        for event in repair["events"]:
            owned = [h for group in installed_document["hooks"][event] for h in group["hooks"] if h.get("statusMessage") == "TideIsland lifecycle observer v1"]
            assert len(owned) == 1 and str(moved) in owned[0]["command"] and str(app) not in owned[0]["command"]
        assert installed_document["hooks"]["Stop"] == foreign["hooks"]["Stop"] and toml.read_bytes() == toml_before
        checks += 1

        helper = moved / "Contents/Helpers/tide-island-bridge"
        baseline = config.read_bytes(), set(backups.iterdir())
        helper.write_bytes(b"broken")
        invoke(application=moved, success=False)
        assert baseline == (config.read_bytes(), set(backups.iterdir()))
        checks += 1
        helper.unlink()
        helper.symlink_to(binary)
        invoke(application=moved, success=False)
        embed(application=moved, success=False)
        assert baseline == (config.read_bytes(), set(backups.iterdir()))
        checks += 1
        helper.unlink()
        embed(application=moved)

        unstable = root / ".build/TideIsland.app"
        unstable.parent.mkdir()
        shutil.copytree(moved, unstable)
        invoke(application=unstable, success=False)
        alias = root / "Alias.app"
        alias.symlink_to(unstable)
        invoke(application=alias, success=False)
        invoke("--bridge", str(binary), application=moved, success=False)
        checks += 1
        assert not any((root / name).exists() for name in ("injected-dollar", "injected-backtick"))
        assert toml.read_bytes() == toml_before
    print(json.dumps({"status": "passed", "checks": checks, "scope": "isolated-embedded-bridge-integrity-move-upgrade-hook-repair", "native_verified": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Bridge delivery checks::" + diagnostic)
        raise
