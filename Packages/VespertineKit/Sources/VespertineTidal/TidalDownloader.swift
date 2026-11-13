//
// Vespertine: explicit downloads of TIDAL tracks, albums and playlists. One track at a time, a random pause of 1–3 s between
// tracks; each is resolved (download priority), read through the same readers as playback (a DASH stream remuxed to FLAC), written
// to a `.partial` file, tagged (TIDAL_TRACK_ID included) and renamed. A backoff pauses the queue until it ends.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio
import VespertineLibrary

@MainActor
@Observable
public final class TidalDownloader {
    public enum State: Sendable, Equatable {
        case queued
        /// The fraction of the file written.
        case downloading(Double)
        case done(URL)
        case failed(String)
        /// Waiting for a TIDAL backoff to end; the reason as the user reads it.
        case paused(String)
    }

    public struct Item: Sendable, Identifiable, Equatable {
        /// A track to download, or an album or playlist whose track list is still to be read (it is replaced by its tracks once
        /// read, and stays, failed or paused, when it can't be).
        public enum Kind: Sendable, Hashable {
            case track(TidalTrack)
            case album(Int)
            case playlist(String)
        }

        public var kind: Kind
        /// The album, when the track was enqueued with it (it gives the album artist, so a compilation's tracks share a folder).
        public var album: TidalAlbum?
        public var state: State

        /// `track:<id>`, `album:<id>` or `playlist:<uuid>`.
        public var id: String {
            switch kind {
            case .track(let track): "track:\(track.id)"
            case .album(let id): "album:\(id)"
            case .playlist(let uuid): "playlist:\(uuid)"
            }
        }

        public var track: TidalTrack? { if case .track(let track) = kind { track } else { nil } }
        public var trackId: Int? { track?.id }
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vespertine", isDirectory: true).appendingPathComponent("TIDAL", isDirectory: true)
    }

    public private(set) var items: [Item] = []
    public var folder: URL

    @ObservationIgnored private let resolver: TidalStreamResolver
    @ObservationIgnored private let catalog: any TidalCatalogReading
    @ObservationIgnored private let database: LibraryDatabase?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let random: @Sendable (ClosedRange<Double>) -> Double
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let gate: ShareIOGate
    @ObservationIgnored private let fetchCover: @Sendable (String) async -> Data?
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// The download being written, to stop it on `cancel`.
    @ObservationIgnored private var running: (id: String, stop: Stop)?
    /// Removing the `.partial` files an earlier run left (a quit or a crash mid-download); downloads start after it.
    @ObservationIgnored let startup: Task<Void, Never>
    /// How long a collection paused by a backoff waits before it is read again.
    @ObservationIgnored private var collectionWaits: [Item.ID: TimeInterval] = [:]
    /// Bytes asked of the stream per read (smaller in tests, so a file of a few hundred KiB takes several).
    @ObservationIgnored var readSize = 1 << 20

