#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders the README tour (scripts/make-tour.swift) to docs/screenshots/tour.gif: 800×500 at 10 fps, one palette
# for the whole tour with error-diffusion dither, and only the changed rectangle stored per frame. The end card's
# glow stays smooth and nothing from an earlier frame lingers. gifsicle (Homebrew) then merges repeated frames, losslessly:
# --lossy (even at 8) streaks the end card's glow sideways, so the GIF stays ~17 MB rather than ~12 MB.
set -euo pipefail
root=${0:A:h:h}
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
swift "$root/scripts/make-tour.swift" 800 500 10 | ffmpeg -loglevel error -f rawvideo -pix_fmt bgra -s 800x500 -r 10 -i - "$frames/f%04d.png"
ffmpeg -loglevel error -y -framerate 10 -i "$frames/f%04d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$frames/tour.gif"
gifsicle -O3 "$frames/tour.gif" -o "$root/docs/screenshots/tour.gif"
print "docs/screenshots/tour.gif: $(du -h "$root/docs/screenshots/tour.gif" | cut -f1)"
