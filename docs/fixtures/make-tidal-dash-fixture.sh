#!/bin/bash
#
# Vespertine: regenerates the DASH FLAC fixture for the TIDAL tests: a 3 s, 96 kHz / 24-bit synthesized FLAC, and the same audio
# cut into fragmented-MP4 segments the way TIDAL serves hi-res tracks (init segment + numbered media segments, FLAC copied
# unchanged). Uses Homebrew's ffmpeg only.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage: docs/fixtures/make-tidal-dash-fixture.sh [output-dir]
# Default output: Packages/VespertineKit/Tests/VespertineTidalTests/Fixtures/dash
#   source.flac    the source audio
#   init.mp4       the initialization segment (moov with fLaC/dfLa)
#   chunk-*.m4s    the media segments (styp, sidx, moof, mdat); ffmpeg names them, tests sort them numerically
#   manifest.mpd   ffmpeg's MPD for them
set -euo pipefail

FFMPEG=/opt/homebrew/bin/ffmpeg
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../../Packages/VespertineKit/Tests/VespertineTidalTests/Fixtures/dash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tidal-dash.XXXXXX")"
trap 'rmdir "$WORK" 2>/dev/null || true' EXIT

mkdir -p "$OUT"
cd "$WORK"

# A tone with a little deterministic noise so the 24-bit samples are not trivially compressible.
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=440:sample_rate=96000:duration=3" \
    -f lavfi -i "anoisesrc=color=white:sample_rate=96000:duration=3:seed=7:amplitude=0.0005" \
    -filter_complex "[0:a][1:a]amix=inputs=2:normalize=0,volume=0.6[a]" -map "[a]" \
    -ac 1 -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 source.flac

"$FFMPEG" -hide_banner -loglevel error -y -i source.flac -c:a copy -f dash -seg_duration 1 -single_file 0 out.mpd

# Replace the previous fixture's generated files, and nothing else.
find "$OUT" -maxdepth 1 \( -name 'chunk-*' -o -name 'init.mp4' -o -name 'source.flac' -o -name 'manifest.mpd' \) -type f -delete
cp source.flac "$OUT/source.flac"
cp init-stream0.m4s "$OUT/init.mp4"
cp out.mpd "$OUT/manifest.mpd"
for chunk in chunk-*.m4s; do cp "$chunk" "$OUT/$chunk"; done

# The temp dir's files are removed explicitly (no wildcards on a variable path).
rm -f source.flac init-stream0.m4s out.mpd chunk-*.m4s
echo "Wrote $(find "$OUT" -maxdepth 1 -type f | wc -l | tr -d ' ') files to $OUT ($(du -sk "$OUT" | cut -f1) KiB)"
