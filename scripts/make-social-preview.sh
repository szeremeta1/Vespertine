#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders docs/design/social-preview.html twice:
#   site/assets/og.png       1280x640 (2:1), for the repo's Settings → General → Social preview;
#   site/assets/og-wide.png  1200x630 (1.91:1), the website's Open Graph / Twitter image, the shape
#                            Facebook, LinkedIn, iMessage, Reddit and X crop to.
# Re-run it whenever docs/screenshots change, and re-upload og.png on GitHub.
set -euo pipefail
root=${0:A:h:h}
# Native renderer is useful on a headless hub where WebKit cannot start its helper service.
if [[ ${VESPERTINE_SOCIAL_RENDERER:-webkit} == native ]]; then
  out="$root/build/social-preview"
  mkdir -p "$out/module-cache"
  swiftc -module-cache-path "$out/module-cache" -O "$root/scripts/brand/BrandKit.swift" \
    "$root/scripts/brand/social/main.swift" -o "$out/render"
  "$out/render"
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# WebKit only reads files under the page's folder, so stage the page next to what it uses.
mkdir -p "$work/site/assets/fonts" "$work/docs/screenshots" "$work/docs/brand"
cp "$root/docs/brand/logo.svg" "$work/docs/brand/"
cp "$root"/site/assets/fonts/*.woff2 "$work/site/assets/fonts/"
cp "$root/docs/screenshots/bit-perfect-fiio-24-192.png" "$work/docs/screenshots/"
sed -e 's#\.\./\.\./site/assets/#site/assets/#g' -e 's#\.\./screenshots/#docs/screenshots/#g' -e 's#\.\./brand/#docs/brand/#g' \
  "$root/docs/design/social-preview.html" > "$work/index.html"

swift "$root/scripts/snapshot-html.swift" "$work/index.html" "$work/og.png" 1280 1 0 640 >/dev/null
# The 1.91:1 card is the same design scaled to 1200 wide, with the card 32 px taller (before scaling)
# so its background fills the canvas, and the content moved down by half of that.
sed -e 's#</style>#  html, body { width: 1200px; height: 630px; } .card { height: 672px; transform: scale(0.9375); transform-origin: 0 0; } .copy { top: 122px; } .window { top: 62px; } .panel { top: 96px; } .foot { bottom: 58px; }\n</style>#' \
  "$work/index.html" > "$work/wide.html"
swift "$root/scripts/snapshot-html.swift" "$work/wide.html" "$work/og-wide.png" 1200 1 0 630 >/dev/null
# Snapshots come out at the screen's scale; social cards want these exact sizes.
sips -z 640 1280 "$work/og.png" --out "$root/site/assets/og.png" >/dev/null
sips -z 630 1200 "$work/og-wide.png" --out "$root/site/assets/og-wide.png" >/dev/null
for f in og.png og-wide.png; do print "wrote site/assets/$f ($(stat -f %z "$root/site/assets/$f") bytes)"; done
