// swift-tools-version: 5.9
//
// Vespertine: makes a Monkey's Audio (APE) fixture from a WAV file with the Monkey's Audio SDK itself, and tags it.
// Run: swift run --package-path docs/fixtures/make-ape-fixture make-ape-fixture in.wav out.ape "Title" "Artist" "Album" "Track"
// SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "make-ape-fixture",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/sbooth/CXXMonkeysAudio", exact: "12.13.0")],
    targets: [.executableTarget(name: "make-ape-fixture", dependencies: [.product(name: "MAC", package: "CXXMonkeysAudio")])],
    cxxLanguageStandard: .cxx20
)