    /// `sleep` is the pause between tracks and the wait through a backoff; `random` picks the pause in 1...3 s; `fetchCover` gets
    /// the cover (1280 px) by TIDAL image UUID. `gate` says when a playing song needs the network: downloads hold between reads
    /// then (the playback cache's copies and the player report to `ShareIOGate.shared`).
    public init(resolver: TidalStreamResolver, catalog: any TidalCatalogReading, database: LibraryDatabase?, folder: URL = TidalDownloader.defaultFolder,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
                session: URLSession = TidalCDN.session,
                gate: ShareIOGate = .shared,
                fetchCover: (@Sendable (String) async -> Data?)? = nil) {
        self.resolver = resolver
        self.catalog = catalog
        self.database = database
        self.folder = folder
        self.sleep = sleep
        self.random = random
        self.session = session
        self.gate = gate
        self.fetchCover = fetchCover ?? { uuid in
            guard let (data, response) = try? await session.data(from: TidalCatalog.coverURL(uuid, size: 1280)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        startup = Task.detached(priority: .utility) { Self.removeStalePartials(in: folder) }
    }

    // MARK: Queue

    /// Adds tracks not already waiting or downloading (a finished or failed one is queued again).
    public func enqueue(tracks: [TidalTrack]) {
        insert(tracks.map { Item(kind: .track($0), album: nil, state: .queued) }, replacing: nil)
    }

    /// Reads the album (for its artist and title) and its tracks, then queues them. If TIDAL is backing off, the album waits in
    /// the queue, paused, and is read when the backoff ends; any other failure leaves it there, failed, with the reason.
    public func enqueue(album: Int) async {
        let placeholder = Item(kind: .album(album), album: nil, state: .queued)
        guard !items.contains(where: { $0.id == placeholder.id }) else { return }
        items.append(placeholder)
        await expand(placeholder.id)
        startWorker()
    }

    /// The playlist's tracks, in order; failures as for `enqueue(album:)`.
    public func enqueue(playlist: String) async {
        let placeholder = Item(kind: .playlist(playlist), album: nil, state: .queued)
        guard !items.contains(where: { $0.id == placeholder.id }) else { return }
        items.append(placeholder)
        await expand(placeholder.id)
        startWorker()
    }

    /// Takes the track out of the queue; one being written stops and leaves no file.
    public func cancel(_ trackId: Int) { cancel(item: "track:\(trackId)") }

    /// Takes any item (a track, or an album or playlist not read yet) out of the queue.
    public func cancel(item id: Item.ID) {
        if let running, running.id == id { running.stop.stop() }
        items.removeAll { $0.id == id }
    }

    /// Puts `new` in the queue (in place of `placeholder` when given), skipping tracks already waiting or downloading.
    private func insert(_ new: [Item], replacing placeholder: Item.ID?) {
        var adding: [Item] = []
        for item in new {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                switch items[index].state {
                case .done, .failed:
                    items[index].state = .queued
                    if item.album != nil { items[index].album = item.album }
                default: break
                }
                continue
            }
            if adding.contains(where: { $0.id == item.id }) { continue }
            adding.append(item)
        }
        if let placeholder, let index = items.firstIndex(where: { $0.id == placeholder }) {
            items.replaceSubrange(index...index, with: adding)
        } else {
            items += adding
        }
        startWorker()
    }

    private func startWorker() {
        if worker == nil, items.contains(where: Self.isWaiting) { worker = Task { await self.run() } }
    }

    /// Queued, or a collection paused by a backoff (read again once the backoff ends).
    private static func isWaiting(_ item: Item) -> Bool {
        switch (item.kind, item.state) {
        case (_, .queued): true
        case (.album, .paused), (.playlist, .paused): true
        default: false
        }
    }

    private func setState(_ id: Item.ID, _ state: State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    /// Reads a collection's track list and puts its tracks in its place. Throws only a backoff (with the time left), after
    /// marking the item paused; other failures mark it failed.
    @discardableResult
    private func expand(_ id: Item.ID) async -> TimeInterval? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        do {
            switch item.kind {
            case .album(let albumId):
                let album = try await catalog.album(albumId, priority: .download)
                let tracks = try await catalog.albumTracks(albumId, priority: .download)
                insert(tracks.map { Item(kind: .track($0), album: album, state: .queued) }, replacing: id)
            case .playlist(let uuid):
                let tracks = try await catalog.playlistTracks(uuid, priority: .download)
                insert(tracks.map { Item(kind: .track($0), album: nil, state: .queued) }, replacing: id)
            case .track:
                return nil
            }
            return nil
        } catch let error as TidalError {
            switch error {
            case .backingOff(let remaining, _), .abuse(let remaining):
                setState(id, .paused(error.localizedDescription))
                collectionWaits[id] = max(1, remaining)
                return max(1, remaining)
            default:
                setState(id, .failed(error.localizedDescription))
                return nil
            }
        } catch {
            setState(id, .failed(error.localizedDescription))
            return nil
        }
    }

    /// Downloads the queue in order, one track at a time.
    private func run() async {
        await startup.value
        var first = true
        while let next = items.first(where: Self.isWaiting) {
            switch next.kind {
            case .album, .playlist:
                // A collection the backoff held up: wait it out, then read it.
                if case .paused = next.state {
                    try? await sleep(collectionWaits.removeValue(forKey: next.id) ?? 1)
                    await expand(next.id)
                }
                continue
            case .track:
                if !first { try? await sleep(random(1...3)) }
                first = false
                guard let item = items.first(where: { $0.id == next.id && $0.state == .queued }) else { continue }
                await download(item)
            }
        }
        worker = nil
    }

    private func download(_ item: Item) async {
        guard let track = item.track else { return }
        let id = item.id, trackId = track.id
        while items.contains(where: { $0.id == id }) {
            setState(id, .downloading(0))
            let stop = Stop()
            running = (id, stop)
            defer { running = nil }
            do {
                let stream = try await resolver.resolve(trackId: trackId, priority: .download)
                let current = items.first { $0.id == id } ?? item
                let destination = Self.destination(for: current, in: folder, fileExtension: stream.fileExtension)
                let edit = Self.tags(for: current, cover: await track.album.cover.asyncMap(fetchCover))
                let progress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, let index = self.items.firstIndex(where: { $0.id == id }),
                              case .downloading = self.items[index].state else { return }
                        self.items[index].state = .downloading(fraction)
                    }
                }
                let (resolver, session, gate, readSize) = (resolver, session, gate, readSize)
                // On a thread of its own, never one of the cooperative pool: the copy blocks for the whole download (and a
                // renewal blocks on a task that needs a pool thread).
                let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    let thread = Thread {
                        continuation.resume(with: Result {
                            try Self.write(stream: stream, trackId: trackId, resolver: resolver, session: session, gate: gate,
                                           readSize: readSize, to: destination, tags: edit, stop: stop, progress: progress)
                        })
                    }
                    thread.name = "Vespertine TIDAL Download"
                    thread.qualityOfService = .utility
                    thread.start()
                }
                try? database?.setTidalDownload(tidalId: trackId, path: url.path)
                setState(id, .done(url))
                return
            } catch let error as TidalError {
                switch error {
                case .backingOff(let remaining, _), .abuse(let remaining):
                    setState(id, .paused(error.localizedDescription))
                    try? await sleep(max(1, remaining))
                    continue
                default:
                    setState(id, .failed(error.localizedDescription))
                    return
                }
            } catch {
                if stop.stopped { return }   // cancelled: the item is gone already
                setState(id, .failed(error.localizedDescription))
                return
            }
        }
    }

    /// Deletes every `.partial` file under `folder`: what an earlier run was writing when it stopped.
    nonisolated static func removeStalePartials(in folder: URL) {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Writing (off the main actor)

    /// Stops a download being written (its reader's requests end at once).
    final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var reader: (any RemoteCacheReader)?
        private var done = false
        var stopped: Bool { lock.withLock { done } }
        func attach(_ reader: any RemoteCacheReader) {
            let stopNow = lock.withLock { () -> Bool in self.reader = reader; return done }
            if stopNow { reader.cancel() }
        }
        func stop() {
            let current = lock.withLock { () -> (any RemoteCacheReader)? in done = true; return reader }
            current?.cancel()
        }
    }

    /// Reads the stream from start to end into `<destination>.partial`, tags it, and renames it to `destination` (replacing an
    /// earlier download of the same track). The partial file is removed when anything fails.
    nonisolated static func write(stream: TidalStream, trackId: Int, resolver: TidalStreamResolver, session: URLSession, gate: ShareIOGate,
                                  readSize: Int = 1 << 20, to destination: URL, tags: TagEdit, stop: Stop, progress: @Sendable (Double) -> Void) throws -> URL {
        try yieldToPlayback(gate, stop: stop)
        let reader = try TidalPlayback.reader(for: stream, renew: {
            try TidalPlayback.resolveBlocking(resolver, trackId: trackId, priority: .download)
        }, session: session)
        stop.attach(reader)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var offset: Int64 = 0
            while offset < reader.size {
                try yieldToPlayback(gate, stop: stop)
                let part = try reader.read(at: offset, count: readSize)
                guard !part.isEmpty else { throw TidalError.malformedStream("the stream ended early") }
                try handle.write(contentsOf: part)
                offset += Int64(part.count)
                progress(Double(offset) / Double(max(1, reader.size)))
            }
            try handle.synchronize()
            try handle.close()
            try TagWriter.writeNewFileTags(tags, at: partial)
            if stop.stopped { throw CancellationError() }
            if fileManager.fileExists(atPath: destination.path) {
                // A download again: the old file stays whole until the new one takes its place in one step.
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// Holds while a playing song needs the network (its copy is starting or behind, or the output's buffer is under a third),
    /// as the share cache's copies do; throws once the download is stopped.
    nonisolated static func yieldToPlayback(_ gate: ShareIOGate, stop: Stop) throws {
        while true {
            if stop.stopped { throw CancellationError() }
            guard gate.isPaused else { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: Names and tags

    /// `<folder>/<Album Artist>/<Album>/<disc>-<track, 2 digits> <Title>.<ext>`.
    nonisolated static func destination(for item: Item, in folder: URL, fileExtension: String) -> URL {
        guard let track = item.track else { return folder }
        let artist = item.album?.artist?.name ?? (track.artists.first { $0.type == "MAIN" } ?? track.artists.first)?.name ?? "Unknown Artist"
        let album = item.album?.title ?? track.album.title
        let name = String(format: "%d-%02d ", track.volumeNumber, track.trackNumber) + safe(displayTitle(track))
        return folder.appendingPathComponent(safe(artist), isDirectory: true).appendingPathComponent(safe(album), isDirectory: true)
            .appendingPathComponent(name).appendingPathExtension(fileExtension)
    }

    nonisolated static func displayTitle(_ track: TidalTrack) -> String {
        guard let version = track.version, !version.isEmpty else { return track.title }
        return "\(track.title) (\(version))"
    }

    /// A file or folder name: no path separators or colons, no leading dot (hidden), not empty, at most 120 characters.
    nonisolated static func safe(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    /// Title, artists, album, album artist, track and disc, date, ISRC, copyright, ReplayGain, cover and TIDAL_TRACK_ID.
    nonisolated static func tags(for item: Item, cover: Data?) -> TagEdit {
        guard let track = item.track else { return TagEdit() }
        let input = TidalTrackInput(track, album: item.album)
        var fields: [TagField: String?] = [
            .title: displayTitle(track),
            .artist: input.artist,
            .album: input.album,
            .albumArtist: input.albumArtist,
            .trackNumber: String(track.trackNumber),
            .discNumber: String(track.volumeNumber),
            .isrc: track.isrc,
        ]
        if let date = input.releaseDate { fields[.releaseDate] = date }
        if let total = item.album?.numberOfVolumes { fields[.discTotal] = String(total) }
        var custom: [String: String?] = ["TIDAL_TRACK_ID": String(track.id)]
        if let copyright = input.copyright { custom["COPYRIGHT"] = copyright }
        if let gain = track.replayGain { custom["REPLAYGAIN_TRACK_GAIN"] = String(format: "%.2f dB", gain) }
        if let peak = track.peak { custom["REPLAYGAIN_TRACK_PEAK"] = String(format: "%.6f", peak) }
        return TagEdit(fields: fields, custom: custom, artwork: cover.map { .replace($0) })
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
