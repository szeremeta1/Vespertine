//
// Vespertine: explicit TIDAL downloads: one track at a time with a pause of 1–3 s between tracks, a `.partial` file renamed when
// complete, tags including TIDAL_TRACK_ID, per-track failures, and a backoff that pauses the queue and resumes it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary
@testable import VespertineTidal

/// A CDN with `/audio/<id>.flac` for each track and a TIDAL API that resolves track `<id>` to it.
private final class DownloadRig: @unchecked Sendable {
    let server: FakeHTTPServer
    let clock = TestClock()
    let folder: URL
    let sleeps = Locked<[TimeInterval]>([])
    /// Track ids whose playback info is a 404.
    let failing = Locked<Set<Int>>([])
    /// How many playback-info requests answer 429 before the rest go through.
    let rateLimited = Locked(0)
    let dash = Locked(false)
    let transport: FakeTransport
    let database: LibraryDatabase

    init(ids: [Int]) throws {
        let server = try FakeHTTPServer()
        self.server = server
        let source = try DASHFixture.source()
        for id in ids { server.serve("/audio/\(id).flac", source) }
        server.serve("/dash/init.mp4", try DASHFixture.initSegment())
        let chunks = try DASHFixture.chunks()
        for (index, chunk) in chunks.enumerated() { server.serve("/dash/\(index + 1).m4s", chunk) }
        folder = try DASHFixture.temporaryDirectory("tidal-downloads")
        database = try LibraryDatabase.inMemory()
        let failing = failing, rateLimited = rateLimited, dash = dash
        transport = FakeTransport { request in
            let parts = request.url?.path.split(separator: "/") ?? []
            let id = parts.firstIndex(of: "tracks").flatMap { parts.indices.contains($0 + 1) ? Int(parts[$0 + 1]) : nil } ?? 0
            let limited = rateLimited.value > 0
            if limited { rateLimited.mutate { $0 -= 1 }; return FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "120"]) }
            if failing.value.contains(id) { return FakeResponse(status: 404, json: #"{"status":404,"userMessage":"Not found"}"#) }
            if dash.value { return dashPlaybackInfo(server: server, segments: chunks.count) }
            return btsPlaybackInfo(url: server.url("/audio/\(id).flac"))
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func downloader(catalog: FakeCatalog = FakeCatalog()) -> TidalDownloader {
        let gate = makeSignedInGate(transport: transport, clock: clock)
        let sleeps = sleeps, clock = clock
        return TidalDownloader(resolver: TidalStreamResolver(gate: gate), catalog: catalog, database: database, folder: folder,
                               sleep: { seconds in sleeps.mutate { $0.append(seconds) }; clock.advance(seconds) },
                               random: { Double.random(in: $0) }, fetchCover: { _ in nil })
    }

    func path(_ id: Int, artist: String = "Artist", album: String = "Album", title: String? = nil) -> URL {
        folder.appendingPathComponent(artist).appendingPathComponent(album)
            .appendingPathComponent(String(format: "1-%02d %@.flac", id, title ?? "Track \(id)"))
    }
}

@MainActor
private func finished(_ downloader: TidalDownloader, timeout: Double = 20) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if downloader.items.allSatisfy({ if case .done = $0.state { true } else if case .failed = $0.state { true } else { false } }) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite("TIDAL downloads")
@MainActor
struct TidalDownloaderTests {
    @Test("Tracks download one at a time, with a pause of 1–3 s between them, to <folder>/Artist/Album/1-01 Title.flac")
    func sequential() async throws {
        let rig = try DownloadRig(ids: [1, 2, 3])
        let downloader = rig.downloader()
        downloader.enqueue(tracks: [tidalTrack(1), tidalTrack(2), tidalTrack(3)])
        #expect(downloader.items.map(\.id) == [1, 2, 3])
        #expect(await finished(downloader))
        for id in 1...3 {
            #expect(downloader.items[id - 1].state == .done(rig.path(id)))
            #expect(FileManager.default.fileExists(atPath: rig.path(id).path))
        }
        // The CDN never served two tracks at once: every request of a track ended before the next track's first began.
        let requests = rig.server.requests.filter { $0.path.hasPrefix("/audio/") }
        for id in 1...2 {
            let this = requests.filter { $0.path == "/audio/\(id).flac" }, next = requests.filter { $0.path == "/audio/\(id + 1).flac" }
            let ended = try #require(this.map(\.finished).max()), began = try #require(next.map(\.started).min())
            #expect(ended <= began, "track \(id) overlapped track \(id + 1)")
        }
        let pauses = rig.sleeps.value
        #expect(pauses.count == 2 && pauses.allSatisfy { (1...3).contains($0) }, "\(pauses)")
        // The library knows nothing of these tracks yet: no row was invented (see the linking test).
        #expect(try rig.database.tidalTrackIds().isEmpty)
    }

    @Test("While a track downloads it is a .partial file; once done there is none, and the tags read back include TIDAL_TRACK_ID")
    func partialAndTags() async throws {
        let rig = try DownloadRig(ids: [7])
        rig.server.throttle(400_000)   // about 1.2 s for the file
        let downloader = rig.downloader()
        downloader.enqueue(tracks: [tidalTrack(7, title: "Seven: Live/Edit", artist: "The Band", albumTitle: "Live")])
        let final = rig.folder.appendingPathComponent("The Band/Live/1-07 Seven- Live-Edit.flac")
        let partial = final.appendingPathExtension("partial")
        var sawPartial = false
        let end = Date().addingTimeInterval(10)
        while Date() < end, !sawPartial {
            sawPartial = FileManager.default.fileExists(atPath: partial.path)
            if case .downloading(let fraction) = downloader.items[0].state { #expect((0...1).contains(fraction)) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawPartial)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(await finished(downloader))
        #expect(downloader.items[0].state == .done(final))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: rig.folder.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)

        let tags = try MetadataReader.read(url: final, artwork: nil)
        #expect(tags.extraTags["TIDAL_TRACK_ID"] == "7")
        #expect(tags.title == "Seven: Live/Edit" && tags.artist == "The Band" && tags.album == "Live" && tags.trackNumber == 7 && tags.discNumber == 1)
        #expect(tags.isrc == "XX7")
        #expect(tags.rgTrackGain == -7)
        // The audio is the stream's, byte for byte after the tags.
        let decoded = try DASHFixture.decode(final), source = try DASHFixture.decode(DASHFixture.directory().appendingPathComponent("source.flac"))
        #expect(decoded.bytes == source.bytes)
    }

    @Test("A DASH track is remuxed into the FLAC file")
    func dashDownload() async throws {
        let rig = try DownloadRig(ids: [])
        rig.dash.mutate { $0 = true }
        let downloader = rig.downloader()
        downloader.enqueue(tracks: [tidalTrack(5)])
        #expect(await finished(downloader))
        #expect(downloader.items[0].state == .done(rig.path(5)))
        let decoded = try DASHFixture.decode(rig.path(5)), source = try DASHFixture.decode(DASHFixture.directory().appendingPathComponent("source.flac"))
        #expect(decoded.frames == source.frames && decoded.bytes == source.bytes)
    }

    @Test("A failure on track 2 of 3 is reported on that track, and track 3 still downloads")
    func failureContinues() async throws {
        let rig = try DownloadRig(ids: [1, 2, 3])
        rig.failing.mutate { $0 = [2] }
        let downloader = rig.downloader()
        downloader.enqueue(tracks: [tidalTrack(1), tidalTrack(2), tidalTrack(3)])
        #expect(await finished(downloader))
        #expect(downloader.items[0].state == .done(rig.path(1)))
        guard case .failed(let message) = downloader.items[1].state else { Issue.record("track 2: \(downloader.items[1].state)"); return }
        #expect(!message.isEmpty)
        #expect(downloader.items[2].state == .done(rig.path(3)))
    }

    @Test("A backoff pauses the queue with its reason, and it resumes by itself when the backoff ends")
    func backoff() async throws {
        let rig = try DownloadRig(ids: [1])
        rig.rateLimited.mutate { $0 = 1 }
        let gate = makeSignedInGate(transport: rig.transport, clock: rig.clock)
        let seen = Locked<[String]>([])
        let box = Locked<TidalDownloader?>(nil)
        let downloader = TidalDownloader(resolver: TidalStreamResolver(gate: gate), catalog: FakeCatalog(), database: rig.database,
                                         folder: rig.folder, sleep: { [clock = rig.clock] seconds in
            // What the queue shows while it waits.
            let state = await MainActor.run { box.value.map { "\($0.items[0].state)" } ?? "-" }
            seen.mutate { $0.append("\(Int(seconds)) \(state)") }
            clock.advance(seconds)
        }, random: { $0.lowerBound }, fetchCover: { _ in nil })
        box.mutate { $0 = downloader }
        downloader.enqueue(tracks: [tidalTrack(1)])
        #expect(await finished(downloader))
        #expect(downloader.items[0].state == .done(rig.path(1)))
        let waits = seen.value
        #expect(waits.count == 1 && waits[0].hasPrefix("120 paused(\"TIDAL asked us to wait 2 min"), "\(waits)")
    }

    @Test("A queued track can be cancelled; an album and a playlist enqueue their tracks in order")
    func cancelAndCollections() async throws {
        let rig = try DownloadRig(ids: [1, 2, 3, 4])
        let catalog = FakeCatalog()
        catalog.albumContents = [9: [tidalTrack(1), tidalTrack(2)]]
        catalog.playlistContents = ["pl": [tidalTrack(3), tidalTrack(4)]]
        let downloader = rig.downloader(catalog: catalog)
        await downloader.enqueue(album: 9)
        await downloader.enqueue(playlist: "pl")
        #expect(downloader.items.map(\.id) == [1, 2, 3, 4])
        downloader.cancel(3)
        #expect(downloader.items.map(\.id) == [1, 2, 4])
        #expect(await finished(downloader))
        #expect(!FileManager.default.fileExists(atPath: rig.path(3).path))
        #expect(catalog.log == ["albumTracks 9", "playlistTracks pl"])
    }

    @Test("A downloaded track in the library is linked to its file")
    func linksLibraryRow() async throws {
        let rig = try DownloadRig(ids: [1])
        let source = try #require(try rig.database.tidalSource(userId: 4242).id)
        try rig.database.upsertTidalTracks([TidalTrackInput(tidalTrack(1))], sourceId: source)
        let downloader = rig.downloader()
        downloader.enqueue(tracks: [tidalTrack(1)])
        #expect(await finished(downloader))
        let record = try #require(try await rig.database.writer.read { try TidalTrackRecord.filter(Column("tidalId") == 1).fetchOne($0) })
        #expect(record.downloadPath == rig.path(1).path)
    }
}
