// swift-tools-version: 6.0
//
// Vespertine: the remote protocol, shared by the Mac app (which serves it) and the iPhone and iPad remote (which speaks it).
// Plain Swift + Foundation so the message tests also run on Linux.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import PackageDescription

let package = Package(
    name: "VespertineRemoteKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VespertineRemoteProtocol", targets: ["VespertineRemoteProtocol"]),
        // The phone's side: finding Macs, pairing, the Keychain, and a session that keeps the Mac's state.
        .library(name: "VespertineRemoteClient", targets: ["VespertineRemoteClient"]),
        // A command-line remote for testing a Mac's remote server (pair, send commands, watch what it pushes).
        .executable(name: "vespertine-remote", targets: ["vespertine-remote"]),
    ],
    targets: [
        .target(name: "VespertineRemoteProtocol"),
        .target(name: "VespertineRemoteClient", dependencies: ["VespertineRemoteProtocol"]),
        .executableTarget(name: "vespertine-remote", dependencies: ["VespertineRemoteProtocol"]),
        .testTarget(name: "VespertineRemoteProtocolTests", dependencies: ["VespertineRemoteProtocol", "VespertineRemoteClient"]),
    ]
)
