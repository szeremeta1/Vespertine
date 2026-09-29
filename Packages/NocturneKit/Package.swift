// swift-tools-version: 6.2
//
// Nocturne — a bit-perfect audio player for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "NocturneKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NocturneAudio", targets: ["NocturneAudio"]),
        .library(name: "NocturneLibrary", targets: ["NocturneLibrary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(path: "../NocturneAnalysis"),
    ],
    targets: [
        // Real-time pieces (ring buffer, IOProc, meters) in plain C so the render
        // thread never touches the Swift runtime, locks or the allocator.
        .target(
            name: "CNocturneRT",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        // DTS CDs / DTS-in-WAV: FFmpeg's DTS decoder only (scripts/build-dts-decoder.sh).
        .binaryTarget(name: "FFmpegDCA", path: "Vendor/FFmpegDCA.xcframework"),
        .target(name: "CNocturneDTS", dependencies: ["FFmpegDCA"]),
        // Decoder calls with C++/Objective-C exceptions caught (a damaged file must not crash the app).
        .target(name: "CNocturneGuard", linkerSettings: [.linkedFramework("AVFAudio"), .linkedLibrary("c++")]),
        .target(
            name: "NocturneAudio",
            dependencies: [
                "CNocturneRT",
                "CNocturneDTS",
                "CNocturneGuard",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                .product(name: "NocturneAnalysisCore", package: "NocturneAnalysis"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "NocturneLibrary",
            dependencies: [
                "NocturneAudio",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        // Generates a demo library of original, synthesized music with artwork (for development and screenshots).
        .executableTarget(
            name: "nocturne-demo",
            dependencies: [
                "NocturneLibrary",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ]
        ),
        // Hardware verification: drives the real engine against a device and reads back what Core Audio did.
        .executableTarget(name: "nocturne-probe", dependencies: ["NocturneAudio"]),
        // Library operations from the command line (find music, import, enrich) — same code the app uses.
        .executableTarget(name: "nocturne-library", dependencies: ["NocturneLibrary"]),
        .testTarget(name: "NocturneAudioTests", dependencies: ["NocturneAudio", "CNocturneRT", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "NocturneLibraryTests", dependencies: ["NocturneLibrary"]),
    ],
    swiftLanguageModes: [.v6]
)
