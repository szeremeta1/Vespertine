//
// Vespertine: music in a folder on the phone (chosen in Files, or the app's own): found, indexed, read and kept up to
// date through the same library a share has. On real folders in the temporary directory.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertineShare

/// A folder that can be told to be somewhere else, or nowhere: a bookmark that stopped working, a drive pulled out.
private final class Whereabouts: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var losses = 0
    init(_ url: URL?) { self.url = url }
    var place: URL? {
        get { lock.withLock { url } }
        set { lock.withLock { url = newValue } }
    }
    var lost: Int { lock.withLock { losses } }
    func noteLost() { lock.withLock { losses += 1 } }
    func locate() throws -> URL {
        guard let url = place else { throw SMBError.accessDenied }
        return url
    }
}

/// Counts what is read through it.
private final class Counting: ShareFiles, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any ShareFiles
    private var paths: [String] = []
    init(_ inner: any ShareFiles) { self.inner = inner }
    var read: Set<String> { lock.withLock { Set(paths) } }
    func forget() { lock.withLock { paths.removeAll() } }
    func list(_ folder: String) throws -> [SMBEntry] { try inner.list(folder) }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        lock.withLock { paths.append(path) }
        return try inner.read(path, offset: offset, length: length)
    }
    func info(_ path: String) throws -> (size: Int64, modified: Date) { try inner.info(path) }
    func rest() { inner.rest() }
}

@MainActor
@Suite struct FolderFilesTests {
    private let manager = FileManager.default

    private func scratch(_ name: String = "Music") throws -> URL {
        let url = manager.temporaryDirectory.appendingPathComponent("folder-tests-\(UUID().uuidString)", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func put(_ data: Data, _ path: String, in root: URL, modified: Date = FakeShare.day) throws {
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// One song of every kind the phone opens, each in an album folder; one folder has a cover picture beside it.
    private func sample() throws -> URL {
        let root = try scratch()
        try put(SongFixtures.flac2496, "Ilse Brandt/Nocturnes/02 Nocturne.flac", in: root)
        try put(SongFixtures.alac, "Kestrel Park/Northern Signal/04 Aurora Line.m4a", in: root)
        try put(SongFixtures.aac, "June Okafor/Velvet Hours/01 Coffee Rings.m4a", in: root)
        try put(SongFixtures.cbrMP3, "Highway Saints/Dust and Chrome/01 Chrome Horses.mp3", in: root)
        try put(SongFixtures.wav, "Loose/Wave Album/Wave.wav", in: root)
        try put(SongFixtures.aiff, "Loose/Aiff Album/Aiff.aiff", in: root)
        try put(SongFixtures.cover, "Loose/Aiff Album/cover.jpg", in: root)
        try put(Data("DTS ".utf8), "Loose/film.dts", in: root)
        try put(Data("notes".utf8), "Loose/notes.txt", in: root)
        try put(SongFixtures.flac2496, "Loose/.hidden.flac", in: root)
        return root
    }

    private func store() -> ShareStore {
        ShareStore(directory: manager.temporaryDirectory.appendingPathComponent("folder-index-\(UUID().uuidString)", isDirectory: true))
    }

    /// The folder opened as the app opens one: looked at every time, and mending its own index.
    private func open(_ files: any ShareFiles, store: ShareStore, playback: (any ShareFiles)? = nil) async throws -> ShareMac {
        let mac = ShareMac(id: SavedFolder.newID(), name: "Music", files: files, playback: playback ?? files, store: store, sayings: .englishFolder)
        mac.rescanAfter = 0
        mac.mendsItself = true
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { !mac.isScanning })
        return mac
    }

    private func ask(_ mac: ShareMac, _ command: RemoteCommand) async throws -> RemoteReply {
        try await mac.request(command, timeout: .seconds(1))
    }

    private func titles(_ mac: ShareMac) async throws -> [String] {
        guard case .songs(let items, _) = try await ask(mac, .songs(offset: 0, limit: 100)) else { return [] }
        return items.map(\.title)
    }

    private func song(_ mac: ShareMac, _ title: String) async throws -> TrackSummary {
        guard case .songs(let items, _) = try await ask(mac, .songs(offset: 0, limit: 100)) else { throw SMBError.notFound }
        return try #require(items.first { $0.title == title })
    }

    // MARK: Scanning

    @Test func aScanFindsEveryKindOfSongThePhoneOpensWithItsTags() async throws {
        let mac = try await open(FolderFiles(at: try sample()), store: store())
        #expect(mac.scan == .idle && mac.reachable == true)
        let byCodec = Dictionary(grouping: mac.library.songs, by: \.tags.codec).mapValues { $0.map { $0.tags.title ?? "" }.sorted() }
        #expect(byCodec == ["FLAC": ["Nocturne No. 2"], "ALAC": ["Aurora Line"], "AAC": ["Coffee Rings"], "MP3": ["Chrome Horses"],
                            "WAV": ["Wave Title"], "AIFF": ["Aiff Title"]])
        // What it can't open without a Mac is counted, not listed; what isn't music or is hidden is passed over.
        #expect(mac.library.needTheMac == 1 && mac.library.unreadable == 0 && mac.library.songs.count == 6)

        let flac = try await song(mac, "Nocturne No. 2")
        #expect(flac.artist == "Ilse Brandt" && flac.album == "Nocturnes for a Small Room" && flac.format == "FLAC · 24/96")
        let lossless = try await song(mac, "Aurora Line")
        #expect(lossless.artist == "Kestrel Park" && lossless.format == "ALAC · 24/192")
        #expect(try await song(mac, "Chrome Horses").album == "Dust and Chrome")
        guard case .library(let overview) = try await ask(mac, .library) else { Issue.record("no overview"); return }
        #expect(overview.albums == 6 && overview.songs == 6 && overview.playlists == 0)
    }

