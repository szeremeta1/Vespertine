//
// Vespertine: indexing a share and arranging it as a library, on a made-up share in memory: what is found, what is
// skipped, what a second scan reads again, and how songs fall into albums.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineShare

/// A share in memory: paths to bytes. Counts what is listed and read, and can be made to fail.
final class FakeShare: ShareFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var dates: [String: Date] = [:]
    private var hidden: Set<String> = []
    private(set) var listed: [String] = []
    private(set) var readPaths: [String] = []
    private(set) var rests = 0
    /// Folders that refuse to be opened.
    var denied: Set<String> = []
    /// What every call fails with, while set.
    var failure: SMBError?
    /// Files whose reading finds the line dead.
    var unanswered: Set<String> = []

    static let day = Date(timeIntervalSince1970: 1_700_000_000)

    func put(_ path: String, _ data: Data, modified: Date = FakeShare.day, hidden isHidden: Bool = false) {
        lock.withLock {
            files[path] = data
            dates[path] = modified
            if isHidden { hidden.insert(path) }
        }
    }

    func remove(_ path: String) { lock.withLock { files[path] = nil } }
    func forgetCounts() { lock.withLock { listed.removeAll(); readPaths.removeAll() } }

    func list(_ folder: String) throws -> [SMBEntry] {
        try lock.withLock {
            if let failure { throw failure }
            if denied.contains(folder) { throw SMBError.accessDenied }
            listed.append(folder)
            let prefix = folder.isEmpty ? "" : folder + "/"
            var entries: [String: SMBEntry] = [:]
            for (path, data) in files where path.hasPrefix(prefix) {
                let rest = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).map(String.init)
                guard let name = rest.first else { continue }
                if rest.count > 1 {
                    entries[name] = SMBEntry(name: name, isFolder: true, size: 0, modified: FakeShare.day)
                } else {
                    entries[name] = SMBEntry(name: name, isFolder: false, size: Int64(data.count), modified: dates[path] ?? FakeShare.day, hidden: hidden.contains(path))
                }
            }
            // A server lists in no particular order.
            return entries.values.sorted { $0.name.count != $1.name.count ? $0.name.count > $1.name.count : $0.name > $1.name }
        }
    }

    func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            if let failure { throw failure }
            guard let data = files[path] else { throw SMBError.notFound }
            if unanswered.contains(path) { throw SMBError.timedOut }
            readPaths.append(path)
            guard offset < Int64(data.count) else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
        }
    }

    func info(_ path: String) throws -> (size: Int64, modified: Date) {
        try lock.withLock {
            if let failure { throw failure }
            guard let data = files[path] else { throw SMBError.notFound }
            return (Int64(data.count), dates[path] ?? FakeShare.day)
        }
    }

    func rest() { lock.withLock { rests += 1 } }

    /// A share with two tagged albums, a folder of untagged files, and things that are not music.
    static func sample() -> FakeShare {
        let share = FakeShare()
        share.put("Ilse Brandt/Nocturnes/02 Nocturne.flac", SongFixtures.flac2496)
        share.put("Ilse Brandt/Nocturnes/cover.jpg", SongFixtures.cover)
        share.put("Ilse Brandt/Nocturnes/booklet.pdf", Data("pdf".utf8))
        share.put("Kestrel Park/Northern Signal/04 Aurora Line.m4a", SongFixtures.alac)
        share.put("Loose/Demos/03 Night Ferry.wav", WavMaker.file())
        share.put("Loose/Demos/10 Late Tram.flac", SongFixtures.surroundFlac)
        share.put("Loose/Demos/old rip.ape", Data("MAC ".utf8))
        share.put("Loose/Demos/broken.flac", Data("junk".utf8))
        share.put("Loose/Demos/.hidden.flac", SongFixtures.flac2496)
        share.put("@eaDir/thumb.flac", SongFixtures.flac2496)
        share.put("#recycle/old.flac", SongFixtures.flac2496)
        return share
    }
}

