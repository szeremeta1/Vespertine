#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders the launch trailer in every aspect and makes the masters:
#   1. trailer-stage renders each aspect at 120 fps (ProRes, real Liquid Glass, captured on screen);
#   2. every other frame makes the 60 fps master (averaging pairs double-exposes fast moves, so frames stay clean);
#   3. the music bed goes on at −14 LUFS.
# Usage: render.sh [--masters-only] [aspect…]   (default: wide square vertical). Keep the screen unlocked while it runs.
#   --masters-only remakes the masters from existing 120 fps renders.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h:h}
out=~/Movies/Vespertine/Trailer
raw=${VESPERTINE_TRAILER_RAW:-$out/raw}
music="$out/Starlight Lounge (bed).wav"
render=1
if [[ ${1:-} == --masters-only ]]; then render=0; shift; fi
aspects=(${@:-wide square vertical})
mkdir -p "$out/renders" "$out/masters" "$out/picture"

(( render )) && (cd "$here" && swift build -c release >/dev/null)

# The bed at −14 LUFS integrated (it measures −12.1; true peak stays under −3 dBTP).
bed="$out/renders/music-14LUFS.wav"
if [[ ! -e $bed ]]; then
  ffmpeg -loglevel error -y -i "$music" -af "volume=-1.9dB" -c:a pcm_s24le "$bed"
fi

for aspect in $aspects; do
  print "== $aspect"
  if (( render )); then
    "$here/.build/release/trailer-stage" --repo "$repo" --raw "$raw" --aspect $aspect --fps 120 --out "$out/renders/$aspect-120.mov"
  fi
  # Written beside and moved into place, so apps that have the old file open (Final Cut Pro) never see half a file.
  master="$out/masters/Vespertine trailer $aspect.mov" picture="$out/picture/Vespertine trailer $aspect (picture).mov"
  ffmpeg -loglevel error -y -i "$out/renders/$aspect-120.mov" -i "$bed" \
    -filter_complex "[0:v]select='not(mod(n\,2))',setpts=N/(60*TB)[v]" \
    -map "[v]" -map 1:a -r 60 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_s24le -shortest \
    "${master:r}.partial.mov"
  mv "${master:r}.partial.mov" "$master"
  # Picture only, for editing in Final Cut Pro against the music on its own lane.
  ffmpeg -loglevel error -y -i "$master" -map 0:v -c copy "${picture:r}.partial.mov"
  mv "${picture:r}.partial.mov" "$picture"
  print "master: $out/masters/Vespertine trailer $aspect.mov"
done