    @Test func coversComeFromThePictureInTheFolderAndFromInsideTheFiles() async throws {
        let mac = try await open(FolderFiles(at: try sample()), store: store())
        // A picture file beside the songs.
        let beside = try #require(try await song(mac, "Aiff Title").artworkKey)
        guard case .artwork(_, _, let type, let picture) = try await ask(mac, .artwork(key: beside, size: 300)) else { Issue.record("no cover"); return }
        #expect(picture == SongFixtures.cover && type == "image/jpeg")
        // A picture inside the song's own file: FLAC, and an AAC file's.
        for title in ["Nocturne No. 2", "Coffee Rings"] {
            let key = try #require(try await song(mac, title).artworkKey)
            guard case .artwork(_, _, _, let inside) = try await ask(mac, .artwork(key: key, size: 300)) else { Issue.record("no cover in \(title)"); return }
            #expect(inside.starts(with: [0xFF, 0xD8]) || inside.starts(with: [0x89, 0x50]))
        }
    }

    @Test func theIndexIsKeptAndALaterLookReadsOnlyWhatIsNewOrChanged() async throws {
        let root = try sample(), store = store()
        _ = try await open(FolderFiles(at: root), store: store)

        // Opened again (the app was closed in between): nothing has changed, so no file is read.
        let counted = Counting(FolderFiles(at: root))
        let again = try await open(counted, store: store)
        #expect(counted.read.isEmpty && again.library.songs.count == 6 && again.revision == 0)

        // A file whose tags were edited (another size, a later date) is read again; a new file is read; the rest aren't.
        try put(FlacMaker.file(["TITLE": "Nocturne No. 2 (Remastered)", "ARTIST": "Ilse Brandt", "ALBUM": "Nocturnes for a Small Room"]),
                "Ilse Brandt/Nocturnes/02 Nocturne.flac", in: root, modified: FakeShare.day.addingTimeInterval(3600))
        try put(FlacMaker.file(["TITLE": "Late Tram"]), "Loose/New/10 Late Tram.flac", in: root)
        again.rescan()
        #expect(await eventually { !again.isScanning })
        #expect(counted.read == ["Ilse Brandt/Nocturnes/02 Nocturne.flac", "Loose/New/10 Late Tram.flac"])
        #expect(try await titles(again).contains("Nocturne No. 2 (Remastered)"))
        #expect(try await !titles(again).contains("Nocturne No. 2"))
        #expect(try await titles(again).contains("Late Tram") && again.revision == 1)
    }

