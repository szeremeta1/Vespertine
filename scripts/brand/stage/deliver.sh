#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Encodes the trailer's deliverables from the ProRes masters (made by render.sh) into ~/Movies/Vespertine/Trailer/deliver:
#   16x9 4K     YouTube (3840×2160; YouTube gives 4K uploads a higher bitrate at every size)
#   16x9        X, the press kit, the release (1920×1080)
#   16x9 web    the website (1280×720, small enough to stream on a phone)
#   1x1         X, Bluesky, Mastodon (1080×1080)
#   9x16        Shorts, Reels, TikTok (1080×1920)
# All 60 fps H.264 High with AAC; the music is already at −14 LUFS in the masters. The 10-bit masters are dithered
# down to 8 bits and x264's dark-biased adaptive quantization keeps the glows from banding again.
set -euo pipefail
src=~/Movies/Vespertine/Trailer/masters
out=~/Movies/Vespertine/Trailer/deliver
mkdir -p "$out"

encode() {  # master, output name, width, height, crf, maxrate, audio bitrate
  local master="$src/Vespertine trailer $1.mov" file="$out/Vespertine trailer $2.mp4"
  ffmpeg -loglevel error -y -i "$master" \
    -vf "scale=${3}:${4}:flags=lanczos:in_range=tv:out_range=tv:sws_dither=ed,format=yuv420p" \
    -c:v libx264 -preset slow -profile:v high -crf ${5} -maxrate ${6} -bufsize $(( ${6%M} * 2 ))M -r 60 -g 60 \
    -x264-params aq-mode=3 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a ${7} -ar 48000 -movflags +faststart "${file:r}.partial.mp4"
  mv "${file:r}.partial.mp4" "$file"
  print "$file: $(du -h "$file" | cut -f1)"
}

encode wide "16x9 4K" 3840 2160 14 60M 320k
encode wide "16x9" 1920 1080 17 16M 256k
encode wide "16x9 web" 1280 720 23 4M 160k
encode square "1x1" 1080 1080 17 14M 256k
encode vertical "9x16" 1080 1920 17 16M 256k

# The website's poster: the end card, where the wordmark sits alone.
ffmpeg -loglevel error -y -ss 31.5 -i "$src/Vespertine trailer wide.mov" -frames:v 1 -vf "scale=1920:1080:flags=lanczos" "$out/Vespertine trailer poster.png"
print "$out/Vespertine trailer poster.png"
