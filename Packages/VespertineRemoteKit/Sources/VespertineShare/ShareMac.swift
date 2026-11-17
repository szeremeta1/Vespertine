//
// Vespertine: a share in place of a Mac. The app's screens ask a Mac for its library and for songs' bytes; this answers
// the same questions from the phone's own index of an SMB share and from the share itself, so a share is browsed and
// played with the screens and the player a Mac's library is. There is no Mac in it: nothing here plays, and the phone
// is always where the music sounds.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteClient
import VespertineRemoteProtocol

/// Where a share's index, favorites and fetched covers are kept on the phone.
public struct ShareStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private var libraryURL: URL { directory.appendingPathComponent("library.json") }
    private var favoritesURL: URL { directory.appendingPathComponent("favorites.json") }

    public func library() -> ShareLibrary? {
        (try? Data(contentsOf: libraryURL)).flatMap { try? JSONDecoder().decode(ShareLibrary.self, from: $0) }
    }

    public func save(_ library: ShareLibrary) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(library).write(to: libraryURL, options: .atomic)
    }

    public func favorites() -> Set<Int64> {
        (try? Data(contentsOf: favoritesURL)).flatMap { try? JSONDecoder().decode(Set<Int64>.self, from: $0) } ?? []
    }

    public func save(favorites: Set<Int64>) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(favorites.sorted()).write(to: favoritesURL, options: .atomic)
    }

    func coverURL(_ key: String, size: Int) -> URL {
        directory.appendingPathComponent("Covers", isDirectory: true).appendingPathComponent("\(key)-\(size)")
    }

    func cover(_ key: String, size: Int) -> Data? { try? Data(contentsOf: coverURL(key, size: size)) }

    func save(cover: Data, _ key: String, size: Int) {
        let url = coverURL(key, size: size)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? cover.write(to: url, options: .atomic)
    }

    /// Forgets the fetched covers (after a scan: a cover may have changed).
    func clearCovers() { try? FileManager.default.removeItem(at: directory.appendingPathComponent("Covers", isDirectory: true)) }

    public func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// The share's answers in words, in the app's language.
public struct ShareSayings: Sendable {
    public var words: ShareWords
    /// Why the share can't be used right now.
    public var trouble: @Sendable (SMBError) -> String
    /// A song asked for that the index no longer has.
    public var notInLibrary: String
    /// Playlists are the Mac's: a share has none.
    public var noPlaylists: String
    /// The file is not what the index says any more (it was replaced on the share).
    public var changed: String

    public init(words: ShareWords, trouble: @escaping @Sendable (SMBError) -> String, notInLibrary: String, noPlaylists: String, changed: String) {
        self.words = words
        self.trouble = trouble
        self.notInLibrary = notInLibrary
        self.noPlaylists = noPlaylists
        self.changed = changed
    }

    public static let english = ShareSayings(words: .english, trouble: { "The share can’t be reached (\($0))." }, notInLibrary: "That isn’t on the share any more.",
                                             noPlaylists: "Playlists are kept on the Mac.", changed: "That file has changed on the share. Scan the share again.")

    /// A folder on the phone, in English (the app says the same in its own languages).
    public static let englishFolder = ShareSayings(words: .english, trouble: { error in
        error == .accessDenied ? "Vespertine can’t open this folder any more. Choose the folder again."
            : "This folder can’t be found. If it is on a drive, plug the drive in. If it was moved or renamed, choose the folder again."
    }, notInLibrary: "That file isn’t in the folder any more.", noPlaylists: "Playlists are kept on the Mac. A folder has none.",
                                                   changed: "That file has changed. Vespertine is reading the folder again.")
}

/// Runs blocking share reads one after another on a thread of their own, so nothing that waits on the network holds up
/// the app or the threads Swift's tasks share.
final class ShareWorker: Sendable {
    private let queue: DispatchQueue

    init(_ label: String) { queue = DispatchQueue(label: "org.szeremeta.vespertine.share." + label, qos: .userInitiated) }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// Set from one thread and read from another: a scan told to stop.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

@MainActor
public final class ShareMac: RemoteChannel {
    public nonisolated static let prefix = "share-"

    public enum Scan: Equatable, Sendable {
        case idle
        case scanning(songs: Int)
        case failed(SMBError)
    }

