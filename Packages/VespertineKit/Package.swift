// swift-tools-version: 6.2
//
// Vespertine — a bit-perfect audio player for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "VespertineKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VespertineAudio", targets: ["VespertineAudio"]),
        .library(name: "VespertineLibrary", targets: ["VespertineLibrary"]),
        .library(name: "VespertineNomad", targets: ["VespertineNomad"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
        // TagLib itself (the copy SFBAudioEngine already builds), for the property map its writer doesn't use.
        .package(url: "https://github.com/sbooth/CXXTagLib", from: "2.3.2"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(path: "../VespertineAnalysis"),
    ],
    targets: [
        // Real-time pieces (ring buffer, IOProc, meters) in plain C so the render
        // thread never touches the Swift runtime, locks or the allocator.
        .target(
            name: "CVespertineRT",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        // DTS CDs / DTS-in-WAV: FFmpeg's DTS decoder only (scripts/build-dts-decoder.sh).
        .binaryTarget(name: "FFmpegDCA", path: "Vendor/FFmpegDCA.xcframework"),
        .target(name: "CVespertineDTS", dependencies: ["FFmpegDCA"]),
        // Decoder calls with C++/Objective-C exceptions caught (a damaged file must not crash the app).
        .target(name: "CVespertineGuard", linkerSettings: [.linkedFramework("AVFAudio"), .linkedLibrary("c++")]),
        // Every value of multi-valued tags (several artists, genres, MusicBrainz IDs), which SFBAudioEngine's writer cuts to one.
        .target(name: "CVespertineTags", dependencies: [.product(name: "taglib", package: "CXXTagLib")]),
        .target(
            name: "VespertineAudio",
            dependencies: [
                "CVespertineRT",
                "CVespertineDTS",
                "CVespertineGuard",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                .product(name: "VespertineAnalysisCore", package: "VespertineAnalysis"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "VespertineLibrary",
            dependencies: [
                "VespertineAudio",
                "CVespertineTags",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        // Work Louder Nomad [E] keyboards: feeds the media widget (text, time, cover art) over the vendor HID channel.
        .target(
            name: "VespertineNomad",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedFramework("ImageIO")]
        ),
        // Hardware verification for the Nomad link: status, watch notifications, push a test card.
        .executableTarget(name: "vespertine-nomad", dependencies: ["VespertineNomad"]),
        // Generates a demo library of original, synthesized music with artwork (for development and screenshots).
        .executableTarget(
            name: "vespertine-demo",
            dependencies: [
                "VespertineLibrary",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ]
        ),
        // Hardware verification: drives the real engine against a device and reads back what Core Audio did.
        .executableTarget(name: "vespertine-probe", dependencies: ["VespertineAudio"]),
        // Library operations from the command line (find music, import, enrich) — same code the app uses.
        .executableTarget(name: "vespertine-library", dependencies: ["VespertineLibrary"]),
        .testTarget(name: "VespertineAudioTests", dependencies: ["VespertineAudio", "CVespertineRT", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VespertineNomadTests", dependencies: ["VespertineNomad"]),
        .testTarget(name: "VespertineLibraryTests", dependencies: ["VespertineLibrary", "CVespertineTags"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
