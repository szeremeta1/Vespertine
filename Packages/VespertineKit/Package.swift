// swift-tools-version: 6.2
//
// Vespertine: a surround and hi-res music player for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "VespertineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VespertineAudio", targets: ["VespertineAudio"]),
        .library(name: "VespertineLibrary", targets: ["VespertineLibrary"]),
        .library(name: "VespertineVisualizer", targets: ["VespertineVisualizer"]),
        .library(name: "VespertineTidal", targets: ["VespertineTidal"]),
        .library(name: "VespertineUPnP", targets: ["VespertineUPnP"]),
        .library(name: "VespertineAirPlay", targets: ["VespertineAirPlay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
        // TagLib itself (the copy SFBAudioEngine already builds), for the property map its writer doesn't use.
        .package(url: "https://github.com/sbooth/CXXTagLib", from: "2.3.2"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(path: "../VespertineAnalysis"),
        // Speaker layouts and Spatial Audio beds, shared with the iPhone player (VespertineChannels).
        .package(path: "../VespertineRemoteKit"),
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
        // libwavpack with DSD support, prefixed so it can't meet the WavPack inside SFBAudioEngine, which leaves DSD out
        // (scripts/build-wavpack-dsd.sh).
        .binaryTarget(name: "WavPackDSD", path: "Vendor/WavPackDSD.xcframework"),
        .target(name: "CVespertineWavPack", dependencies: ["WavPackDSD"]),
        // Decoder calls with C++/Objective-C exceptions caught (a damaged file must not crash the app).
        // Also the input source that lets a decoder read a share file while it is still being copied (see NetworkPlaybackCache).
        .target(name: "CVespertineGuard",
                dependencies: [.product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
                linkerSettings: [.linkedFramework("AVFAudio"), .linkedLibrary("c++")]),
        // Every value of multi-valued tags (several artists, genres, MusicBrainz IDs), which SFBAudioEngine's writer cuts to one.
        .target(name: "CVespertineTags", dependencies: [.product(name: "taglib", package: "CXXTagLib")]),
        .target(
            name: "VespertineAudio",
            dependencies: [
                "CVespertineRT",
                "CVespertineDTS",
                "CVespertineGuard",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                "CVespertineWavPack",
                .product(name: "VespertineAnalysisCore", package: "VespertineAnalysis"),
                .product(name: "VespertineChannels", package: "VespertineRemoteKit"),
            ],
            // The known-DoP-DAC list (dop-dacs.json), read by DoPDACList.bundled.
            resources: [.copy("Resources/dop-dacs.json")],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
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
        // TIDAL: auth, request gate, catalog, stream resolution and the fragmented-MP4-to-FLAC layout. No UI, no engine state.
        .target(name: "VespertineTidal", dependencies: ["VespertineAudio", "VespertineLibrary"],
                linkerSettings: [.linkedFramework("Security")]),
        // Network renderers (UPnP AV / OpenHome): discovery, control, and the HTTP server they pull the music from.
        .target(
            name: "VespertineUPnP",
            dependencies: ["VespertineAudio", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")]
        ),
        // AirPlay 1 (RAOP) receivers: Bonjour discovery, the RTSP/RTP session, ALAC encoding and the engine-shaped playback.
        .target(
            name: "VespertineAirPlay",
            dependencies: ["VespertineAudio", "VespertineUPnP"],
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("Security"), .linkedFramework("Network")]
        ),
        // The visualizer window's analysis (FFT, bands, beats) and Metal renderer. Reads a copy of the samples only.
        .target(
            name: "VespertineVisualizer",
            linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("Metal"), .linkedFramework("MetalKit")]
        ),
        // Renders the visualizer offline from a decoded file, frame by frame (screenshots, recordings, timing).
        .executableTarget(name: "vespertine-visualize", dependencies: ["VespertineVisualizer"]),
        // Generates a demo library of original, synthesized music with artwork (for development and screenshots).
        .executableTarget(
            name: "vespertine-demo",
            dependencies: [
                "VespertineLibrary",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ]
        ),
        // Hardware verification: drives the real engine against a device and reads back what Core Audio did.
        .executableTarget(name: "vespertine-probe", dependencies: ["VespertineAudio", "VespertineGroupProbe"]),
        // Phase 0 of multi-DAC "speaker groups": the probe's group-info / group-play / group-skew commands. Not a product, so
        // nothing links it into the app; only vespertine-probe and its tests use it.
        .target(name: "VespertineGroupProbe", dependencies: ["VespertineAudio"]),
        // Library operations from the command line (find music, import, enrich), with the same code the app uses.
        .executableTarget(name: "vespertine-library", dependencies: ["VespertineLibrary"]),
        // Synthetic test media both test targets build (SACD images, DST frames, DSDIFF files).
        .target(name: "VespertineTestSupport", path: "Tests/VespertineTestSupport"),
        .testTarget(name: "VespertineAudioTests", dependencies: ["VespertineAudio", "CVespertineRT", "CVespertineGuard", "VespertineTestSupport", "VespertineLibrary",
                                                                 .product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VespertineGroupProbeTests", dependencies: ["VespertineGroupProbe", "VespertineAudio"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VespertineTidalTests",
                    dependencies: ["VespertineTidal", "VespertineAudio", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VespertineUPnPTests", dependencies: ["VespertineUPnP", "VespertineAudio",
                                                               .product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VespertineAirPlayTests", dependencies: ["VespertineAirPlay", "VespertineUPnP", "VespertineAudio",
                                                                  .product(name: "SFBAudioEngine", package: "SFBAudioEngine")]),
        .testTarget(name: "VespertineVisualizerTests", dependencies: ["VespertineVisualizer"]),
        .testTarget(name: "VespertineLibraryTests", dependencies: ["VespertineLibrary", "CVespertineTags", "VespertineTestSupport"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
