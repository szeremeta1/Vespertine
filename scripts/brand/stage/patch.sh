#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Re-renders part of the trailer and splices it into existing renders, then remakes their masters.
# Motion is a pure function of time, so a range rendered on its own matches the full render frame for frame.
# ProRes is intra-only, so the splice is a stream copy: nothing outside the range is re-encoded.
# Usage: patch.sh <from s> <to s> [aspect…]   (default: wide square vertical). The screen must be unlocked.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h:h}
out=~/Movies/Vespertine/Trailer
raw=${VESPERTINE_TRAILER_RAW:-$out/raw}
from=$1 to=$2; shift 2
if (( $# )); then aspects=($@); else aspects=(wide square vertical); fi
fps=60
# Frame numbers as trailer-stage computes them.
first=$(printf '%.0f' $(( from * fps ))) last=$(printf '%.0f' $(( to * fps )))

# One MD5 per video packet (ProRes frame), without decoding.
hashes() { ffmpeg -loglevel error -i "$1" -map 0:v -c copy -f framemd5 - | grep -v '^#' | awk -F', *' '{ print $NF }' }

(cd "$here" && swift build -c release >/dev/null)
work=$(mktemp -d "$out/renders/patch.XXXXXX")
trap 'rm -rf "$work"' EXIT

for aspect in $aspects; do
  print "== $aspect: frames $first..<$last"
  full="$out/renders/$aspect.mov"
  "$here/.build/release/trailer-stage" --repo "$repo" --raw "$raw" --aspect $aspect --fps $fps --behind \
    --from $from --to $to --out "$work/part.mov"
  hashes "$full" > "$work/old.txt"
  total=$(wc -l < "$work/old.txt")
  print -l "file '$full'" "outpoint $(printf '%.6f' $(( first / 60.0 )))" "file '$work/part.mov'" > "$work/list.txt"
  # A range that runs to the end has no tail to copy.
  (( last < total )) && print -l "file '$full'" "inpoint $(printf '%.6f' $(( last / 60.0 )))" >> "$work/list.txt"
  # The part's own time base doesn't survive the concat (its frames all land at the splice point), so every
  # frame is stamped afresh at 1/fps.
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$work/list.txt" -map 0:v -c copy \
    -bsf:v "setts=ts=N/($fps*TB)" -video_track_timescale $fps "$work/spliced.mov"
  # Every packet must be the old render's, except the range, which must be the new part's.
  hashes "$work/part.mov" > "$work/part.txt"
  { head -n $first "$work/old.txt"; cat "$work/part.txt"; tail -n +$(( last + 1 )) "$work/old.txt" } > "$work/want.txt"
  hashes "$work/spliced.mov" > "$work/got.txt"
  cmp -s "$work/want.txt" "$work/got.txt" || { print "splice doesn't match frame for frame; $full left as it was"; exit 1 }
  [[ $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$work/spliced.mov") == $(printf '%.6f' $(( total / $fps.0 ))) ]] \
    || { print "splice's timing is off; $full left as it was"; exit 1 }
  mv "$work/spliced.mov" "$full"
done

"$here/render.sh" --masters-only $aspects
