#!/bin/bash
set -euo pipefail

if ! tide_sdk_version=$(xcrun --sdk macosx --show-sdk-version); then
    echo "Cannot query the macOS SDK. Open Xcode and complete its first-launch setup." >&2
    exit 2
fi

python3 - "$tide_sdk_version" <<'PY'
import sys

actual = tuple(int(part) for part in sys.argv[1].split('.')[:2])
if actual < (27, 3):
    print(f'Native Live Activities require macOS SDK 27.3+, found {sys.argv[1]}.', file=sys.stderr)
    sys.exit(2)
print(f'Native SDK requirement satisfied: macOS {sys.argv[1]}. Runtime and signing still need verification.')
PY
