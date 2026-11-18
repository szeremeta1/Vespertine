// Vespertine: tests for what Previous does: the song starts over once it is more than a few seconds in, and the song before
// it plays otherwise. Every way of asking (the transport bar's button, the Controls menu and its shortcut, the media keys and
// Control Centre, the phone remote) calls the same `PlayerController.previous()`.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
@testable import Vespertine

@Suite("Previous", .serialized) @MainActor
struct PreviousSongTests {
    /// A player with nothing behind it and the five songs of an album (S1 to S5). The engine's reports are given by hand
    /// (`report`): the files are gone, so nothing opens or plays on a real output.
    private func fixture(_ body: (PlayerController, [Track]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-previous-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeScratch(root) }
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
        try body(player, (1...5).map { track($0, "S\($0)") })
    }

    /// Hands the player an engine event, as the engine does.
    private func report(_ event: EngineEvent, to player: PlayerController) throws {
        let handler = try #require(player.engine.eventHandler)
        handler(event)
    }

    @Test("In the first seconds of a song, Previous goes to the song before it")
    func goesToTheSongBefore() throws {
        try fixture { player, album in
            player.play(album, startAt: 2)
            try report(.trackStarted(try #require(player.current).item), to: player)
            player.seek(to: 2)

            player.previous()
            #expect(player.currentIndex == 1)
            #expect(player.current?.track.title == "S2")
        }
    }

    @Test("More than a few seconds in, Previous starts the song over, and pressed again goes to the song before it")
    func startsTheSongOverFirst() throws {
        try fixture { player, album in
            player.play(album, startAt: 2)
            try report(.trackStarted(try #require(player.current).item), to: player)
            player.seek(to: 42)

            player.previous()
            #expect(player.current?.track.title == "S3", "the same song")
            #expect(player.position == 0, "from its start")

            player.previous()
            #expect(player.current?.track.title == "S2")
        }
    }

    @Test("On the first song of the queue, Previous starts it over")
    func firstSongStartsOver() throws {
        try fixture { player, album in
            player.play(album, startAt: 0)
            try report(.trackStarted(try #require(player.current).item), to: player)
            player.seek(to: 1)

            player.previous()
            #expect(player.currentIndex == 0)
            #expect(player.current?.track.title == "S1")
            #expect(player.position == 0)
        }
    }

    @Test("Back and forth: Previous, then Next, lands on the song it left, and Previous again on the one before")
    func backAndForth() throws {
        try fixture { player, album in
            player.play(album, startAt: 3)
            try report(.trackStarted(try #require(player.current).item), to: player)

            player.previous()
            #expect(player.current?.track.title == "S3")
            player.next()
            #expect(player.current?.track.title == "S4")
            player.previous()
            #expect(player.current?.track.title == "S3")
            // The engine's report of a song skipped past on the way does not move the queue back to it.
            try report(.trackStarted(try #require(player.queue.first { $0.track.title == "S4" }).item), to: player)
            #expect(player.current?.track.title == "S3")
        }
    }
}
