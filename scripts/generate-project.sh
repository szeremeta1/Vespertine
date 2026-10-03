#!/bin/zsh
# Generates Vespertine.xcodeproj with XcodeGen and gives it the app's committed lockfile, App/Package.resolved.
#
#   scripts/generate-project.sh
#
# The generated project is ignored by git, so without this a fresh clone resolves every package that isn't pinned
# exactly (GRDB, TagLib, SFBAudioEngine's codec libraries) to whatever is newest. Build with
# -onlyUsePackageVersionsFromResolvedFile so Xcode uses these versions or stops. To update a dependency, change
# Packages/VespertineKit (swift package update), then copy its pins into App/Package.resolved (Sparkle's pin is only
# in the app's file); CI fails when the two disagree.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
swiftpm=Vespertine.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$swiftpm"
cp App/Package.resolved "$swiftpm/Package.resolved"
