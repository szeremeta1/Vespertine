// Vespertine: tests for what Play does once the queue has played to its end.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
@testable import Vespertine

@Suite("Play after the queue ended", .serialized) @MainActor
struct PlayAfterQueueEndTests {
    /// A player with nothing behind it, the five songs of an album (S1 to S5) and one more to add (X). The engine's
    /// reports are given by hand (`report`): nothing plays, so the player stays stopped throughout.
    private func fixture(_ body: (PlayerController, [Track], Track) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-queue-end-\(UUID())")
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
        func track(_ id: Int, _ title: String) -> Track {
            var t = original; t.id = Int64(id); t.title = title; t.location = "/nowhere/\(title).wav"; t.filePath = t.location; return t
        }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false })
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        defer { player.stop() }
        try body(player, (1...5).map { track($0, "S\($0)") }, track(6, "X"))
    }

    /// Hands the player an engine event, as the engine does.
    private func report(_ event: EngineEvent, to player: PlayerController) throws {
        let handler = try #require(player.engine.eventHandler)
        handler(event)
    }

    @Test("After the queue has played to its end, Play starts it from the first song")
    func playStartsTheQueueOver() throws {
        try fixture { player, album, _ in
            player.play(album, startAt: 4)
            let last = try #require(player.current)
            try report(.trackStarted(last.item), to: player)
            try report(.queueEnded, to: player)
            #expect(player.current?.id == last.id, "the last song stays shown once it has ended")

            player.togglePlayPause()
            #expect(player.currentIndex == 0)
            #expect(player.current?.track.title == "S1")
        }
    }

    @Test("Play on a song that was stopped, with the queue not at its end, starts that song again")
    func playRestartsAStoppedSong() throws {
        try fixture { player, album, _ in
            player.play(album, startAt: 2)
            try report(.trackStarted(try #require(player.current).item), to: player)
            player.stop()

            player.togglePlayPause()
            #expect(player.current?.track.title == "S3")
        }
    }

    @Test("With songs added after the end, Play starts the last song again and goes on to them")
    func songsAddedAfterTheEnd() throws {
        try fixture { player, album, x in
            player.play(album, startAt: 4)
            try report(.trackStarted(try #require(player.current).item), to: player)
            try report(.queueEnded, to: player)
            player.playNext([x])

            player.togglePlayPause()
            #expect(player.current?.track.title == "S5")
            #expect(player.upcoming.map(\.track.title) == ["X"])
        }
    }

    @Test("A last song that couldn't play is tried again, not skipped for the first one")
    func aFailedLastSongIsTriedAgain() throws {
        try fixture { player, album, _ in
            player.play(album, startAt: 4)
            let last = try #require(player.current)
            try report(.failed(last.item, "The file couldn't be opened."), to: player)
            try report(.queueEnded, to: player)

            player.togglePlayPause()
            #expect(player.current?.track.title == "S5")
        }
    }
}
