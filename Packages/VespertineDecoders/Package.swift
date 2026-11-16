// swift-tools-version: 6.0
//
// Vespertine: the decoders the iPhone and iPad app brings for kinds of file iOS doesn't open itself: Monkey's Audio (APE),
// WavPack, Ogg Vorbis and Opus. Each is the library's own code (all BSD-3-Clause), in the builds the Mac app plays the same
// files with, so a file decodes to the same samples on both.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import PackageDescription

let package = Package(
    name: "VespertineDecoders",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VespertineDecoders", targets: ["VespertineDecoders"]),
    ],
    dependencies: [
        .package(path: "../VespertineRemoteKit"),
        // The versions SFBAudioEngine 0.14.0 (the Mac's decoders) builds with.
        .package(url: "https://github.com/sbooth/CXXMonkeysAudio", exact: "12.13.0"),
        .package(url: "https://github.com/sbooth/wavpack-binary-xcframework", exact: "0.2.0"),
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework", exact: "0.1.3"),
        .package(url: "https://github.com/sbooth/vorbis-binary-xcframework", exact: "0.1.2"),
        .package(url: "https://github.com/sbooth/opus-binary-xcframework", exact: "0.3.0"),
    ],
    targets: [
        // One plain C interface over the four libraries: open from a reader of ranges, read frames from any frame.
        .target(
            name: "CVespertineDecoders",
            dependencies: [
                .product(name: "MAC", package: "CXXMonkeysAudio"),
                .product(name: "wavpack", package: "wavpack-binary-xcframework"),
                .product(name: "ogg", package: "ogg-binary-xcframework"),
                .product(name: "vorbis", package: "vorbis-binary-xcframework"),
                .product(name: "opus", package: "opus-binary-xcframework"),
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "VespertineDecoders",
            dependencies: ["CVespertineDecoders", .product(name: "VespertineShare", package: "VespertineRemoteKit")]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
