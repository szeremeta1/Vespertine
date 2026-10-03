import AVFAudio
import CVespertineTags
import Foundation
import GRDB
import SFBAudioEngine
import Testing
@testable import VespertineLibrary

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-audit-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
private func audio(_ url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 88200))
    buffer.frameLength = 88200
    for c in 0..<2 { for i in 0..<88200 { buffer.floatChannelData![c][i] = 0 } }
    try file.write(from: buffer)
}
private func cue(_ title: String = "Second", at url: URL) throws {
    try """
    TITLE "Album"
    FILE "set.wav" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "\(title)"
        INDEX 01 00:01:00
    """.write(to: url, atomically: true, encoding: .utf8)
}
@Suite("Audit regressions") struct AuditRegressionTests {
    @Test func cueOnlyChangeIsRescanned() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("set.wav")); let c = dir.appendingPathComponent("set.cue"); try cue(at: c)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source); try cue("Corrected", at: c); try await scanner.scan(source)
        #expect(try db.allTracks().contains { $0.title == "Corrected" })
    }
    @Test func folderFilterHonorsBoundariesAndLiteralWildcards() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["Album", "Album-extra", "100%", "100x"] {
            let folder = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try audio(folder.appendingPathComponent("\(name).wav"))
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        #expect(try db.albums(underPath: dir.appendingPathComponent("Album").path).reduce(0) { $0 + $1.trackCount } == 1)
        #expect(try db.albums(underPath: dir.appendingPathComponent("100%").path).reduce(0) { $0 + $1.trackCount } == 1)
    }
    @Test func importKeepsCueReferencesValid() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src"), dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("set.wav"); try audio(file); try cue(at: src.appendingPathComponent("set.cue"))
        let tagged = try AudioFile(readingPropertiesAndMetadataFrom: file)
        tagged.metadata.title = "Renamed by tags"; try tagged.writeMetadata()
        let folders = try Importer.copyAndOrganize([src], into: dst)
        let enumerated = LibraryScanner.enumerate(try #require(folders.first))
        #expect(LibraryScanner.cueSheets(enumerated.cue).count == 1)
    }
    /// Importing the same folder twice copies nothing the second time (it used to leave a "… 2" of every file),
    /// even after the first copy's tags were filled in; a different file that wants the same name still gets one.
    @Test func importingTwiceCopiesNothingNew() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src"), dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try audio(src.appendingPathComponent("set.wav")); try cue(at: src.appendingPathComponent("set.cue"))
        let first = try Importer.copyAndOrganize([src], into: dst)
        let copy = try #require(first.first)
        #expect(first.count == 1)
        let edited = try AudioFile(readingPropertiesAndMetadataFrom: copy)
        edited.metadata.comment = "edited after import"; try edited.writeMetadata()

        #expect(try Importer.copyAndOrganize([src], into: dst).isEmpty)
        let folder = copy.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted() == ["set.cue", "set.wav"])

        // A different file that wants the same name is new music: it gets a numbered name.
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try audio(other.appendingPathComponent("set.wav"))
        #expect(try Importer.copyAndOrganize([other], into: dst).map(\.lastPathComponent) == ["set 2.wav"])

        // So is one with the same size and date as the first, but different music.
        let twin = dir.appendingPathComponent("twin")
        try FileManager.default.createDirectory(at: twin, withIntermediateDirectories: true)
        let twinFile = twin.appendingPathComponent("set.wav")
        try FileManager.default.copyItem(at: src.appendingPathComponent("set.wav"), to: twinFile)
        let handle = try FileHandle(forUpdating: twinFile)
        try handle.seek(toOffset: try handle.seekToEnd() - 4); try handle.write(contentsOf: Data([1, 2, 3, 4])); try handle.close()
        var st = stat(); #expect(stat(src.appendingPathComponent("set.wav").path, &st) == 0)
        var times = [st.st_atimespec, st.st_mtimespec]
        #expect(utimensat(AT_FDCWD, twinFile.path, &times, 0) == 0)
        #expect(Importer.identity(of: twinFile) == Importer.identity(of: src.appendingPathComponent("set.wav")))
        #expect(try Importer.copyAndOrganize([twin], into: dst).map(\.lastPathComponent) == ["set 3.wav"])
    }
    /// A compilation tagged without an Album Artist is one album, not one per artist; the files keep their tags.
    @Test func compilationWithoutAlbumArtistIsOneAlbum() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        for (i, artist) in ["First Artist", "Second Artist"].enumerated() {
            let wav = dir.appendingPathComponent("\(i).wav"); try audio(wav)
            let flac = dir.appendingPathComponent("0\(i + 1) Song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: flac)
            try FileManager.default.removeItem(at: wav)
            let file = try AudioFile(readingPropertiesAndMetadataFrom: flac)
            file.metadata.artist = artist; file.metadata.albumTitle = "Hits"; file.metadata.isCompilation = true
            try file.writeMetadata()
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let tracks = try db.allTracks()
        #expect(tracks.count == 2 && Set(tracks.map(\.albumKey)).count == 1)
        #expect(tracks.allSatisfy { $0.albumArtist == Track.variousArtists })
        #expect(Set(tracks.compactMap(\.artist)) == ["First Artist", "Second Artist"])
        let onDisk = try AudioFile(readingPropertiesAndMetadataFrom: try #require(tracks.first).fileURL)
        #expect(onDisk.metadata.albumArtist == nil)
    }
    @Test func tagUndoRestoresCustomTagsAndExactFile() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        let tagged = try AudioFile(readingPropertiesAndMetadataFrom: url)
        tagged.metadata.title = "Original"; tagged.metadata.additionalMetadata = ["TEST_CUSTOM": "Original value"]
        try tagged.writeMetadata()
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited"], custom: ["TEST_CUSTOM": "Changed"]), to: [track])
        #expect(result.written == 1)
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try Data(contentsOf: url) == original)
    }
    @Test("A read-only file is edited in the library only: no backup, the file untouched, and a rescan keeps the edit")
    func readOnlyFileEditsStayInLibrary() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        let backups = dir.appendingPathComponent(".backups")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: backups)
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited", .album: "Library Only"]), to: [track])
        #expect(result.databaseOnly == 1 && result.written == 0 && result.failures.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.isEmpty ?? true)
        // Make the next scan read the file again (as if it had changed on the share).
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        try await scanner.scan(source)
        let rescanned = try #require(try db.allTracks().first)
        #expect(rescanned.title == "Edited" && rescanned.album == "Library Only")
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try db.allTracks().first?.title == track.title)
    }

    @Test func failedBackupDoesNotModifyOriginal() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let blocker = dir.appendingPathComponent("blocker"); try Data().write(to: blocker)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: blocker)
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: db.allTracks())
        #expect(result.written == 0); #expect(result.failures.count == 1)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func tagRefreshPreservesAnalysis() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("song.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        try db.saveAnalysis(trackID: track.id!, effectiveBitDepth: 16, bandwidthHz: 20000, verdict: "genuine")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        _ = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: [track])
        #expect(try db.tracks(ids: [track.id!]).first?.effectiveBitDepth == 16)
    }
    @Test func albumDoesNotOfferMissingCueTracks() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("set.wav")); try cue(at: dir.appendingPathComponent("set.cue"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference)); try await scanner.scan(source)
        let tracks = try db.allTracks(); let key = try #require(tracks.first?.albumKey)
        try await db.writer.write { db in try db.execute(sql: "UPDATE track SET isMissing = 1 WHERE id = ?", arguments: [tracks.first!.id]) }
        #expect(try db.tracks(albumKey: key).count == 1)
        try await scanner.scan(source)
        #expect(try db.allTracks().count == 2)
    }
    @Test func malformedCueTimesAreRejected() {
        #expect(CueSheet.cdFrames("-1:00:00") == nil)
        #expect(CueSheet.cdFrames("00:60:00") == nil)
        #expect(CueSheet.cdFrames("00:00:75") == nil)
        #expect(CueSheet.cdFrames("1:x:2:3") == nil)
    }
    @Test func cueEditsPersistThroughRescanAndUndo() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("set.wav"); try audio(url)
        let c = dir.appendingPathComponent("set.cue"); try cue(at: c)
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference)); try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.lyrics: "Words", .title: "Edited CUE"], custom: ["TEST": "Value"]), to: [track])
        #expect(result.databaseOnly == 1)
        try cue("New CUE data", at: c); try await scanner.scan(source)
        let refreshed = try #require(try db.tracks(ids: [track.id!]).first)
        #expect(refreshed.title == "Edited CUE"); #expect(refreshed.lyrics == "Words"); #expect(refreshed.extraTags["TEST"] == "Value")
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try db.tracks(ids: [track.id!]).first?.title == track.title)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func individualFileReferenceOnlyScansSelectedFile() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let selected = dir.appendingPathComponent("selected.wav"); try audio(selected)
        try audio(dir.appendingPathComponent("unselected.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: selected.path, mode: .reference))
        async let first = scanner.scan(source)
        async let second = scanner.scan(source)
        _ = try await (first, second)
        #expect(try db.allTracks().map(\.title) == ["selected"])
    }
    /// A song opened with Open With becomes a source of its own; adding its folder later takes it in instead of
    /// failing with an overlap error, and the song keeps its identity (plays, playlists, favorites).
    @Test func addingTheFolderOfAnOpenedSongTakesItIn() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let opened = dir.appendingPathComponent("opened.wav"); try audio(opened)
        try audio(dir.appendingPathComponent("other.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let single = try db.addSource(LibrarySource(path: opened.path, mode: .reference))
        try await scanner.scan(single)
        let song = try #require(try db.allTracks().first)
        try db.markPlayed(try #require(song.id))

        let folder = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(folder)
        #expect(try db.sources().map(\.id) == [folder.id])
        let tracks = try db.allTracks()
        #expect(tracks.map(\.title).sorted() == ["opened", "other"])
        let kept = try #require(tracks.first { $0.title == "opened" })
        #expect(kept.id == song.id && kept.playCount == 1 && kept.sourceId == folder.id)

        // A share or the managed library inside a folder still isn't taken over.
        let db2 = try LibraryDatabase.inMemory()
        try db2.addSource(LibrarySource(path: dir.appendingPathComponent("Share").path, mode: .reference, remoteURL: "smb://nas/Music"))
        #expect(throws: (any Error).self) { try db2.addSource(LibrarySource(path: dir.path, mode: .reference)) }
    }
    @Test func symlinkBackUpTheTreeIsListedOnce() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try audio(album.appendingPathComponent("one.wav"))
        try FileManager.default.createSymbolicLink(atPath: album.appendingPathComponent("Up").path, withDestinationPath: "..")
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        #expect(try db.allTracks().map(\.title) == ["one"])
    }
    @Test func richFLACUndoRestoresArtworkAndCustomTags() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("source.wav"); try audio(wav)
        let url = dir.appendingPathComponent("song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        let f = try AudioFile(readingPropertiesAndMetadataFrom: url)
        f.metadata.additionalMetadata = ["TEST_CUSTOM": "original"]
        let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZe8AAAAASUVORK5CYII=")!
        f.metadata.attachPicture(AttachedPicture(imageData: picture, type: .frontCover)); try f.writeMetadata()
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        #expect(track.extraTags["TEST_CUSTOM"] == "original")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        _ = try await writer.apply(TagEdit(custom: ["TEST_CUSTOM": "changed"], artwork: .remove), to: [track])
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try Data(contentsOf: url) == original)
    }
    /// A tag edit doesn't rewrite the file under whatever has it open (the song that's playing): the edited copy takes
    /// its place in one step, the open file reads on unchanged, and no copy is left behind. Creation dates are kept.
    @Test func editingAPlayingFileLeavesWhatItsReadingAlone() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("source.wav"); try audio(wav)
        let url = dir.appendingPathComponent("song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        var dated = url
        var values = URLResourceValues(); values.creationDate = Date(timeIntervalSince1970: 1_000_000_000)
        try dated.setResourceValues(values)
        let original = try Data(contentsOf: url)
        let playing = try FileHandle(forReadingFrom: url)       // what a decoder holds while it plays
        defer { try? playing.close() }

        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited while playing"]), to: [track])
        #expect(result.written == 1 && result.failures.isEmpty)

        #expect(try playing.readToEnd() == original)              // the open file is the one it opened, whole
        #expect(try AudioFile(readingPropertiesAndMetadataFrom: url).metadata.title == "Edited while playing")
        #expect(try url.resourceValues(forKeys: [.creationDateKey]).creationDate == Date(timeIntervalSince1970: 1_000_000_000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".vespertine-edit-") }.isEmpty)
        #expect(try await writer.revertLastEdit(trackID: try #require(track.id)))
        #expect(try AudioFile(readingPropertiesAndMetadataFrom: url).metadata.title != "Edited while playing")
    }
    @Test func editingSomeFieldsKeepsEveryValueOfTheOthers() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("source.wav"); try audio(wav)
        let url = dir.appendingPathComponent("song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        func set(_ key: String, _ values: [String]) {
            let copies = values.compactMap { strdup($0) }
            defer { copies.forEach { free($0) } }
            let status = copies.map { UnsafePointer($0) }.withUnsafeBufferPointer { nvt_property_set(url.path, key, $0.baseAddress, Int32(values.count)) }
            #expect(status == 0)
        }
        func values(_ key: String) -> [String] {
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = nvt_property_get(url.path, key, &buffer, Int32(buffer.count))
            return count > 0 ? String(cString: buffer).components(separatedBy: "\n") : []
        }
        let ids = ["5d3b3f2c-0000-4000-8000-000000000001", "5d3b3f2c-0000-4000-8000-000000000002"]
        set("ARTIST", ["Simon", "Garfunkel"]); set("GENRE", ["Folk", "Rock"]); set("MUSICBRAINZ_ARTISTID", ids); set("TEST_GONE", ["x"])
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited", .genre: "Pop"], custom: ["TEST_GONE": nil]), to: [track])
        #expect(result.written == 1 && result.failures.isEmpty)
        #expect(values("ARTIST") == ["Simon", "Garfunkel"])     // untouched: every value kept
        #expect(values("MUSICBRAINZ_ARTISTID") == ids)
        #expect(values("GENRE") == ["Pop"])                     // edited: as edited
        #expect(values("TITLE") == ["Edited"])
        #expect(values("TEST_GONE").isEmpty)                    // a deleted custom tag leaves the file
    }
    @Test func backupsOverTheBudgetGoOldestFirstAndTheEditCanStillBeUndone() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("source.wav"); try audio(wav)
        let url = dir.appendingPathComponent("song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let backups = dir.appendingPathComponent(".backups")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: backups)
        _ = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: [track])
        func backupFiles() -> [String] {
            (FileManager.default.enumerator(atPath: backups.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".flac") }
        }
        #expect(backupFiles().count == 1)
        // Asking for the whole budget again makes room by deleting the oldest backups, referenced or not.
        await writer.pruneBackups(making: TagWriter.backupBudget)
        #expect(backupFiles().isEmpty)
        #expect(try await db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tagHistory WHERE fileBackupPath IS NOT NULL") } == 0)
        // The edit is still recorded, so it can be undone from its tags.
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try db.allTracks().first?.title != "Edited")
    }
    @Test func cueWrittenForTheWAVSplitsTheFLACItWasCompressedTo() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rip.wav"); try audio(wav)
        try SFBAudioEngine.AudioConverter.convert(wav, to: dir.appendingPathComponent("set.flac"))
        try FileManager.default.removeItem(at: wav)
        try cue(at: dir.appendingPathComponent("set.cue"))          // FILE "set.wav", as the ripper wrote it
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        #expect(try db.allTracks().count == 2)
        #expect(try db.allTracks().contains { $0.title == "Second" })
    }
    @Test func cueSheetsInLegacyEncodingsReadAsWritten() throws {
        func sheet(_ title: String, _ encoding: String.Encoding) throws -> String? {
            let text = "PERFORMER \"\(title)\"\nFILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"\(title)\"\n    INDEX 01 00:00:00\n"
            return CueSheet.text(of: try #require(text.data(using: encoding))).map { CueSheet.parse($0).files.first?.tracks.first?.title } ?? nil
        }
        #expect(try sheet("交響曲第9番 ニ短調", .shiftJIS) == "交響曲第9番 ニ短調")
        #expect(try sheet("Группа крови", .windowsCP1251) == "Группа крови")
        #expect(try sheet("Mötley Crüe, Café Tacvba", .windowsCP1252) == "Mötley Crüe, Café Tacvba")
        #expect(try sheet("Ångström Größe", .windowsCP1252) == "Ångström Größe")
        #expect(CueSheet.text(of: Data([0xEF, 0xBB, 0xBF]) + Data("TITLE \"Édith\"".utf8)) == "TITLE \"Édith\"")
    }
    @Test func numericCueOverflowIsRejected() {
        #expect(CueSheet.cdFrames("9223372036854775807:59:74") == nil)
        #expect(CueSheet.sampleFrame(cdFrames: Int.max, sampleRate: .infinity) == 0)
    }

    /// Sources never overlap, so every track has one owner: a folder inside a source is that source, and a folder
    /// around local sources takes them in (their tracks move to it). The managed library is never taken in.
    @Test func overlappingSourcesKeepOneOwner() throws {
        let db = try LibraryDatabase.inMemory()
        let child = try db.addSource(LibrarySource(path: "/audit-music/album", mode: .reference))
        #expect(try db.addSource(LibrarySource(path: "/audit-music/album/song.wav", mode: .reference)).id == child.id)
        let parent = try db.addSource(LibrarySource(path: "/audit-music", mode: .reference))
        #expect(try db.sources().map(\.id) == [parent.id])

        let managed = try LibraryDatabase.inMemory()
        try managed.addSource(LibrarySource(path: "/audit-music/Vespertine", mode: .managed))
        #expect(throws: (any Error).self) { try managed.addSource(LibrarySource(path: "/audit-music", mode: .reference)) }
        #expect(try managed.sources().count == 1)
    }
    @Test func cueStatisticsCountPhysicalFileOnce() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("set.wav"); try audio(url); try cue(at: dir.appendingPathComponent("set.cue"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        #expect(try db.stats().bytes == Int64(Data(contentsOf: url).count))
    }
    @Test func managedFolderIsNotRecursivelyReimported() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("song.wav"))
        #expect(try Importer.copyAndOrganize([dir], into: dir).isEmpty)
        #expect(LibraryScanner.enumerate(dir).audio.count == 1)
    }

    @Test("A short track imported on purpose stays; the same clip in a referenced folder is skipped")
    func importedShortTrackIsKept() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let managed = dir.appendingPathComponent("managed"), referenced = dir.appendingPathComponent("referenced")
        for folder in [managed, referenced] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try audio(folder.appendingPathComponent("jingle.wav"))   // 2 s, untagged: a clip
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        #expect(await scanner.skipsNonMusic)
        let kept = try await scanner.scan(db.addSource(LibrarySource(path: managed.path, mode: .managed)))
        let skipped = try await scanner.scan(db.addSource(LibrarySource(path: referenced.path, mode: .reference)))
        #expect(kept.added == 1 && kept.skipped == 0)
        #expect(skipped.added == 0 && skipped.skipped == 1)
        #expect(try db.allTracks().map { $0.fileURL.deletingLastPathComponent().lastPathComponent } == ["managed"])
    }

    @Test func undoRefusesToOverwriteExternalChanges() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        await #expect(throws: (any Error).self) {
            try await writer.apply(TagEdit(fields: [.trackNumber: "not a number"]), to: [track])
        }
        _ = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: [track])
        var external = try Data(contentsOf: url); external.append(contentsOf: [1,2,3,4]); try external.write(to: url)
        await #expect(throws: (any Error).self) { try await writer.revertLastEdit(trackID: track.id!) }
        #expect(try Data(contentsOf: url) == external)
    }

}