@Suite struct ShareScannerTests {
    @Test func aScanFindsTheSongsThePhoneCanPlayAndCountsTheRest() throws {
        let share = FakeShare.sample()
        let library = try ShareScanner.scan(share, now: FakeShare.day)
        #expect(library.songs.map(\.path) == ["Ilse Brandt/Nocturnes/02 Nocturne.flac", "Kestrel Park/Northern Signal/04 Aurora Line.m4a",
                                              "Loose/Demos/03 Night Ferry.wav", "Loose/Demos/10 Late Tram.flac"])
        #expect(library.needTheMac == 1)
        #expect(library.unreadable == 1)
        #expect(library.covers == ["Ilse Brandt/Nocturnes": "cover.jpg"])
        #expect(library.scanned == FakeShare.day)
        // A NAS's own folders, a recycle bin and hidden files are never opened.
        #expect(!share.listed.contains("@eaDir") && !share.listed.contains("#recycle"))
        #expect(!share.readPaths.contains("Loose/Demos/.hidden.flac"))
        #expect(Set(library.songs.map(\.id)).count == 4)
    }

    @Test func aScanSaysWhyEachFileNeedsTheMac() throws {
        let share = FakeShare()
        for name in ["a.dts", "b.DTS", "c.thd", "d.mlp", "e.ac3", "f.ec3", "g.tta", "h.tak", "i.wma", "j.mka", "k.iso", "l.ape"] {
            share.put("Films/" + name, Data("x".utf8))
        }
        let library = try ShareScanner.scan(share, now: FakeShare.day)
        #expect(library.songs.isEmpty && library.unreadable == 0 && library.needTheMac == 12)
        // In the order the screen lists them, a kind with no files left out.
        let expected: [MacNeed.Count] = [.init(need: .dts, files: 2), .init(need: .trueHD, files: 2), .init(need: .dolbyDigital, files: 2), .init(need: .tta, files: 1),
                                         .init(need: .tak, files: 1), .init(need: .wma, files: 1), .init(need: .matroska, files: 1), .init(need: .discImage, files: 1),
                                         .init(need: .other, files: 1)]
        #expect(library.needsByKind == expected)
        #expect(library.needsByKind.map(\.files).reduce(0, +) == library.needTheMac)
        // A second scan counts them afresh: nothing doubles.
        #expect(try ShareScanner.scan(share, previous: library, now: FakeShare.day).needs == library.needs)
    }

    @Test func aSecondScanReadsOnlyWhatChanged() throws {
        let share = FakeShare.sample()
        let first = try ShareScanner.scan(share, now: FakeShare.day)
        share.forgetCounts()

        // Nothing changed: every folder is listed, no song is opened.
        let same = try ShareScanner.scan(share, previous: first, now: FakeShare.day)
        #expect(same == first)
        #expect(share.readPaths == ["Loose/Demos/broken.flac"])   // still not a song, so still looked at

        // One file replaced, one added, one gone.
        share.forgetCounts()
        share.put("Kestrel Park/Northern Signal/04 Aurora Line.m4a", SongFixtures.aac, modified: FakeShare.day.addingTimeInterval(60))
        share.put("Kestrel Park/Northern Signal/05 New.mp3", SongFixtures.cbrMP3)
        share.remove("Loose/Demos/10 Late Tram.flac")
        let later = try ShareScanner.scan(share, previous: first, now: FakeShare.day.addingTimeInterval(3600))
        #expect(Set(share.readPaths) == ["Kestrel Park/Northern Signal/04 Aurora Line.m4a", "Kestrel Park/Northern Signal/05 New.mp3", "Loose/Demos/broken.flac"])
        #expect(later.songs.map(\.path) == ["Ilse Brandt/Nocturnes/02 Nocturne.flac", "Kestrel Park/Northern Signal/04 Aurora Line.m4a",
                                            "Kestrel Park/Northern Signal/05 New.mp3", "Loose/Demos/03 Night Ferry.wav"])
        // A song keeps its ID across scans, changed or not: a queue or a favorite still means the same file.
        let before = Dictionary(uniqueKeysWithValues: first.songs.map { ($0.path, $0.id) })
        for song in later.songs where before[song.path] != nil { #expect(song.id == before[song.path]) }
        #expect(later.songs.first { $0.path.hasSuffix("Aurora Line.m4a") }?.tags.codec == "AAC")
    }

    @Test func aFolderThatWontOpenIsPassedOverButAShareThatStopsAnsweringEndsTheScan() throws {
        let share = FakeShare.sample()
        share.denied = ["Kestrel Park"]
        let library = try ShareScanner.scan(share, now: FakeShare.day)
        #expect(library.songs.count == 3)

        share.failure = .timedOut
        #expect(throws: SMBError.timedOut) { _ = try ShareScanner.scan(share, now: FakeShare.day) }
        share.failure = .signInFailed
        #expect(throws: SMBError.signInFailed) { _ = try ShareScanner.scan(share, now: FakeShare.day) }
    }

    @Test func aScanStopsWhenToldTo() {
        let share = FakeShare.sample()
        #expect(throws: CancellationError.self) { _ = try ShareScanner.scan(share, now: FakeShare.day, cancelled: { true }) }
    }

    @Test func aFirstScanShowsWhatItHasFoundSoFarAndALaterOneDoesNot() throws {
        var glimpses: [ShareLibrary] = []
        let first = try ShareScanner.scan(FakeShare.sample(), now: FakeShare.day, glimpseEvery: 1, glimpse: { glimpses.append($0) })
        #expect(glimpses.map(\.songs.count) == [1, 2, 3, 4])
        #expect(glimpses.allSatisfy { $0.scanned == nil })
        #expect(glimpses.last?.songs == first.songs)

        // Once a scan has finished, the library shown is that one until the next scan is done.
        glimpses.removeAll()
        let share = FakeShare.sample()
        share.put("New/01 Fresh.flac", FlacMaker.file(["TITLE": "Fresh"]))
        _ = try ShareScanner.scan(share, previous: first, now: FakeShare.day, glimpseEvery: 1, glimpse: { glimpses.append($0) })
        #expect(glimpses.isEmpty)
    }

    @Test func aScanCutShortCarriesOnFromWhatItHadFound() throws {
        let share = FakeShare.sample()
        share.unanswered = ["Ilse Brandt/Nocturnes/02 Nocturne.flac"]
        var partial: ShareLibrary?
        #expect(throws: SMBError.timedOut) { _ = try ShareScanner.scan(share, now: FakeShare.day, glimpseEvery: 1, glimpse: { partial = $0 }) }
        #expect(partial?.songs.count == 3)

        share.unanswered = []
        share.forgetCounts()
        let whole = try ShareScanner.scan(share, previous: partial, now: FakeShare.day)
        #expect(whole.songs.count == 4)
        #expect(Set(share.readPaths) == ["Ilse Brandt/Nocturnes/02 Nocturne.flac", "Loose/Demos/broken.flac"])
    }

    @Test func progressCountsUp() throws {
        var seen: [Int] = []
        _ = try ShareScanner.scan(FakeShare.sample(), now: FakeShare.day, progress: { seen.append($0.songs) })
        #expect(seen.last == 4)
        #expect(seen == seen.sorted())
    }
}

