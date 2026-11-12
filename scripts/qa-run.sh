#!/bin/zsh
# Launches the debug build against an isolated test library, runs QA hooks, snapshots windows.
# Usage: scripts/qa-run.sh <data-dir> <music-dir> <snapshot-dir> [extra -Vespertine… args]
# Only a copy this script started is ever stopped: its process ID is kept in build/qa-run.pid while it runs. Any other
# Vespertine that is running (the one you are listening to) is left alone.
set -e
(( $# >= 3 )) || { print -u2 "usage: scripts/qa-run.sh <data-dir> <music-dir> <snapshot-dir> [extra -Vespertine… args]"; exit 2; }
data=$1 music=$2 shots=$3; shift 3
# Clears earlier snapshots, and only those: a path holding anything but the PNGs this writes is left alone.
if [[ -e $shots ]]; then
  [[ -d $shots && -z "$(find "$shots" -mindepth 1 ! -name '*.png' -print -quit)" ]] \
    || { print -u2 "$shots holds more than snapshots; not deleting it."; exit 2; }
  rm -rf "$shots"
fi
bin=${0:A:h:h}/build/DD/Build/Products/Debug/Vespertine.app/Contents/MacOS/Vespertine
pidfile=${0:A:h:h}/build/qa-run.pid
# A copy an earlier run left behind (that run was interrupted): stopped by the process ID that run recorded, and only
# if that process is still this build's app.
if [[ -f $pidfile ]]; then
  left=$(<"$pidfile")
  if [[ $left == <-> && "$(ps -ww -o command= -p $left 2>/dev/null)" == "$bin "* ]]; then
    kill $left 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pidfile"
fi
"$bin" \
  -ApplePersistenceIgnoreState YES -VespertineDataDirectory "$data" -VespertineAddSource "$music" \
  -VespertineSnapshot "$shots" -VespertineQuitAfterSnapshot YES "$@" > "$shots.log" 2>&1 &
print $! > "$pidfile"
wait
rm -f "$pidfile"
ls "$shots"
