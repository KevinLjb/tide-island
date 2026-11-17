#!/usr/bin/env python3
"""Embed an already built/signed helper; never install hooks or execute it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
from release_metadata import NOTICE_FILENAMES, read_regular


MAXIMUM_BYTES = 64 * 1024 * 1024
ROOT = Path(__file__).resolve().parent.parent


def embed(binary, application):
    app = Path(application)
    if not app.is_absolute() or app.suffix != ".app":
        raise ValueError("Use an absolute application bundle path")
    contents = app / "Contents"
    for directory in (app, contents):
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise ValueError("Bundle directories must not be symlinks")
    info_path = contents / "Info.plist"
    if not stat.S_ISREG(info_path.lstat().st_mode) or info_path.stat().st_size > 65536:
        raise ValueError("Invalid application metadata")
    info = plistlib.loads(info_path.read_bytes())
    if (info.get("CFBundleIdentifier"), info.get("CFBundlePackageType"), info.get("CFBundleExecutable")) != (
        "dev.kevinljb.tide-island", "APPL", "TideIsland"
    ):
        raise ValueError("Expected the TideIsland application bundle")
    descriptor = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAXIMUM_BYTES or not before.st_mode & 0o111:
            raise ValueError("Expected a bounded regular executable")
        data = source.read(MAXIMUM_BYTES + 1)
        after = os.fstat(source.fileno())
        if len(data) != before.st_size or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError("The helper changed during embedding")
    notices = {name: read_regular(ROOT / name, 65536) for name in NOTICE_FILENAMES}
    if any(not data.decode("utf-8").strip() for data in notices.values()):
        raise ValueError("Missing distribution notice text")
    helpers = contents / "Helpers"
    resources = contents / "Resources"
    for directory in (helpers, resources):
        if directory.is_symlink():
            raise ValueError("Bundle output directories must not be symlinks")
        directory.mkdir(exist_ok=True)
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise ValueError("Bundle outputs must use real directories")
    legacy_manifest = helpers / "bridge-manifest.json"
    for target in (helpers / "tide-island-bridge", resources / "bridge-manifest.json", legacy_manifest,
                   *(resources / name for name in NOTICE_FILENAMES)):
        if target.is_symlink() or (target.exists() and not stat.S_ISREG(target.lstat().st_mode)):
            raise ValueError("Refusing a symlink or special output file")
    manifest = {
        "version": 1, "kind": "tide-island-embedded-bridge", "executable": "tide-island-bridge",
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    # Each output is individually atomic. Only a completed build is packaged;
    # this is not a transaction across the helper, manifest and notices.
    with tempfile.TemporaryDirectory(prefix=".tide-island-embed-", dir=resources) as staging:
        staged = Path(staging)
        helper = staged / "tide-island-bridge"
        helper.write_bytes(data)
        helper.chmod(0o755)
        record = staged / "bridge-manifest.json"
        record.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        record.chmod(0o644)
        os.replace(helper, helpers / helper.name)
        os.replace(record, resources / record.name)
        for name, notice_data in notices.items():
            notice = staged / name
            notice.write_bytes(notice_data)
            notice.chmod(0o644)
            os.replace(notice, resources / name)
    # Incremental builds can still contain our old metadata location. Helpers
    # is a code-only directory: an unsigned JSON there prevents outer signing.
    legacy_manifest.unlink(missing_ok=True)
    return {"status": "embedded", "sha256": manifest["sha256"], "bytes": len(data), "hooks_installed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--app", required=True)
    args = parser.parse_args()
    print(json.dumps(embed(args.binary, args.app), sort_keys=True))


if __name__ == "__main__":
    main()