@Suite struct ShareCatalogTests {
    private func catalog(_ share: FakeShare = .sample(), favorites: Set<Int64> = []) throws -> ShareCatalog {
        ShareCatalog(try ShareScanner.scan(share, now: FakeShare.day), favorites: favorites)
    }

    @Test func songsFallIntoAlbumsByTheirTagsAndByTheirFoldersWhenTheyHaveNone() throws {
        let catalog = try catalog()
        #expect(catalog.albums.map(\.summary.title) == ["Nocturnes for a Small Room", "Northern Signal", "Demos"])
        #expect(catalog.albums.map(\.summary.artist) == ["Ilse Brandt Trio", "Kestrel Park", "Loose"])

        let nocturnes = catalog.albums[0].summary
        #expect(nocturnes.format == "FLAC · 24/96" && nocturnes.hiRes && !nocturnes.multichannel && nocturnes.year == 2023 && nocturnes.trackCount == 1)
        #expect(catalog.albums[1].summary.format == "ALAC · 24/192")

        // No tags: the folder is the album, the folder above it the artist, the file name the title and number.
        let demos = catalog.albums[2]
        #expect(demos.summary.multichannel && !demos.summary.hiRes)
        let songs = demos.tracks.compactMap { catalog.tracks[$0] }
        #expect(songs.map(\.title) == ["Night Ferry", "Allegro"])
        #expect(songs.map(\.trackNumber) == [3, 10])
        #expect(songs.map(\.artist) == ["Loose", "Loose"])
        #expect(songs.allSatisfy { $0.albumKey == demos.summary.key })
    }

