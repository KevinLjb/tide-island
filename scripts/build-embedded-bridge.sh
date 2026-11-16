#!/bin/bash
# Called by the app's build phase, before Xcode signs the outer application.
set -euo pipefail

: "${SRCROOT:?}" "${DERIVED_FILE_DIR:?}" "${TARGET_BUILD_DIR:?}" "${WRAPPER_NAME:?}" "${ARCHS:?}" "${CONFIGURATION:?}"
case "$CONFIGURATION" in
  Debug) tide_configuration=debug ;;
  Release) tide_configuration=release ;;
  *) echo "Unsupported bridge configuration" >&2; exit 1 ;;
esac

mkdir -p "$DERIVED_FILE_DIR"
tide_staging=$(mktemp -d "$DERIVED_FILE_DIR/tide-island-bridge.XXXXXX")
trap 'rm -rf "$tide_staging"' EXIT
read -r -a tide_architectures <<< "$ARCHS"
tide_binaries=()
for tide_arch in "${tide_architectures[@]}"; do
  case "$tide_arch" in arm64|x86_64) ;; *) echo "Unsupported bridge architecture" >&2; exit 1 ;; esac
  tide_scratch="$DERIVED_FILE_DIR/bridge-$tide_arch"
  tide_options=(--package-path "$SRCROOT" --scratch-path "$tide_scratch" --configuration "$tide_configuration" --arch "$tide_arch" --disable-sandbox)
  /usr/bin/xcrun --sdk macosx swift build "${tide_options[@]}" --product tide-island-bridge
  tide_bin_directory=$(/usr/bin/xcrun --sdk macosx swift build "${tide_options[@]}" --show-bin-path)
  tide_binaries+=("$tide_bin_directory/tide-island-bridge")
done

tide_helper="$tide_staging/tide-island-bridge"
/usr/bin/xcrun lipo -create "${tide_binaries[@]}" -output "$tide_helper"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  /usr/bin/codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$tide_helper"
fi
# Hash after helper signing. Xcode subsequently signs both files as part of app.
/usr/bin/python3 "$SRCROOT/scripts/embed-bridge.py" --binary "$tide_helper" --app "$TARGET_BUILD_DIR/$WRAPPER_NAME"
