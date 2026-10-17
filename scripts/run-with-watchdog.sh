#!/bin/bash
# Runs a test command; if it is still running after the limit (seconds), prints the stacks of the test processes, stops
# them and fails, so a hung test shows where it is stuck instead of only running into the job's timeout.
#   scripts/run-with-watchdog.sh 600 swift test --package-path Packages/VespertineKit -c release
set -u
limit=$1; shift
"$@" &
pid=$!
for ((i = 0; i < limit; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
    sleep 1
done
echo "::error::Still running after ${limit} s. Stacks of the test processes follow."
for p in $(pgrep -f 'swiftpm-testing-helper|xctest'); do
    [ "$p" = "$$" ] && continue
    echo "=== $p: $(ps -o command= -p "$p")"
    sample "$p" 3 -file "/tmp/sample-$p.txt" >/dev/null 2>&1 && cat "/tmp/sample-$p.txt"
done
pkill -f 'swiftpm-testing-helper|xctest'
kill "$pid" 2>/dev/null
exit 1
