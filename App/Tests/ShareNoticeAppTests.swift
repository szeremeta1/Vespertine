import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

/// What the listener is told while a song waits on a share that has stopped answering (`EngineSnapshot.shareStalledSeconds`).
@Suite("Share not answering: the notice in the app", .serialized) @MainActor
struct ShareNoticeAppTests {
    private func rig() throws -> (player: PlayerController, root: URL, track: Track) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-notice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sample.wav")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48)!
        buffer.frameLength = 48
        for c in 0..<2 { for f in 0..<48 { buffer.floatChannelData![c][f] = 0 } }
        try file.write(from: buffer)
        let track = try MetadataReader.read(url: url, artwork: nil)
        try FileManager.default.removeItem(at: url)   // a model test: never plays
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"))
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        return (PlayerController(library: library, settings: settings, shares: shares), root, track)
    }

    @Test("The snapshot's silence shows as a notice in the Inspector and the banner; its end takes both away")
    func noticeAppearsAndGoes() throws {
        let (player, root, track) = try rig()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        player.play([track])
        var snapshot = player.engine.snapshot
        snapshot.lastError = nil
        snapshot.outputDevice = nil
        snapshot.state = .stopped
        snapshot.item = nil
        snapshot.isBuffering = true
        player.poll(snapshot)
        #expect(player.shareNotice == nil && player.lastError == nil, "a wait with no silence reported says nothing")

        snapshot.shareStalledSeconds = 12
        player.poll(snapshot)
        let notice = try #require(player.shareNotice)
        #expect(notice.contains("Still trying"), "\(notice)")
        #expect(player.lastError == notice, "the banner says it too")

        snapshot.shareStalledSeconds = 40   // still quiet: the same notice, nothing re-raised
        player.clearError()                 // dismissed
        player.poll(snapshot)
        #expect(player.shareNotice == notice && player.lastError == nil, "a dismissed banner stays dismissed while it is the same stall")

        snapshot.shareStalledSeconds = nil
        player.poll(snapshot)
        #expect(player.shareNotice == nil)
    }

    @Test("When the notice goes, its banner goes with it; a banner about something else stays")
    func bannerClearedOnlyIfItsOwn() throws {
        let (player, root, track) = try rig()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        player.play([track])
        var snapshot = player.engine.snapshot
        snapshot.lastError = nil
        snapshot.outputDevice = nil
        snapshot.state = .stopped
        snapshot.item = nil
        snapshot.isBuffering = true
        snapshot.shareStalledSeconds = 11
        player.poll(snapshot)
        #expect(player.lastError != nil && player.lastError == player.shareNotice)
        snapshot.shareStalledSeconds = nil
        player.poll(snapshot)
        #expect(player.lastError == nil, "the share answered: the banner is taken down")

        snapshot.shareStalledSeconds = 11
        player.poll(snapshot)
        player.engine.eventHandler?(.deviceLost("The DAC"))
        snapshot.shareStalledSeconds = nil
        player.poll(snapshot)
        #expect(player.lastError != nil && player.lastError != player.shareNotice, "another message is not the notice's to remove")
    }
}
