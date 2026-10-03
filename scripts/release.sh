#!/bin/zsh
# Builds a Release Vespertine.app and signs it (and every embedded framework) with a Developer ID.
#
#   scripts/release.sh [--notarize] [--install]
#
#   --notarize  submits the app to Apple's notary service, staples the ticket, then builds,
#               signs, notarizes and staples build/Release/Vespertine-<version>.dmg for distribution.
#   --install   copies the (stapled) app to /Applications.
#   --resume    skips the build and continues a notarization that timed out (uses <out>/.notary-id).
#
# Environment:
#   VESPERTINE_SIGN_IDENTITY   identity name or SHA-1 (default: "Developer ID Application"; name the exact one when the
#                            keychain holds more than one Developer ID);
#                            "-" makes a local-only ad-hoc build (no hardened runtime, runs on this Mac only)
#   VESPERTINE_OUT / VESPERTINE_DERIVED     output and derived-data folders (default build/Release, build/DDR)
#   VESPERTINE_VERSION / VESPERTINE_BUILD   override marketing version / build number (e.g. for update tests)
#   VESPERTINE_NOTARY_PROFILE  notarytool keychain profile (default: vespertine-notary), created once with:
#                            xcrun notarytool store-credentials vespertine-notary --apple-id <you@example.com> --team-id <your Developer ID team ID>
#   VESPERTINE_SIGN_KEYCHAIN   keychain holding it (default: search list), e.g. ~/Library/Keychains/old-mac-login.keychain-db
set -euo pipefail
cd "$(dirname $0)/.."
identity=${VESPERTINE_SIGN_IDENTITY:-"Developer ID Application"}
profile=${VESPERTINE_NOTARY_PROFILE:-vespertine-notary}
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
out=${VESPERTINE_OUT:-build/Release}
derived=${VESPERTINE_DERIVED:-build/DDR}
# Refuse destructive output roots before building or removing anything.
resolved_out=${out:A}
resolved_project=${PWD:A}
if [[ $resolved_out == / || $resolved_out == $HOME || $resolved_out == $resolved_project || $resolved_out == /Applications ]]; then
  print -u2 "Refusing unsafe release output folder: $out"; exit 2
