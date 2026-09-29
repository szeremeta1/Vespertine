#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders docs/design/social-preview.html to site/assets/og.png (1280x640), the image GitHub,
# Open Graph and Twitter/X cards show. Re-run it whenever docs/screenshots change, then upload
# the result in the repo's Settings → General → Social preview.
set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# WebKit only reads files under the page's folder, so stage the page next to what it uses.
mkdir -p "$work/site/assets" "$work/docs/screenshots"
cp "$root/site/assets/icon-512.png" "$work/site/assets/"
cp "$root/docs/screenshots/bit-perfect-fiio-24-192.png" "$work/docs/screenshots/"
sed -e 's#\.\./\.\./site/assets/#site/assets/#g' -e 's#\.\./screenshots/#docs/screenshots/#g' \
  "$root/docs/design/social-preview.html" > "$work/index.html"

swift "$root/scripts/snapshot-html.swift" "$work/index.html" "$work/og.png" 1280 1 0 640 >/dev/null
# The snapshot comes out at the screen's scale; social cards want exactly 1280x640.
sips -z 640 1280 "$work/og.png" --out "$root/site/assets/og.png" >/dev/null
print "wrote site/assets/og.png ($(stat -f %z "$root/site/assets/og.png") bytes)"
