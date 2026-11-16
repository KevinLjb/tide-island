#!/usr/bin/env python3
"""Exercise the built CLI against an isolated inbox, without editing Codex config."""
from pathlib import Path
import argparse
import json
import os
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
    # These checks never need the caller's Wave context or credentials.
    base_environment = {"PATH": os.defpath, "LANG": "en_US.UTF-8"}
    with tempfile.TemporaryDirectory(prefix="tide-island-cli-", dir=args.temporary_root) as directory:
        def invoke(*arguments, payload=None, inbox=None, environment=None):
            return subprocess.run(
                [binary, *arguments, "--inbox", str(inbox or directory)],
                input=payload, capture_output=True, text=True, timeout=15,
                env={**base_environment, **(environment or {})},
            )

        emitted = invoke("emit", "--session", "smoke-session", "--project", "tide-island",
                         "--phase", "working", "--wave-block", "block-1")
        assert emitted.returncode == 0, emitted.stderr
        event = json.loads(emitted.stdout)
        assert event["phase"] == "working" and event["waveBlockID"] == "block-1"
        assert event["version"] == 2 and event["context"]["source"] == "manual"
        assert json.loads((Path(directory) / (event["id"] + ".json")).read_text()) == event
        checks += 1

        payload = json.dumps({
            "type": "agent-turn-complete", "thread-id": "smoke-session", "cwd": "/work/tide-island",
            "last-assistant-message": "private-do-not-store", "input-messages": ["private-do-not-store"],
        })
        notified = invoke("notify", "--payload", payload)
        assert notified.returncode == 0, notified.stderr
        assert json.loads(notified.stdout)["phase"] == "completed"
        assert "private-do-not-store" not in notified.stdout + notified.stderr
        for path in Path(directory).glob("*.json"):
            assert "private-do-not-store" not in path.read_text()
        checks += 1

        invalid = invoke("emit", "--session", "smoke-session", "--project", "tide-island", "--phase", "invalid")
        assert invalid.returncode != 0 and not invalid.stdout
        assert len(list(Path(directory).glob("*.json"))) == 2
        checks += 1
        rejected = invoke("notify", "--payload", '{"private-do-not-store":')
        assert rejected.returncode != 0
        assert "private-do-not-store" not in rejected.stdout + rejected.stderr
        assert len(list(Path(directory).glob("*.json"))) == 2
        checks += 1

        capability = subprocess.run([binary, "capabilities"], capture_output=True, text=True, timeout=15, env=base_environment)
        assert capability.returncode == 0, capability.stderr
        supported = json.loads(capability.stdout)
        assert supported["event_protocol_versions"] == [1, 2]
        assert supported["contract_cli_version"] == "0.169.0"
        assert supported["hook_stdout"] == "empty"
        assert supported["session_persistence"]["schema_version"] == 2
        assert supported["session_persistence"]["readable_schema_versions"] == [1, 2]
        assert supported["wave_location"]["environment_keys"] == ["WAVETERM_BLOCKID", "WAVETERM_TABID", "WAVETERM_VERSION"]
        assert not supported["wave_location"]["runs_wsh"] and not supported["wave_location"]["implements_navigation"]
        assert supported["wave_navigation"]["scope"] == "shared-policy-and-injected-driver"
        assert supported["wave_navigation"]["candidate_route"] == "tab-layout-focus"
        assert supported["wave_navigation"]["default_route"] == "application-fallback-required"
        assert not supported["wave_navigation"]["reports_visible_focus"]
        assert not supported["wave_navigation"]["production_driver_installed"] and not supported["wave_navigation"]["runs_wsh"]
        assert supported["wave_application_return"]["bundle_identifier"] == "dev.commandline.waveterm"
        assert supported["wave_application_return"]["resolves_current_session_links"]
        assert not supported["wave_application_return"]["reports_exact_focus"]
        assert not supported["wave_application_return"]["launches_app_from_cli"]
        assert not supported["wave_application_return"]["native_runtime_verified"]
        assert supported["island_activity"]["scope"] == "shared-presentation-and-client"
        assert supported["island_activity"]["content_fields"] == 6
        assert supported["island_activity"]["shared_json_development_budget_bytes"] > 0
        assert not supported["island_activity"]["formal_sdk_limit_verified"]
        assert not supported["island_activity"]["native_runtime_verified"]
        assert not supported["island_activity"]["runs_native_api_from_cli"]
        assert supported["island_activity"]["latest_snapshot_scheduler"] and supported["island_activity"]["ordered_source_sequences"]
        assert supported["island_activity"]["minimum_ordinary_update_interval_seconds"] > 0
        assert supported["island_activity"]["delivery_stream"]
        checks += 1

        fixture_path = Path(__file__).resolve().parent.parent / "Tests/TideIslandCoreTests/Fixtures/Codex/lifecycle.json"
        fixtures = json.loads(fixture_path.read_text())["fixtures"]
        for fixture in fixtures:
            before = set(Path(directory).glob("*.json"))
            result = invoke("hook", payload=json.dumps(fixture["payload"]))
            assert result.returncode == 0 and not result.stdout, fixture["name"]
            assert not result.stderr, fixture["name"]
            added = set(Path(directory).glob("*.json")) - before
            if fixture["kind"] is None:
                assert not added, fixture["name"]
            else:
                assert len(added) == 1, fixture["name"]
                observed = json.loads(next(iter(added)).read_text())
                assert observed["phase"] == fixture["phase"]
                assert observed["context"]["kind"] == fixture["kind"]
                assert observed["context"]["source"] == "codexHook"
                assert "fixture-private" not in json.dumps(observed)
            checks += 1

        # A pipe can deliver multiple chunks; accepting only the first read
        # would truncate this valid payload, while an unbounded read could grow.
        large = dict(fixtures[0]["payload"])
        large["prompt"] = "fixture-private-prompt" * 10000
        before = set(Path(directory).glob("*.json"))
        result = invoke("hook", payload=json.dumps(large))
        assert result.returncode == 0 and not result.stdout and not result.stderr
        added = set(Path(directory).glob("*.json")) - before
        assert len(added) == 1
        assert "fixture-private" not in next(iter(added)).read_text()
        checks += 1

        for body in ["", '{"fixture-private":', " " * (1024 * 1024 + 1)]:
            before = set(Path(directory).glob("*.json"))
            result = invoke("hook", payload=body)
            assert result.returncode == 0 and not result.stdout
            assert "fixture-private" not in result.stderr
            assert set(Path(directory).glob("*.json")) == before
            checks += 1

        blocked = Path(directory) / "not-a-directory"
        blocked.write_text("fixture-private")
        result = invoke("hook", payload=json.dumps(fixtures[0]["payload"]), inbox=blocked)
        assert result.returncode == 0 and not result.stdout
        assert "fixture-private" not in result.stderr
        checks += 1

        block = "10000000-0000-0000-0000-000000000001"
        tab = "20000000-0000-0000-0000-000000000001"
        explicit_block = "10000000-0000-0000-0000-000000000002"
        explicit_tab = "20000000-0000-0000-0000-000000000002"
        wave_environment = {
            "WAVETERM_BLOCKID": block, "WAVETERM_TABID": tab, "WAVETERM_VERSION": "0.14.5",
            "WAVETERM_JWT": "fixture-private-jwt", "WAVE_AUTH_KEY": "fixture-private-key",
            "WAVETERM_WORKSPACEID": "fixture-private-workspace", "WAVETERM_WINDOWID": "fixture-private-window",
            "PWD": "/fixture-private-directory",
        }
        emit_arguments = ("emit", "--session", "location", "--project", "project", "--phase", "working")
        captured = invoke(*emit_arguments, environment=wave_environment)
        assert captured.returncode == 0 and not captured.stderr
        observed = json.loads(captured.stdout)
        location = observed["waveLocation"]
        assert location["blockID"] == block and location["tabID"] == tab and location["source"] == "environment"
        assert location["version"] == 1 and location["waveVersion"] == "0.14.5"
        assert location["observedAt"] == observed["occurredAt"] == observed["context"]["receivedAt"]
        assert "workspaceID" not in location and "windowID" not in location
        checks += 1

        notified = invoke("notify", "--payload", payload, environment=wave_environment)
        assert notified.returncode == 0 and json.loads(notified.stdout)["waveLocation"]["blockID"] == block
        before = set(Path(directory).glob("*.json"))
        hooked = invoke("hook", payload=json.dumps(fixtures[0]["payload"]), environment=wave_environment)
        assert hooked.returncode == 0 and not hooked.stdout and not hooked.stderr
        added = set(Path(directory).glob("*.json")) - before
        assert len(added) == 1
        assert json.loads(next(iter(added)).read_text())["waveLocation"]["tabID"] == tab
        checks += 1

        for explicit in [explicit_block, "legacy-block"]:
            result = invoke(*emit_arguments, "--wave-block", explicit, environment=wave_environment)
            assert result.returncode == 0 and not result.stderr
            event = json.loads(result.stdout)
            assert event["waveBlockID"] == explicit
            if explicit == "legacy-block":
                assert "waveLocation" not in event
            else:
                assert event["waveLocation"]["source"] == "explicitArguments"
                assert "tabID" not in event["waveLocation"] and "waveVersion" not in event["waveLocation"]
            checks += 1

        overridden = invoke(*emit_arguments, "--wave-block", explicit_block, "--wave-tab", explicit_tab,
                            "--wave-version", "0.14.6", environment=wave_environment)
        assert overridden.returncode == 0 and not overridden.stderr
        override_location = json.loads(overridden.stdout)["waveLocation"]
        assert override_location["blockID"] == explicit_block and override_location["tabID"] == explicit_tab
        assert override_location["waveVersion"] == "0.14.6" and override_location["source"] == "explicitArguments"
        checks += 1

        malformed_environment = {**wave_environment, "WAVETERM_TABID": "bad", "WAVETERM_VERSION": "bad\nversion"}
        partial = invoke(*emit_arguments, environment=malformed_environment)
        assert partial.returncode == 0 and not partial.stderr
        partial_location = json.loads(partial.stdout)["waveLocation"]
        assert partial_location["blockID"] == block and "tabID" not in partial_location and "waveVersion" not in partial_location
        absent = invoke(*emit_arguments, environment={**malformed_environment, "WAVETERM_BLOCKID": "bad\nblock"})
        assert absent.returncode == 0 and "waveLocation" not in json.loads(absent.stdout)
        assert "waveBlockID" not in json.loads(absent.stdout)
        checks += 1

        for arguments in [("--wave-tab", explicit_tab), ("--wave-version", "0.14.5"),
                          ("--wave-block", block, "--wave-tab", "fixture-private-invalid"),
                          ("--wave-block", "legacy-block", "--wave-version", "0.14.5")]:
            before = set(Path(directory).glob("*.json"))
            invalid = invoke(*emit_arguments, *arguments, environment=wave_environment)
            assert invalid.returncode == 1 and not invalid.stdout
            assert "fixture-private" not in invalid.stderr
            hook_invalid = invoke("hook", *arguments, payload=json.dumps(fixtures[0]["payload"]), environment=wave_environment)
            assert hook_invalid.returncode == 0 and not hook_invalid.stdout
            assert "fixture-private" not in hook_invalid.stderr
            assert set(Path(directory).glob("*.json")) == before
            checks += 1

        for path in Path(directory).glob("*.json"):
            assert "fixture-private" not in path.read_text()
        checks += 1
    print(json.dumps({"status": "passed", "checks": checks, "scope": "bridge-cli-isolated-inbox-and-hooks"}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        diagnostic = traceback.format_exc().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Bridge checks::" + diagnostic)
        raise