    public var onPush: (@MainActor (ServerMessage) -> Void)?
    public var onClose: (@MainActor (String?) -> Void)?
    /// The scan started, moved on, ended or failed; or the share was found reachable or not.
    public var onChange: (@MainActor () -> Void)?

    public let info: ServerInfo
    public private(set) var library: ShareLibrary
    public private(set) var catalog: ShareCatalog
    public private(set) var scan: Scan = .idle
    /// Whether the share answered the last time it was asked for anything; nil before the first time.
    public private(set) var reachable: Bool?
    /// Goes up when a finished scan changed what the library holds (screens showing it load it again).
    public private(set) var revision = 0
    /// How old an index may be before a connection looks at the share again by itself.
    public var rescanAfter: TimeInterval = 24 * 3600
    /// How many songs a first scan reads between showing (and keeping) what it has found so far.
    public var glimpseEvery = 200
    /// A song asked for whose file is gone is taken off the lists there and then, and one whose file changed has the
    /// library looked at again, without being asked. For a folder on the phone, where looking again costs nothing.
    public var mendsItself = false

    private let files: any ShareFiles
    private let playback: any ShareFiles
    private let store: ShareStore
    private let sayings: ShareSayings
    private let shrink: @Sendable (Data, Int) -> Data?
    private let libraryWorker = ShareWorker("library")
    private let playbackWorker = ShareWorker("playback")
    private let now: @Sendable () -> Date

    private var favorites: Set<Int64>
    private var isOpen = false
    private var scanning: Task<Void, Never>?
    private var stop: StopFlag?
    /// An open stream: the song, and for a DSD file how it is given to the player (nil: the file's own bytes).
    private struct OpenStream {
        var song: ShareSong
        var rendering: DSDRendering?
        var size: Int64 { rendering?.byteSize ?? song.size }
    }
    private var streams: [Int: OpenStream] = [:]
    private var nextStream = 0

    /// - Parameters:
    ///   - files: the share for browsing: scans and covers. `playback`: the same share on a connection of its own, so
    ///     a song being played never waits behind a scan.
    ///   - shrink: makes a cover no larger than a size in pixels (nil: use it as it is).
    public init(id: String, name: String, files: any ShareFiles, playback: any ShareFiles, store: ShareStore, sayings: ShareSayings = .english,
                appVersion: String = "", now: @escaping @Sendable () -> Date = { Date() },
                shrink: @escaping @Sendable (Data, Int) -> Data? = { data, _ in data }) {
        info = ServerInfo(name: name, serverID: id, appVersion: appVersion)
        self.files = files
        self.playback = playback
        self.store = store
        self.sayings = sayings
        self.shrink = shrink
        self.now = now
        favorites = store.favorites()
        library = store.library() ?? ShareLibrary()
        catalog = ShareCatalog(library, favorites: favorites, words: sayings.words)
    }

    // MARK: RemoteChannel

    public func open(timeout: Duration) async throws {
        isOpen = true
        // A scan that never finished, one that failed, or an index a day old: look at the share again.
        if case .failed = scan { rescan() } else if library.scanned.map({ now().timeIntervalSince($0) > rescanAfter }) ?? true { rescan() }
    }

    /// The phone's network changed: the connections are let go, so the next thing asked for goes over the new one at
    /// once instead of waiting out a dead line. A scan that had failed is tried again.
    public func lineChanged() {
        guard isOpen else { return }
        let files = files, playback = playback
        DispatchQueue.global(qos: .utility).async {
            playback.rest()
            files.rest()
        }
        if case .failed = scan { rescan() }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        stopScan()
        if isScanning { scan = .idle }
        streams.removeAll()
        files.rest()
        playback.rest()
        onClose?(nil)
    }

