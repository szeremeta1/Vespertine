// Vespertine: tests for the queue following a share that comes back mounted at another path.
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Queue after a share remounts", .serialized) @MainActor
struct QueueRemountTests {
    @Test("Queued songs follow a share that comes back at a new path, the song playing included")
    func queueFollowsRemount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-remount-\(UUID())")
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one", "two", "three"] {
            let file = try AVAudioFile(forWriting: music.appendingPathComponent("\(name).wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100 * 50))
            buffer.frameLength = 44100 * 50
            try file.write(from: buffer)
        }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false })
        let source = try library.database.addSource(LibrarySource(path: music.standardizedFileURL.path, mode: .reference))
        let sourceID = try #require(source.id)
        await library.scan(source)
        let tracks = library.allTracks().sorted { $0.title < $1.title }
        try #require(tracks.count == 3)
        // Queue-only test: with the files gone nothing opens or plays on a real output.
        try FileManager.default.removeItem(at: music)

        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        defer { player.stop() }
        player.play(tracks)
        let ids = player.queue.map(\.id)
        let oldPaths = player.queue.map(\.item.url.path)

        // The share comes back mounted somewhere else, as connect() reports it.
        let newRoot = "/Volumes/Music Share"
        let oldRoot = music.standardizedFileURL.path
        try library.database.relinkSource(sourceID, to: newRoot)
        player.sourceRelinked(sourceID)

        #expect(player.queue.map(\.id) == ids, "entries keep their places and identities")
        #expect(player.queue.map(\.item.url.path) == oldPaths.map { newRoot + $0.dropFirst(oldRoot.count) })
        #expect(player.queue.allSatisfy { $0.track.filePath.hasPrefix(newRoot) })
        #expect(player.queue.map(\.item.trackID) == tracks.map(\.id), "same songs, same library rows")

        // Asking again, or about another source, changes nothing.
        let after = player.queue
        player.sourceRelinked(sourceID)
        player.sourceRelinked(sourceID + 100)
        #expect(player.queue == after)
    }
}
