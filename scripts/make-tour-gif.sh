#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders the README tour (scripts/make-tour.swift) to docs/screenshots/tour.gif, kept under 3 MB so it starts
# playing quickly on GitHub. The slow zooms change every pixel of every frame, which no GIF encoder keeps small, so
# this keeps the tour's own frames but not its motion: each shot's fully zoomed, captioned frame is held for 2.6 s and
# crossfades to the next in three frames, ending on the title card. 800×500 at 10 fps, one palette for the whole tour
# with error-diffusion dither, and only the changed rectangle stored per frame; gifsicle (Homebrew) then merges the
# repeated frames and trims the LZW stream (--lossy=60). The full motion version is make-tour.swift's video output.
set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/render" "$work/seq"
swift "$root/scripts/make-tour.swift" 800 500 10 | ffmpeg -loglevel error -f rawvideo -pix_fmt bgra -s 800x500 -r 10 -i - "$work/render/f%04d.png"

# make-tour.swift: shot i starts at i × 3.7 s (hold 4.2 s, fade 0.5 s), its zoom ends by 2.0 s and its caption shows
# from 0.7 s to 3.65 s; the title card fades in after the last shot. Frame n (from 1) is at (n - 1) / 10 s.
shots=$(grep -c '^    Shot(file:' "$root/scripts/make-tour.swift")
stills=()
for (( i = 0; i < shots; i++ )); do stills+=("$work/render/f$(printf %04d $(( i * 37 + 26 + 1 ))).png"); done
stills+=("$work/render/f$(printf %04d $(( shots * 37 + 10 + 1 ))).png")
fades=3 n=0
for (( s = 1; s <= ${#stills}; s++ )); do
  hold=$(( s == ${#stills} ? 30 : 26 ))
  for (( h = 0; h < hold; h++ )); do (( ++n )); cp "$stills[s]" "$work/seq/s$(printf %04d $n).png"; done
  (( s < ${#stills} )) || break
  for (( f = 1; f <= fades; f++ )); do
    (( ++n ))
    ffmpeg -loglevel error -y -i "$stills[s+1]" -i "$stills[s]" \
      -filter_complex "blend=all_mode=normal:all_opacity=$(( f / (fades + 1.0) ))" "$work/seq/s$(printf %04d $n).png"
  done
done

ffmpeg -loglevel error -y -framerate 10 -i "$work/seq/s%04d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$work/tour.gif"
gifsicle -O3 --lossy=60 "$work/tour.gif" -o "$root/docs/screenshots/tour.gif"
print "docs/screenshots/tour.gif: $(( $(stat -f %z "$root/docs/screenshots/tour.gif") / 1000 )) kB"