/// Removing a share after a failed unmount must never delete what's inside the mount folder (the music on the server).
@Test func unmountCleanupNeverDeletesContents() async throws {
    let base = try fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let stillMounted = base.appendingPathComponent("share", isDirectory: true)
    try FileManager.default.createDirectory(at: stillMounted, withIntermediateDirectories: true)
    let song = stillMounted.appendingPathComponent("song.flac")
    try Data([1, 2, 3]).write(to: song)
    await NetworkVolume.forceUnmount(stillMounted, ownedBy: base)
    await NetworkVolume.unmount(stillMounted, ownedBy: base)
    #expect(FileManager.default.fileExists(atPath: song.path))

    let empty = base.appendingPathComponent("gone", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(!NetworkVolume.isMountPoint(empty))
    NetworkVolume.removeEmptyMountFolder(empty, ownedBy: base)
    #expect(!FileManager.default.fileExists(atPath: empty.path))
    #expect(NetworkVolume.isMountPoint(URL(fileURLWithPath: "/")))

    // A sibling that merely starts with the same name isn't inside `base`.
    let sibling = URL(fileURLWithPath: base.path + "-backup", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sibling) }
    NetworkVolume.removeEmptyMountFolder(sibling, ownedBy: base)
    #expect(FileManager.default.fileExists(atPath: sibling.path))
}

