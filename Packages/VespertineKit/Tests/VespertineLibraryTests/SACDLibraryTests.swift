//
// Vespertine — SACD images in the library: each song once, with a stereo and a 5.1 version, tagged from the disc.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
import VespertineTestSupport
@testable import VespertineLibrary

@Suite("SACD images in the library")
struct SACDLibraryTests {
    @Test("An SACD image lists each song once, with its stereo and 5.1 versions; other disc images are left alone")
    func scan() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = [SACDFixture.TrackSpec(title: "Prélude", performer: "Ana Ruiz", isrc: "USXYZ0300001", frames: 3),
                      SACDFixture.TrackSpec(title: "Coda", frames: 2)]
        let iso = dir.appendingPathComponent("Night Studies.iso")
        try SACDFixture.write(to: iso,
                              stereo: .init(channels: 2, dst: false, planes: SACDFixture.modulate(channels: 2, frames: 5), tracks: tracks),
                              multichannel: .init(channels: 6, dst: false, planes: SACDFixture.modulate(channels: 6, frames: 5), tracks: tracks))
        try Data(repeating: 0, count: 600 * 2048).write(to: dir.appendingPathComponent("installer.iso"))

        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        let summary = try await scanner.scan(source)
        #expect(summary.added == 4 && summary.failed.isEmpty)

        let all = try db.allTracks().sorted { ($0.channels, $0.trackNumber ?? 0) < ($1.channels, $1.trackNumber ?? 0) }
        #expect(all.map(\.location) == ["#2ch-1", "#2ch-2", "#mch-1", "#mch-2"].map { iso.path + $0 })
        #expect(all.map(\.sacdArea) == [.stereo, .stereo, .multichannel, .multichannel])
        let first = all[0]
        #expect(first.title == "Prélude" && first.artist == "Ana Ruiz" && first.albumArtist == "The Vesper Quartet")
        #expect(first.album == "Night Studies" && first.genre == "Rock" && first.year == 2003 && first.releaseDate == "2003-03-01")
        #expect(first.isrc == "USXYZ0300001" && first.label == "Fixture Records" && first.extraTags["CATALOGNUMBER"] == "FXR-1001")
        #expect(first.codec == "SACD" && first.isDSD && first.isLossless && first.formatSummary == "DSD64")
        #expect(all[1].artist == "The Vesper Quartet" && all[1].genre == "Jazz" && all[1].trackTotal == 2)
        #expect(all[3].formatSummary == "DSD64 · 5.1" && all[3].formatMark?.text == "DSD 64")
        #expect(first.cueStartFrame == 0 && all[1].cueStartFrame == 3 * 37_632 && all[1].cueFrameLength == 2 * 37_632)
        #expect(abs(all[1].duration - 2.0 / 75) < 1e-9)
        // Read-only on disk: edits stay in the library.
        #expect(MusicFinder.keepsInLibrary(first))

        let albums = try db.albums()
        #expect(albums.count == 1)
        let album = try #require(albums.first)
        #expect(album.title == "Night Studies" && album.maxChannels == 6 && album.isDSD)
        #expect(album.totalSize == Int64(try iso.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        let songs = TrackVersions.group(all)
        #expect(songs.count == 2 && songs.allSatisfy { $0.count == 2 })
        #expect(TrackVersions.choose(songs[0], multichannel: true)?.sacdArea == .multichannel)
        #expect(TrackVersions.choose(songs[0], multichannel: false)?.sacdArea == .stereo)

        // Unchanged on the next scan; a track the image no longer has is missing.
        let again = try await scanner.scan(source)
        #expect(again.added == 0 && again.updated == 0 && again.missing == 0)
        try SACDFixture.write(to: iso,
                              stereo: .init(channels: 2, dst: false, planes: SACDFixture.modulate(channels: 2, frames: 3), tracks: [tracks[0]]))
        let third = try await scanner.scan(source)
        #expect(third.missing == 3 && third.updated == 1)
        #expect(try db.allTracks().filter { !$0.isMissing }.map(\.location) == [iso.path + "#2ch-1"])
    }

    @Test("Import & Organize files an SACD image under its disc's artist and title, under its own name")
    func organize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("src").appendingPathComponent("NS-SACD.iso")
        try FileManager.default.createDirectory(at: iso.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SACDFixture.write(to: iso, stereo: .init(channels: 2, dst: false, planes: SACDFixture.modulate(channels: 2, frames: 2),
                                                     tracks: [.init(title: "One", frames: 2)]))
        let written = try Importer.copyAndOrganize([iso.deletingLastPathComponent()], into: dir.appendingPathComponent("lib"))
        #expect(written.map { Array($0.pathComponents.suffix(3)) } == [["The Vesper Quartet", "Night Studies", "NS-SACD.iso"]])
    }
}
