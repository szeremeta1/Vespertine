#!/bin/zsh
# Launches the debug build against an isolated test library, runs QA hooks, snapshots windows.
# Usage: scripts/qa-run.sh <data-dir> <music-dir> <snapshot-dir> [extra -Vespertine… args]
set -e
(( $# >= 3 )) || { print -u2 "usage: scripts/qa-run.sh <data-dir> <music-dir> <snapshot-dir> [extra -Vespertine… args]"; exit 2; }
data=$1 music=$2 shots=$3; shift 3
# Clears earlier snapshots, and only those: a path holding anything but the PNGs this writes is left alone.
if [[ -e $shots ]]; then
  [[ -d $shots && -z "$(find "$shots" -mindepth 1 ! -name '*.png' -print -quit)" ]] \
    || { print -u2 "$shots holds more than snapshots; not deleting it."; exit 2; }
  rm -rf "$shots"
fi
pkill -x Vespertine 2>/dev/null || true
sleep 1
"$(dirname $0)/../build/DD/Build/Products/Debug/Vespertine.app/Contents/MacOS/Vespertine" \
  -ApplePersistenceIgnoreState YES -VespertineDataDirectory "$data" -VespertineAddSource "$music" \
  -VespertineSnapshot "$shots" -VespertineQuitAfterSnapshot YES "$@" > "$shots.log" 2>&1 &
wait
ls "$shots"
