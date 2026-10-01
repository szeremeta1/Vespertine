//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Network shares")
struct NetworkTests {
    @Test("Share addresses parse the way people type them")
    func parsing() throws {
        let a = try #require(NetworkShare(string: "smb://nas.local/Music/Hi-Res Albums"))
        #expect(a.kind == .smb && a.host == "nas.local" && a.share == "Music" && a.subpath == "Hi-Res Albums" && a.user == nil)
        #expect(a.mountURL.absoluteString == "smb://nas.local/Music")
        #expect(a.defaultName == "Hi-Res Albums")

        let b = try #require(NetworkShare(string: #"\\server\share\folder\sub"#))
        #expect(b.kind == .smb && b.host == "server" && b.share == "share" && b.subpath == "folder/sub")

        let c = try #require(NetworkShare(string: "music@100.64.1.2/media"))
        #expect(c.user == "music" && c.host == "100.64.1.2" && c.share == "media" && c.subpath.isEmpty)
        #expect(c.urlString == "smb://music@100.64.1.2/media")

        let d = try #require(NetworkShare(string: "nfs://nas.tail1234.ts.net/volume1/music"))
        #expect(d.kind == .nfs && d.share == "volume1/music" && d.defaultPort == 2049)

        let e = try #require(NetworkShare(string: "https://dav.example.com/remote.php/music"))
        #expect(e.kind == .webdav && e.secure && e.defaultPort == 443)

        // Round trip through what the library stores.
        let f = try #require(NetworkShare(string: a.urlString))
        #expect(f == a)
        #expect(NetworkShare(string: "") == nil)
        #expect(NetworkShare(string: "ftp://host/x") == nil)
    }

    @Test("Blocking share work never holds the caller past its deadline")
    func blockingDeadline() async {
        // A wedged mount: the work doesn't return for seconds. The caller gets the fallback at the deadline.
        let start = Date()
        let stuck = await NetworkVolume.blocking(timeout: 0.2, otherwise: "fallback") { Thread.sleep(forTimeInterval: 3); return "late" }
        #expect(stuck == "fallback")
        #expect(Date().timeIntervalSince(start) < 1.5)
        // Work that finishes in time returns its own result.
        #expect(await NetworkVolume.blocking(timeout: 5, otherwise: 0) { 42 } == 42)
        // Main-actor callers aren't blocked meanwhile: the work runs on a GCD thread.
        let onMain = await MainActor.run { Thread.isMainThread }
        #expect(onMain)
        let workerIsMain = await NetworkVolume.blocking(timeout: 5, otherwise: true) { Thread.isMainThread }
        #expect(!workerIsMain)
    }

    @Test("Network reads are spread across folders")
    func interleaving() {
        let urls = ["/a/1", "/a/2", "/a/3", "/b/1", "/c/1", "/c/2"].map { URL(fileURLWithPath: $0) }
        let order = LibraryScanner.interleavedByFolder(urls).map(\.path)
        #expect(order == ["/a/1", "/b/1", "/c/1", "/a/2", "/c/2", "/a/3"])
    }

