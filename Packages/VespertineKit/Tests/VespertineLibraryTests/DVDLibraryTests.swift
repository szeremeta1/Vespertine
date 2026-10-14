//
// Vespertine — DVD-Video LPCM in the library: a VIDEO_TS folder and a disc image scan into one album per title,
// a track per chapter, played as exact sample ranges; menus, other IFOs and previews add nothing; rescans keep IDs.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
import VespertineAudio
import VespertineTestSupport
@testable import VespertineLibrary

@Suite("DVD-Video in the library")
struct DVDLibraryTests {
    static let format = DVDFixture.Format(bits: 24, rate: 96_000, channels: 2)

    static func vob(_ id: Int, seconds: Double, seed: Int, cells: [(id: Int, startPTM: Int64)]? = nil) -> DVDFixture.VOB {
        DVDFixture.VOB(vobID: id, format: format, firstPTS: 30_000,
                       samples: DVDFixture.samples(frames: Int(seconds * 96_000), format: format, seed: seed), cells: cells, lead: 20_000)
    }

    @Test("A VIDEO_TS folder and a two-title disc image become albums of LPCM tracks; rescans change nothing")
    func scan() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A VIDEO_TS folder: one VOB in two cells (two chapters), and a short preview cell at the end of chapter 2.
        let folderDisc = DVDFixture.disc(vobs: [Self.vob(1, seconds: 2, seed: 1, cells: [(1, 30_000), (2, 30_000 + 90_000 + 3003)]),
                                                Self.vob(2, seconds: 1, seed: 2)],
                                         titles: [[[0], [1, 2]]])
        let folder = dir.appendingPathComponent("Night Recital [LPCM 24-96]/VIDEO_TS")
        try DVDFixture.writeFolder(folderDisc.files, at: folder)
        // A disc image with two titles (two albums): two VOBs, then one.
        let imageDisc = DVDFixture.disc(vobs: [Self.vob(1, seconds: 1.5, seed: 3), Self.vob(2, seconds: 1, seed: 4), Self.vob(3, seconds: 2.5, seed: 5)],
                                        titles: [[[0], [1]], [[2]]])
        let iso = dir.appendingPathComponent("Two Albums.iso")
        try Data(DVDFixture.image(imageDisc.files)).write(to: iso)

        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        let summary = try await scanner.scan(source)
        #expect(summary.added == 5 && summary.failed.isEmpty)

        let all = try db.allTracks().sorted { $0.location < $1.location }
        let entry = folder.appendingPathComponent("VIDEO_TS.IFO").resolvingSymlinksInPath().path
        let folderTracks = all.filter { $0.filePath == entry }, imageTracks = all.filter { $0.filePath.hasSuffix("Two Albums.iso") }
        #expect(folderTracks.count == 2 && imageTracks.count == 3)
        #expect(all.allSatisfy { $0.dvdStream != nil && $0.sacdArea == nil && $0.codec == "LPCM" && $0.isLossless && !$0.isDSD })
        #expect(all.allSatisfy { $0.formatSummary == "LPCM · 24/96" && $0.channels == 2 && $0.artist == nil && $0.cueStartFrame != nil })
        #expect(folderTracks.allSatisfy(\.isDVDFolderTrack) && !imageTracks.contains(where: \.isDVDFolderTrack))
        #expect(all.allSatisfy(MusicFinder.keepsInLibrary))

        // The folder: the disc's name, two chapters split at the cell time, the preview left out.
        let f = folderTracks.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(f.map(\.album) == ["Night Recital [LPCM 24-96]", "Night Recital [LPCM 24-96]"])
        #expect(f.map(\.title) == ["Track 1", "Track 2"] && f.map(\.trackTotal) == [2, 2])
        #expect(f[0].cueStartFrame == 0 && f[1].cueStartFrame == 99_203)       // (90 000 + 3003) × 96/90, nearest sample
        #expect(f[0].cueFrameLength! + f[1].cueFrameLength! == 192_000)
        #expect(abs(f[1].duration - Double(192_000 - 99_203) / 96_000) < 1e-9)
        #expect(f.allSatisfy { $0.extraTags["DVD_TITLE"] == "1" })

        // The image: one album per title.
        let albums = Dictionary(grouping: imageTracks, by: { $0.album ?? "" })
        #expect(Set(albums.keys) == ["Two Albums · Title 1", "Two Albums · Title 2"])
        #expect(albums["Two Albums · Title 1"]?.count == 2 && albums["Two Albums · Title 2"]?.count == 1)
        #expect(albums["Two Albums · Title 2"]?.first?.cueFrameLength == 240_000)

        // Every track plays its exact samples through the source opener.
        for t in all {
            let item = PlayableItem(url: t.fileURL, regionStartFrame: t.cueStartFrame, regionFrameLength: t.cueFrameLength, dvd: t.dvdStream)
            let (format, _) = try SourceInspector.inspect(t.fileURL)
            #expect(format.codec == "LPCM")
            #expect(item.dvd == t.dvdStream)
        }

        // Unchanged on the next scan, with the same IDs.
        let ids = Set(all.compactMap(\.id))
        let again = try await scanner.scan(source)
        #expect(again.added == 0 && again.updated == 0 && again.missing == 0)
        #expect(Set(try db.allTracks().compactMap(\.id)) == ids)
    }

    @Test("A movie DVD (AC-3 only), a blank image and a VIDEO_TS's other IFOs add nothing; copy-and-organize leaves VIDEO_TS alone")
    func nothingElse() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = DVDFixture.disc(vobs: [Self.vob(1, seconds: 1, seed: 6)], titles: [[[0]]], audio: [(0, 0, 0, 6)])
        try DVDFixture.writeFolder(movie.files, at: dir.appendingPathComponent("Movie/VIDEO_TS"))
        try Data(repeating: 0, count: 600 * 2048).write(to: dir.appendingPathComponent("blank.iso"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        let summary = try await scanner.scan(source)
        #expect(summary.added == 0 && summary.failed.isEmpty)
        #expect(try db.allTracks().isEmpty)

        let music = DVDFixture.disc(vobs: [Self.vob(1, seconds: 1, seed: 7)], titles: [[[0]]])
        let disc = dir.appendingPathComponent("Concert/VIDEO_TS")
        try DVDFixture.writeFolder(music.files, at: disc)
        let managed = dir.appendingPathComponent("Managed")
        let written = try Importer.copyAndOrganize([disc.deletingLastPathComponent()], into: managed)
        #expect(written.isEmpty)
    }
}
