// swift-tools-version: 6.2
//
// Vespertine — file analysis core (true bit depth, lossy-origin, upsampling and synthetic-HF forensics).
// Plain Swift + Foundation so the same code runs in the app and on a Linux file server
// (`vespertine-analyze`), next to the music, where reading files is fast.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "VespertineAnalysis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VespertineAnalysisCore", targets: ["VespertineAnalysisCore"]),
        .executable(name: "vespertine-analyze", targets: ["vespertine-analyze"]),
    ],
    targets: [
        .target(name: "VespertineAnalysisCore"),
        // Analyzes a folder tree on a server (decoding with ffmpeg) into `.vespertine/analysis.jsonl`,
        // which Vespertine imports instead of reading every file over the network.
        .executableTarget(name: "vespertine-analyze", dependencies: ["VespertineAnalysisCore"]),
        .testTarget(name: "VespertineAnalysisCoreTests", dependencies: ["VespertineAnalysisCore"]),
    ],
    swiftLanguageModes: [.v6]
)
