#!/bin/bash
# Runs a test command; if it is still running after the limit (seconds), prints the stacks of the test processes, stops
# them and fails, so a hung test shows where it is stuck instead of only running into the job's timeout.
#   scripts/run-with-watchdog.sh 600 swift test --package-path Packages/VespertineKit -c release
# Only the command's own process tree is sampled and stopped, by process ID: other test runs on the same machine (a second
# checkout, another job on a shared runner) are left alone.
set -u
limit=$1; shift
"$@" &
pid=$!

# The process IDs below $1, children first.
descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        descendants "$child"
        echo "$child"
    done
}

for ((i = 0; i < limit; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
    sleep 1
done
echo "::error::Still running after ${limit} s. Stacks of the test processes follow."
tree=$(descendants "$pid")
for p in $tree; do
    command=$(ps -o command= -p "$p" 2>/dev/null)
    case "$command" in
        *swiftpm-testing-helper*|*xctest*)
            echo "=== $p: $command"
            sample "$p" 3 -file "/tmp/sample-$p.txt" >/dev/null 2>&1 && cat "/tmp/sample-$p.txt" ;;
    esac
done
for p in $tree "$pid"; do kill "$p" 2>/dev/null; done
sleep 2
for p in $tree "$pid"; do kill -9 "$p" 2>/dev/null; done
exit 1
