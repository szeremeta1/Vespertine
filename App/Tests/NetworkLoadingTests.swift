import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Network loading transport", .serialized) @MainActor
struct NetworkLoadingTests {
    @Test("Waiting, ready, rebuffer, pause and resume update the real transport model without losing position")
    func loadingTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-loading-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48)!
            buffer.frameLength = 48
            for c in 0..<2 { for f in 0..<48 { buffer.floatChannelData![c][f] = 0 } }
            try file.write(from: buffer)
        }
        let track = try MetadataReader.read(url: url, artwork: nil)
        try FileManager.default.removeItem(at: url) // Queue/model test: never configures or plays a real DAC.
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"))
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        defer { player.stop() }
        player.play([track])
        var snapshot = player.engine.snapshot
        snapshot.lastError = nil
        snapshot.outputDevice = nil
        snapshot.isBuffering = true
        snapshot.state = .stopped
        snapshot.item = nil
        player.poll(snapshot)
        #expect(player.loading && player.canCancelLoading)

        snapshot.item = try #require(player.current?.item)
        snapshot.state = .playing
        snapshot.isBuffering = false
        snapshot.position = 33
        player.poll(snapshot)
        #expect(!player.loading && player.isPlaying && !player.canCancelLoading)

        snapshot.isBuffering = true
        player.poll(snapshot)
        #expect(player.loading)
        player.togglePlayPause()
        #expect(!player.loading && !player.isPlaying && player.position == 33)
        snapshot.state = .paused
        player.poll(snapshot)
        player.togglePlayPause()
        snapshot.state = .playing
        snapshot.isBuffering = false
        player.poll(snapshot)
        #expect(!player.loading && player.isPlaying && player.position == 33)
    }
}
