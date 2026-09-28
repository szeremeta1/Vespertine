#!/bin/zsh
# Publishes a notarized build (from scripts/release.sh --notarize) as a GitHub release
# with a Sparkle appcast, so installed copies update themselves.
#
#   scripts/publish.sh <release-notes.md>
#
# The appcast lives on every release as `appcast.xml`; the app's SUFeedURL points at
# .../releases/latest/download/appcast.xml, so the newest release always serves the feed.
# Each entry is EdDSA-signed with the `nocturne` key in the login keychain (generate_keys --account nocturne).
set -euo pipefail
cd "$(dirname $0)/.."

repo=szeremeta1/Nocturne
out=${NOCTURNE_OUT:-build/Release}
notes=${1:?usage: scripts/publish.sh <release-notes.md>}
app="$out/Nocturne.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$out/Nocturne-$version.dmg"
tools=$(dirname "$(find build -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' | head -1)")

[[ -f $dmg ]] || { print -u2 "Missing $dmg; run scripts/release.sh --notarize first."; exit 1; }
xcrun stapler validate "$dmg" >/dev/null || { print -u2 "$dmg is not notarized and stapled."; exit 1; }

feed="$out/appcast"
rm -rf "$feed" && mkdir -p "$feed"
cp "$dmg" "$feed/"
# Carry forward the existing feed so older versions stay listed.
gh release download --repo "$repo" --pattern appcast.xml --dir "$feed" 2>/dev/null || print "No existing appcast; starting a new one."

# Sparkle shows HTML release notes placed beside the archive.
/usr/bin/python3 - "$notes" "$feed/Nocturne-$version.html" <<'PY'
import html, re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
out, in_list, in_code = [], False, False
def inline(t):
    t = html.escape(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    return re.sub(r"\[(.+?)\]\((.+?)\)", r'<a href="\2">\1</a>', t)
for line in lines:
    if line.startswith("```"):
        in_code = not in_code
        out.append("<pre>" if in_code else "</pre>")
        continue
    if in_code:
        out.append(html.escape(line)); continue
    if line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append(f"<li>{inline(line[2:])}</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if line.startswith("### "): out.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.strip(): out.append(f"<p>{inline(line)}</p>")
if in_list: out.append("</ul>")
open(sys.argv[2], "w", encoding="utf-8").write(
    "<!doctype html><meta charset=utf-8><style>body{font:13px -apple-system;}code{font:12px ui-monospace}</style>\n"
    + "\n".join(out))
PY

"$tools/generate_appcast" --account nocturne \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --link "https://github.com/$repo" --embed-release-notes --maximum-deltas 0 \
  -o "$feed/appcast.xml" "$feed"
grep -q "sparkle:edSignature" "$feed/appcast.xml" || { print -u2 "appcast entry is not EdDSA-signed"; exit 1; }

if ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  git tag -s "v$version" -m "Nocturne $version"
fi
git push -q origin "v$version"
gh release create "v$version" "$dmg" "$feed/appcast.xml" --repo "$repo" --verify-tag --latest \
  --title "Nocturne $version" --notes-file "$notes"