    @Test("Relinking a share keeps tracks and library state")
    func relink() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/old/mount/Music", mode: .reference, remoteURL: "smb://h/Music"))
        try db.writer.write { db in
            var t = Track.stub(path: "/old/mount/Music/Artist/01 Song.flac")
            t.sourceId = source.id
            t.playCount = 7
            try t.insert(db)
        }
        try db.relinkSource(source.id!, to: "/Volumes/Music")
        let track = try #require(try db.allTracks().first)
        #expect(track.filePath == "/Volumes/Music/Artist/01 Song.flac")
        #expect(track.location == track.filePath)
        #expect(track.playCount == 7)
        #expect(try db.sources().first?.path == "/Volumes/Music")
    }

    @Test("Fast network tag reading matches a direct read", arguments: ["flac", "m4a", "wav", "aiff"])
    func fastReadMatches(ext: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.\(ext)")
        try Self.writeAudio(url, seconds: 3)

        let db = try LibraryDatabase.inMemory()
        let art = ArtworkStore(directory: dir.appendingPathComponent(".art"))
        let scanner = LibraryScanner(database: db, artwork: art)
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak"))
        let track = try #require(try db.allTracks().first)
        _ = try await writer.apply(TagEdit(fields: [.title: "Night Train", .artist: "The Testers", .album: "Rails",
                                                    .genre: "Jazz", .releaseDate: "1987", .trackNumber: "3"]), to: [track])

        let size = Int64(try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let shadow = dir.appendingPathComponent("shadow").appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reads = try RemoteMetadata.makeShadow(of: url, size: size, at: shadow)
        #expect(reads <= 4)
        let fast = try MetadataReader.read(url: shadow, artwork: nil, original: url)
        let direct = try MetadataReader.read(url: url, artwork: nil)
        #expect(fast.title == direct.title && fast.title == "Night Train")
        #expect(fast.artist == direct.artist && fast.album == direct.album && fast.genre == direct.genre)
        #expect(fast.year == direct.year && fast.trackNumber == direct.trackNumber)
        #expect(fast.codec == direct.codec && fast.sampleRate == direct.sampleRate && fast.bitDepth == direct.bitDepth)
        #expect(abs(fast.duration - direct.duration) < 0.05)
    }

    @Test("Cache copies, finds, evicts and keeps offline copies")
    func cache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-cache-\(UUID().uuidString)")
        let remote = dir.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var tracks: [Track] = []
        for i in 0..<3 {
            let url = remote.appendingPathComponent("\(i).flac")
            try Data(repeating: UInt8(i), count: 1_000_000).write(to: url)
            var t = Track.stub(path: url.path)
            t.fileSize = 1_000_000
            tracks.append(t)
        }
        let cache = NetworkCache(directory: dir.appendingPathComponent("cache"), limitBytes: 2_500_000)
        cache.request([tracks[0]], offline: true)
        cache.request([tracks[1], tracks[2]])
        for _ in 0..<200 where cache.usage().downloading + cache.usage().queued > 0 { try await Task.sleep(for: .milliseconds(20)) }
        let usage = cache.usage()
        #expect(usage.offlineFiles == 1 && usage.cachedFiles == 2)
        let local = try #require(cache.localURL(forKey: NetworkCache.key(for: tracks[1])))
        #expect(try Data(contentsOf: local) == Data(repeating: 1, count: 1_000_000))

        // Over the limit: least recently used cached copy goes; the offline copy stays.
        cache.limitBytes = 1_500_000
        #expect(cache.usage().cachedFiles == 1)
        #expect(cache.isOffline(tracks[0]))
        #expect(cache.localURL(forKey: NetworkCache.key(for: tracks[2])) == nil)

        // A changed file on the share is a different copy.
        var edited = tracks[1]
        edited.fileSize += 1
        #expect(NetworkCache.key(for: edited) != NetworkCache.key(for: tracks[1]))

        cache.clear(includingOffline: true)
        #expect(cache.usage() == NetworkCache.Usage())
    }

    @Test("Copies of songs skipped past stop; queued ones are dropped; Keep Offline copies carry on")
    func cacheKeepOnly() async throws {
        signal(SIGPIPE, SIG_IGN)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-cache-\(UUID().uuidString)")
        let remote = dir.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var tracks: [Track] = []
        for i in 0..<4 {
            let url = remote.appendingPathComponent("\(i).flac")
            try Data(repeating: UInt8(i), count: 100_000).write(to: url)
            var t = Track.stub(path: url.path)
            t.fileSize = 100_000
            tracks.append(t)
        }
        // A file that arrives only as fast as the test writes it: a slow share.
        let pipe = remote.appendingPathComponent("slow.flac")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        var slow = Track.stub(path: pipe.path)
        slow.fileSize = 8_000_000
        let cache = NetworkCache(directory: dir.appendingPathComponent("cache"), limitBytes: 100_000_000)
        cache.maxConcurrentDownloads = 1
        cache.request([slow, tracks[0], tracks[1]])
        cache.request([tracks[3]], offline: true)
        let path = pipe.path
        let writer = await Task.detached { open(path, O_WRONLY) }.value
        #expect(writer >= 0)
        defer { close(writer) }
        let chunk = [UInt8](repeating: 7, count: 65_536)
        #expect(write(writer, chunk, chunk.count) == chunk.count)
        #expect(cache.usage().downloading == 1 && cache.usage().queued == 3)

        // Skipped on: only tracks[1] is still wanted (and the offline copy, which isn't the player's to drop).
        cache.keepOnly([tracks[1]])
        #expect(cache.usage().queued == 2)
        _ = write(writer, chunk, chunk.count)   // a stalled read returns and sees it (or it already stopped: EPIPE)
        for _ in 0..<200 where cache.usage().downloading + cache.usage().queued > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cache.localURL(forKey: NetworkCache.key(for: slow)) == nil)
        #expect(cache.localURL(forKey: NetworkCache.key(for: tracks[0])) == nil)
        #expect(cache.localURL(forKey: NetworkCache.key(for: tracks[1])) != nil)
        #expect(cache.isOffline(tracks[3]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("cache").path)
        #expect(!leftovers.contains { $0.hasSuffix(".partial") })
    }

    static func writeAudio(_ url: URL, seconds: Double) throws {
        var settings: [String: Any] = [AVSampleRateKey: 96_000.0, AVNumberOfChannelsKey: 2]
        switch url.pathExtension {
        case "flac": settings[AVFormatIDKey] = kAudioFormatFLAC; settings[AVEncoderBitDepthHintKey] = 24
        case "m4a": settings[AVFormatIDKey] = kAudioFormatAppleLossless; settings[AVEncoderBitDepthHintKey] = 24
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            if url.pathExtension == "aiff" { settings[AVLinearPCMIsBigEndianKey] = true }
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(96_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = 0.25 * sin(Float(i) * 2 * .pi * 440 / 96_000) }
        }
        try file.write(from: buffer)
    }
}

extension Track {
    static func stub(path: String) -> Track {
        Track(id: nil, sourceId: nil, location: path, filePath: path, fileSize: 0, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
              addedAt: .now, codec: "FLAC", isLossless: true, isDSD: false, sampleRate: 96_000, bitDepth: 24, channels: 2,
              duration: 180, bitrate: nil, cueStartFrame: nil, cueFrameLength: nil, title: URL(fileURLWithPath: path).lastPathComponent,
              artist: nil, album: nil, albumArtist: nil, composer: nil, genre: nil, releaseDate: nil, year: nil,
              trackNumber: nil, trackTotal: nil, discNumber: nil, discTotal: nil, compilation: false, grouping: nil,
              comment: nil, lyrics: nil, bpm: nil, rating: nil, isrc: nil, label: nil, musicBrainzReleaseID: nil,
              musicBrainzRecordingID: nil, titleSort: nil, artistSort: nil, albumSort: nil, albumArtistSort: nil,
              extraTags: [:], rgTrackGain: nil, rgTrackPeak: nil, rgAlbumGain: nil, rgAlbumPeak: nil, artworkKey: nil,
              playCount: 0, lastPlayedAt: nil, isMissing: false, effectiveBitDepth: nil, bandwidthHz: nil, analysisVerdict: nil)
    }
}
