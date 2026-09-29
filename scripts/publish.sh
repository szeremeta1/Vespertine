#!/bin/zsh
# Publishes a notarized build (from scripts/release.sh --notarize) as a GitHub release
# with a Sparkle appcast, so installed copies update themselves.
#
#   scripts/publish.sh <release-notes.md>
#
# The appcast lives on every release as `appcast.xml`; the app's SUFeedURL points at
# .../releases/latest/download/appcast.xml, so the newest release always serves the feed.
# Each entry is EdDSA-signed with the Sparkle key stored in the login keychain under the account `nocturne` (kept from before the rename so the EdDSA key never changes).
set -euo pipefail
cd "$(dirname $0)/.."

repo=szeremeta1/Vespertine
out=${VESPERTINE_OUT:-build/Release}
notes=${1:?usage: scripts/publish.sh <release-notes.md>}
app="$out/Vespertine.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$out/Vespertine-$version.dmg"
tools=$(dirname "$(find build -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' | head -1)")

[[ -f $dmg ]] || { print -u2 "Missing $dmg; run scripts/release.sh --notarize first."; exit 1; }
xcrun stapler validate "$dmg" >/dev/null || { print -u2 "$dmg is not notarized and stapled."; exit 1; }

feed="$out/appcast"
rm -rf "$feed" && mkdir -p "$feed"
cp "$dmg" "$feed/"
# Carry forward the existing feed so older versions stay listed.
gh release download --repo "$repo" --pattern appcast.xml --dir "$feed" 2>/dev/null || print "No existing appcast; starting a new one."

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
"$tools/generate_appcast" --account nocturne \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --link "https://github.com/$repo/releases/latest" --embed-release-notes --maximum-deltas 0 \
  --informational-update-versions "<$first_vespertine_build" \
  -o "$feed/appcast.xml" "$feed"
# The channel title was carried over from the feed's Nocturne days.
/usr/bin/sed -i '' 's|<title>Nocturne</title>|<title>Vespertine</title>|' "$feed/appcast.xml"
grep -q "sparkle:edSignature" "$feed/appcast.xml" || { print -u2 "appcast entry is not EdDSA-signed"; exit 1; }

if ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  git tag -s "v$version" -m "Vespertine $version"
fi
git push -q origin "v$version"
gh release create "v$version" "$dmg" "$feed/appcast.xml" --repo "$repo" --verify-tag --latest \
  --title "Vespertine $version" --notes-file "$notes"
