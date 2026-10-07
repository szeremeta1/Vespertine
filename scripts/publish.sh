#!/bin/zsh
# Publishes a notarized build (from scripts/release.sh --notarize) as a GitHub release
# with a Sparkle appcast, so installed copies update themselves.
#
#   scripts/publish.sh <release-notes.md>
#
# The appcast lives on every release as `appcast.xml`; the app's SUFeedURL points at
# .../releases/latest/download/appcast.xml, so the newest release always serves the feed. Any other release must be
# created with --latest=false: a Latest release without appcast.xml breaks every installed copy's update check.
# Each entry is EdDSA-signed with the Sparkle key stored in the login keychain under the account `nocturne` (kept from before the rename so the EdDSA key never changes).
set -euo pipefail
cd "$(dirname $0)/.."

repo=szeremeta1/Vespertine
out=${VESPERTINE_OUT:-build/Release}
notes=${1:?usage: scripts/publish.sh <release-notes.md>}
app="$out/Vespertine.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$out/Vespertine-$version.dmg"
# The Sparkle tools from the release's own build, not whichever derived-data folder find lists first.
tools=${VESPERTINE_DERIVED:-build/DDR}/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x $tools/generate_appcast ]] || { print -u2 "No Sparkle tools in $tools; run scripts/release.sh --notarize first."; exit 1; }

[[ -f $dmg ]] || { print -u2 "Missing $dmg; run scripts/release.sh --notarize first."; exit 1; }
xcrun stapler validate "$dmg" >/dev/null || { print -u2 "$dmg is not notarized and stapled."; exit 1; }
# The tag goes on the commit this DMG's app was built from, which release.sh records with the DMG's hash when it
# finishes the DMG: not whatever HEAD is now, nor whatever a later test build recorded.
provenance=( $(cat "$dmg.built-from" 2>/dev/null || true) )
built=${provenance[1]:-} dmg_sha=${provenance[2]:-}
[[ -n $built && -n $dmg_sha ]] || { print -u2 "$dmg.built-from is missing: build the release with scripts/release.sh --notarize first."; exit 1; }
[[ "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" == "$dmg_sha" ]] \
  || { print -u2 "$dmg isn't the DMG release.sh made from $built; build the release again."; exit 1; }

feed="$out/appcast"
rm -rf "$feed" && mkdir -p "$feed"
cp "$dmg" "$feed/"
# Carry forward the existing feed so older versions stay listed. Its channel title is carried over from the feed's
# Nocturne days; it's fixed here, before generate_appcast, because nothing may edit the appcast after it's written:
# with a signed feed (SURequireSignedFeed) any later edit breaks the signature and every installed copy's updates.
gh release download --repo "$repo" --pattern appcast.xml --dir "$feed" 2>/dev/null || print "No existing appcast; starting a new one."
[[ ! -f "$feed/appcast.xml" ]] || /usr/bin/sed -i '' 's|<title>Nocturne</title>|<title>Vespertine</title>|' "$feed/appcast.xml"

