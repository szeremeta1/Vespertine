#!/bin/bash
# Run the actual geometry unit tests on macOS without a Simulator or copied implementation.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/layout-checks build/module-cache
cat > build/layout-checks/main.swift <<'SWIFT'
import XCTest
let suite = XCTestSuite(forTestCaseClass: AdaptiveLayoutTests.self)
suite.run()
guard let result = suite.testRun, result.executionCount == 7, result.failureCount == 0 else {
    fatalError("Layout tests did not all pass")
}
SWIFT
developer="$(xcode-select -p)"
frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libs="$developer/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -disable-sandbox -I "$libs" -L "$libs" -Xlinker -rpath -Xlinker "$libs" -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -module-cache-path build/module-cache -D LAYOUT_STANDALONE \
    RemoteApp/Sources/AdaptiveLayout.swift RemoteApp/Tests/AdaptiveLayoutTests.swift \
    build/layout-checks/main.swift -o build/layout-checks/check
build/layout-checks/check
