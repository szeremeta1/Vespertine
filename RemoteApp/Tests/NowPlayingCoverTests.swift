//
// Vespertine Remote: Now Playing's cover and its record are one picture, and a tap on it is the only switch between them.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import UIKit
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertineRemote

@MainActor
@Suite struct NowPlayingCover {
    /// A demo Mac that, like the real one, keeps covers at 160 and 600 pixels and sends nothing larger.
    private func connected() async throws -> (RemoteSession, String) {
        let mac = DemoMac(name: "Demo", appVersion: "1.0") { key, size in size <= 600 ? DemoArtwork.png(key: key, size: size) : nil }
        let pairing = SavedPairing(serverID: DemoMac.serverID, name: "Demo", device: "demo", key: Data())
        let session = RemoteSession(pairing: pairing, clientName: "Test phone") { mac }
        session.connect()
        for _ in 0..<100 where !session.isConnected { try await Task.sleep(for: .milliseconds(50)) }
        try #require(session.isConnected)
        guard case .albums(let items, _) = await session.send(.albums(offset: 0, limit: 1)), let key = items.first?.artworkKey else {
            throw CancellationError()
        }
        return (session, key)
    }

    @Test func theFlatCoverAsksForTheSizeTheRecordDoes() {
        #expect(NowPlayingArt.flatSize == NowPlayingArt.recordSize)
        #expect(NowPlayingArt.flatSize <= 600)
    }

    @Test func theFlatCoverIsFoundWhereverTheMacKeepsItsCovers() async throws {
        let (session, key) = try await connected()
        let cache = ArtworkCache()
        cache.session = session
        #expect(await cache.image(key, size: NowPlayingArt.recordSize) != nil)
        #expect(await cache.image(key, size: NowPlayingArt.flatSize) != nil)
    }

    @Test func aTapSwitchesBetweenTheRecordAndTheCover() {
        #expect(NowPlayingArt.toggled(vinyl: false) == true)
        #expect(NowPlayingArt.toggled(vinyl: true) == false)
    }

    @Test func theViewsSayWhatTheyAreAndWhatATapDoes() {
        #expect(NowPlayingArt.label(vinyl: true) != NowPlayingArt.label(vinyl: false))
        #expect(NowPlayingArt.switchHint(vinyl: true) != NowPlayingArt.switchHint(vinyl: false))
    }

    @Test func theChoiceIsRemembered() {
        let suite = "vespertine-art-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.vinyl == false)
        settings.vinyl = NowPlayingArt.toggled(vinyl: settings.vinyl)
        #expect(AppSettings(defaults: defaults).vinyl == true)
    }
}