    public func request(_ command: RemoteCommand, timeout: Duration) async throws -> RemoteReply {
        guard isOpen else { throw RemoteLinkError.closed }
        switch command {
        case .hello(_, _, let version, let highest):
            guard RemoteProtocol.negotiate(baseline: version, highest: highest) != nil else { return .failed(reason: "") }
            Task { [weak self] in
                guard let self, self.isOpen else { return }
                // Nothing plays on a share: an idle player, an empty queue and no outputs, as a Mac with nothing on says it.
                self.onPush?(.player(PlayerState(playback: .stopped, loading: false, nowPlaying: nil, position: 0, positionAt: self.now(), duration: 0,
                                                 shuffle: false, repeatMode: .off, signal: nil, output: nil,
                                                 volume: VolumeState(route: .fixed, level: nil, muted: false), waitingFor: nil, error: nil, transitions: nil)))
                self.onPush?(.queue(QueueState(revision: 1, current: nil, playingNext: [], continuing: [], continuingTotal: 0)))
                self.onPush?(.outputs(OutputsState(outputs: [])))
            }
            return .welcome(info)
        case .streamOpen(let id, let maxSampleRate, let smaller, let dop):
            return await openStream(id, maxSampleRate: maxSampleRate, smaller: smaller ?? false, dop: dop)
        case .artwork(let key, let size):
            return await artwork(key, size: size)
        case .streamInfo(let ids, let maxSampleRate) where ids.count == 1:
            return await streamInfo(ids[0], maxSampleRate: maxSampleRate)
        default:
            return perform(command)
        }
    }

    public func read(stream: Int, offset: Int64, length: Int, timeout: Duration) async throws -> StreamFrame {
        guard isOpen, let open = streams[stream] else { throw RemoteLinkError.closed }
        let playback = playback, path = open.song.path, length = min(length, RemoteProtocol.maximumChunk)
        do {
            let data = try await playbackWorker.run {
                // A DSD file: the range of what the player reads is made from the DSD it covers.
                if let rendering = open.rendering {
                    return try rendering.read(offset: offset, length: length) { try playback.read(path, offset: $0, length: $1) }
                }
                return try playback.read(path, offset: offset, length: length)
            }
            noteReachable(true)
            return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: offset + Int64(data.count) >= open.size, payload: data)
        } catch let error as SMBError {
            noteReachable(false)
            throw RemoteLinkError.readFailed(sayings.trouble(error))
        }
    }

    // MARK: Scanning

    public var isScanning: Bool { if case .scanning = scan { true } else { false } }

