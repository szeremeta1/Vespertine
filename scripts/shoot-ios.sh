#!/bin/bash
# Screenshots of every screen of the iPhone remote, from the built-in demo, on one booted Simulator.
# Usage: scripts/shoot-ios.sh <simulator UDID> <output folder> [path to VespertineRemote.app]
# Builds a Debug app into build/shoot-ios unless one is given. The Simulator must be booted already
# (xcrun simctl boot <UDID>); this script never boots or shuts one down. The screens are opened with the
# debug-only launch arguments in RemoteApp/Sources/LaunchOptions.swift.
set -euo pipefail
udid="${1:?simulator UDID}"
out="${2:?output folder}"
app="${3:-}"
bundle=org.szeremeta.VespertineRemote
cd "$(dirname "$0")/.."
if [ -z "$app" ]; then
  xcodegen generate --spec RemoteApp/project.yml >/dev/null
  xcodebuild -project RemoteApp/VespertineRemote.xcodeproj -scheme VespertineRemote -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/shoot-ios CODE_SIGNING_ALLOWED=NO build >/dev/null
  app=build/shoot-ios/Build/Products/Debug-iphonesimulator/VespertineRemote.app
fi
mkdir -p "$out"
xcrun simctl install "$udid" "$app"
xcrun simctl ui "$udid" appearance dark
xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

shoot() {
  local name="$1"; shift
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
  sleep 3
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "$out/$name.png"
}

shoot 01-macs            -VTSamplePairing YES
shoot 02-connection      -VTSamplePairing YES -VTScreen connection
shoot 03-now-playing     -VTDemo YES -VTPlay YES -VTVinyl NO
shoot 04-now-playing-vinyl -VTDemo YES -VTPlay YES -VTVinyl YES
shoot 05-cover-flow      -VTDemo YES -VTPlay YES -VTScreen coverFlow -VTTilt "0,0"
shoot 06-cover-flow-tilted -VTDemo YES -VTPlay YES -VTScreen coverFlow -VTTilt "0.9,0.6"
shoot 07-library         -VTDemo YES -VTPlay YES -VTScreen library
shoot 08-albums          -VTDemo YES -VTPlay YES -VTScreen albums
shoot 09-album           -VTDemo YES -VTPlay YES -VTScreen album
shoot 10-queue           -VTDemo YES -VTPlay YES -VTScreen queue
shoot 11-output          -VTDemo YES -VTPlay YES -VTScreen output
shoot 12-settings        -VTSamplePairing YES -VTScreen settings
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
xcrun simctl status_bar "$udid" clear