# Sparkle shows HTML release notes placed beside the archive.
/usr/bin/python3 - "$notes" "$feed/Vespertine-$version.html" <<'PY'
import html, re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
out, depth, in_code = [], 0, False   # depth = open <ul> levels (bullets indented by 2 spaces nest)
def inline(t):
    t = html.escape(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", t)
    t = re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    return re.sub(r"\[(.+?)\]\((.+?)\)", r'<a href="\2">\1</a>', t)
def close_to(level):
    global depth
    while depth > level: out.append("</ul>"); depth -= 1
for line in lines:
    if line.startswith("```"):
        in_code = not in_code
        out.append("<pre>" if in_code else "</pre>")
        continue
    if in_code:
        out.append(html.escape(line)); continue
    m = re.match(r"^( *)- (.*)$", line)
    if m:
        level = len(m.group(1)) // 2 + 1
        close_to(level)
        while depth < level: out.append("<ul>"); depth += 1
        out.append(f"<li>{inline(m.group(2))}</li>"); continue
    close_to(0)
    if line.startswith("### "): out.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.strip(): out.append(f"<p>{inline(line)}</p>")
close_to(0)
open(sys.argv[2], "w", encoding="utf-8").write(
    "<!doctype html><meta charset=utf-8><style>body{font:13px -apple-system;}code{font:12px ui-monospace}</style>\n"
    + "\n".join(out))
PY

# Copies installed before the rename (Nocturne, bundle ID org.nocturne.Nocturne, builds up to 26) can't
# install Vespertine: Sparkle only replaces an app with one of the same bundle ID. For them every new entry is
# informational: they're told about it and offered the download page instead of a failing install.
first_vespertine_build=27
# The keychain lets only generate_keys read the Sparkle key without asking (it made or imported it), so a Mac with
# nobody at the screen, like the hub, would hang at generate_appcast's prompt. Hand the tools a private copy instead,
# removed on exit.
keydir=$(mktemp -d)
trap 'rm -P "$keydir"/key 2>/dev/null; rmdir "$keydir"' EXIT
"$tools/generate_keys" --account nocturne -x "$keydir/key" >/dev/null
sparkle_key=(--ed-key-file "$keydir/key")

"$tools/generate_appcast" "${sparkle_key[@]}" \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --link "https://github.com/$repo/releases/latest" --embed-release-notes --maximum-deltas 0 \
  --informational-update-versions "<$first_vespertine_build" \
  -o "$feed/appcast.xml" "$feed"
# generate_appcast only warns (and exits 0) when it can't sign, and the entries carried over from older
# releases are always signed, so check this release's own entry, and that the keychain key is the one
# installed copies trust. Either failure would publish an update every installed copy refuses.
trusted_key=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$app/Contents/Info.plist")
[[ "$("$tools/generate_keys" --account nocturne -p)" == "$trusted_key" ]] \
  || { print -u2 "The Sparkle key in the keychain doesn't match SUPublicEDKey; installed copies would reject this update."; exit 1; }
/usr/bin/python3 - "$feed/appcast.xml" "Vespertine-$version.dmg" <<'PY' || { print -u2 "The appcast entry for $version is not EdDSA-signed."; exit 1; }
import sys, xml.etree.ElementTree as ET
signature = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
signed = any(e.get("url", "").endswith("/" + sys.argv[2]) and e.get(signature)
             for e in ET.parse(sys.argv[1]).iter("enclosure"))
sys.exit(0 if signed else 1)
PY
# A build that requires a signed feed refuses every later update if this feed's signature is missing or broken.
if [[ "$(/usr/libexec/PlistBuddy -c 'Print SURequireSignedFeed' "$app/Contents/Info.plist" 2>/dev/null)" == true ]]; then
  "$tools/sign_update" "${sparkle_key[@]}" --verify "$feed/appcast.xml" \
    || { print -u2 "appcast.xml is not validly signed; copies of $version would refuse every future update."; exit 1; }
fi

# The FFmpeg decoders are LGPL: the exact source they were built from goes up with every release, checked against
# the hash build-dts-decoder.sh builds from, so it stays available as long as the release does.
ffmpeg_version=$(sed -n 's/^version=//p' scripts/build-dts-decoder.sh)
ffmpeg_sha=$(sed -n 's/^sha256=//p' scripts/build-dts-decoder.sh)
ffmpeg_source="$out/ffmpeg-$ffmpeg_version.tar.xz"
[[ -f $ffmpeg_source ]] || curl -sSfL "https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz" -o "$ffmpeg_source"
print "$ffmpeg_sha  $ffmpeg_source" | shasum -a 256 -c - >/dev/null \
  || { print -u2 "$ffmpeg_source doesn't match the SHA-256 in scripts/build-dts-decoder.sh."; exit 1; }

if ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  git tag -s "v$version" -m "Vespertine $version" "$built"
fi
[[ "$(git rev-parse "v$version^{commit}")" == "$built" ]] \
  || { print -u2 "Tag v$version doesn't point at the commit this app was built from ($built)."; exit 1; }
git push -q origin "v$version"
gh release create "v$version" "$dmg" "$feed/appcast.xml" "$ffmpeg_source" --repo "$repo" --verify-tag --latest \
  --title "Vespertine $version" --notes-file "$notes"

# Homebrew: point the cask in szeremeta1/homebrew-tap at this release (a commit through GitHub's API).
tap=szeremeta1/homebrew-tap cask=Casks/vespertine.rb
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
if current=$(gh api "repos/$tap/contents/$cask" 2>/dev/null); then
  blob=$(print -r -- "$current" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
  body=$(print -r -- "$current" | /usr/bin/python3 -c 'import json,sys,base64; print(base64.b64decode(json.load(sys.stdin)["content"]).decode(), end="")' \
    | /usr/bin/sed -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$sha\"/")
  gh api -X PUT "repos/$tap/contents/$cask" -f message="vespertine $version" -f sha="$blob" \
    -f content="$(print -r -- "$body" | base64)" >/dev/null && print "Homebrew cask updated to $version."
else
  print -u2 "Homebrew cask not found in $tap; update it by hand."
fi
