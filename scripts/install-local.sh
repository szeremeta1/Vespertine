#!/bin/zsh
# Builds Vespertine (Release), signs it for this Mac the way scripts/release.sh signs a local build (ad hoc, no hardened
# runtime: the embedded codec frameworks keep their vendors' Team IDs otherwise, and dyld refuses to load them), and installs
# it as /Applications/Vespertine.app. Quits a running copy first. Nothing is notarized or published.
#
#   scripts/install-local.sh
#
# A TIDAL client built into the app is read from App/Resources/TidalClient.json when that file exists (git ignores it).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/generate-project.sh
xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Release -derivedDataPath build/DD \
  -onlyUsePackageVersionsFromResolvedFile build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
git checkout --quiet -- Packages/VespertineKit/Package.resolved 2>/dev/null || true

built=build/DD/Build/Products/Release/Vespertine.app
app=/Applications/Vespertine.app

if pgrep -f "$app/Contents/MacOS/Vespertine" >/dev/null; then
  osascript -e 'tell application id "org.szeremeta.Vespertine" to quit' || true
  for _ in {1..50}; do pgrep -f "$app/Contents/MacOS/Vespertine" >/dev/null || break; sleep 0.2; done
fi
rm -rf "$app"
ditto "$built" "$app"

sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d $sp ]]; then
  codesign --force --sign - "$sp/XPCServices/Installer.xpc"
  codesign --force --sign - --preserve-metadata=entitlements "$sp/XPCServices/Downloader.xpc"
  codesign --force --sign - "$sp/Autoupdate"
  codesign --force --sign - "$sp/Updater.app"
fi
for fw in "$app"/Contents/Frameworks/*.framework; do codesign --force --sign - "$fw"; done
helper="$app/Contents/Library/LoginItems/Vespertine Sound Helper.app"
for fw in "$helper"/Contents/Frameworks/*.framework(N); do codesign --force --sign - "$fw"; done
codesign --force --sign - "$app/Contents/Library/Audio/VespertineSound.driver"
codesign --force --sign - --entitlements Helper/VespertineSoundHelper.entitlements "$helper"
codesign --force --sign - --entitlements App/Vespertine.entitlements "$app"
codesign --verify --deep --strict "$app"

print "Installed $(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString) at $app"
[[ -f $app/Contents/Resources/TidalClient.json ]] && print "TIDAL: client built in (Sign In works without setup)." \
  || print "TIDAL: no client built in (App/Resources/TidalClient.json missing): Settings › TIDAL asks for one."
