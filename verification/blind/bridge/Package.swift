// swift-tools-version: 6.0
//
// Vespertine verification, blind-agent round: exports what Vespertine's own DoP and IEC 61937 code produces for
// the fixed inputs in ../vectors/inputs.json, so ../tools/compare.py can compare it word for word with the blind
// reference implementation. Read-only use of VespertineKit (path dependency); nothing in the app changes.
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   cd verification/blind/bridge && BLIND_VECTORS=$PWD/../vectors swift test
//   (writes ../vectors/vespertine.json)

import PackageDescription

let package = Package(
    name: "BlindBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../Packages/VespertineKit"),
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
    ],
    targets: [
        .testTarget(name: "BridgeExport", dependencies: [
            .product(name: "VespertineAudio", package: "VespertineKit"),
            .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