    @Test func aFileEditedInPlaceWithTheSameSizeIsReadAgainByItsDate() async throws {
        let root = try scratch(), store = store()
        try put(FlacMaker.file(["TITLE": "Take 1"]), "a.flac", in: root)
        let mac = try await open(FolderFiles(at: root), store: store)
        #expect(try await titles(mac) == ["Take 1"])
        try put(FlacMaker.file(["TITLE": "Take 2"]), "a.flac", in: root, modified: FakeShare.day.addingTimeInterval(60))
        mac.rescan()
        #expect(await eventually { !mac.isScanning })
        #expect(try await titles(mac) == ["Take 2"])
    }

    // MARK: Files that go

    @Test func aDeletedFileIsGoneFromTheListsAtTheNextLook() async throws {
        let root = try sample(), store = store()
        let mac = try await open(FolderFiles(at: root), store: store)
        try manager.removeItem(at: root.appendingPathComponent("Loose/Wave Album/Wave.wav"))
        // Every time the folder is opened it is looked at: there is no day's wait as a share has.
        let again = try await open(FolderFiles(at: root), store: store)
        #expect(try await !titles(again).contains("Wave Title") && again.library.songs.count == 5)
        _ = mac
    }

    @Test func aFileDeletedSinceTheLastLookSaysSoWhenPlayedAndIsNotShownAsPlayableAfter() async throws {
        let root = try sample(), store = store()
        let mac = try await open(FolderFiles(at: root), store: store)
        var changes = 0
        mac.onChange = { changes += 1 }
        let wave = try await song(mac, "Wave Title")
        let id = try #require(wave.id)
        let before = mac.revision
        try manager.removeItem(at: root.appendingPathComponent("Loose/Wave Album/Wave.wav"))

        #expect(try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: ShareSayings.englishFolder.notInLibrary))
        // The folder is fine: it is the one file that is the trouble. It is off every list at once, and off the kept index.
        #expect(mac.reachable == true && mac.revision == before + 1 && changes >= 1)
        #expect(try await !titles(mac).contains("Wave Title"))
        #expect(try await ask(mac, .tracks(ids: [id])) == .tracks(items: []))
        guard case .albums(let albums, _) = try await ask(mac, .albums(offset: 0, limit: 100)) else { Issue.record("no albums"); return }
        #expect(!albums.contains { $0.title == "Wave Album" })
        #expect(store.library()?.songs.contains { $0.id == id } == false)
        #expect(try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: ShareSayings.englishFolder.notInLibrary))
    }

    @Test func aFileReplacedSinceTheLastLookIsNotPlayedAsTheOldOneAndTheFolderIsReadAgain() async throws {
        let root = try sample(), store = store()
        let mac = try await open(FolderFiles(at: root), store: store)
        let id = try #require(try await song(mac, "Wave Title").id)
        try put(WavMaker.file(frames: 4410), "Loose/Wave Album/Wave.wav", in: root, modified: FakeShare.day.addingTimeInterval(60))
        #expect(try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: ShareSayings.englishFolder.changed))
        #expect(await eventually { !mac.isScanning && mac.library.songs.first { $0.id == id }?.tags.frames == 4410 })
        guard case .streamOpened(let stream) = try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        #expect(stream.frames == 4410)
    }

    // MARK: Playing

