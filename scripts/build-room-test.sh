#!/bin/zsh
# Builds "Vespertine Room Test.app": the current tree as a separate app (bundle ID org.szeremeta.Vespertine.roomtest,
# its own library folder, no updater) for trying room measurement without touching the installed Vespertine.
#
#   scripts/build-room-test.sh
#
# Environment:
#   VESPERTINE_SIGN_IDENTITY   identity name or SHA-1 (default: the Developer ID used by scripts/release.sh);
#                            "-" signs ad-hoc. If the default identity can't sign here, the build falls back to ad-hoc
#                            and says so. Never notarized.
#   VESPERTINE_OUT / VESPERTINE_DERIVED   output and derived-data folders (default build/RoomTest, build/DDR-roomtest)
set -euo pipefail
cd "$(dirname $0)/.."
team=${VESPERTINE_TEAM_ID:-7WMQ9ZV6V8}
identity=${VESPERTINE_SIGN_IDENTITY:-"Developer ID Application: Alexander Szeremeta ($team)"}
out=${VESPERTINE_OUT:-build/RoomTest}
derived=${VESPERTINE_DERIVED:-build/DDR-roomtest}
name="Vespertine Room Test"
app="$out/$name.app"
mkdir -p "$out"

scripts/generate-project.sh
xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Release -derivedDataPath "$derived" \
  -onlyUsePackageVersionsFromResolvedFile -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- \
  PRODUCT_BUNDLE_IDENTIFIER=org.szeremeta.Vespertine.roomtest "VESPERTINE_DISPLAY_NAME=$name" build > "$out".log 2>&1 \
  || { grep -E "error:" "$out".log; exit 1; }

staged="$out/.build-$$.app"
ditto "$derived"/Build/Products/Release/Vespertine.app "$staged"
rm -rf "$app"
mv "$staged" "$app"
find "$app" -type d -name ru.lproj -prune -exec rm -rf {} +
git rev-parse HEAD > "$out/built-from"
git status --porcelain --untracked-files=all -- . ':(exclude)Packages/*/Package.resolved' | grep -q . && print "(built from a tree with uncommitted changes)" >> "$out/built-from" || true

# This copy must never update itself into the real Vespertine.
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist"
/usr/libexec/PlistBuddy -c "Set :SUAllowsAutomaticUpdates false" "$plist"

sign_all() {  # sign_all <identity> [codesign options…]: inside-out, as release.sh does
  local id=$1; shift
  local sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  if [[ -d $sp ]]; then
    codesign --force "$@" --sign "$id" "$sp/XPCServices/Installer.xpc"
    codesign --force "$@" --sign "$id" --preserve-metadata=entitlements "$sp/XPCServices/Downloader.xpc"
    codesign --force "$@" --sign "$id" "$sp/Autoupdate"
    codesign --force "$@" --sign "$id" "$sp/Updater.app"
  fi
  for fw in "$app"/Contents/Frameworks/*.framework; do codesign --force "$@" --sign "$id" "$fw"; done
  codesign --force "$@" --sign "$id" --entitlements App/Vespertine.entitlements "$app"
}

signed=adhoc
if [[ $identity != "-" ]] && sign_all "$identity" --timestamp --options runtime > "$out/sign.log" 2>&1; then
  signed=developer-id
else
  [[ $identity == "-" ]] || print -u2 "Developer ID signing failed (see $out/sign.log); signing ad-hoc instead."
  sign_all - > "$out/sign-adhoc.log" 2>&1
fi
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -E "Identifier|Signature|Authority=Developer ID Application|TeamIdentifier|flags"
print "signing: $signed (not notarized)"
print "bundle id: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")"
print "version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
print "built from: $(cat "$out/built-from")"
print "App: ${app:A}"
