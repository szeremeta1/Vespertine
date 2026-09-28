// swift-tools-version: 6.2
//
// Nocturne — file analysis core (true bit depth, lossy-origin, upsampling and synthetic-HF forensics).
// Plain Swift + Foundation so the same code runs in the app and on a Linux file server
// (`nocturne-analyze`), next to the music, where reading files is fast.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "NocturneAnalysis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NocturneAnalysisCore", targets: ["NocturneAnalysisCore"]),
        .executable(name: "nocturne-analyze", targets: ["nocturne-analyze"]),
    ],
    targets: [
        .target(name: "NocturneAnalysisCore"),
        // Analyzes a folder tree on a server (decoding with ffmpeg) into `.nocturne/analysis.jsonl`,
        // which Nocturne imports instead of reading every file over the network.
        .executableTarget(name: "nocturne-analyze", dependencies: ["NocturneAnalysisCore"]),
        .testTarget(name: "NocturneAnalysisCoreTests", dependencies: ["NocturneAnalysisCore"]),
    ],
    swiftLanguageModes: [.v6]
)
