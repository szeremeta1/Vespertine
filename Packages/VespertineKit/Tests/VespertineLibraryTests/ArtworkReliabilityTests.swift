//
// Vespertine — the cover of the playing song is found however the library came to lack it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import AVFoundation
import Foundation
import GRDB
import SFBAudioEngine
import Testing
@testable import VespertineLibrary

/// Pictures to embed and to leave in folders.
private enum Pictures {
    static func png(_ side: Int, red: UInt8 = 200, green: UInt8 = 40, blue: UInt8 = 40) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Write the bytes directly: setColor per pixel logs a colour-space warning for every call (millions of lines in CI).
        let pixels = rep.bitmapData!, stride = rep.bytesPerRow
        for y in 0..<side {
            for x in 0..<side {
                let p = y * stride + x * 4
                pixels[p] = red
                pixels[p + 1] = UInt8(min(255, Int(green) + (x % 7) * 6))
                pixels[p + 2] = UInt8(min(255, Int(blue) + (y % 5) * 6))
                pixels[p + 3] = 255
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }

    static func jpeg(_ side: Int, red: UInt8 = 40, green: UInt8 = 40, blue: UInt8 = 200) -> Data {
        let rep = NSBitmapImageRep(data: png(side, red: red, green: green, blue: blue))!
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }

    /// A JPEG with its tail gone, as a failed copy leaves it.
    static func cutOffJPEG(_ side: Int) -> Data { jpeg(side).prefix(jpeg(side).count * 2 / 3) }

    /// Bytes that start like a PNG and are nothing.
    static let junk = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x42, count: 400)
}

@Suite("Cover art that is always there")
struct ArtworkReliabilityTests {
    private func fixture() throws -> (dir: URL, store: ArtworkStore) {
        let dir = try tempDir()
        return (dir, ArtworkStore(directory: dir.appendingPathComponent(".art", isDirectory: true)))
    }

