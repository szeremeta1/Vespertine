// Vespertine: tests for turning shuffle on and off around songs added with Play Next.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Shuffle and Playing Next", .serialized) @MainActor
struct QueueShuffleTests {
    /// A player with nothing behind it, the five songs of an album (S1 to S5) and two more to add (X, Y).
    private func fixture(_ body: (PlayerController, [Track], Track, Track) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-shuffle-\(UUID())")
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
        try body(player, (1...5).map { track($0, "S\($0)") }, track(6, "X"), track(7, "Y"))
    }

    private func titles(_ entries: some Sequence<QueueEntry>) -> [String] { entries.map(\.track.title) }

    private func jump(_ player: PlayerController, to title: String) throws {
        player.jump(to: try #require(player.queue.first { $0.track.title == title }?.id))
    }

    @Test("Jumping past songs in Playing Next leaves them behind the song playing, as the Mac's Up Next does (the phone remote jumps the same way)")
    func jumpingPastPlayingNextSongs() throws {
        try fixture { player, album, x, y in
            player.play(album)
            player.playNext([x, y])
            #expect(titles(player.playingNext) == ["X", "Y"])
            try jump(player, to: "Y")
            #expect(player.current?.track.title == "Y")
            // X had its turn (skipped): it is no longer upcoming; the rest of the album carries on.
            #expect(titles(player.upcoming) == ["S2", "S3", "S4", "S5"])
            #expect(titles(player.queue) == ["S1", "X", "Y", "S2", "S3", "S4", "S5"])
        }
    }

    @Test("Play Next goes ahead of what was added before; Add to Queue goes after it, both before the rest of the album")
    func playNextAndAddToQueuePlacement() throws {
        try fixture { player, album, x, y in
            player.play(album)
            player.addToQueue([x])
            player.addToQueue([y])
            #expect(titles(player.playingNext) == ["X", "Y"])
            #expect(titles(player.continuing) == ["S2", "S3", "S4", "S5"])
            var z = x; z.id = 8; z.title = "Z"; z.location = "/nowhere/Z.wav"; z.filePath = z.location
            player.playNext([z])
            #expect(titles(player.playingNext) == ["Z", "X", "Y"])
        }
    }

    @Test("Turning shuffle off during a song added with Play Next carries on with the album from where it was")
    func shuffleOffDuringAPlayNextSong() throws {
        try fixture { player, album, x, _ in
            player.play(album, startAt: 1)
            player.playNext([x])
            try jump(player, to: "X")
            player.shuffle = true
            #expect(player.current?.track.title == "X")
            #expect(Set(titles(player.upcoming)) == ["S1", "S2", "S3", "S4", "S5"])

            player.shuffle = false
            #expect(titles(player.queue) == ["S1", "S2", "X", "S3", "S4", "S5"])
            #expect(player.current?.track.title == "X")
            #expect(titles(player.upcoming) == ["S3", "S4", "S5"])
        }
    }

    @Test("The same when shuffle was already on as the album started")
    func shuffleOffDuringAPlayNextSongOfAShuffledAlbum() throws {
        try fixture { player, album, x, _ in
            player.shuffle = true
            player.play(album, startAt: 1)
            #expect(player.current?.track.title == "S2")
            player.playNext([x])
            try jump(player, to: "X")

            player.shuffle = false
            #expect(titles(player.queue) == ["S1", "S2", "X", "S3", "S4", "S5"])
            #expect(titles(player.upcoming) == ["S3", "S4", "S5"])
        }
    }

    @Test("A Play Next song that has played doesn't play again after shuffle is turned on and off")
    func aPlayedPlayNextSongIsNotQueuedAgain() throws {
        try fixture { player, album, x, _ in
            player.play(album)
            player.playNext([x])
            try jump(player, to: "X")
            try jump(player, to: "S2")

            player.shuffle = true
            #expect(player.current?.track.title == "S2")
            #expect(Set(titles(player.upcoming)) == ["S1", "S3", "S4", "S5"])

            player.shuffle = false
            #expect(titles(player.queue) == ["S1", "X", "S2", "S3", "S4", "S5"])
            #expect(player.current?.track.title == "S2")
            #expect(titles(player.upcoming) == ["S3", "S4", "S5"])
        }
    }

    @Test("Songs still waiting in Playing Next come next, in their order, with shuffle on and off again")
    func playingNextStaysNext() throws {
        try fixture { player, album, x, y in
            player.play(album, startAt: 1)
            player.playNext([x])
            player.addToQueue([y])

            player.shuffle = true
            #expect(player.current?.track.title == "S2")
            #expect(titles(player.playingNext) == ["X", "Y"])
            #expect(Set(titles(player.continuing)) == ["S1", "S3", "S4", "S5"])

            player.shuffle = false
            #expect(titles(player.queue) == ["S1", "S2", "X", "Y", "S3", "S4", "S5"])
            #expect(player.current?.track.title == "S2")
        }
    }
}
