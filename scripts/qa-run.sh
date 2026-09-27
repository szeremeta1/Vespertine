#!/bin/zsh
# Launches the debug build against an isolated test library, runs QA hooks, snapshots windows.
# Usage: scripts/qa-run.sh <data-dir> <music-dir> <snapshot-dir> [extra -Nocturne… args]
set -e
data=$1 music=$2 shots=$3; shift 3
pkill -x Nocturne 2>/dev/null || true
sleep 1
rm -rf "$shots"
"$(dirname $0)/../build/DD/Build/Products/Debug/Nocturne.app/Contents/MacOS/Nocturne" \
  -ApplePersistenceIgnoreState YES -NocturneDataDirectory "$data" -NocturneAddSource "$music" \
  -NocturneSnapshot "$shots" -NocturneQuitAfterSnapshot YES "$@" > "$shots.log" 2>&1 &
wait
ls "$shots"