    /// Looks at the share again: new and changed files are read, files that are gone are dropped.
    public func rescan() {
        guard isOpen, !isScanning else { return }
        stopScan()
        scan = .scanning(songs: 0)
        onChange?()
        let stop = StopFlag()
        self.stop = stop
        let files = files, previous = library, started = now(), store = store, glimpseEvery = glimpseEvery
        let moved: @Sendable (Int) -> Void = { [weak self] songs in Task { @MainActor in self?.scanMoved(songs) } }
        // Kept at once, on the scan's own thread: a scan cut short (the app closed, the share gone) carries on from it.
        let glimpsed: @Sendable (ShareLibrary) -> Void = { [weak self] partial in
            guard !stop.isSet else { return }
            store.save(partial)
            Task { @MainActor in self?.glimpse(partial) }
        }
        scanning = Task { [weak self, libraryWorker] in
            let result: Result<ShareLibrary, Error>
            do {
                let scanned = try await libraryWorker.run {
                    try ShareScanner.scan(files, previous: previous, now: started, glimpseEvery: glimpseEvery, progress: { moved($0.songs) }, glimpse: glimpsed, cancelled: { stop.isSet })
                }
                result = .success(scanned)
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.scanning = nil
            switch result {
            case .success(let scanned):
                self.noteReachable(true)
                self.adopt(scanned)
                self.scan = .idle
            case .failure(let error):
                self.noteReachable(false)
                // What a first scan found before it stopped is kept, and shown.
                if self.library.scanned == nil, let partial = self.store.library() { self.show(partial) }
                self.scan = .failed(error as? SMBError ?? .closed)
            }
            self.onChange?()
        }
    }

    private func stopScan() {
        stop?.set()
        stop = nil
        scanning?.cancel()
        scanning = nil
    }

    private func scanMoved(_ songs: Int) {
        guard case .scanning(let shown) = scan, songs > shown else { return }
        scan = .scanning(songs: songs)
        onChange?()
    }

    private func adopt(_ scanned: ShareLibrary) {
        let changed = scanned.songs != library.songs || scanned.covers != library.covers
        library = scanned
        store.save(scanned)
        guard changed else { return }
        store.clearCovers()
        catalog = ShareCatalog(scanned, favorites: favorites, words: sayings.words)
        revision += 1
    }

    /// Part of a first scan: shown and kept (a scan cut short carries on from it), without telling the screens to start
    /// over; they show it as they are opened.
    private func glimpse(_ partial: ShareLibrary) {
        guard isScanning else { return }
        show(partial)
        onChange?()
    }

    private func show(_ partial: ShareLibrary) {
        guard library.scanned == nil, partial.scanned == nil, partial.songs.count > library.songs.count else { return }
        library = partial
        catalog = ShareCatalog(partial, favorites: favorites, words: sayings.words)
    }

    private func noteReachable(_ value: Bool) {
        guard reachable != value else { return }
        reachable = value
        onChange?()
    }

    // MARK: Songs

    private func container(_ song: ShareSong) -> String {
        switch SongTagReader.fileExtension(song.fileName) {
        case "m4a", "mp4", "m4b": "m4a"
        case "wav", "wave": "wav"
        case "aif", "aiff", "aifc": "aiff"
        case let other: other
        }
    }

    private func format(_ song: ShareSong) -> StreamFormat {
        if song.tags.dsd != nil {
            return StreamFormat(codec: "DSD", container: container(song), sampleRate: song.tags.sampleRate, bitDepth: 1, channels: song.tags.channels,
                                channelLabels: nil, lossless: true)
        }
        return StreamFormat(codec: song.tags.codec, container: container(song), sampleRate: song.tags.sampleRate, bitDepth: song.tags.bitDepth,
                     channels: song.tags.channels, channelLabels: nil, lossless: song.tags.lossless)
    }

    private static func tag(size: Int64, modified: Date) -> String { "\(size)-\(Int64(modified.timeIntervalSince1970))" }

    /// A DSD file's tag says the form first: the phone names a stream's file by the start of its tag, and the DoP form and
    /// a PCM form of one song can be the same size.
    private static func tag(_ rendering: DSDRendering, size: Int64, modified: Date) -> String {
        "\(rendering.form.rawValue)\(Int(rendering.sampleRate))-" + tag(size: size, modified: modified)
    }

    /// What the player is given for a DSD file: 24-bit PCM in a CAF file (as DoP, the samples are the DSD's packaging).
    private func delivered(_ rendering: DSDRendering) -> StreamFormat {
        StreamFormat(codec: "PCM", container: "caf", sampleRate: rendering.sampleRate, bitDepth: 24, channels: rendering.channels, channelLabels: nil, lossless: true)
    }

    /// Opens a song for reading. The share is asked for the file first: a share that can't be reached, or a file that
    /// is no longer the one indexed, is said here rather than found out by a read.
    ///
    /// A DSD file is opened as the player can read it (`DSDRendering`): as DoP frames when the output takes them (`dop`,
    /// the highest carrier rate), else as PCM no higher than `maxSampleRate`.
    private func openStream(_ id: Int64, maxSampleRate: Double? = nil, smaller: Bool = false, dop: Double? = nil) async -> RemoteReply {
        guard let song = catalog.songs[id] else { return .failed(reason: sayings.notInLibrary) }
        let playback = playback
        do {
            let found = try await playbackWorker.run { try playback.info(song.path) }
            noteReachable(true)
            guard found.size == song.size else {
                if mendsItself { rescan() }
                return .failed(reason: sayings.changed)
            }
        } catch let error as SMBError {
            if error != .notFound { noteReachable(false) } else if mendsItself { drop(song) }
            return .failed(reason: error == .notFound ? sayings.notInLibrary : sayings.trouble(error))
        } catch {
            return .failed(reason: sayings.trouble(.closed))
        }
        guard isOpen else { return .failed(reason: "") }
        var rendering: DSDRendering?
        if let dsd = song.tags.dsd {
            rendering = DSDRendering.plan(dsd, maxSampleRate: maxSampleRate, smaller: smaller, dop: dop)
            guard rendering != nil else { return .failed(reason: sayings.notInLibrary) }
        }
        nextStream += 1
        streams[nextStream] = OpenStream(song: song, rendering: rendering)
        // More than a handful open means some were never closed: the oldest go.
        for old in streams.keys.sorted().dropLast(8) { streams[old] = nil }
        if let rendering {
            return .streamOpened(StreamDescriptor(stream: nextStream, kind: .pcm, byteSize: rendering.byteSize, format: delivered(rendering),
                                                  frames: rendering.frames, tag: Self.tag(rendering, size: song.size, modified: song.modified),
                                                  chunkSize: RemoteProtocol.defaultChunkSize, dsdRate: rendering.form == .dop ? song.tags.sampleRate : nil))
        }
        return .streamOpened(StreamDescriptor(stream: nextStream, kind: .original, byteSize: song.size, format: format(song), frames: song.tags.frames,
                                              tag: Self.tag(size: song.size, modified: song.modified), chunkSize: RemoteProtocol.defaultChunkSize))
    }

    /// A song whose file is gone: off the lists now (it isn't shown as something that can be played), and the index
    /// with it.
    private func drop(_ song: ShareSong) {
        guard library.songs.contains(where: { $0.id == song.id }) else { return }
        library.songs.removeAll { $0.id == song.id }
        store.save(library)
        catalog = ShareCatalog(library, favorites: favorites, words: sayings.words)
        revision += 1
        onChange?()
    }

    // MARK: Covers

    private func streamInfo(_ id: Int64, _ song: ShareSong, replayGain: ReplayGain?, maxSampleRate: Double? = nil) -> StreamInfo? {
        if let dsd = song.tags.dsd {
            // Asked without an output in mind: the PCM form (DoP is offered when a song is opened for a DAC).
            guard let rendering = DSDRendering.plan(dsd, maxSampleRate: maxSampleRate) else { return nil }
            return StreamInfo(id: id, streamable: true, kind: .pcm, source: format(song), delivered: delivered(rendering), macOnlyReason: nil,
                              byteSize: nil, totalFrames: rendering.frames, replayGain: replayGain, encoderDelay: nil, endPadding: nil)
        }
        return StreamInfo(id: id, streamable: true, kind: .original, source: format(song), delivered: format(song), macOnlyReason: nil,
                          byteSize: song.size, totalFrames: song.tags.frames, replayGain: replayGain, encoderDelay: nil, endPadding: nil)
    }

    /// One song asked about by itself is being asked for its ReplayGain values, to be played with them: its tags are
    /// read from the file again (a few small reads), so that an index made before those were read, or a file tagged
    /// since, still answers with what the file says now. A share that can't be read answers with what the index has.
    private func streamInfo(_ id: Int64, maxSampleRate: Double?) async -> RemoteReply {
        guard let song = catalog.songs[id] else { return .streamInfo(items: []) }
        let playback = playback
        let path = song.path, size = song.size
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let values: ReplayGain?
        do {
            values = try await playbackWorker.run {
                try SongTagReader.read(name: name, size: size) { offset, length in try playback.read(path, offset: offset, length: length) }
            }?.replayGain
        } catch {
            values = song.tags.replayGain
        }
        return .streamInfo(items: [streamInfo(id, song, replayGain: values, maxSampleRate: maxSampleRate)].compactMap { $0 })
    }

    private func artwork(_ key: String, size: Int) async -> RemoteReply {
        guard let cover = catalog.covers[key] else { return .failed(reason: "") }
        let size = min(max(size, 32), 2048)
        func reply(_ data: Data) -> RemoteReply {
            .artwork(key: key, size: size, mimeType: data.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg", data: data)
        }
        let store = store
        if let kept = store.cover(key, size: size) { return reply(kept) }
        let source: (path: String, offset: Int64, length: Int)
        switch cover {
        case .file(let path): source = (path, 0, 24 << 20)
        case .embedded(let id):
            guard let song = catalog.songs[id], let offset = song.tags.pictureOffset, let length = song.tags.pictureLength, length <= 24 << 20 else {
                return .failed(reason: "")
            }
            source = (song.path, offset, length)
        }
        let files = files, shrink = shrink
        // Covers come over the browsing connection, a megabyte at a time, behind whatever a scan is doing.
        let made = try? await libraryWorker.run { () -> Data? in
            var picture = Data()
            while picture.count < source.length {
                let piece = try files.read(source.path, offset: source.offset + Int64(picture.count), length: min(1 << 20, source.length - picture.count))
                if piece.isEmpty { break }
                picture.append(piece)
            }
            guard !picture.isEmpty, let small = shrink(picture, size) else { return nil }
            store.save(cover: small, key, size: size)
            return small
        }
        guard let made else { return .failed(reason: "") }
        return reply(made)
    }

    // MARK: The library

    private var sourceName: String { info.name }

    private func perform(_ command: RemoteCommand) -> RemoteReply {
        switch command {
        case .hello, .streamOpen, .artwork:
            return .failed(reason: "")      // answered above
        case .pair:
            return .failed(reason: "")
        case .ping, .setLanguage:
            return .ok

        // Playing, the queue and the volume belong to the phone's own player; nothing here has them.
        case .playPause, .play, .pause, .next, .previous, .stop, .seek, .setShuffle, .setRepeat,
             .jump, .removeFromQueue, .moveInQueue, .clearUpcoming,
             .playAlbum, .playTracks, .playPlaylist, .playNext, .addToQueue, .playAlbums, .playCopy,
             .selectOutput, .volume, .setVolume, .setTransitions,
             .setEqualizer, .setRoomCorrection, .setSpatialMode, .setSpatializeStereo, .setBalance:
            return .failed(reason: "")

        case .setFavorite(let ids, let on):
            let known = ids.filter { catalog.songs[$0] != nil }
            guard !known.isEmpty else { return .failed(reason: sayings.notInLibrary) }
            if on { favorites.formUnion(known) } else { favorites.subtract(known) }
            store.save(favorites: favorites)
            catalog.setFavorite(known, on)
            return .ok
        case .addToPlaylist, .createPlaylist, .playlistTracks:
            return .failed(reason: sayings.noPlaylists)
        case .playlists:
            return .playlists(items: [])

        case .albums(let offset, let limit, let sort, let filter):
            let listed = AlbumListing.arrange(catalog.albums.map(\.summary), sort: sort, filter: filter)
            let start = min(max(0, offset), listed.count)
            return .albums(items: Array(listed[start..<min(listed.count, start + max(0, limit))]), total: listed.count)
        case .tracks(let ids):
            return .tracks(items: ids.compactMap { catalog.tracks[$0] })
        case .albumTracks(let key):
            guard let album = catalog.album(key) else { return .failed(reason: sayings.notInLibrary) }
            return .tracks(items: album.tracks.compactMap { catalog.tracks[$0] })
        case .artists:
            return .artists(items: catalog.artists.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending })
        case .artistAlbums(let name):
            let theirs = catalog.albums.map(\.summary).filter { $0.artist == name }
            return .albums(items: theirs, total: theirs.count)
        case .favorites:
            return .tracks(items: catalog.allTracks.filter(\.favorite))
        case .library:
            let source = SourceSummary(id: 1, name: sourceName, kind: .network, online: reachable ?? true, scanning: isScanning,
                                       albumCount: catalog.albums.count, detail: "")
            return .library(LibraryOverview(albums: catalog.albums.count, artists: catalog.artists.count, songs: catalog.tracks.count,
                                            genres: catalog.genres.count, favorites: catalog.tracks.values.filter(\.favorite).count, playlists: 0,
                                            sources: [source]))
        case .genres:
            return .genres(items: catalog.genres)
        case .genreAlbums(let key):
            let theirs = catalog.albums(genre: key)
            return .albums(items: theirs, total: theirs.count)
        case .recentlyAdded(let limit):
            let newest = catalog.recentlyAdded(limit)
            return .albums(items: newest, total: newest.count)
        case .sourceAlbums(let id):
            guard id == 1 else { return .failed(reason: sayings.notInLibrary) }
            return .albums(items: catalog.albums.map(\.summary), total: catalog.albums.count)
        case .search(let text, let limit):
            return .tracks(items: catalog.search(text, limit: limit))
        case .songs(let offset, let limit):
            let page = catalog.songs(offset: offset, limit: limit)
            return .songs(items: page.items, total: page.total)
        case .find(let text, let limit):
            return .found(catalog.find(text, limit: limit))

        case .streamInfo(let ids, let maxSampleRate):
            return .streamInfo(items: ids.compactMap { id in
                guard let song = catalog.songs[id] else { return nil }
                return streamInfo(id, song, replayGain: song.tags.replayGain, maxSampleRate: maxSampleRate)
            })
        case .streamRead:
            return .failed(reason: "")
        case .streamClose(let stream):
            streams[stream] = nil
            return .ok
        }
    }
}
