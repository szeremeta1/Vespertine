#!/bin/sh
# Builds and runs the DST fixture writer: ./build.sh [out-dir] (default: verification/fixtures/dst).
#
# Compiles a temporary copy of the test support's SACDFixture.swift. Swift 6.2 on Linux can't type-check one closure
# in it in reasonable time, so the copy spells out that closure's parameter types; nothing else changes, and the
# file in Packages/ is left alone.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=${1:-$repo/verification/fixtures/dst}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed 's/(0\.\.<total)\.reduce(0) { \$0 + ((k >> \$1) \& 1 == 1 ? 1 : -1) \* f\[j \* 8 + \$1\] }/(0..<total).reduce(0) { (sum: Int, b: Int) -> Int in sum + ((k >> b) \& 1 == 1 ? 1 : -1) * f[j * 8 + b] }/' \
    "$repo/Packages/VespertineKit/Tests/VespertineTestSupport/SACDFixture.swift" > "$tmp/SACDFixture.swift"
swiftc -O "$tmp/SACDFixture.swift" "$here/main.swift" -o "$tmp/dst-fixtures"
"$tmp/dst-fixtures" "$out"
