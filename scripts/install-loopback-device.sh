#!/bin/zsh
# Builds and installs "Vespertine Loopback": a 2-channel BlackHole of its own for the loopback self-test
# (Settings › Playback › Loopback test…, or vespertine-probe loopback). Leaves any other BlackHole alone.
#
#   scripts/install-loopback-device.sh            build, install (asks for your password) and restart Core Audio
#   scripts/install-loopback-device.sh --remove   uninstall it
#
# BlackHole (GPL-3.0, github.com/ExistentialAudio/BlackHole) is built from source at a pinned commit, with its own name,
# bundle ID and UIDs, so it can't be mistaken for (or replace) a BlackHole 2ch or 16ch used for something else. Signed
# ad hoc unless VESPERTINE_LOOPBACK_SIGN_ID names a signing identity. Needs Xcode.
set -euo pipefail

name="Vespertine Loopback"
bundle_id="org.szeremeta.vespertine.loopback"
driver="/Library/Audio/Plug-Ins/HAL/VespertineLoopback.driver"
tag="v0.7.2"
commit="561d934c77a1fa64987e01ccabe890fed30e181f"

if [[ "${1:-}" == "--remove" ]]; then
    [[ -d "$driver" ]] || { echo "$name isn't installed."; exit 0; }
    sudo rm -rf "$driver"
    sudo killall -9 coreaudiod 2>/dev/null || true
    echo "Removed $name."
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" fetch -q --depth 1 https://github.com/ExistentialAudio/BlackHole "$commit"
git -C "$work" checkout -q FETCH_HEAD
[[ "$(git -C "$work" rev-parse HEAD)" == "$commit" ]] || { echo "BlackHole $tag isn't at the expected commit."; exit 1; }

# The device is named exactly "$name" (no channel count appended), with UIDs of its own. The name is defined in the
# source, because build settings split definitions at spaces and no escape survives that. Signing happens below.
sed -i '' "1i\\
#define kDevice_Name \"$name\"
" "$work/BlackHole/BlackHole.c"
(cd "$work" && xcodebuild -quiet \
    -project BlackHole.xcodeproj -configuration Release -target BlackHole CONFIGURATION_BUILD_DIR="$work/build" CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kNumber_Of_Channels=2 kHas_Driver_Name_Format=false kDriver_Name=\"VespertineLoopback\" kPlugIn_BundleID=\"'"$bundle_id"'\"')
built="$work/build/BlackHole.driver"
[[ -d "$built" ]] || { echo "The build didn't produce BlackHole.driver."; exit 1; }
# A factory UUID of its own, as BlackHole's own installer does for each variant.
plist="$built/Contents/Info.plist"
sed -i '' "s/e395c745-4eea-4d94-bb92-46224221047c/$(uuidgen | tr 'A-Z' 'a-z')/" "$plist"
codesign --force --deep --options runtime --sign "${VESPERTINE_LOOPBACK_SIGN_ID:--}" "$built"

echo "Installing $name (your password is needed to write to /Library/Audio/Plug-Ins/HAL)…"
sudo rm -rf "$driver"
sudo cp -R "$built" "$driver"
sudo chown -R root:wheel "$driver"
sudo killall -9 coreaudiod 2>/dev/null || true
sleep 3
if system_profiler SPAudioDataType 2>/dev/null | grep -q "$name"; then
    echo "Installed: “$name” is ready."
else
    echo "Installed, but Core Audio doesn't list “$name” yet; it appears after a restart."
fi
