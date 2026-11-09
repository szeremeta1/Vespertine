// Vespertine: tests for moving queued songs with ids that are stale, repeated or not upcoming.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Moving upcoming songs", .serialized) @MainActor
struct QueueMoveTests {
    @Test("Unknown, repeated, playing and target ids are skipped; the rest move in the order given")
    func staleIDsAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-move-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
            buffer.frameLength = 480
            for c in 0..<2 { for i in 0..<480 { buffer.floatChannelData![c][i] = 0 } }
            try file.write(from: buffer)
        }
        let original = try MetadataReader.read(url: url, artwork: nil)
        // Queue-only test: with the file gone nothing opens or plays on a real output.
        try FileManager.default.removeItem(at: url)
        let tracks = (1...5).map { i -> Track in
            var t = original; t.id = Int64(i); t.title = "S\(i)"; t.location = "/nowhere/S\(i).wav"; t.filePath = t.location; return t
        }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false })
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        defer { player.stop() }

        player.play(tracks)
        let entries = Dictionary(uniqueKeysWithValues: player.queue.map { ($0.track.title, $0.id) })
        let playing = try #require(player.current?.id)
        func titles() -> [String] { player.upcoming.map(\.track.title) }
        #expect(titles() == ["S2", "S3", "S4", "S5"])

        // S4 twice, an id that was never queued, the song playing, S2 (the target) and S3: only S4 and S3 move.
        player.moveUpcoming([entries["S4"]!, UUID(), entries["S4"]!, playing, entries["S2"]!, entries["S3"]!],
                            before: entries["S2"]!)
        #expect(titles() == ["S4", "S3", "S2", "S5"])
        #expect(player.current?.id == playing)

        // Nothing valid to move changes nothing.
        let before = player.queue
        player.moveUpcoming([UUID(), playing], before: nil)
        #expect(player.queue == before)
    }
}