    @Test func aSongIsReadAsItsOwnFile() async throws {
        let root = try sample()
        let mac = try await open(FolderFiles(at: root), store: store(), playback: FolderFiles(at: root))
        let id = try #require(try await song(mac, "Nocturne No. 2").id)
        guard case .streamOpened(let stream) = try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        let whole = SongFixtures.flac2496
        #expect(stream.kind == .original && stream.byteSize == Int64(whole.count) && stream.format.codec == "FLAC" && stream.format.container == "flac")
        let first = try await mac.read(stream: stream.stream, offset: 0, length: 1000, timeout: .seconds(1))
        #expect(first.payload == whole.prefix(1000) && !first.endOfStream)
        let last = try await mac.read(stream: stream.stream, offset: 1000, length: 1 << 20, timeout: .seconds(1))
        #expect(last.payload == whole.dropFirst(1000) && last.endOfStream)
        // Back to an earlier place (a seek), and past the end.
        #expect(try await mac.read(stream: stream.stream, offset: 10, length: 20, timeout: .seconds(1)).payload == whole.dropFirst(10).prefix(20))
        #expect(try await mac.read(stream: stream.stream, offset: Int64(whole.count), length: 20, timeout: .seconds(1)).payload.isEmpty)
    }

    @Test func aDrivePulledOutInTheMiddleOfASongIsSaidAndPluggingItBackCarriesOn() async throws {
        let root = try sample()
        let away = root.deletingLastPathComponent().appendingPathComponent("Unplugged", isDirectory: true)
        let folder = Whereabouts(root)
        let files = FolderFiles(locate: folder.locate, lost: folder.noteLost)
        let mac = try await open(files, store: store(), playback: FolderFiles(locate: folder.locate, lost: folder.noteLost))
        let id = try #require(try await song(mac, "Nocturne No. 2").id)
        guard case .streamOpened(let stream) = try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        let nextID = try #require(try await song(mac, "Aurora Line").id)
        guard case .streamOpened(let next) = try await ask(mac, .streamOpen(id: nextID, maxSampleRate: nil)) else { Issue.record("next not opened"); return }
        _ = try await mac.read(stream: stream.stream, offset: 0, length: 100, timeout: .seconds(1))

        // The folder is somewhere else now, as a drive's is once it is pulled out. (A test can't pull a drive: the file
        // already open here would still read, so it is the next song, not yet read, that finds the folder gone.)
        try manager.moveItem(at: root, to: away)
        let words = ShareSayings.englishFolder.trouble(.unreachable)
        await #expect(throws: RemoteLinkError.readFailed(words)) {
            try await mac.read(stream: next.stream, offset: 0, length: 100, timeout: .seconds(1))
        }
        #expect(mac.reachable == false && folder.lost >= 1)
        #expect(words.contains("plug the drive in"))
        // The songs it had are still listed: only playing them waits for the drive.
        #expect(mac.library.songs.count == 6)
        #expect(try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: words))
        mac.rescan()
        #expect(await eventually { mac.scan == .failed(.unreachable) })
        #expect(mac.library.songs.count == 6)

