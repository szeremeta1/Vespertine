#!/bin/zsh
# Builds a Release Nocturne.app and signs it (and every embedded framework) with a Developer ID.
#
#   scripts/release.sh [--install]
#
# Environment:
#   NOCTURNE_SIGN_IDENTITY   identity name or SHA-1 (default: "Developer ID Application");
#                            "-" makes a local-only ad-hoc build (no hardened runtime, runs on this Mac only)
#   NOCTURNE_SIGN_KEYCHAIN   keychain holding it (default: search list), e.g. ~/Library/Keychains/old-mac-login.keychain-db
set -euo pipefail
cd "$(dirname $0)/.."
identity=${NOCTURNE_SIGN_IDENTITY:-"Developer ID Application"}
keychain=(); [[ -n ${NOCTURNE_SIGN_KEYCHAIN:-} ]] && keychain=(--keychain "$NOCTURNE_SIGN_KEYCHAIN")

xcodegen generate >/dev/null
xcodebuild -project Nocturne.xcodeproj -scheme Nocturne -configuration Release -derivedDataPath build/DDR \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- build > build/release-log.txt 2>&1 \
  || { grep -E "error:" build/release-log.txt; exit 1; }

app=build/Release/Nocturne.app
rm -rf build/Release && mkdir -p build/Release && ditto build/DDR/Build/Products/Release/Nocturne.app "$app"

# Inside-out: frameworks first, then the app.
if [[ $identity == "-" ]]; then
  # Ad-hoc code has no Team ID, so hardened-runtime library validation would reject the
  # embedded frameworks. Local-only builds therefore skip the hardened runtime.
  for fw in "$app"/Contents/Frameworks/*.framework; do codesign --force --sign - "$fw"; done
  codesign --force --sign - --entitlements App/Nocturne.entitlements "$app"
else
  for fw in "$app"/Contents/Frameworks/*.framework; do
    codesign --force --timestamp --options runtime "${keychain[@]}" --sign "$identity" "$fw"
  done
  codesign --force --timestamp --options runtime "${keychain[@]}" --sign "$identity" \
    --entitlements App/Nocturne.entitlements "$app"
fi

codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -E "Signature|Authority=Developer ID Application|TeamIdentifier"

if [[ ${1:-} == --install ]]; then
  pkill -x Nocturne 2>/dev/null || true
  rm -rf /Applications/Nocturne.app
  ditto "$app" /Applications/Nocturne.app
  echo "Installed /Applications/Nocturne.app"
fi
