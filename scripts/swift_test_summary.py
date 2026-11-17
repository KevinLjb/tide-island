#!/usr/bin/env python3
"""Validate positive Swift Testing execution summaries across toolchain versions."""
import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent


def verified_test_count(text, declared):
    counts = [int(value) for value in re.findall(r"Test run with ([0-9]+) tests?(?: in [0-9]+ suites?)? passed", text)]
    if declared <= 0 or not counts or max(counts) < declared:
        raise ValueError("Missing or incomplete Swift Testing summary")
    return max(counts)


def check_fixtures():
    for text, declared in [
        ("✔ Test run with 419 tests passed after 3 seconds.", 419),
        ("✔ Test run with 419 tests in 0 suites passed after 3.358 seconds.", 419),
        ("✔ Test run with 1 test in 1 suite passed after 0.1 seconds.", 1),
        ("✔ Test run with 6 tests in 2 suites passed after 1 second.", 3),
    ]:
        assert verified_test_count(text, declared) >= declared
    for text, declared in [
        ("Test Suite 'All tests' passed. Executed 0 tests.", 419),
        ("Test run with 0 tests in 0 suites passed after 0.1 seconds.", 419),
        ("Test run with 418 tests in 0 suites passed after 1 second.", 419),
        ("Test run with 419 tests in 0 suites failed after 1 second.", 419),
        ("Test run with 0 tests passed after 0.1 seconds.", 0),
    ]:
        try:
            verified_test_count(text, declared)
            raise AssertionError("Incomplete or failed execution was accepted")
        except ValueError:
            pass
    return 9


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-fixtures", action="store_true")
    mode.add_argument("--log", type=Path)
    parser.add_argument("--tests", type=Path, default=ROOT / "Tests/TideIslandCoreTests")
    args = parser.parse_args()
    if args.check_fixtures:
        print(json.dumps({"status": "passed", "scope": "swift-test-summary-fixtures", "checks": check_fixtures()}))
        return
    declared = sum(len(re.findall(r"(?m)^\s*@Test\b", path.read_text())) for path in args.tests.rglob("*.swift"))
    executed = verified_test_count(args.log.read_text(), declared)
    print(json.dumps({"status": "passed", "tests_executed": executed, "tests_declared": declared}))


if __name__ == "__main__":
    main()
