#!/usr/bin/env python3
"""Check release metadata with synthetic headers; never build/sign/run native UI."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import platform
import struct
import subprocess
import sys
import tempfile
import zipfile
from release_metadata import inspect_application, mach_architectures, read_regular, verify_manifest, version_record


ROOT = Path(__file__).resolve().parent.parent


def thin(cpu):
    return struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 2, 0, 0, 0, 0)


def universal():
    x86, arm = thin(0x01000007), thin(0x0100000C)
    return struct.pack(">II", 0xCAFEBABE, 2) + struct.pack(">IIIII", 0x01000007, 0, 48, 32, 0) + struct.pack(">IIIII", 0x0100000C, 0, 80, 32, 0) + x86 + arm


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build/debug/tide-island-bridge")
    parser.add_argument("--temporary-root")
    parser.add_argument("--metadata-only", action="store_true", help="Skip the CI-built shared CLI version command")
    args = parser.parse_args()
    if args.temporary_root:
        Path(args.temporary_root).mkdir(parents=True, exist_ok=True)
    checks = 0
    record = version_record(ROOT)
    with tempfile.TemporaryDirectory(prefix="tide-island-release-", dir=args.temporary_root) as temporary:
        root = Path(temporary)
        subprocess.run([sys.executable, str(ROOT / "scripts/sync-version.py")], check=True, capture_output=True, text=True)
        checks += 1
        if not args.metadata_only:
            binary = Path(args.binary).resolve(strict=True)
            actual = subprocess.run([str(binary), "version"], check=True, capture_output=True, text=True)
            assert json.loads(actual.stdout) == {"version": record["version"], "build": str(record["build"])}
            human = subprocess.run([str(binary), "--version"], check=True, capture_output=True, text=True)
            assert human.stdout.strip() == f'tide-island-bridge {record["version"]} ({record["build"]})'
            assert platform.machine() in mach_architectures(read_regular(binary, 64 * 1024 * 1024))
            checks += 1
        fixture = root / "version-fixture"
        fixture.mkdir()
        metadata = fixture / "VERSION.json"
        metadata.write_text(json.dumps(record))
        subprocess.run([sys.executable, str(ROOT / "scripts/sync-version.py"), "--root", str(fixture), "--write"], check=True, capture_output=True)
        changed = dict(record); changed["build"] += 1
        metadata.write_text(json.dumps(changed))
        drift = subprocess.run([sys.executable, str(ROOT / "scripts/sync-version.py"), "--root", str(fixture)], capture_output=True)
        assert drift.returncode != 0
        checks += 1
        for value in [dict(record, build=True), dict(record, version="01.2.3"), dict(record, schema_version=2)]:
            metadata.write_text(json.dumps(value))
            try:
                version_record(fixture)
                raise AssertionError("Invalid version was accepted")
            except ValueError:
                pass
        metadata.write_text('{"schema_version":1,"version":"0.1.0","version":"0.2.0","build":1}')
        try:
            version_record(fixture)
            raise AssertionError("Duplicate version key was accepted")
        except ValueError:
            pass
        checks += 1
        assert mach_architectures(thin(0x01000007)) == ["x86_64"] and mach_architectures(thin(0x0100000C)) == ["arm64"]
        assert mach_architectures(universal()) == ["arm64", "x86_64"]
        wide = struct.pack(">II", 0xCAFEBABF, 2) + struct.pack(">IIQQII", 0x01000007, 0, 72, 32, 0, 0) + struct.pack(">IIQQII", 0x0100000C, 0, 104, 32, 0, 0) + thin(0x01000007) + thin(0x0100000C)
        little = struct.pack("<II", 0xCAFEBABE, 2) + struct.pack("<IIIII", 0x01000007, 0, 48, 32, 0) + struct.pack("<IIIII", 0x0100000C, 0, 80, 32, 0) + thin(0x01000007) + thin(0x0100000C)
        assert mach_architectures(wide) == mach_architectures(little) == ["arm64", "x86_64"]
        checks += 1
        overlap = bytearray(universal()); struct.pack_into(">I", overlap, 36, 48)
        for data in [b"", b"not-code", thin(1), universal()[:40], bytes(overlap), struct.pack(">II", 0xCAFEBABE, 100)]:
            try:
                mach_architectures(data)
                raise AssertionError("Invalid Mach-O metadata was accepted")
            except ValueError:
                pass
        checks += 1
        app = root / "TideIsland.app"
        extension = app / "Contents/PlugIns/TideIslandActivity.appex"
        revision = "a" * 40
        for bundle, identifier, kind, name in [(app, "dev.kevinljb.tide-island", "APPL", "TideIsland"), (extension, "dev.kevinljb.tide-island.activity", "XPC!", "TideIslandActivity")]:
            (bundle / "Contents/MacOS").mkdir(parents=True)
            info = {"CFBundleIdentifier": identifier, "CFBundlePackageType": kind, "CFBundleExecutable": name,
                    "CFBundleShortVersionString": record["version"], "CFBundleVersion": str(record["build"]),
                    "TideIslandSourceRevision": revision, "LSMinimumSystemVersion": "27.3"}
            if bundle == app:
                info["NSSupportsLiveActivities"] = True
            else:
                info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            code = bundle / "Contents/MacOS" / name
            code.write_bytes(universal()); code.chmod(0o755)
        helpers = app / "Contents/Helpers"
        helpers.mkdir()
        helper = helpers / "tide-island-bridge"
        helper.write_bytes(universal()); helper.chmod(0o755)
        resources = app / "Contents/Resources"
        resources.mkdir()
        manifest = resources / "bridge-manifest.json"
        manifest.write_text(json.dumps({"version": 1, "kind": "tide-island-embedded-bridge", "executable": helper.name, "sha256": hashlib.sha256(helper.read_bytes()).hexdigest()}))
        inspected = inspect_application(app, record, ["arm64", "x86_64"], revision)
        assert len(inspected["files"]) == 3 and inspected["signature_verified"] is False and inspected["native_runtime_verified"] is False
        checks += 1
        for architectures, source in [(["arm64"], revision), (["arm64", "x86_64"], "b" * 40)]:
            try:
                inspect_application(app, record, architectures, source)
                raise AssertionError("Mismatched archive was accepted")
            except ValueError:
                pass
        checks += 1
        info_path = extension / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes()); original_info = info_path.read_bytes()
        info["CFBundleVersion"] = "999"
        info_path.write_bytes(plistlib.dumps(info))
        try:
            inspect_application(app, record)
            raise AssertionError("Mismatched extension version was accepted")
        except ValueError:
            pass
        info_path.write_bytes(original_info)
        checks += 1
        original = helper.read_bytes()
        helper.write_bytes(original + b"tampered")
        try:
            inspect_application(app, record)
            raise AssertionError("Changed helper was accepted")
        except ValueError:
            pass
        helper.unlink(); helper.symlink_to(app / "Contents/MacOS/TideIsland")
        try:
            inspect_application(app, record)
            raise AssertionError("Linked helper was accepted")
        except (ValueError, OSError):
            pass
        checks += 1
        suffix = record["version"] + "-" + str(record["build"]) + "-macos-universal.zip"
        artifacts = {}
        for name in ("TideIsland-" + suffix, "TideIsland-bridge-" + suffix):
            path = root / name
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("metadata-test.txt", "Synthetic fixture only")
            data = path.read_bytes()
            artifacts[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        release = {"schema_version": 1, "kind": "tide-island-release", "version": record["version"], "build": str(record["build"]),
                   "architectures": ["arm64", "x86_64"], "artifacts": artifacts}
        release_path = root / "release-manifest.json"
        release_path.write_text(json.dumps(release))
        verified = verify_manifest(release_path, root)
        assert verified["artifacts_checked"] == 2 and not verified["signature_verified"] and not verified["native_runtime_verified"]
        checks += 1
        path.write_bytes(path.read_bytes() + b"tamper")
        try:
            verify_manifest(release_path, root)
            raise AssertionError("Changed zip was accepted")
        except ValueError:
            pass
        release["artifacts"] = {"../../outside.zip": next(iter(artifacts.values()))}
        release_path.write_text(json.dumps(release))
        try:
            verify_manifest(release_path, root)
            raise AssertionError("Out-of-scope artifact name was accepted")
        except ValueError:
            pass
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "synthetic-release-metadata-headers-checksums-and-shared-cli-version", "shared_cli_checked": not args.metadata_only, "native_verified": False, "signing_executed": False}))


if __name__ == "__main__":
    main()