fi
if [[ $resolved_project == $resolved_out/* ]]; then
  print -u2 "Release output must not contain the project: $out"; exit 2
fi
mkdir -p "${out:h}"
keychain=(); [[ -n ${VESPERTINE_SIGN_KEYCHAIN:-} ]] && keychain=(--keychain "$VESPERTINE_SIGN_KEYCHAIN")

app="$out/Vespertine.app"

# Designed installer window (layout in scripts/dmg-settings.py, artwork in scripts/make-dmg-background.swift).
make_dmg() {
  local version=$1 dest=$2
  local art="$out/dmg-art"
  [[ -x build/.venv/bin/dmgbuild ]] || { python3 -m venv build/.venv && build/.venv/bin/pip install -q dmgbuild; }
  swift scripts/make-dmg-background.swift "$version" "$art" >/dev/null
  rm -f "$dest"
  if ! build/.venv/bin/dmgbuild -s scripts/dmg-settings.py -D app="$app" -D background="$art/background.png" \
      "Vespertine $version" "$dest" > "$out/dmgbuild.log" 2>&1; then
    cat "$out/dmgbuild.log" >&2
    print -u2 "dmgbuild failed"; exit 1
  fi
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

# A release is built from committed sources, and records which commit (publish.sh tags that one, not whatever HEAD is
# by then). Untracked files count too: XcodeGen builds every file in the source folders, committed or not.
# VESPERTINE_ALLOW_DIRTY=1 allows a test build from a tree with changes. The packages' own Package.resolved files don't
# count: SwiftPM rewrites them after builds and tests. The app's lockfile, App/Package.resolved, does: it decides what
# ships.
if ! $resume && $notarize && [[ -n "$(git status --porcelain --untracked-files=all -- . ':(exclude)Packages/*/Package.resolved')" && -z ${VESPERTINE_ALLOW_DIRTY:-} ]]; then
  print -u2 "The working tree has uncommitted or untracked files: commit or remove them first (or set VESPERTINE_ALLOW_DIRTY=1 for a test build)."
  git status --short --untracked-files=all -- . ':(exclude)Packages/*/Package.resolved' >&2
  exit 2
fi

if ! $resume; then
  scripts/generate-project.sh
  xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Release -derivedDataPath "$derived" \
    -onlyUsePackageVersionsFromResolvedFile -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- \
    ${VESPERTINE_VERSION:+MARKETING_VERSION=$VESPERTINE_VERSION} ${VESPERTINE_BUILD:+CURRENT_PROJECT_VERSION=$VESPERTINE_BUILD} build > "$out".log 2>&1 \
    || { grep -E "error:" "$out".log; exit 1; }

  app="$out/Vespertine.app"
  mkdir -p "$out"
  staged="$out/.Vespertine-build-$$.app"
  ditto "$derived"/Build/Products/Release/Vespertine.app "$staged"
  rm -rf "$app"
  mv "$staged" "$app"
  git rev-parse HEAD > "$out/built-from"

  # Inside-out: frameworks first, then the app.
  if [[ $identity == "-" ]]; then
    # Ad-hoc code has no Team ID, so hardened-runtime library validation would reject the
    # embedded frameworks. Local-only builds therefore skip the hardened runtime.
    sign_sparkle --sign -
    for fw in "$app"/Contents/Frameworks/*.framework; do codesign --force --sign - "$fw"; done
    codesign --force --sign - --entitlements App/Vespertine.entitlements "$app"
  else
    sign_sparkle --timestamp --options runtime "${keychain[@]}" --sign "$identity"
    for fw in "$app"/Contents/Frameworks/*.framework; do
      codesign --force --timestamp --options runtime "${keychain[@]}" --sign "$identity" "$fw"
    done
    codesign --force --timestamp --options runtime "${keychain[@]}" --sign "$identity" \
      --entitlements App/Vespertine.entitlements "$app"
  fi

  codesign --verify --deep --strict --verbose=2 "$app"
  codesign -dv "$app" 2>&1 | grep -E "Signature|Authority=Developer ID Application|TeamIdentifier"
fi

if $notarize; then
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
  print "Notarizing Vespertine.app $version (this usually takes a few minutes)…"
  # Submit (or resume) and wait; Apple occasionally takes longer than an hour.
  if $resume && [[ -f "$out/.notary-id" ]]; then
    id=$(<"$out/.notary-id")
  else
    ditto -c -k --keepParent "$app" "$out/Vespertine-notarize.zip"
    id=$(xcrun notarytool submit "$out/Vespertine-notarize.zip" --keychain-profile "$profile" --output-format json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    print "$id" > "$out/.notary-id"
    rm -f "$out/Vespertine-notarize.zip"
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

  dmg=$out/Vespertine-$version.dmg
  make_dmg "$version" "$dmg"
  codesign --force --timestamp "${keychain[@]}" --sign "$identity" "$dmg"
  print "Notarizing $dmg…"
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --timeout 2h
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type execute -vv "$app"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
  # What publish.sh tags and uploads: this DMG and the commit its app was built from. built-from alone follows the
  # last build, which a later test build moves on.
  print "$(<"$out/built-from") $(shasum -a 256 "$dmg" | cut -d' ' -f1)" > "$dmg.built-from"
  print "Distributable: $dmg"
fi

if $install; then
  # Quit a running copy the way its Quit command does, so it puts back the DAC's format, the volume keys and the
  # alert volume before it's replaced. Only a copy still running 15 s later is killed (it puts the volume keys and
  # alert volume back at its next launch). A development build (its own bundle ID) is left alone.
  running() { [[ $(osascript -e 'application id "org.szeremeta.Vespertine" is running' 2>/dev/null) == true ]] }
  if running; then
    print "Quitting Vespertine…"
    # Without waiting for a reply: an app that hangs would hold osascript for its two-minute timeout.
    osascript -e 'ignoring application responses' -e 'tell application id "org.szeremeta.Vespertine" to quit' \
      -e 'end ignoring' >/dev/null 2>&1 || true
    for _ in {1..30}; do running || break; sleep 0.5; done
    pkill -f '^/Applications/Vespertine\.app/Contents/MacOS/Vespertine( |$)' 2>/dev/null || true
  fi
  staged_install="/Applications/.Vespertine-install-$$.app"
  ditto "$app" "$staged_install"
  codesign --verify --deep --strict "$staged_install"
  prior_install="/Applications/.Vespertine-previous-$$.app"
  if [[ -e /Applications/Vespertine.app ]]; then mv /Applications/Vespertine.app "$prior_install"; fi
  if ! mv "$staged_install" /Applications/Vespertine.app; then
    [[ ! -e "$prior_install" ]] || mv "$prior_install" /Applications/Vespertine.app
    print -u2 "Installation failed; previous app restored."; exit 1
  fi
  rm -rf "$prior_install"
  echo "Installed /Applications/Vespertine.app"
fi
