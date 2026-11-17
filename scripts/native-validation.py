#!/usr/bin/env python3
"""Explicit native compile validation for a reviewed commit and declared channel."""
import argparse
import json
import platform
from pathlib import Path
import re
import subprocess
import sys
from release_metadata import inspect_application, version_record
from native_environment import inspect_environment


ROOT = Path(__file__).resolve().parent.parent


class GateFailure(Exception):
    def __init__(self, code, environment=None, attestation=None):
        super().__init__(code)
        self.environment = environment
        self.attestation = attestation


def read_command(words):
    try:
        result = subprocess.run(words, cwd=ROOT, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateFailure("toolchain-or-source-unavailable") from error
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


def environment_attestation(*, stable, prerelease):
    if not stable and not prerelease:
        raise GateFailure("environment-attestation-required")
    if stable and prerelease:
        raise GateFailure("conflicting-environment-attestations")
    return {"validation_channel": "stable" if stable else "prerelease",
            "operator_attested_stable_environment": stable,
            "operator_attested_prerelease_environment": prerelease}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--configuration", choices=["Debug", "Release", "both"], default="both")
    parser.add_argument("--architectures", choices=["arm64", "x86_64", "universal"], default="arm64")
    channel = parser.add_mutually_exclusive_group()
    channel.add_argument("--stable-environment-confirmed", action="store_true")
    channel.add_argument("--prerelease-environment-confirmed", action="store_true", help="Explicit beta compile only; does not complete stable acceptance")
    parser.add_argument("--check-request-only", action="store_true")
    args = parser.parse_args()
    attestation = None if args.check_request_only else environment_attestation(
        stable=args.stable_environment_confirmed, prerelease=args.prerelease_environment_confirmed)
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
    environment = inspect_environment()
    if environment["status"] != "ready":
        raise GateFailure("native-environment-blocked", environment, attestation)
    system, sdk = environment["host_version"], environment["sdk_version"]
    xcode = "Xcode " + environment["xcode_version"] + "\nBuild version " + environment["xcode_build"]
    # The numeric checks do not identify beta vs stable; the operator assertion
    # is recorded separately and never presented as an automatic proof.
    read_command([sys.executable, str(ROOT / "scripts/sync-version.py")])
    record = version_record(ROOT)
    architectures = ["arm64", "x86_64"] if args.architectures == "universal" else [args.architectures]
    configurations = ["Debug", "Release"] if args.configuration == "both" else [args.configuration]
    report = {"schema_version": 1, "status": "running", "source_revision": args.expected_revision,
              "version": record["version"], "build": str(record["build"]), "host_system": system, "sdk_version": sdk,
              "xcode": xcode, "environment": environment, **attestation, "architectures": architectures,
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
            print(json.dumps({"status": "failed", **attestation, "configuration": configuration, "failure_code": row["failure_code"],
                              "native_compile_verified": False, "native_runtime_verified": False}))
            return 1
        save()
    report["status"] = "passed"; report["native_compile_verified"] = True
    report["both_configurations_verified"] = configurations == ["Debug", "Release"]
    save()
    print(json.dumps({"status": "passed", "scope": "native-compile-and-artifact-metadata", **attestation, "configurations": configurations,
                      "native_compile_verified": True, "native_runtime_verified": False}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except GateFailure as error:
        report = {"status": "blocked", "failure_code": str(error), "native_compile_verified": False, "native_runtime_verified": False}
        if error.environment is not None:
            report["environment"] = error.environment
        if error.attestation is not None:
            report.update(error.attestation)
        print(json.dumps(report))
        sys.exit(2)
