#!/bin/zsh
# Repeatable local regression and real-time safety checks. Does not sign, install, or publish.
# Set NOCTURNE_HARDWARE_TESTS=1 to run the silent built-in-output integration test.
set -euo pipefail
cd "$(dirname "$0")/.."
out="build/audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
print "Audit evidence: $out"
swift test --package-path Packages/NocturneKit > "$out/debug-tests.log" 2>&1
swift test --package-path Packages/NocturneKit -c release > "$out/release-tests.log" 2>&1
for sanitizer in address,undefined thread; do
  binary="$out/rt-${sanitizer//,/}-audit"
  clang -std=c11 -g -O1 -fsanitize="$sanitizer" -I Packages/NocturneKit/Sources/CNocturneRT/include \
    tests/rt-audit.c Packages/NocturneKit/Sources/CNocturneRT/nocturne_rt.c -framework CoreAudio -o "$binary"
  "$binary" > "$binary.log" 2>&1
done
clang --analyze -std=c11 -I Packages/NocturneKit/Sources/CNocturneRT/include \
  Packages/NocturneKit/Sources/CNocturneRT/nocturne_rt.c -o "$out/rt-static.plist"
xcodegen generate > "$out/xcodegen.log" 2>&1
xcodebuild -project Nocturne.xcodeproj -scheme Nocturne -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/AuditDD CODE_SIGNING_ALLOWED=NO test > "$out/app-tests.log" 2>&1
xcodebuild -project Nocturne.xcodeproj -scheme Nocturne -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/AuditDD ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build > "$out/universal-build.log" 2>&1
zsh -n scripts/release.sh scripts/publish.sh scripts/backup-sparkle-key.sh
git diff --check
print "All audit checks passed. Logs: $out"
