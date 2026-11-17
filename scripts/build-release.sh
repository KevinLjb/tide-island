#!/bin/bash
# Prepare local artifacts. No install or GitHub release is performed.
set -euo pipefail
tide_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tide_output=
tide_architectures=universal
tide_signing=unsigned
tide_identity=
tide_notarize_profile=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|--architectures|--signing|--identity|--notarize-profile)
      [ "$#" -ge 2 ] || { echo "Missing packaging option value" >&2; exit 2; }
      case "$1" in
        --output) tide_output=$2 ;;
        --architectures) tide_architectures=$2 ;;
        --signing) tide_signing=$2 ;;
        --identity) tide_identity=$2 ;;
        --notarize-profile) tide_notarize_profile=$2 ;;
      esac
      shift 2 ;;
    --help)
      echo "build-release.sh --output /NEW/DIRECTORY [--architectures universal|arm64|x86_64] [--signing unsigned|adhoc|developer-id] [--identity ID] [--notarize-profile PROFILE]"
      exit 0 ;;
    *) echo "Unknown packaging option" >&2; exit 2 ;;
  esac
done
case "$tide_output" in /*) ;; *) echo "Use an absolute output path" >&2; exit 2 ;; esac
[ ! -e "$tide_output" ] && [ ! -L "$tide_output" ] || { echo "Output must be a new directory" >&2; exit 2; }
case "$tide_architectures" in universal) tide_xcode_archs="arm64 x86_64" ;; arm64|x86_64) tide_xcode_archs=$tide_architectures ;; *) exit 2 ;; esac
case "$tide_signing" in
  unsigned|adhoc) [ -z "$tide_identity" ] && [ -z "$tide_notarize_profile" ] || exit 2 ;;
  developer-id) [ -n "$tide_identity" ] || { echo "Developer ID identity is required" >&2; exit 2; } ;;
  *) exit 2 ;;
esac
[ -z "$(git -C "$tide_root" status --porcelain)" ] || { echo "Commit source changes before making traced release artifacts" >&2; exit 2; }
tide_revision=$(git -C "$tide_root" rev-parse HEAD)
python3 "$tide_root/scripts/sync-version.py"
bash "$tide_root/scripts/check-native-sdk.sh"
tide_sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
mkdir "$tide_output"
if ! /usr/bin/xcodebuild -project "$tide_root/TideIsland.xcodeproj" -scheme TideIsland -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$tide_output/DerivedData" -archivePath "$tide_output/TideIsland.xcarchive" \
    "ARCHS=$tide_xcode_archs" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO "TIDE_ISLAND_SOURCE_REVISION=$tide_revision" archive \
    > "$tide_output/native-build.log" 2>&1; then
  echo "Native archive failed; inspect $tide_output/native-build.log" >&2
  exit 1
fi
tide_options=(--archive "$tide_output/TideIsland.xcarchive" --output "$tide_output/Package" --source-revision "$tide_revision" \
  --sdk-version "$tide_sdk" --architectures "$tide_architectures" --signing "$tide_signing")
if [ -n "$tide_identity" ]; then tide_options+=(--identity "$tide_identity"); fi
if [ -n "$tide_notarize_profile" ]; then tide_options+=(--notarize-profile "$tide_notarize_profile"); fi
python3 "$tide_root/scripts/package-artifacts.py" "${tide_options[@]}"