/// A folder that can't be listed is reported, not fatal: the rest of the source is still listed.
@Test func unreadableFolderDoesNotStopTheListing() async throws {
    let root = try fixture()
    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try audio(root.appendingPathComponent("open.wav"))
    try audio(locked.appendingPathComponent("hidden.wav"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }
    let listing = try await LibraryScanner.list(root)
    #expect(listing.audio.map(\.url.lastPathComponent) == ["open.wav"])
    #expect(listing.unreadable.count == 1)
    #expect(listing.unreadable.first?.hasSuffix("/locked") == true)
}

/// A rescan that can't list a folder keeps the songs already indexed under it, and still picks up the rest.
@Test func rescanKeepsTracksUnderUnreadableFolder() async throws {
    let root = try fixture()
    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try audio(root.appendingPathComponent("open.wav"))
    try audio(locked.appendingPathComponent("hidden.wav"))
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }
    let db = try LibraryDatabase.inMemory()
    let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: root.appendingPathComponent(".art")))
    await scanner.setSkipsNonMusic(false) // fixtures are short clips
    let source = try db.addSource(LibrarySource(path: root.path, mode: .reference))
    try await scanner.scan(source)
    #expect(Set(try db.allTracks().map(\.fileURL.lastPathComponent)) == ["open.wav", "hidden.wav"])

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    try audio(root.appendingPathComponent("added.wav"))
    let summary = try await scanner.scan(source)
    #expect(summary.missing == 0)
    #expect(summary.failed.contains { $0.hasSuffix("/locked") })
    #expect(Set(try db.allTracks().map(\.fileURL.lastPathComponent)) == ["open.wav", "hidden.wav", "added.wav"])
}
