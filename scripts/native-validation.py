#!/usr/bin/env python3
"""Explicit native compile validation for a reviewed commit on a stable host."""
import argparse
import json
import platform
from pathlib import Path
import re
import subprocess
import sys
from release_metadata import inspect_application, version_record


ROOT = Path(__file__).resolve().parent.parent


class GateFailure(Exception):
    pass


def read_command(words):
    result = subprocess.run(words, cwd=ROOT, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise GateFailure("toolchain-or-source-unavailable")
    return result.stdout.strip()


def source_request(revision):
    if not re.fullmatch("[0-9a-f]{40}", revision):
        raise GateFailure("invalid-reviewed-revision")
    if read_command(["git", "rev-parse", "HEAD"]) != revision:
        raise GateFailure("reviewed-revision-mismatch")
    if read_command(["git", "status", "--porcelain"]):
        raise GateFailure("uncommitted-source")
    return {"status": "request-verified", "scope": "source-request-only", "source_revision": revision,
            "native_compile_verified": False, "native_runtime_verified": False}


def numeric_version(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", value):
        raise GateFailure("unknown-environment-version")
    return tuple(map(int, value.split(".")[:2]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--configuration", choices=["Debug", "Release", "both"], default="both")
    parser.add_argument("--architectures", choices=["arm64", "x86_64", "universal"], default="arm64")
    parser.add_argument("--stable-environment-confirmed", action="store_true")
    parser.add_argument("--check-request-only", action="store_true")
    args = parser.parse_args()
    if not args.check_request_only and not args.stable_environment_confirmed:
        raise GateFailure("stable-environment-attestation-required")
    request = source_request(args.expected_revision)
    if args.check_request_only:
        print(json.dumps(request)); return
    if args.output is None or not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise GateFailure("new-absolute-output-required")
    args.output = args.output.resolve()
    if args.output.is_relative_to(ROOT):
        ignored = subprocess.run(["git", "check-ignore", "--quiet", str(args.output)], cwd=ROOT, capture_output=True)
        if ignored.returncode:
            raise GateFailure("output-must-be-outside-source-or-ignored")
    if platform.system() != "Darwin":
        raise GateFailure("unsupported-host-system")
    system = read_command(["/usr/bin/sw_vers", "-productVersion"])
    sdk = read_command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
    xcode = read_command(["/usr/bin/xcodebuild", "-version"])
    xcode_number = re.search(r"(?m)^Xcode ([0-9]+\.[0-9]+(?:\.[0-9]+)?)$", xcode)
    if numeric_version(system) < (27, 3) or numeric_version(sdk) < (27, 3) or not xcode_number or numeric_version(xcode_number.group(1)) < (27, 3):
        raise GateFailure("unsupported-native-environment")
    # The numeric checks do not identify beta vs stable; the operator assertion
    # is recorded separately and never presented as an automatic proof.
    read_command([sys.executable, str(ROOT / "scripts/sync-version.py")])
    record = version_record(ROOT)
    architectures = ["arm64", "x86_64"] if args.architectures == "universal" else [args.architectures]
    configurations = ["Debug", "Release"] if args.configuration == "both" else [args.configuration]
    report = {"schema_version": 1, "status": "running", "source_revision": args.expected_revision,
              "version": record["version"], "build": str(record["build"]), "host_system": system, "sdk_version": sdk,
              "xcode": xcode, "operator_attested_stable_environment": True, "architectures": architectures,
              "configurations": {}, "signing_requested": False, "native_compile_verified": False, "native_runtime_verified": False}
    args.output.mkdir(parents=True, exist_ok=False)
    report_path = args.output / "native-validation.json"

    def save():
        report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")

    save()
    for configuration in configurations:
        row = {"status": "running", "build_completed": False}
        report["configurations"][configuration] = row
        save()
        derived = args.output / ("DerivedData-" + configuration)
        log = args.output / (configuration + ".log")
        words = ["/usr/bin/xcodebuild", "-project", str(ROOT / "TideIsland.xcodeproj"), "-scheme", "TideIsland", "-configuration", configuration,
                 "-destination", "generic/platform=macOS", "-derivedDataPath", str(derived), "-resultBundlePath", str(args.output / (configuration + ".xcresult")),
                 "ARCHS=" + " ".join(architectures), "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", "TIDE_ISLAND_SOURCE_REVISION=" + args.expected_revision, "build"]
        try:
            source_request(args.expected_revision)
            with log.open("w") as stream:
                result = subprocess.run(words, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=1200)
            if result.returncode:
                raise GateFailure("native-build-failed")
            row["build_completed"] = True
            application = derived / "Build/Products" / configuration / "TideIsland.app"
            row["metadata"] = inspect_application(application, record, architectures, args.expected_revision)
            row["bridge_execution"] = "not-run-incompatible-host"
            if platform.machine() in architectures:
                version = json.loads(read_command([str(application / "Contents/Helpers/tide-island-bridge"), "version"]))
                if version != {"version": record["version"], "build": str(record["build"])}:
                    raise GateFailure("embedded-cli-version-drift")
                row["bridge_execution"] = "version-command-verified-on-host"
            source_request(args.expected_revision)
            row["status"] = "passed"
        except Exception as error:
            row["status"] = "failed"
            row["failure_code"] = str(error) if isinstance(error, GateFailure) else "native-check-incomplete"
            report["status"] = "failed"; save()
            print(json.dumps({"status": "failed", "configuration": configuration, "failure_code": row["failure_code"],
                              "native_compile_verified": False, "native_runtime_verified": False}))
            return 1
        save()
    report["status"] = "passed"; report["native_compile_verified"] = True
    report["both_configurations_verified"] = configurations == ["Debug", "Release"]
    save()
    print(json.dumps({"status": "passed", "scope": "native-compile-and-artifact-metadata", "configurations": configurations,
                      "native_compile_verified": True, "native_runtime_verified": False}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except GateFailure as error:
        print(json.dumps({"status": "blocked", "failure_code": str(error), "native_compile_verified": False, "native_runtime_verified": False}))
        sys.exit(2)
