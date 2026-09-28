#!/bin/zsh
# Builds a Release Nocturne.app and signs it (and every embedded framework) with a Developer ID.
#
#   scripts/release.sh [--notarize] [--install]
#
#   --notarize  submits the app to Apple's notary service, staples the ticket, then builds,
#               signs, notarizes and staples build/Release/Nocturne-<version>.dmg for distribution.
#   --install   copies the (stapled) app to /Applications.
#   --resume    skips the build and continues a notarization that timed out (uses build/Release/.notary-id).
#
# Environment:
#   NOCTURNE_SIGN_IDENTITY   identity name or SHA-1 (default: "Developer ID Application");
#                            "-" makes a local-only ad-hoc build (no hardened runtime, runs on this Mac only)
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
keychain=(); [[ -n ${NOCTURNE_SIGN_KEYCHAIN:-} ]] && keychain=(--keychain "$NOCTURNE_SIGN_KEYCHAIN")

app=build/Release/Nocturne.app
if ! $resume; then
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
fi

if $notarize; then
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
  print "Notarizing Nocturne.app $version (this usually takes a few minutes)…"
  # Submit (or resume) and wait; Apple occasionally takes longer than an hour.
  if $resume && [[ -f build/Release/.notary-id ]]; then
    id=$(<build/Release/.notary-id)
  else
    ditto -c -k --keepParent "$app" build/Release/Nocturne-notarize.zip
    id=$(xcrun notarytool submit build/Release/Nocturne-notarize.zip --keychain-profile "$profile" --output-format json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    print "$id" > build/Release/.notary-id
    rm -f build/Release/Nocturne-notarize.zip
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
  rm -f build/Release/.notary-id
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"

  dmg=build/Release/Nocturne-$version.dmg
  staging=$(mktemp -d)
  ditto "$app" "$staging/Nocturne.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  hdiutil create -volname "Nocturne $version" -srcfolder "$staging" -fs APFS -format UDZO -quiet "$dmg"
  rm -rf "$staging"
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