    @Test func aFolderOfOneAlbumByManyArtistsIsOneCompilation() throws {
        let share = FakeShare()
        func tagged(_ artist: String, _ title: String) -> Data { FlacMaker.file(["ARTIST": artist, "ALBUM": "Summer Mix", "TITLE": title]) }
        share.put("Mixes/Summer/01.flac", tagged("June Okafor", "Velvet"))
        share.put("Mixes/Summer/02.flac", tagged("Pavel Hart", "Lamp Room"))
        share.put("Albums/Lamp/01.flac", FlacMaker.file(["ARTIST": "Pavel Hart", "ALBUM": "The Lamp Room", "TITLE": "Stairwell"]))
        let catalog = try catalog(share)
        #expect(catalog.albums.map(\.summary.title) == ["The Lamp Room", "Summer Mix"])
        #expect(catalog.albums.map(\.summary.artist) == ["Pavel Hart", "Various Artists"])
        #expect(catalog.albums[1].tracks.compactMap { catalog.tracks[$0]?.artist } == ["June Okafor", "Pavel Hart"])
    }

    @Test func anAlbumIsInDiscAndTrackOrder() throws {
        let share = FakeShare()
        func song(_ disc: String, _ track: String, _ title: String) -> Data {
            FlacMaker.file(["ARTIST": "Aster Quartet", "ALBUM": "Concert", "TITLE": title, "DISCNUMBER": disc, "TRACKNUMBER": track])
        }
        share.put("c/a.flac", song("2", "1", "Scherzo"))
        share.put("c/b.flac", song("1", "2", "Adagio"))
        share.put("c/c.flac", song("1", "1", "Allegro"))
        share.put("c/d.flac", song("2", "2", "Finale"))
        let catalog = try catalog(share)
        #expect(catalog.albums.count == 1)
        #expect(catalog.albums[0].tracks.compactMap { catalog.tracks[$0]?.title } == ["Allegro", "Adagio", "Scherzo", "Finale"])
    }

    @Test func aCoverIsThePictureInTheFolderOrElseTheOneInAFile() throws {
        let catalog = try catalog()
        let nocturnes = try #require(catalog.albums[0].summary.artworkKey)
        #expect(catalog.covers[nocturnes] == .file(path: "Ilse Brandt/Nocturnes/cover.jpg"))
        #expect(catalog.albums[1].summary.artworkKey == nil)

        let share = FakeShare()
        share.put("a/01.flac", SongFixtures.flac2496)
        let embedded = try self.catalog(share)
        let key = try #require(embedded.albums[0].summary.artworkKey)
        #expect(embedded.covers[key] == .embedded(song: embedded.albums[0].tracks[0]))
        #expect(embedded.tracks.values.first?.artworkKey == key)
    }

    @Test func artistsGenresSearchAndRecent() throws {
        let share = FakeShare.sample()
        share.put("Kestrel Park/Northern Signal/04 Aurora Line.m4a", SongFixtures.alac, modified: FakeShare.day.addingTimeInterval(86_400))
        let catalog = try catalog(share)
        #expect(catalog.artists.map(\.name) == ["Ilse Brandt Trio", "Kestrel Park", "Loose"])
        #expect(catalog.genres.map(\.name) == ["Classical", "Electronic"])
        #expect(catalog.albums(genre: "electronic").map(\.title) == ["Northern Signal"])
        #expect(catalog.recentlyAdded(2).map(\.title) == ["Northern Signal", "Nocturnes for a Small Room"])
        #expect(catalog.search("aurora kestrel", limit: 10).map(\.title) == ["Aurora Line"])
        #expect(catalog.search("NOCTURNE", limit: 10).map(\.title) == ["Nocturne No. 2"])
        #expect(catalog.search("   ", limit: 10).isEmpty)
        let found = catalog.find("signal", limit: 10)
        #expect(found.albums.map(\.title) == ["Northern Signal"] && found.tracks.map(\.title) == ["Aurora Line"] && found.playlists.isEmpty)
        #expect(catalog.find("kestrel", limit: 10).artists.map(\.name) == ["Kestrel Park"])
        let page = catalog.songs(offset: 1, limit: 2)
        #expect(page.total == 4 && page.items.map(\.title) == ["Aurora Line", "Night Ferry"])
    }

