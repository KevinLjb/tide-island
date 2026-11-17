#!/usr/bin/env python3
"""Report native toolchain prerequisites without building or changing the Mac."""
import argparse
import json
import platform
import re
import subprocess
import sys


MINIMUM_VERSION = (27, 3)
COMMANDS = {
    "host_version": ["/usr/bin/sw_vers", "-productVersion"],
    "host_build": ["/usr/bin/sw_vers", "-buildVersion"],
    "xcode": ["/usr/bin/xcodebuild", "-version"],
    "sdk": ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
}


def numeric_version(value):
    if len(value) > 32 or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", value):
        return None
    return tuple(map(int, value.split(".")[:2]))


def inspect_environment(*, system=None, runner=subprocess.run):
    """Only fixed version queries; injected runners are for isolated checks."""
    report = {"schema_version": 1, "status": "blocked", "scope": "native-environment-only",
              "minimum_version": "27.3", "host_system": system if system is not None else platform.system(),
              "host_version": None, "host_build": None, "xcode_version": None, "xcode_build": None,
              "sdk_version": None, "issues": [], "release_channel": "unverified",
              "native_compile_verified": False, "native_runtime_verified": False}

    def issue(component, code):
        report["issues"].append({"component": component, "code": code})

    if report["host_system"] != "Darwin":
        issue("host", "unsupported-host-system")
        return report

    values = {}
    for component, words in COMMANDS.items():
        try:
            result = runner(words, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
        except subprocess.TimeoutExpired:
            issue(component, "tool-timed-out")
            continue
        except OSError:
            issue(component, "tool-unavailable")
            continue
        if len(result.stdout.encode("utf-8")) + len(result.stderr.encode("utf-8")) > 8192:
            issue(component, "tool-output-too-large")
            continue
        if result.returncode:
            diagnostic = (result.stdout + result.stderr).lower()
            license_required = result.returncode == 69 and "license agreements" in diagnostic and "xcodebuild -license" in diagnostic
            issue(component, "xcode-license-required" if license_required else "tool-failed")
            continue
        values[component] = result.stdout.strip()

    for component, target in [("host_version", "host_version"), ("sdk", "sdk_version")]:
        if component not in values:
            continue
        number = numeric_version(values[component])
        if number is None:
            issue(component, "unknown-version")
        else:
            report[target] = values[component]
            if number < MINIMUM_VERSION:
                issue(component, "version-below-minimum")
    if "host_build" in values:
        if re.fullmatch(r"[0-9A-Za-z]{1,32}", values["host_build"]):
            report["host_build"] = values["host_build"]
        else:
            issue("host_build", "unknown-build")
    if "xcode" in values:
        match = re.fullmatch(r"Xcode ([0-9]+\.[0-9]+(?:\.[0-9]+)?)\nBuild version ([0-9A-Za-z]{1,32})", values["xcode"])
        if not match or numeric_version(match.group(1)) is None:
            issue("xcode", "unknown-version")
        else:
            report["xcode_version"], report["xcode_build"] = match.groups()
            if numeric_version(match.group(1)) < MINIMUM_VERSION:
                issue("xcode", "version-below-minimum")
    if not report["issues"]:
        report["status"] = "ready"
    return report


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    report = inspect_environment()
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "ready" else 2


if __name__ == "__main__":
    sys.exit(main())
