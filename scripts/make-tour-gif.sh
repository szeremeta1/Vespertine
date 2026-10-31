#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders the README tour (scripts/make-tour.swift) to docs/screenshots/tour.gif: 800×500 at 6 fps, one 160-colour palette
# for the whole tour with error-diffusion dither, and only the changed rectangle stored per frame. gifsicle (Homebrew)
# then merges repeated frames and runs a light --lossy=25 so the GIF stays under 5 MB (about 4 MB); every pan moves all
# the pixels, so frames, colours and --lossy are what bound the size (lossless it was 7 MB even at 6 fps; --lossy=60 streaks
# the end card's glow sideways).
set -euo pipefail
root=${0:A:h:h}
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
swift "$root/scripts/make-tour.swift" 800 500 6 | ffmpeg -loglevel error -f rawvideo -pix_fmt bgra -s 800x500 -r 6 -i - "$frames/f%04d.png"
ffmpeg -loglevel error -y -framerate 6 -i "$frames/f%04d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$frames/tour.gif"
gifsicle -O3 --lossy=25 "$frames/tour.gif" -o "$root/docs/screenshots/tour.gif"
print "docs/screenshots/tour.gif: $(du -h "$root/docs/screenshots/tour.gif" | cut -f1)"
