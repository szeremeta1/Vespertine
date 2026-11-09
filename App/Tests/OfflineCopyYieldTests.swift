import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
@testable import Vespertine

/// Keep Offline and Network Cache copies give a song's copy from the share the link whenever that copy needs it (the scan gate
/// is held for it: the song is starting, its copy is behind, or a read waits on it), not only when the output buffer runs low.
@Suite("Offline copies make way for the song being copied", .serialized) @MainActor
struct OfflineCopyYieldTests {
    @Test("While a song's copy holds the share (a start on a prefix, a full copy before the first note), Keep Offline copies wait")
    func yieldsWhileTheGateIsHeld() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-yield-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"))
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        let owner = "copy-\(UUID().uuidString)"
        defer { ShareIOGate.shared.setPlaybackDemand(false, from: owner, grace: false) }

        // The song plays with a full output buffer, but its copy is still arriving and asks for the link (it is behind).
        var snapshot = player.engine.snapshot
        snapshot.state = .playing
        snapshot.readingFromShare = true
        snapshot.bufferFill = 0.9
        snapshot.isBuffering = false
        ShareIOGate.shared.setPlaybackDemand(true, from: owner)
        player.poll(snapshot)
        #expect(shares.cache.yieldsToPlayback, "the copy that holds the share goes first")

        // Before the first note: the whole song is being copied (nothing decodes from the share yet).
        snapshot.readingFromShare = false
        snapshot.bufferFill = 0
        player.poll(snapshot)
        #expect(shares.cache.yieldsToPlayback, "a song still being copied before it starts goes first too")

        // The copy is local: Keep Offline copies carry on.
        ShareIOGate.shared.setPlaybackDemand(false, from: owner, grace: false)
        player.poll(snapshot)
        #expect(!shares.cache.yieldsToPlayback)
    }
}
