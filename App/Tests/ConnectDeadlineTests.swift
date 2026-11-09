//
// Vespertine: connecting to a share whose mount (or keychain prompt) never finishes ends in "offline" with the reason, not
// "Connecting…" for ever, and the share can be tried again.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Connecting to a share has a deadline", .serialized) @MainActor
struct ConnectDeadlineTests {
    @Test("A mount that never returns ends offline with the unreachable message, and Reconnect tries again")
    func mountNeverReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-connect-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"))
        let source = try library.database.addSource(LibrarySource(path: "/Volumes/Music Share", mode: .reference,
                                                                  remoteURL: "smb://nas.local/Music%20Share"))
        let share = try #require(source.networkShare)
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let attempts = Attempts()
        shares.connectDeadline = 0.3
        shares.mounter = { _, _ in
            attempts.add()
            try await Task.sleep(for: .seconds(3600))   // the server took the connection and never answered
            throw CancellationError()
        }

        #expect(await shares.connect(source) == false)
        #expect(shares.status(of: source) == .offline(NetworkShareError.unreachable(host: share.host).localizedDescription))
        #expect(await shares.connect(source) == false, "not stuck as connecting: Reconnect tries again")
        #expect(attempts.count == 2)
    }
}

nonisolated private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
