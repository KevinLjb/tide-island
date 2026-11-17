#!/usr/bin/env python3
"""Validate manual native workflow / request guards without invoking native tools."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from native_environment import COMMANDS, inspect_environment


ROOT = Path(__file__).resolve().parent.parent


def check_environment_guards():
    baseline = {"host_version": "27.3", "host_build": "26C5047e", "xcode": "Xcode 27.3\nBuild version 27C5035i", "sdk": "27.3"}

    def inspect(overrides=None, system="Darwin"):
        supplied = dict(baseline); supplied.update(overrides or {})
        calls = []

        def run(words, **kwargs):
            calls.append(words)
            assert kwargs["capture_output"] and kwargs["timeout"] == 30
            component = next(key for key, command in COMMANDS.items() if command == words)
            value = supplied[component]
            if isinstance(value, Exception):
                raise value
            if isinstance(value, tuple):
                code, stdout, stderr = value
                return subprocess.CompletedProcess(words, code, stdout, stderr)
            return subprocess.CompletedProcess(words, 0, value + "\n", "")

        report = inspect_environment(system=system, runner=run)
        allowed = [["/usr/bin/sw_vers", "-productVersion"], ["/usr/bin/sw_vers", "-buildVersion"],
                   ["/usr/bin/xcodebuild", "-version"], ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]]
        assert calls == (allowed if system == "Darwin" else [])
        assert not report["native_compile_verified"] and not report["native_runtime_verified"]
        assert report["release_channel"] == "unverified"
        return report

    good = inspect()
    assert good["status"] == "ready" and good["issues"] == []
    assert good["host_build"] == "26C5047e" and good["xcode_version"] == "27.3" and good["sdk_version"] == "27.3"
    old = inspect({"host_version": "27.2", "xcode": "Xcode 27.2\nBuild version 27B52", "sdk": "27.2"})
    assert old["status"] == "blocked" and len(old["issues"]) == 3
    assert {item["component"] for item in old["issues"]} == {"host_version", "xcode", "sdk"}
    license_error = "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license'. private-output"
    missing_license = inspect({"xcode": "Xcode 27.2\nBuild version 27B52", "sdk": (69, "", license_error)})
    assert missing_license["status"] == "blocked" and missing_license["sdk_version"] is None
    assert missing_license["issues"] == [{"component": "sdk", "code": "xcode-license-required"}, {"component": "xcode", "code": "version-below-minimum"}]
    assert "private-output" not in json.dumps(missing_license) and "sudo" not in json.dumps(missing_license)
    missing_tool = inspect({"xcode": FileNotFoundError("private-path")})
    assert missing_tool["status"] == "blocked" and missing_tool["issues"] == [{"component": "xcode", "code": "tool-unavailable"}]
    timed_out = inspect({"sdk": subprocess.TimeoutExpired("private-command", 30)})
    assert timed_out["status"] == "blocked" and timed_out["issues"] == [{"component": "sdk", "code": "tool-timed-out"}]
    unknown = inspect({"host_version": "27.3 beta", "sdk": "", "xcode": "Command Line Tools"})
    assert unknown["status"] == "blocked" and len(unknown["issues"]) == 3 and all(item["code"] == "unknown-version" for item in unknown["issues"])
    excessive_number = inspect({"sdk": "9" * 5000 + ".3", "xcode": "Xcode " + "9" * 5000 + ".3\nBuild version 27C5035i"})
    assert excessive_number["status"] == "blocked" and len(excessive_number["issues"]) == 2 and all(item["code"] == "unknown-version" for item in excessive_number["issues"])
    build = inspect({"host_build": "private/path"})
    assert build["status"] == "blocked" and build["host_build"] is None and build["issues"] == [{"component": "host_build", "code": "unknown-build"}]
    large = inspect({"sdk": "x" * 8193})
    assert large["status"] == "blocked" and large["issues"] == [{"component": "sdk", "code": "tool-output-too-large"}]
    linux = inspect(system="Linux")
    assert linux["status"] == "blocked" and linux["issues"] == [{"component": "host", "code": "unsupported-host-system"}]
    failure = inspect({"sdk": (69, "", "an unrelated tool error with private-output")})
    assert failure["status"] == "blocked" and failure["issues"] == [{"component": "sdk", "code": "tool-failed"}]
    assert "private-output" not in json.dumps(failure)
    return 10


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-request-check", action="store_true", help="Only source checks while editing; CI must not use this")
    args = parser.parse_args()
    ruby = 'require "yaml"; require "json"; puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: false))'
    parsed = subprocess.run(["/usr/bin/ruby", "-e", ruby, str(ROOT / ".github/workflows/native.yml")], check=True, capture_output=True, text=True)
    workflow = json.loads(parsed.stdout)
    assert set(workflow["on"]) == {"workflow_dispatch"}
    inputs = workflow["on"]["workflow_dispatch"]["inputs"]
    assert inputs["revision"]["type"] == "string" and inputs["revision"]["required"] is True and "default" not in inputs["revision"]
    assert inputs["stable_environment_confirmed"]["type"] == "boolean" and inputs["stable_environment_confirmed"]["default"] is False
    assert workflow["permissions"] == {"contents": "read"}
    job = workflow["jobs"]["native"]
    assert job["if"] == "${{ inputs.stable_environment_confirmed }}"
    assert job["runs-on"] == ["self-hosted", "macOS", "ARM64", "tide-island-native-27.3"]
    checkout = next(step for step in job["steps"] if step.get("uses", "").startswith("actions/checkout@"))
    assert checkout["with"]["ref"] == "${{ inputs.revision }}" and checkout["with"]["persist-credentials"] is False
    compile_step = next(step for step in job["steps"] if step.get("name") == "Native Debug and Release compile")
    assert "--configuration both" in compile_step["run"] and "--stable-environment-confirmed" in compile_step["run"]
    assert "${{ inputs.revision }}" not in compile_step["run"]
    assert not any("--notarize-profile" in step.get("run", "") or "integration install" in step.get("run", "") for step in job["steps"])
    script = ROOT / "scripts/native-validation.py"
    blocked = subprocess.run([sys.executable, str(script), "--expected-revision", "0" * 40], capture_output=True, text=True, cwd=ROOT)
    assert blocked.returncode == 2 and json.loads(blocked.stdout)["failure_code"] == "stable-environment-attestation-required"
    environment_checks = check_environment_guards()
    checks = 2 + environment_checks
    if not args.skip_request_check:
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        valid = subprocess.run([sys.executable, str(script), "--expected-revision", revision, "--check-request-only"], capture_output=True, text=True, cwd=ROOT)
        assert valid.returncode == 0, valid.stdout + valid.stderr
        report = json.loads(valid.stdout)
        assert report["scope"] == "source-request-only" and not report["native_compile_verified"] and not report["native_runtime_verified"]
        for supplied, code in [("main", "invalid-reviewed-revision"), ("0" * 40, "reviewed-revision-mismatch")]:
            result = subprocess.run([sys.executable, str(script), "--expected-revision", supplied, "--check-request-only"], capture_output=True, text=True, cwd=ROOT)
            assert result.returncode == 2 and json.loads(result.stdout)["failure_code"] == code
        checks += 3
    print(json.dumps({"status": "passed", "checks": checks, "scope": "native-workflow-source-request-and-isolated-environment", "request_checked": not args.skip_request_check,
                      "environment_fixture_checks": environment_checks, "native_environment_queried": False,
                      "native_compile_verified": False, "native_runtime_verified": False}))


if __name__ == "__main__":
    main()
