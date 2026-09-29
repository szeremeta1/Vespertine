// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
// The launch trailer, rendered frame by frame on screen so it can use the system's real Liquid Glass.
import PackageDescription

let package = Package(
    name: "TrailerStage",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "trailer-stage",
            path: "Sources/TrailerStage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
