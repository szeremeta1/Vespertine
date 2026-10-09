// swift-tools-version: 6.0
//
// Vespertine verification: the spec-traced test harness (see ../README.md).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contracts       the interface contracts (../contracts/*.md) as Swift protocols
// SpecKit         Checker, SpecCheck, Mutant, the DST fixture loader
// SpecChecks      agent A's checks, written blind from the contracts and requirement records
// CleanRoomB(2)   agent B's (and B2's, another model) implementations, written blind from the same
// Mutants         agent C's deliberately wrong variants, each aimed at named requirements
// VespertineAdapters
//                 Vespertine behind each contract. macOS: VespertineKit itself (path dependency). Linux: the C under
//                 test (vespertine_rt.c, vespertine_dst.c) compiled from Packages/ through symlinks, with a Core
//                 Audio shim; Vespertine's Swift code is macOS-only, so those groups run there only.
// AcceptanceTests B passes every check, every mutant is killed by a check on its targets, Vespertine is reported.

import PackageDescription

var dependencies: [Package.Dependency] = []
var adapterDependencies: [Target.Dependency] = ["Contracts"]
var platformTargets: [Target] = []

#if os(macOS)
dependencies += [
    .package(path: "../../Packages/VespertineKit"),
    .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
]
adapterDependencies += [
    .product(name: "VespertineAudio", package: "VespertineKit"),
    .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
]
#else
platformTargets += [
    .target(name: "CoreAudioShim"),
    .target(name: "RTUnderTest", dependencies: ["CoreAudioShim"]),
    .target(name: "DSTUnderTest"),
]
adapterDependencies += ["RTUnderTest", "DSTUnderTest"]
#endif

let package = Package(
    name: "VespertineVerification",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: platformTargets + [
        .target(name: "Contracts"),
        .target(name: "SpecKit", dependencies: ["Contracts"]),
        .target(name: "SpecChecks", dependencies: ["Contracts", "SpecKit"]),
        .target(name: "CleanRoomB", dependencies: ["Contracts"]),
        .target(name: "CleanRoomB2", dependencies: ["Contracts"]),
        .target(name: "Mutants", dependencies: ["Contracts", "SpecKit"]),
        .target(name: "VespertineAdapters", dependencies: adapterDependencies),
        .testTarget(name: "AcceptanceTests",
                    dependencies: ["Contracts", "SpecKit", "SpecChecks", "CleanRoomB", "CleanRoomB2", "Mutants", "VespertineAdapters"]),
    ],
    swiftLanguageModes: [.v6]
)
