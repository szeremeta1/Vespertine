#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders the launch trailer in every aspect and makes the masters:
#   1. trailer-stage renders each aspect at 60 fps (real Liquid Glass, streamed from a window that stays
#      behind your other windows, so the Mac stays usable while it runs);
#   2. the master smooths the capture's 8-bit gradient steps, adds the music bed at −14 LUFS and is
#      encoded on the hardware ProRes engine.
# Usage: render.sh [--masters-only] [aspect…]   (default: wide square vertical). The screen must be unlocked.
#   --masters-only remakes the masters from existing renders.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h:h}
out=~/Movies/Vespertine/Trailer
raw=${VESPERTINE_TRAILER_RAW:-$out/raw}
music="$out/Starlight Lounge (bed).wav"
render=1
if [[ ${1:-} == --masters-only ]]; then render=0; shift; fi
if (( $# )); then aspects=($@); else aspects=(wide square vertical); fi
mkdir -p "$out/renders" "$out/masters" "$out/picture"

(( render )) && (cd "$here" && swift build -c release >/dev/null)

# The bed at −14 LUFS integrated (it measures −12.1; true peak stays under −3 dBTP).
bed="$out/renders/music-14LUFS.wav"
if [[ ! -e $bed ]]; then
  ffmpeg -loglevel error -y -i "$music" -af "volume=-1.9dB" -c:a pcm_s24le "$bed"
fi

# The capture is 8-bit, so the dark brass glows step in single levels and show as rings. Two passes of
# deband smooth steps of a level or two into the 10-bit master; the interface's hairlines (3+ levels)
# and text are untouched (PSNR ≥ 58 dB on interface frames).
deband="deband=1thr=0.008:2thr=0.008:3thr=0.008:4thr=0.008:range=48:blur=1,deband=1thr=0.006:2thr=0.006:3thr=0.006:4thr=0.006:range=24:blur=1"

for aspect in $aspects; do
  print "== $aspect"
  if (( render )); then
    "$here/.build/release/trailer-stage" --repo "$repo" --raw "$raw" --aspect $aspect --fps 60 --behind --out "$out/renders/$aspect.mov"
  fi
  # Written beside and moved into place, so apps that have the old file open (Final Cut Pro) never see half a file.
  master="$out/masters/Vespertine trailer $aspect.mov" picture="$out/picture/Vespertine trailer $aspect (picture).mov"
  ffmpeg -loglevel error -y -i "$out/renders/$aspect.mov" -i "$bed" \
    -filter_complex "[0:v]${deband},format=p210le[v]" \
    -map "[v]" -map 1:a -c:v prores_videotoolbox -profile:v hq \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_s24le -shortest \
    "${master:r}.partial.mov"
  mv "${master:r}.partial.mov" "$master"
  # Picture only, for editing in Final Cut Pro against the music on its own lane.
  ffmpeg -loglevel error -y -i "$master" -map 0:v -c copy "${picture:r}.partial.mov"
  mv "${picture:r}.partial.mov" "$picture"
  print "master: $master"
done
