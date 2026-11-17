#!/usr/bin/env python3
"""Assemble reviewed native archive artifacts; no install, release or hook changes."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
from release_metadata import NOTICE_FILENAMES, inspect_application, read_regular, version_record


ROOT = Path(__file__).resolve().parent.parent


def command(words):
    result = subprocess.run(words, capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Artifact tool failed: " + Path(words[0]).name)
    return result


def zip_directory(source, destination):
    command(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source), str(destination)])


def signature(path):
    command(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    details = command(["/usr/bin/codesign", "--display", "--verbose=4", str(path)]).stderr
    team = re.search(r"(?m)^TeamIdentifier=([A-Z0-9]+)$", details)
    return {"team": team.group(1) if team else None, "developer_id": "Authority=Developer ID Application:" in details}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--architectures", choices=["arm64", "x86_64", "universal"], default="universal")
    parser.add_argument("--signing", choices=["unsigned", "adhoc", "developer-id"], default="unsigned")
    parser.add_argument("--identity")
    parser.add_argument("--notarize-profile")
    args = parser.parse_args()
    if not re.fullmatch("[0-9a-f]{40}", args.source_revision) or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", args.sdk_version) or tuple(map(int, args.sdk_version.split(".")[:2])) < (27, 3):
        raise ValueError("Use a reviewed commit and a supported native SDK")
    if bool(args.identity) != (args.signing == "developer-id") or (args.notarize_profile and args.signing != "developer-id"):
        raise ValueError("Developer ID signing requires an explicit identity; notarization requires Developer ID")
    if not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise ValueError("Use a new absolute artifact output directory")
    record = version_record(ROOT)
    architectures = ["arm64", "x86_64"] if args.architectures == "universal" else [args.architectures]
    source = args.archive / "Products/Applications/TideIsland.app"
    inspect_application(source, record, architectures, args.source_revision)
    args.output.mkdir(parents=True, exist_ok=False)
    app = args.output / "TideIsland.app"
    command(["/usr/bin/ditto", str(source), str(app)])
    helper = app / "Contents/Helpers/tide-island-bridge"
    extension = app / "Contents/PlugIns/TideIslandActivity.appex"
    signature_verified = False
    team = None
    if args.signing != "unsigned":
        identity = args.identity if args.signing == "developer-id" else "-"
        common = ["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", identity]
        if args.signing == "developer-id":
            common += ["--timestamp"]
        command(common + [str(helper)])
        # A new signature changes helper bytes. Recreate the manifest before
        # signing the extension and outer bundle, never after the outer sign.
        command([sys.executable, str(ROOT / "scripts/embed-bridge.py"), "--binary", str(helper), "--app", str(app)])
        command(common + ["--entitlements", str(ROOT / "Native/ActivityExtension/TideIslandActivity.entitlements"), str(extension)])
        command(common + [str(app)])
        signatures = [signature(path) for path in (helper, extension, app)]
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        if args.signing == "developer-id":
            teams = {item["team"] for item in signatures}
            if len(teams) != 1 or None in teams or not all(item["developer_id"] for item in signatures):
                raise ValueError("All delivered code must use the same Developer ID team")
            team = next(iter(teams))
        signature_verified = True
    inspection = inspect_application(app, record, architectures, args.source_revision)
    host = {"aarch64": "arm64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    execution = "not-run-incompatible-host"
    if host in architectures:
        actual = json.loads(command([str(helper), "version"]).stdout)
        if actual != {"version": record["version"], "build": str(record["build"])}:
            raise ValueError("Embedded CLI version differs from app / extension metadata")
        execution = "version-command-verified-on-host"
    suffix = record["version"] + "-" + str(record["build"]) + "-macos-" + args.architectures
    app_zip = args.output / ("TideIsland-" + suffix + ".zip")
    zip_directory(app, app_zip)
    notarization = "not-requested"
    if args.notarize_profile:
        # An explicit future packaging invocation authorizes this upload. No
        # credential lookup / submission occurs during ordinary development.
        accepted = json.loads(command(["/usr/bin/xcrun", "notarytool", "submit", str(app_zip), "--keychain-profile", args.notarize_profile,
                                       "--wait", "--output-format", "json"]).stdout)
        if accepted.get("status") != "Accepted":
            raise ValueError("Notarization was not accepted; no distribution claim was recorded")
        command(["/usr/bin/xcrun", "stapler", "staple", str(app)])
        command(["/usr/bin/xcrun", "stapler", "validate", str(app)])
        command(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
        app_zip.unlink()
        zip_directory(app, app_zip)
        notarization = "accepted-and-app-stapled"
    cli = args.output / ("TideIsland-bridge-" + suffix)
    cli.mkdir()
    shutil.copy2(helper, cli / "tide-island-bridge")
    for name in NOTICE_FILENAMES:
        shutil.copy2(app / "Contents/Resources" / name, cli / name)
    (cli / "version.json").write_text(json.dumps({"version": record["version"], "build": str(record["build"]), "source_revision": args.source_revision}, sort_keys=True) + "\n")
    cli_zip = args.output / (cli.name + ".zip")
    zip_directory(cli, cli_zip)
    artifacts = {}
    for path in (app_zip, cli_zip):
        data = read_regular(path, 512 * 1024 * 1024)
        artifacts[path.name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    manifest = {"schema_version": 1, "kind": "tide-island-release", "version": record["version"], "build": str(record["build"]),
                "source_revision": args.source_revision, "sdk_version": args.sdk_version, "architectures": architectures,
                "signing": args.signing, "code_signatures_verified": signature_verified, "team_identifier": team,
                "notarization": notarization, "native_runtime_verified": False, "bridge_execution": execution,
                "validation_scope": inspection["scope"], "components": inspection["files"],
                "notices": inspection["notices"], "artifacts": artifacts}
    (args.output / "release-manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"status": "packaged", "version": record["version"], "build": str(record["build"]), "artifacts": len(artifacts),
                      "signing": args.signing, "notarization": notarization, "native_runtime_verified": False}))


if __name__ == "__main__":
    main()
