#!/usr/bin/env python3
"""Check (default) or generate version constants from VERSION.json."""
import argparse
import json
from pathlib import Path
from release_metadata import version_record


ROOT = Path(__file__).resolve().parent.parent


def generated_files(record):
    version, build = record["version"], record["build"]
    return {
        "Config/Version.xcconfig": "// Generated from VERSION.json by scripts/sync-version.py.\n"
        f"MARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\nTIDE_ISLAND_SOURCE_REVISION = development\n",
        "Sources/TideIslandCore/TideIslandVersion.swift": "// Generated from VERSION.json by scripts/sync-version.py.\n"
        "public enum TideIslandVersion {\n"
        f'    public static let version = "{version}"\n    public static let build = "{build}"\n'
        "}\n",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    record = version_record(root)
    expected = generated_files(record)
    for relative, text in expected.items():
        path = root / relative
        if path.is_symlink():
            raise ValueError("Generated version files must not be symlinks")
        if args.write:
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_text() != text:
                path.write_text(text)
        elif not path.is_file() or path.read_text() != text:
            raise ValueError("Version constants drifted; run scripts/sync-version.py --write")
    print(json.dumps({"status": "written" if args.write else "passed", "version": record["version"], "build": str(record["build"]), "checked_files": len(expected)}))


if __name__ == "__main__":
    main()
