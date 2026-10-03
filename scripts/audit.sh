#!/bin/zsh
# Repeatable local regression and real-time safety checks. Does not sign, install, or publish.
# Set VESPERTINE_HARDWARE_TESTS=1 to run the silent built-in-output integration test.
set -euo pipefail
cd "$(dirname "$0")/.."
out="build/audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
print "Audit evidence: $out"
swift test --package-path Packages/VespertineKit > "$out/debug-tests.log" 2>&1
swift test --package-path Packages/VespertineKit -c release > "$out/release-tests.log" 2>&1
# The analysis core also runs on Linux servers (vespertine-analyze): its own parity/chunking tests.
swift test --package-path Packages/VespertineAnalysis > "$out/analysis-tests.log" 2>&1
for sanitizer in address,undefined thread; do
  binary="$out/rt-${sanitizer//,/}-audit"
  clang -std=c11 -g -O1 -fsanitize="$sanitizer" -I Packages/VespertineKit/Sources/CVespertineRT/include \
    tests/rt-audit.c Packages/VespertineKit/Sources/CVespertineRT/vespertine_rt.c -framework CoreAudio -framework AudioToolbox -o "$binary"
  "$binary" > "$binary.log" 2>&1
done
clang --analyze -std=c11 -I Packages/VespertineKit/Sources/CVespertineRT/include \
  Packages/VespertineKit/Sources/CVespertineRT/vespertine_rt.c -o "$out/rt-static.plist"
scripts/generate-project.sh > "$out/xcodegen.log" 2>&1
xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/AuditDD -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO test > "$out/app-tests.log" 2>&1
xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/AuditDD -onlyUsePackageVersionsFromResolvedFile ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build > "$out/universal-build.log" 2>&1
zsh -n scripts/release.sh scripts/publish.sh scripts/backup-sparkle-key.sh
git diff --check
print "All audit checks passed. Logs: $out"