    /// A one-second FLAC / M4A / WAV, optionally with embedded pictures, in `folder`.
    @discardableResult
    private func song(_ name: String, in folder: URL, pictures: [(Data, String)] = [], album: String = "Album") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try NetworkTests.writeAudio(url, seconds: 1)
        if !pictures.isEmpty || url.pathExtension != "" {
            let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
            file.metadata.title = url.deletingPathExtension().lastPathComponent
            file.metadata.albumTitle = album
            file.metadata.artist = "Artist"
            for (data, kind) in pictures {
                file.metadata.attachPicture(AttachedPicture(imageData: data, type: kind == "back" ? .backCover : .frontCover))
            }
            try file.writeMetadata()
        }
        return url
    }

    // MARK: The store

    @Test("A cover that lost a thumbnail is rebuilt, not trusted because one file is there")
    func incompleteCoverIsRebuilt() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Pictures.jpeg(900)
        let key = try #require(store.store(data))
        #expect(store.isStored(key))
        try FileManager.default.removeItem(at: store.thumbnailURL(key, size: 600))   // a crash between two writes
        #expect(!store.isStored(key))
        #expect(store.store(data) == key)
        #expect(store.isStored(key), "the 600 px thumbnail is written again")
    }

    @Test("A cover whose original is gone still shows from its thumbnails, at any size asked for")
    func urlFallsBackToWhatExists() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = try #require(store.store(Pictures.jpeg(900)))
        try FileManager.default.removeItem(at: store.originalURL(key))
        let url = store.url(for: key, minimumSize: 1200)
        #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        #expect(NSImage(contentsOf: url) != nil)
    }

    @Test("Bytes that only look like an image are no cover")
    func junkIsNoCover() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.store(Pictures.junk) == nil)
        #expect(store.store(Data()) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test("Storing the same cover from many threads at once never leaves a half-written file")
    func concurrentStores() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Pictures.png(1500)
        let keys = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<12 { group.addTask { store.store(data) } }
            var keys: [String?] = []
            for await key in group { keys.append(key) }
            return keys
        }
        let key = try #require(keys.first ?? nil)
        #expect(keys.allSatisfy { $0 == key })
        for size in ArtworkStore.thumbnailSizes { #expect(NSImage(contentsOf: store.thumbnailURL(key, size: size)) != nil) }
        #expect(NSImage(contentsOf: store.originalURL(key)) != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(leftovers.count == 3, "\(leftovers)")
    }

    // MARK: Folder art

    @Test("A cover and the ._ file macOS writes beside it on a share are one cover, not two images")
    func appleDoubleFilesAreNotImages() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let cover = Pictures.jpeg(400)
        try cover.write(to: album.appendingPathComponent("scan.jpg"))                 // not named like a cover
        try Data(repeating: 0, count: 4096).write(to: album.appendingPathComponent("._scan.jpg"))
        try Data(repeating: 0, count: 4096).write(to: album.appendingPathComponent("._cover.jpg"))
        #expect(ArtworkStore.folderImage(near: album.appendingPathComponent("01.flac")) == cover)
        #expect(ArtworkStore.folderArtKey(near: album.appendingPathComponent("01.flac"), store: store) == ArtworkStore.key(for: cover))
    }

    @Test("Covers named the way taggers and rippers name them are found, a back cover is not taken for the front")
    func coverNames() throws {
        func pick(_ names: [String]) -> String? {
            ArtworkStore.pickCover(names.map { URL(fileURLWithPath: "/m/Album/\($0)") })?.lastPathComponent
        }
        #expect(pick(["Cover.JPG"]) == "Cover.JPG")
        #expect(pick(["back.jpg", "Front.jpg"]) == "Front.jpg")
        #expect(pick(["inlay.png", "Cover Art.png", "disc.png"]) == "Cover Art.png")
        #expect(pick(["AlbumArt_{4B2E}_Large.jpg", "back.jpg"]) == "AlbumArt_{4B2E}_Large.jpg")
        #expect(pick(["folder.jpeg", "cover.png"]) == "cover.png")                       // the order of the plain names
        #expect(pick(["front-1.jpg", "back-1.jpg"]) == "front-1.jpg")
        #expect(pick(["AlbumArtSmall.jpg"]) == "AlbumArtSmall.jpg")                       // the only image
        #expect(pick(["back.jpg", "inlay.png"]) == nil)                                 // several, none a front: no guess
        #expect(pick(["._cover.jpg"]) == nil)
        #expect(pick(["cover.tif"]) == "cover.tif")
    }

    @Test("A folder image that can't be decoded doesn't stop the next one from being used")
    func undecodableFolderImageIsSkipped() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Pictures.junk.write(to: album.appendingPathComponent("cover.jpg"))
        let good = Pictures.png(300)
        try good.write(to: album.appendingPathComponent("folder.png"))
        #expect(ArtworkStore.folderArtKey(near: album.appendingPathComponent("a.flac"), store: store) == ArtworkStore.key(for: good))
    }

    // MARK: Reading a file

    @Test("An embedded picture that won't decode doesn't hide the folder's cover")
    func brokenEmbeddedPictureFallsBackToFolder() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album")
        let folder = Pictures.jpeg(500)
        let file = try song("01.flac", in: album, pictures: [(Pictures.junk, "front")])
        try folder.write(to: album.appendingPathComponent("cover.jpg"))
        let track = try MetadataReader.read(url: file, artwork: store)
        #expect(track.artworkKey == ArtworkStore.key(for: folder))
    }

    @Test("A one-pixel placeholder picture doesn't hide a real cover in the folder, and a good picture still beats the folder")
    func placeholderEmbeddedPicture() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = Pictures.jpeg(500)
        let tiny = Pictures.png(1), good = Pictures.png(300, red: 10, green: 200, blue: 10)
        let a = dir.appendingPathComponent("A"), b = dir.appendingPathComponent("B"), c = dir.appendingPathComponent("C")
        try folder.write(to: { try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true); return a.appendingPathComponent("cover.jpg") }())
        try folder.write(to: { try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true); return b.appendingPathComponent("cover.jpg") }())
        let withTiny = try song("1.flac", in: a, pictures: [(tiny, "front")])
        let withGood = try song("1.flac", in: b, pictures: [(good, "front")])
        let tinyOnly = try song("1.flac", in: c, pictures: [(tiny, "front")])
        #expect(try MetadataReader.read(url: withTiny, artwork: store).artworkKey == ArtworkStore.key(for: folder))
        #expect(try MetadataReader.read(url: withGood, artwork: store).artworkKey == ArtworkStore.key(for: good))
        // Nothing better anywhere: the placeholder is still better than a blank.
        #expect(try MetadataReader.read(url: tinyOnly, artwork: store).artworkKey == ArtworkStore.key(for: tiny))
    }

    @Test("The front cover is the one used, a back cover only when there is nothing else")
    func frontBeforeBack() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let front = Pictures.png(300), back = Pictures.png(300, red: 5, green: 5, blue: 250)
        let file = try song("1.flac", in: dir, pictures: [(back, "back"), (front, "front")])
        #expect(try MetadataReader.read(url: file, artwork: store).artworkKey == ArtworkStore.key(for: front))
    }

    @Test("A cut-off picture gives way to the folder's, and is used when there is no other")
    func cutOffPicture() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let cut = Pictures.cutOffJPEG(600), whole = Pictures.jpeg(600, red: 9, green: 99, blue: 199)
        #expect(store.coverKey(embedded: [{ cut }], folder: { store.store(whole) }) == ArtworkStore.key(for: whole))
        #expect(store.coverKey(embedded: [{ cut }], folder: { nil }) == ArtworkStore.key(for: cut))
        #expect(store.coverKey(embedded: [{ nil }, { Pictures.junk }], folder: { nil }) == nil)
    }

    @Test("Embedded covers are found in FLAC, M4A (covr) and WAV (ID3) files, and the same through a share's sparse copy")
    func everyContainer() throws {
        for ext in ["flac", "m4a", "wav"] {
            let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let cover = Pictures.jpeg(400)
            let file = try song("1.\(ext)", in: dir, pictures: [(cover, "front")])
            #expect(try MetadataReader.read(url: file, artwork: store).artworkKey == ArtworkStore.key(for: cover), "\(ext) directly")
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let shared = try RemoteMetadata.readTrack(url: file, size: size, modified: .now, artwork: store, folderArt: nil)
            #expect(shared.artworkKey == ArtworkStore.key(for: cover), "\(ext) over a share")
        }
    }

    @Test("A song on a share with no embedded picture gets the cover.jpg beside it")
    func shareFolderArt() throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = Pictures.png(400)
        let file = try song("1.flac", in: dir.appendingPathComponent("Album"))
        try folder.write(to: dir.appendingPathComponent("Album/Cover.PNG"))
        let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        #expect(try RemoteMetadata.readTrack(url: file, size: size, modified: .now, artwork: store, folderArt: FolderArtCache()).artworkKey
                == ArtworkStore.key(for: folder))
    }

    // MARK: At play time

    /// A library with one scanned song (no cover found by the scan), returning its row.
    private func scanned(_ dir: URL, _ store: ArtworkStore, _ db: LibraryDatabase) async throws -> [Track] {
        let scanner = LibraryScanner(database: db, artwork: store)
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        return try db.allTracks()
    }

    @Test("A song the scan found no cover for gets the cover that was added to its folder since, and keeps it")
    func folderCoverAddedAfterTheScan() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Artist/Album")
        try song("01 One.flac", in: album); try song("02 Two.flac", in: album)
        let db = try LibraryDatabase.inMemory()
        let tracks = try await scanned(dir, store, db)
        #expect(tracks.count == 2 && tracks.allSatisfy { $0.artworkKey == nil })

        let cover = Pictures.jpeg(500)
        try cover.write(to: album.appendingPathComponent("folder.jpg"))
        let resolver = ArtworkResolver(database: db, store: store)
        let first = resolver.resolve(tracks[0])
        #expect(first == ResolvedArtwork(key: ArtworkStore.key(for: cover), source: .folder))
        // Kept with the song, so albums and queues show it too.
        #expect(try db.tracks(ids: [tracks[0].id!]).first?.artworkKey == first.key)
        // The other song of the album reads the folder for itself (and is not told by the first).
        #expect(resolver.resolve(tracks[1]).key == first.key)
    }

    @Test("A song whose tags gained a picture after the scan shows it")
    func embeddedAddedAfterTheScan() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Artist/Album")
        let file = try song("01 One.flac", in: album)
        let db = try LibraryDatabase.inMemory()
        let track = try #require(try await scanned(dir, store, db).first)
        #expect(track.artworkKey == nil)
        let cover = Pictures.png(400)
        let tags = try AudioFile(readingPropertiesAndMetadataFrom: file)
        tags.metadata.attachPicture(AttachedPicture(imageData: cover, type: .frontCover)); try tags.writeMetadata()
        #expect(ArtworkResolver(database: db, store: store).resolve(track) == ResolvedArtwork(key: ArtworkStore.key(for: cover), source: .embedded))
    }

    @Test("The library's current cover wins over the one the queue's copy of the song remembers (a tag edit changed it)")
    func staleQueueEntry() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Artist/Album")
        let old = Pictures.png(300), new = Pictures.png(300, red: 5, green: 150, blue: 5)
        try song("01 One.flac", in: album, pictures: [(old, "front")])
        let db = try LibraryDatabase.inMemory()
        var queued = try #require(try await scanned(dir, store, db).first)          // what the queue holds
        #expect(queued.artworkKey == ArtworkStore.key(for: old))
        let newKey = try #require(store.store(new))
        try await db.writer.write { try $0.execute(sql: "UPDATE track SET artworkKey = ?", arguments: [newKey]) }   // the tag edit
        #expect(ArtworkResolver(database: db, store: store).resolve(queued) == ResolvedArtwork(key: newKey, source: .library))
        // Without a row to ask (a song not in the library) the queue's copy is all there is.
        queued.id = nil
        #expect(ArtworkResolver(database: db, store: store).resolve(queued).key == ArtworkStore.key(for: old))
    }

    @Test("A cover the artwork folder lost is found again from the file")
    func coverFilesLost() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let cover = Pictures.png(300)
        try song("01 One.flac", in: dir.appendingPathComponent("Artist/Album"), pictures: [(cover, "front")])
        let db = try LibraryDatabase.inMemory()
        let track = try #require(try await scanned(dir, store, db).first)
        for item in try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: item) }
        let found = ArtworkResolver(database: db, store: store).resolve(track)
        #expect(found == ResolvedArtwork(key: ArtworkStore.key(for: cover), source: .embedded))
        #expect(store.isStored(try #require(found.key)))
    }

    @Test("A song with nothing of its own shows its album's cover, then nothing, and nothing is not remembered")
    func albumThenNothing() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Artist/Album")
        let cover = Pictures.png(300)
        try song("01 One.flac", in: album, pictures: [(cover, "front")]); try song("02 Two.flac", in: album)
        let db = try LibraryDatabase.inMemory()
        let tracks = try await scanned(dir, store, db)
        let bare = try #require(tracks.first { $0.title == "02 Two" })
        let resolver = ArtworkResolver(database: db, store: store)
        #expect(resolver.resolve(bare) == ResolvedArtwork(key: ArtworkStore.key(for: cover), source: .album))

        let alone = dir.appendingPathComponent("Other/Single")
        try song("01 Solo.flac", in: alone, album: "Single")
        let solo = try #require(try await scanned(dir, store, db).first { $0.title == "01 Solo" })
        #expect(resolver.resolve(solo) == .none)
        #expect(try db.tracks(ids: [solo.id!]).first?.artworkKey == nil)
    }

    @Test("A song still being copied from a share has no picture to read yet, then has it the moment the copy is whole")
    func shareFileMidCopy() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let cover = Pictures.jpeg(400)
        // An M4A keeps its tags in the 'moov' box, here after the audio (the usual layout of ALAC from Music).
        let whole = try song("01 One.m4a", in: dir.appendingPathComponent("whole"), pictures: [(cover, "front")])
        let data = try Data(contentsOf: whole)
        let partial = dir.appendingPathComponent("Artist/Album/01 One.m4a")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(data.count / 3).write(to: partial)                       // the copy so far
        var track = Track.stub(path: partial.path)
        track.album = "Album"
        let resolver = ArtworkResolver(database: try .inMemory(), store: store)
        let early = resolver.resolve(track)
        #expect(early.source == .none || early.key == nil || early.key == ArtworkStore.key(for: cover))   // never a wrong cover, never a crash
        try data.write(to: partial)                                              // the copy completes
        #expect(resolver.resolve(track) == ResolvedArtwork(key: ArtworkStore.key(for: cover), source: .embedded))
    }

    @Test("A disc image's songs take the cover from beside the image")
    func discImageUsesFolder() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let cover = Pictures.jpeg(400)
        try cover.write(to: dir.appendingPathComponent("Folder.jpg"))
        var track = Track.stub(path: dir.appendingPathComponent("Album.iso").path)
        track.location = track.filePath + "#2ch-1"
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: track.filePath))   // not a readable image of anything
        #expect(ArtworkResolver(database: try .inMemory(), store: store).resolve(track) == ResolvedArtwork(key: ArtworkStore.key(for: cover), source: .folder))
    }

    @Test("A CUE sheet's songs share their file's cover")
    func cueSongsGetTheCover() async throws {
        let (dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Artist/Album")
        let cover = Pictures.png(300)
        let file = try song("Album.flac", in: album, pictures: [(cover, "front")])
        try """
        PERFORMER "Artist"
        TITLE "Album"
        FILE "Album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 00:00:50
        """.write(to: album.appendingPathComponent("Album.cue"), atomically: true, encoding: .utf8)
        _ = file
        let db = try LibraryDatabase.inMemory()
        let tracks = try await scanned(dir, store, db)
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.artworkKey == ArtworkStore.key(for: cover) })
        let resolver = ArtworkResolver(database: db, store: store)
        #expect(tracks.map { resolver.resolve($0).key } == [ArtworkStore.key(for: cover), ArtworkStore.key(for: cover)])
    }
}