        try manager.moveItem(at: away, to: root)
        guard case .streamOpened(let back) = try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened again"); return }
        #expect(try await mac.read(stream: back.stream, offset: 0, length: 4, timeout: .seconds(1)).payload == Data("fLaC".utf8))
        #expect(mac.reachable == true)
    }

    // MARK: A folder that can't be opened

    @Test func aLostBookmarkSaysToChooseTheFolderAgainAndKeepsWhatWasIndexed() async throws {
        let root = try sample(), store = store()
        let folder = Whereabouts(root)
        _ = try await open(FolderFiles(locate: folder.locate), store: store)

        // The bookmark no longer leads anywhere (the app's permission is gone): nothing under it can be listed or read.
        folder.place = nil
        let mac = ShareMac(id: SavedFolder.newID(), name: "Music", files: FolderFiles(locate: folder.locate), playback: FolderFiles(locate: folder.locate),
                           store: store, sayings: .englishFolder)
        mac.rescanAfter = 0
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { mac.scan == .failed(.accessDenied) })
        #expect(mac.reachable == false && mac.library.songs.count == 6)
        let words = ShareSayings.englishFolder.trouble(.accessDenied)
        #expect(words == "Vespertine can’t open this folder any more. Choose the folder again.")
        let id = try #require(try await song(mac, "Wave Title").id)
        #expect(try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: words))

        // Chosen again: the same index carries on, with nothing read twice.
        folder.place = root
        mac.rescan()
        #expect(await eventually { mac.scan == .idle })
        #expect(mac.reachable == true && mac.revision == 0)
    }

    @Test func everyFolderTroubleEndsInWhatToDo() {
        for error in [SMBError.accessDenied, .unreachable, .notFound, .closed] {
            #expect(ShareSayings.englishFolder.trouble(error).lowercased().contains("choose the folder again"))
        }
    }

    @Test func aPathCantStepOutOfTheFolder() throws {
        let root = try sample()
        let secret = root.deletingLastPathComponent().appendingPathComponent("secret.flac")
        try SongFixtures.flac2496.write(to: secret)
        let files = FolderFiles(at: root)
        #expect(throws: SMBError.notFound) { try files.read("../secret.flac", offset: 0, length: 4) }
        #expect(throws: SMBError.notFound) { try files.info("Loose/../../secret.flac") }
        #expect(throws: SMBError.notFound) { try files.list("..") }
        #expect(throws: SMBError.notFound) { try files.list("No Such Folder") }
    }

    // MARK: The folders kept

    @Test func addedFoldersAreKeptAndAFolderIsAShareToTheScreens() throws {
        let shelf = FolderShelf(file: manager.temporaryDirectory.appendingPathComponent("folder-shelf-\(UUID().uuidString)/folders.json"))
        #expect(shelf.load().isEmpty)
        let first = SavedFolder(name: "Music", bookmark: Data([1, 2, 3]), addedAt: FakeShare.day)
        var second = SavedFolder(name: "USB", bookmark: Data([4]), addedAt: FakeShare.day.addingTimeInterval(1))
        shelf.upsert(second)
        shelf.upsert(first)
        #expect(shelf.load() == [first, second])
        second.bookmark = Data([5])
        shelf.upsert(second)
        #expect(shelf.load() == [first, second])
        shelf.remove(id: first.id)
        #expect(shelf.load() == [second])

        #expect(first.id != second.id && !first.isOwn && SavedFolder(id: SavedFolder.ownID, name: "", bookmark: nil).isOwn)
        #if canImport(Darwin)
        let session = RemoteSession(pairing: SavedPairing(serverID: first.id, name: first.name, device: "folder", key: Data()), clientName: "phone") { nil }
        #expect(session.isShare && session.isFolder)
        let share = RemoteSession(pairing: SavedPairing(serverID: SavedShare.newID(), name: "NAS", device: "share", key: Data()), clientName: "phone") { nil }
        #expect(share.isShare && !share.isFolder)
        #else
        #expect(first.id.hasPrefix(ShareMac.prefix + "folder-"))
        #endif
    }

    // MARK: Single files opened in the app

    @Test func aFileOpenedInTheAppIsCopiedIntoItsOwnFolderAndPlaysFromThere() async throws {
        let own = try scratch("Documents")
        let elsewhere = try scratch("Downloads")
        try put(SongFixtures.flac2496, "Nocturne.flac", in: elsewhere)
        #expect(!OpenedFiles.holdsAnything(own))
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("Nocturne.flac"), into: own) == .added("Nocturne.flac"))
        // The file stays where it was: what was handed over is a copy.
        #expect(manager.fileExists(atPath: elsewhere.appendingPathComponent("Nocturne.flac").path) && OpenedFiles.holdsAnything(own))

        let mac = try await open(FolderFiles(at: own), store: store())
        let id = try #require(mac.library.songs.first { $0.path == "Nocturne.flac" }?.id)
        guard case .streamOpened(let stream) = try await ask(mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        #expect(stream.byteSize == Int64(SongFixtures.flac2496.count))
    }

    @Test func theSameFileOpenedTwiceIsKeptOnceAndAnotherOfTheSameNameIsKeptBesideIt() throws {
        let own = try scratch("Documents")
        let elsewhere = try scratch("Downloads")
        try put(SongFixtures.flac2496, "Song.flac", in: elsewhere)
        try put(SongFixtures.surroundFlac, "Other/Song.flac", in: elsewhere)
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("Song.flac"), into: own) == .added("Song.flac"))
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("Song.flac"), into: own) == .added("Song.flac"))
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("Other/Song.flac"), into: own) == .added("Song 2.flac"))
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("Other/Song.flac"), into: own) == .added("Song 2.flac"))
        #expect(try manager.contentsOfDirectory(atPath: own.path).sorted() == ["Song 2.flac", "Song.flac"])
        #expect(try Data(contentsOf: own.appendingPathComponent("Song 2.flac")) == SongFixtures.surroundFlac)
    }

    @Test func whatTheSystemLeftInTheInboxIsMovedOutAndAFileAlreadyInTheFolderStaysWhereItIs() throws {
        let own = try scratch("Documents")
        try put(SongFixtures.alac, "Inbox/Aurora Line.m4a", in: own)
        #expect(!OpenedFiles.holdsAnything(own))
        #expect(OpenedFiles.take(own.appendingPathComponent("Inbox/Aurora Line.m4a"), into: own) == .added("Aurora Line.m4a"))
        #expect(!manager.fileExists(atPath: own.appendingPathComponent("Inbox/Aurora Line.m4a").path))
        // Opened from Files, where the app's folder shows: nothing is copied, and it is found under its own path.
        try put(SongFixtures.wav, "Albums/Demo/Wave.wav", in: own)
        #expect(OpenedFiles.take(own.appendingPathComponent("Albums/Demo/Wave.wav"), into: own) == .added("Albums/Demo/Wave.wav"))
        #expect(try manager.contentsOfDirectory(atPath: own.path).sorted() == ["Albums", "Aurora Line.m4a", "Inbox"])
    }

    @Test func aFileThePhoneCantOpenItselfIsRefusedNotCopied() throws {
        let own = try scratch("Documents")
        let elsewhere = try scratch("Downloads")
        try put(Data("DTS ".utf8), "film.dts", in: elsewhere)
        try put(Data("pdf".utf8), "booklet.pdf", in: elsewhere)
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("film.dts"), into: own) == .notPlayable)
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("booklet.pdf"), into: own) == .notPlayable)
        #expect(OpenedFiles.take(elsewhere.appendingPathComponent("gone.flac"), into: own) == .failed)
        #expect(!OpenedFiles.holdsAnything(own))
    }

    // MARK: Bookmarks

    #if canImport(Darwin)
    @Test func aBookmarkFindsItsFolderAgainAndOneWhoseFolderIsGoneSaysSo() throws {
        let root = try sample()
        let bookmark = try #require(FolderAccess.bookmark(for: root))
        let access = FolderAccess(bookmark: bookmark)
        let files = FolderFiles(locate: access.url, lost: access.letGo)
        #expect(try files.list("").map(\.name).sorted() == ["Highway Saints", "Ilse Brandt", "June Okafor", "Kestrel Park", "Loose"])
        access.letGo()
        #expect(try files.info("Loose/Wave Album/Wave.wav").size == Int64(SongFixtures.wav.count))

        try manager.removeItem(at: root)
        access.letGo()
        #expect(throws: SMBError.self) { try files.list("") }
        #expect(throws: SMBError.accessDenied) { try FolderAccess(bookmark: Data("not a bookmark".utf8)).url() }
    }
    #endif
}
