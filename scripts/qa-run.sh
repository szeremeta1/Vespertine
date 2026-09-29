#!/bin/zsh
# Launches the debug build against an isolated test library, runs QA hooks, snapshots windows.
# Usage: scripts/qa-run.sh <data-dir> <music-dir> <snapshot-dir> [extra -Vespertine… args]
set -e
data=$1 music=$2 shots=$3; shift 3
pkill -x Vespertine 2>/dev/null || true
sleep 1
rm -rf "$shots"
"$(dirname $0)/../build/DD/Build/Products/Debug/Vespertine.app/Contents/MacOS/Vespertine" \
  -ApplePersistenceIgnoreState YES -VespertineDataDirectory "$data" -VespertineAddSource "$music" \
  -VespertineSnapshot "$shots" -VespertineQuitAfterSnapshot YES "$@" > "$shots.log" 2>&1 &
wait
ls "$shots"
