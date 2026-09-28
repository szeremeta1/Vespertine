#!/bin/zsh
# Builds a Release Nocturne.app and signs it (and every embedded framework) with a Developer ID.
#
#   scripts/release.sh [--notarize] [--install]
#
#   --notarize  submits the app to Apple's notary service, staples the ticket, then builds,
#               signs, notarizes and staples build/Release/Nocturne-<version>.dmg for distribution.
#   --install   copies the (stapled) app to /Applications.
#   --resume    skips the build and continues a notarization that timed out (uses <out>/.notary-id).
#
# Environment:
#   NOCTURNE_SIGN_IDENTITY   identity name or SHA-1 (default: "Developer ID Application");
#                            "-" makes a local-only ad-hoc build (no hardened runtime, runs on this Mac only)
#   NOCTURNE_OUT / NOCTURNE_DERIVED     output and derived-data folders (default build/Release, build/DDR)
#   NOCTURNE_VERSION / NOCTURNE_BUILD   override marketing version / build number (e.g. for update tests)
#   NOCTURNE_NOTARY_PROFILE  notarytool keychain profile (default: nocturne-notary), created once with:
#                            xcrun notarytool store-credentials nocturne-notary --apple-id <you@example.com> --team-id 36XY8752RX
#   NOCTURNE_SIGN_KEYCHAIN   keychain holding it (default: search list), e.g. ~/Library/Keychains/old-mac-login.keychain-db
set -euo pipefail
cd "$(dirname $0)/.."
identity=${NOCTURNE_SIGN_IDENTITY:-"Developer ID Application"}
profile=${NOCTURNE_NOTARY_PROFILE:-nocturne-notary}
notarize=false; install=false; resume=false
for arg in "$@"; do
  case $arg in
    --notarize) notarize=true ;;
    --install) install=true ;;
    --resume) resume=true; notarize=true ;;
    *) print -u2 "unknown option $arg"; exit 2 ;;
  esac
done
if $notarize && [[ $identity == "-" ]]; then print -u2 "Notarization needs a Developer ID identity."; exit 2; fi
out=${NOCTURNE_OUT:-build/Release}
derived=${NOCTURNE_DERIVED:-build/DDR}
keychain=(); [[ -n ${NOCTURNE_SIGN_KEYCHAIN:-} ]] && keychain=(--keychain "$NOCTURNE_SIGN_KEYCHAIN")

app="$out/Nocturne.app"

# Designed installer window (layout in scripts/dmg-settings.py, artwork in scripts/make-dmg-background.swift).
make_dmg() {
  local version=$1 dest=$2
  local art="$out/dmg-art"
  [[ -x build/.venv/bin/dmgbuild ]] || { python3 -m venv build/.venv && build/.venv/bin/pip install -q dmgbuild; }
  swift scripts/make-dmg-background.swift "$version" "$art" >/dev/null
  rm -f "$dest"
  build/.venv/bin/dmgbuild -s scripts/dmg-settings.py -D app="$app" -D background="$art/background.png" \
    "Nocturne $version" "$dest" 2>&1 | grep -v deprecated || true
  [[ -f $dest ]] || { print -u2 "dmgbuild failed"; exit 1; }
}

# Sparkle's nested helpers must be signed inside-out before the framework itself.
sign_sparkle() {
  local sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  [[ -d $sp ]] || return 0
  codesign --force "$@" "$sp/XPCServices/Installer.xpc"
  codesign --force "$@" --preserve-metadata=entitlements "$sp/XPCServices/Downloader.xpc"
  codesign --force "$@" "$sp/Autoupdate"
  codesign --force "$@" "$sp/Updater.app"
}

if ! $resume; then
  xcodegen generate >/dev/null
  xcodebuild -project Nocturne.xcodeproj -scheme Nocturne -configuration Release -derivedDataPath "$derived" \
    -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- \
    ${NOCTURNE_VERSION:+MARKETING_VERSION=$NOCTURNE_VERSION} ${NOCTURNE_BUILD:+CURRENT_PROJECT_VERSION=$NOCTURNE_BUILD} build > "$out".log 2>&1 \
    || { grep -E "error:" "$out".log; exit 1; }

  app="$out/Nocturne.app"
  rm -rf "$out" && mkdir -p "$out" && ditto "$derived"/Build/Products/Release/Nocturne.app "$app"

  # Inside-out: frameworks first, then the app.
  if [[ $identity == "-" ]]; then
    # Ad-hoc code has no Team ID, so hardened-runtime library validation would reject the
    # embedded frameworks. Local-only builds therefore skip the hardened runtime.
    sign_sparkle --sign -
    for fw in "$app"/Contents/Frameworks/*.framework; do codesign --force --sign - "$fw"; done
    codesign --force --sign - --entitlements App/Nocturne.entitlements "$app"
  else
    sign_sparkle --timestamp --options runtime "${keychain[@]}" --sign "$identity"
    for fw in "$app"/Contents/Frameworks/*.framework; do
      codesign --force --timestamp --options runtime "${keychain[@]}" --sign "$identity" "$fw"
    done
    codesign --force --timestamp --options runtime "${keychain[@]}" --sign "$identity" \
      --entitlements App/Nocturne.entitlements "$app"
  fi

  codesign --verify --deep --strict --verbose=2 "$app"
  codesign -dv "$app" 2>&1 | grep -E "Signature|Authority=Developer ID Application|TeamIdentifier"
fi

if $notarize; then
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
  print "Notarizing Nocturne.app $version (this usually takes a few minutes)…"
  # Submit (or resume) and wait; Apple occasionally takes longer than an hour.
  if $resume && [[ -f "$out/.notary-id" ]]; then
    id=$(<"$out/.notary-id")
  else
    ditto -c -k --keepParent "$app" "$out/Nocturne-notarize.zip"
    id=$(xcrun notarytool submit "$out/Nocturne-notarize.zip" --keychain-profile "$profile" --output-format json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    print "$id" > "$out/.notary-id"
    rm -f "$out/Nocturne-notarize.zip"
  fi
  print "Submission $id"
  xcrun notarytool wait "$id" --keychain-profile "$profile" --timeout 2h
  verdict=$(xcrun notarytool info "$id" --keychain-profile "$profile" --output-format json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
  if [[ $verdict != Accepted ]]; then
    print -u2 "Notarization status: $verdict"
    xcrun notarytool log "$id" --keychain-profile "$profile" || true
    print -u2 "Re-run with --resume once it finishes."
    exit 1
  fi
  rm -f "$out/.notary-id"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"

  dmg=$out/Nocturne-$version.dmg
  make_dmg "$version" "$dmg"
  codesign --force --timestamp "${keychain[@]}" --sign "$identity" "$dmg"
  print "Notarizing $dmg…"
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --timeout 2h
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type execute -vv "$app"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
  print "Distributable: $dmg"
fi

if $install; then
  pkill -x Nocturne 2>/dev/null || true
  rm -rf /Applications/Nocturne.app
  ditto "$app" /Applications/Nocturne.app
  echo "Installed /Applications/Nocturne.app"
fi
