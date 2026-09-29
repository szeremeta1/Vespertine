#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Re-renders part of the trailer and splices it into existing 120 fps renders, then remakes their masters.
# Motion is a pure function of time, so a range rendered on its own matches the full render frame for frame.
# ProRes is intra-only, so the splice is a stream copy: nothing outside the range is re-encoded.
# Usage: patch.sh <from s> <to s> [aspect…]   (default: wide square vertical). Keep the screen unlocked.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h:h}
out=~/Movies/Vespertine/Trailer
raw=${VESPERTINE_TRAILER_RAW:-$out/raw}
from=$1 to=$2; shift 2
aspects=(${@:-wide square vertical})
fps=120
# Frame numbers as trailer-stage computes them; kept even so the 60 fps masters keep the same frames.
first=$(printf '%.0f' $(( from * fps ))) last=$(printf '%.0f' $(( to * fps )))
(( first % 2 == 0 && last % 2 == 0 )) || { print "range must start and end on even 120 fps frames"; exit 2 }

# One MD5 per video packet (ProRes frame), without decoding.
hashes() { ffmpeg -loglevel error -i "$1" -map 0:v -c copy -f framemd5 - | grep -v '^#' | awk -F', *' '{ print $NF }' }

(cd "$here" && swift build -c release >/dev/null)
work=$(mktemp -d "$out/renders/patch.XXXXXX")
trap 'rm -rf "$work"' EXIT

for aspect in $aspects; do
  print "== $aspect: frames $first..<$last"
  full="$out/renders/$aspect-120.mov"
  "$here/.build/release/trailer-stage" --repo "$repo" --raw "$raw" --aspect $aspect --fps $fps \
    --from $from --to $to --out "$work/part.mov"
  print -l "file '$full'" "outpoint $(printf '%.6f' $(( first / 120.0 )))" \
           "file '$work/part.mov'" \
           "file '$full'" "inpoint $(printf '%.6f' $(( last / 120.0 )))" > "$work/list.txt"
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$work/list.txt" -map 0:v -c copy "$work/spliced.mov"
  # Every packet must be the old render's, except the range, which must be the new part's.
  hashes "$full" > "$work/old.txt"
  { head -n $first "$work/old.txt"; hashes "$work/part.mov"; tail -n +$(( last + 1 )) "$work/old.txt" } > "$work/want.txt"
  hashes "$work/spliced.mov" > "$work/got.txt"
  cmp -s "$work/want.txt" "$work/got.txt" || { print "splice doesn't match frame for frame; $full left as it was"; exit 1 }
  mv "$work/spliced.mov" "$full"
done

"$here/render.sh" --masters-only $aspects
