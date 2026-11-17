#!/usr/bin/env python3
"""Verify only release archive checksums, not signing, notarization or runtime."""
import argparse
import json
from pathlib import Path
from release_metadata import verify_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify_manifest(args.manifest, args.directory or args.manifest.parent), sort_keys=True))


if __name__ == "__main__":
    main()