    @Test func favoritesAreMarked() throws {
        let plain = try catalog()
        let id = try #require(plain.albums[1].tracks.first)
        var catalog = try catalog(favorites: [id])
        #expect(catalog.tracks[id]?.favorite == true)
        #expect(catalog.allTracks.filter(\.favorite).count == 1)
        catalog.setFavorite([id], false)
        #expect(catalog.tracks[id]?.favorite == false)
    }

    @Test func formatsAreWordedAsTheMacWordsThem() {
        func tags(_ codec: String, _ rate: Double, _ depth: Int?, _ channels: Int, bitRate: Int? = nil) -> SongTags {
            SongTags(codec: codec, sampleRate: rate, bitDepth: depth, channels: channels, duration: 1, bitRate: bitRate)
        }
        #expect(ShareCatalog.format(tags("FLAC", 44_100, 16, 2)) == "FLAC · 16/44.1")
        #expect(ShareCatalog.format(tags("FLAC", 88_200, 24, 2)) == "FLAC · 24/88.2")
        #expect(ShareCatalog.format(tags("ALAC", 352_800, 24, 2)) == "ALAC · 24/352.8")
        #expect(ShareCatalog.format(tags("MP3", 44_100, nil, 2, bitRate: 320)) == "MP3 · 320k")
        #expect(ShareCatalog.format(tags("FLAC", 96_000, 24, 8)) == "FLAC · 24/96 · 7.1")
    }
}

/// Writes the smallest FLAC file that says what its tags are (a header and comments, no sound): enough for the index.
enum FlacMaker {
    static func file(_ tags: [String: String], rate: Int = 44_100, bits: Int = 16, channels: Int = 2, frames: Int = 44_100) -> Data {
        var out = Data("fLaC".utf8)
        var info = [UInt8](repeating: 0, count: 34)
        info[10] = UInt8(rate >> 12 & 0xff)
        info[11] = UInt8(rate >> 4 & 0xff)
        info[12] = UInt8(rate & 0xf) << 4 | UInt8(channels - 1) << 1 | UInt8((bits - 1) >> 4)
        info[13] = UInt8((bits - 1) & 0xf) << 4
        info[14] = UInt8(frames >> 24 & 0xff); info[15] = UInt8(frames >> 16 & 0xff); info[16] = UInt8(frames >> 8 & 0xff); info[17] = UInt8(frames & 0xff)
        out.append(contentsOf: [0, 0, 0, 34] + info)
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xff), UInt8(n >> 8 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 24 & 0xff)] }
        var comments = le(4) + Array("test".utf8) + le(tags.count)
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            let text = Array("\(key)=\(value)".utf8)
            comments += le(text.count) + text
        }
        out.append(contentsOf: [0x84, UInt8(comments.count >> 16 & 0xff), UInt8(comments.count >> 8 & 0xff), UInt8(comments.count & 0xff)] + comments)
        return out
    }
}

/// Writes a WAV file with no tags: a header and silence.
enum WavMaker {
    static func file(rate: Int = 44_100, bits: Int = 16, channels: Int = 2, frames: Int = 441) -> Data {
        func le(_ n: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(n >> (8 * $0) & 0xff) } }
        let block = channels * bits / 8, size = frames * block
        var out = Array("RIFF".utf8) + le(36 + size, 4) + Array("WAVEfmt ".utf8) + le(16, 4) + le(1, 2) + le(channels, 2)
        out += le(rate, 4) + le(rate * block, 4) + le(block, 2) + le(bits, 2) + Array("data".utf8) + le(size, 4)
        return Data(out) + Data(count: size)
    }
}
