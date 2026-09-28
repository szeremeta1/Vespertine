import AVFAudio
import Foundation
import NocturneLibrary
import Testing
@testable import Nocturne

@Suite("App audit", .serialized) @MainActor
struct AppAuditTests {
    @Test func malformedRatePreferencesFallBack() {
        for code in ["fixed:nan", "fixed:inf", "fixed:-1", "fixed:1e200", "fixed:0", "garbage"] {
            #expect(RateChoice(code: code) == .match)
        }
        #expect(RateChoice(code: "fixed:96000") == .fixed(96000))
    }
    @Test func queueClearingAndReorderingSurviveShuffle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-app-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let b = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 480))
            b.frameLength = 480
            for c in 0..<2 { for i in 0..<480 { b.floatChannelData![c][i] = 0 } }
            try f.write(from: b)
        }
        let original = try MetadataReader.read(url: url, artwork: nil)
        // Nonexistent paths exercise queue logic without playing anything on the user's DAC.
        try FileManager.default.removeItem(at: url)
        let tracks = (0..<4).map { i in var t = original; t.id = Int64(i+1); t.title = "Track \(i)"; return t }
        let suite = "nocturne-audit-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("database"))
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root.appendingPathComponent("database"))
        let player = PlayerController(library: library, settings: settings, shares: shares)
        player.play(tracks)
        player.clearUpcoming()
        player.shuffle = true; player.shuffle = false
        #expect(player.queue.map(\.track.title) == ["Track 0"])
        player.play(tracks)
        player.moveUpcoming(from: IndexSet(integer: 0), to: 3)
        let reordered = player.queue.map(\.id)
        player.shuffle = true; player.shuffle = false
        #expect(player.queue.map(\.id) == reordered)
        settings.replayGain = .track
        player.refreshReplayGain()
        #expect(player.queue.map(\.id) == reordered)
        let duplicateRows = [TrackRow(track: tracks[0], index: 0), TrackRow(track: tracks[0], index: 1)]
        #expect(duplicateRows[0].id != duplicateRows[1].id)
        player.stop()
    }
    @Test func recoveryDirectoryOverridesLaunchArgument() throws {
        let suite = "nocturne-recovery-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/bad/library", forKey: "NocturneDataDirectory")
        let chosen = URL(fileURLWithPath: "/chosen/library")
        #expect(AppSettings(defaults: defaults, dataDirectory: chosen).dataDirectory == chosen)
    }
    @Test func corruptDatabaseProducesRecoverableError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("This is not SQLite".utf8)
        let url = root.appendingPathComponent("Library.sqlite")
        try data.write(to: url)
        #expect(throws: (any Error).self) { try LibraryStore(dataDirectory: root) }
        #expect(try Data(contentsOf: url) == data)
    }
}
