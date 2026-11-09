//
// Vespertine: CUE sheets inside FLAC files, and Matroska files with several audio streams, in the library.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
import VespertineAudio
@testable import VespertineLibrary

@Suite("Embedded CUE and container streams in the library")
struct ContainerLibraryTests {
    /// The audio tests' fixtures: they are plain files in the package's source tree.
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VespertineAudioTests/Fixtures/Formats/\(name)")
    }

    private func library(_ files: [(fixture: String, as: String)]) async throws -> (dir: URL, db: LibraryDatabase, scanner: LibraryScanner, source: LibrarySource) {
        let dir = try tempDir()
        for file in files { try FileManager.default.copyItem(at: Self.fixture(file.fixture), to: dir.appendingPathComponent(file.as)) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)   // the fixtures are one-second clips
        return (dir, db, scanner, try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
    }

    @Test("A FLAC CUESHEET block splits the file into its tracks, at the sample the block says")
    func cueBlock() async throws {
        let (dir, db, scanner, source) = try await library([("cue-block.flac", "Album.flac")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = try await scanner.scan(source)
        #expect(summary.added == 2 && summary.failed.isEmpty)
        let tracks = try db.allTracks().sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        let path = dir.appendingPathComponent("Album.flac").resolvingSymlinksInPath().path
        #expect(tracks.map(\.location) == [path + "#1", path + "#2"])
        // The block holds sample offsets: 37 frames of 1/75 s at 48 kHz, exact without going through CD frames.
        #expect(tracks.map(\.cueStartFrame) == [0, 23_680])
        #expect(tracks.map(\.cueFrameLength) == [23_680, 48_000 - 23_680])
        #expect(tracks.map(\.trackTotal) == [2, 2] && tracks.allSatisfy { $0.codec == "FLAC" && $0.channels == 2 && $0.filePath == path })
        // Unchanged on the next scan.
        let again = try await scanner.scan(source)
        #expect(again.added == 0 && again.updated == 0 && again.missing == 0 && again.failed.isEmpty)
        #expect(try db.allTracks().count == 2)
    }

    @Test("A CUESHEET tag gives the tracks their titles and the album its name")
    func cueTag() async throws {
        let (dir, db, scanner, source) = try await library([("cue-tag.flac", "Embedded Album.flac")])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await scanner.scan(source)
        let tracks = try db.allTracks().sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(tracks.map(\.title) == ["First", "Second"])
        #expect(tracks.allSatisfy { $0.album == "Embedded Album" && $0.artist == "Nocturne Test" })
        #expect(tracks.map(\.cueStartFrame) == [0, 37 * 640])
        let again = try await scanner.scan(source)
        #expect(again.added == 0 && again.updated == 0 && again.missing == 0)
    }

    @Test("A file with no sheet inside is one track, and an external sheet still wins")
    func noEmbeddedSheet() async throws {
        let (dir, db, scanner, source) = try await library([("stereo24.flac", "Plain.flac")])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await scanner.scan(source)
        #expect(try db.allTracks().count == 1)
        #expect(EmbeddedCue.sheet(for: Self.fixture("stereo24.flac"), tags: [:]) == nil)
        #expect(EmbeddedCue.sheet(for: Self.fixture("cue-block.flac"), tags: [:])?.files.first?.tracks.count == 2)
        // A sheet of one track, or with starts out of order, isn't a split.
        let one = "FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
        let backwards = "FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:10:00\n  TRACK 02 AUDIO\n    INDEX 01 00:05:00\n"
        #expect(EmbeddedCue.sheet(for: Self.fixture("stereo24.flac"), tags: ["CUESHEET": one]) == nil)
        #expect(EmbeddedCue.sheet(for: Self.fixture("stereo24.flac"), tags: ["CUESHEET": backwards]) == nil)
    }

    /// A FLAC file's metadata only (no audio frames): STREAMINFO at 48 kHz, then a CUESHEET block with these tracks,
    /// each (offset in samples, its index 01 offset from there). The lead-out (track 170) ends the list.
    static func cueBlockFLAC(_ tracks: [(offset: UInt64, index: UInt64)]) -> Data {
        func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64(n - 1 - $0))) } }
        var info = [UInt8](repeating: 0, count: 34)
        info[10] = 0x0B; info[11] = 0xB8; info[12] = 0x02             // 48 000 Hz, 2 channels
        var cue = [UInt8](repeating: 0, count: 395) + [UInt8(tracks.count + 1)]
        for (i, t) in tracks.enumerated() {
            cue += be(t.offset, 8) + [UInt8(i + 1)] + [UInt8](repeating: 0, count: 26) + [1]   // audio, one index
            cue += be(t.index, 8) + [1, 0, 0, 0]
        }
        cue += be(48_000, 8) + [170] + [UInt8](repeating: 0, count: 26) + [0]
        return Data(Array("fLaC".utf8) + [0x00] + be(34, 3) + info + [0x85] + be(UInt64(cue.count), 3) + cue)
    }

    @Test("A FLAC CUESHEET block whose offsets add up past 64 bits is ignored, not a crash")
    func cueBlockOverflow() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("Good.flac"), bad = dir.appendingPathComponent("Bad.flac")
        try Self.cueBlockFLAC([(0, 0), (23_000, 680)]).write(to: good)
        try Self.cueBlockFLAC([(0, 0), (0xFFFF_FFFF_FFFF_FFF0, 0x100)]).write(to: bad)
        #expect(EmbeddedCue.flacBlock(good)?.files.first?.tracks.map(\.startSample) == [0, 23_680])
        #expect(EmbeddedCue.flacBlock(bad) == nil)
    }

    @Test("A Matroska file with two audio streams lists a track for each, with its own format and layout")
    func streams() async throws {
        let (dir, db, scanner, source) = try await library([("two-streams.mka", "Two.mka"), ("flac-stereo.mka", "One.mka"), ("opus-51.webm", "Opus.webm")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = try await scanner.scan(source)
        #expect(summary.added == 4 && summary.failed.isEmpty)
        let two = try db.allTracks().filter { $0.filePath.hasSuffix("Two.mka") }.sorted { $0.channels < $1.channels }
        #expect(two.map(\.channels) == [2, 6] && two.map(\.bitDepth) == [24, 16] && two.allSatisfy { $0.codec == "FLAC" && $0.isLossless })
        #expect(two.map(\.audioStream) == [0, 1])
        #expect(two.map { $0.location.components(separatedBy: "#").last } == ["audio-0", "audio-1"])
        #expect(two[0].title == two[1].title, "different layouts are versions of one song")
        #expect(TrackVersions.group(two).count == 1)
        #expect(TrackVersions.choose(TrackVersions.group(two)[0], multichannel: true)?.audioStream == 1)
        #expect(TrackVersions.choose(TrackVersions.group(two)[0], multichannel: false)?.audioStream == 0)
        // One stream: the file's own location, no suffix.
        let one = try db.allTracks().filter { $0.filePath.hasSuffix("One.mka") }
        #expect(one.count == 1 && one[0].location == one[0].filePath && one[0].audioStream == nil && one[0].codec == "FLAC" && one[0].bitDepth == 24)
        let opus = try #require(try db.allTracks().first { $0.filePath.hasSuffix("Opus.webm") })
        #expect(opus.codec == "Opus" && !opus.isLossless && opus.channels == 6)
        // Unchanged on the next scan.
        let again = try await scanner.scan(source)
        #expect(again.added == 0 && again.updated == 0 && again.missing == 0)
    }

    @Test("Two streams with the same layout are told apart by their titles")
    func sameLayout() {
        let base = Track.stub(path: "/m/film.mka")
        func stream(_ i: Int, _ title: String?, _ lang: String?) -> ContainerAudioStream {
            ContainerAudioStream(index: i, codec: "AAC", channels: 2, sampleRate: 48_000, bits: nil, title: title, language: lang, isDefault: i == 0, lossless: false)
        }
        let tracks = ContainerStreamTracks.split(base, url: URL(fileURLWithPath: "/m/film.mka"), streams: [stream(1, nil, "eng"), stream(2, "Commentary", "eng")])
        #expect(tracks.map(\.title) == ["\(base.title) (ENG)", "\(base.title) (Commentary)"])
        #expect(tracks.map(\.location) == ["/m/film.mka#audio-1", "/m/film.mka#audio-2"])
        #expect(AudioStreamRef(location: "/m/film.mka#audio-2")?.index == 2)
        #expect(AudioStreamRef(location: "/m/film.mka#2") == nil && AudioStreamRef(location: "/m/film.mka") == nil && AudioStreamRef(location: "/m/a#b#audio-x") == nil)
    }

    @Test("Matroska audio rows from before this upgrade are read again, with their real codec")
    func migration() async throws {
        let (dir, db, scanner, source) = try await library([("flac-stereo.mka", "Old.mka")])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await scanner.scan(source)
        // As 0.15.0 had listed it: described as DTS.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE track SET codec = 'DTS', isLossless = 0, bitDepth = NULL")
        }
        #expect(try db.allTracks().first?.codec == "DTS")
        // The upgrade's migration marks .mka rows stale: simulated by what it does.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE track SET modifiedAt = '1970-01-01 00:00:00.000' WHERE lower(filePath) LIKE '%.mka'")
        }
        let summary = try await scanner.scan(source)
        #expect(summary.updated == 1)
        let track = try #require(try db.allTracks().first)
        #expect(track.codec == "FLAC" && track.isLossless && track.bitDepth == 24)
    }
}
