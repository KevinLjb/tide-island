#!/usr/bin/env python3
"""Validate manual native workflow / request guards without invoking native tools."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


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
    checks = 2
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
    print(json.dumps({"status": "passed", "checks": checks, "scope": "native-workflow-and-source-request-only", "request_checked": not args.skip_request_check,
                      "native_compile_verified": False, "native_runtime_verified": False}))


if __name__ == "__main__":
    main()
