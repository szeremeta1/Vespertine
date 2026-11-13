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
        /// The TIDAL track ID.
        public var id: Int { track.id }
        public var track: TidalTrack
        /// The album, when the track was enqueued with it (it gives the album artist).
        public var album: TidalAlbum?
        public var state: State
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
    @ObservationIgnored private let fetchCover: @Sendable (String) async -> Data?
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// The download being written, to stop it on `cancel`.
    @ObservationIgnored private var running: (id: Int, stop: Stop)?

    /// `sleep` is the pause between tracks and the wait through a backoff; `random` picks the pause in 1...3 s; `fetchCover` gets
    /// the cover (1280 px) by TIDAL image UUID.
    public init(resolver: TidalStreamResolver, catalog: any TidalCatalogReading, database: LibraryDatabase?, folder: URL = TidalDownloader.defaultFolder,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
                session: URLSession = TidalCDN.session,
                fetchCover: (@Sendable (String) async -> Data?)? = nil) {
        self.resolver = resolver
        self.catalog = catalog
        self.database = database
        self.folder = folder
        self.sleep = sleep
        self.random = random
        self.session = session
        self.fetchCover = fetchCover ?? { uuid in
            guard let (data, response) = try? await session.data(from: TidalCatalog.coverURL(uuid, size: 1280)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
    }

    // MARK: Queue

    /// Adds tracks not already waiting or downloading (a finished or failed one is queued again).
    public func enqueue(tracks: [TidalTrack]) { add(tracks.map { ($0, nil) }) }

    public func enqueue(album: Int) async {
        do {
            let tracks = try await catalog.albumTracks(album, priority: .download)
            add(tracks.map { ($0, nil) })
        } catch {
            // Nothing to show a track against: the album's failure is the caller's to report.
        }
    }

    public func enqueue(playlist: String) async {
        guard let tracks = try? await catalog.playlistTracks(playlist, priority: .download) else { return }
        add(tracks.map { ($0, nil) })
    }

    /// Takes the track out of the queue; one being written stops and leaves no file.
    public func cancel(_ id: Int) {
        if let running, running.id == id { running.stop.stop() }
        items.removeAll { $0.id == id }
    }

    private func add(_ entries: [(TidalTrack, TidalAlbum?)]) {
        for (track, album) in entries {
            if let index = items.firstIndex(where: { $0.id == track.id }) {
                switch items[index].state {
                case .done, .failed: items[index].state = .queued
                default: break
                }
                continue
            }
            items.append(Item(track: track, album: album, state: .queued))
        }
        if worker == nil { worker = Task { await self.run() } }
    }

    private func setState(_ id: Int, _ state: State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    /// Downloads the queue in order, one track at a time.
    private func run() async {
        var first = true
        while let next = items.first(where: { $0.state == .queued }) {
            if !first { try? await sleep(random(1...3)) }
            first = false
            guard let item = items.first(where: { $0.id == next.id && $0.state == .queued }) else { continue }
            await download(item)
        }
        worker = nil
    }

    private func download(_ item: Item) async {
        let id = item.id
        while items.contains(where: { $0.id == id }) {
            setState(id, .downloading(0))
            let stop = Stop()
            running = (id, stop)
            defer { running = nil }
            do {
                let stream = try await resolver.resolve(trackId: id, priority: .download)
                let destination = Self.destination(for: item, in: folder, fileExtension: stream.fileExtension)
                let edit = Self.tags(for: item, cover: await item.track.album.cover.asyncMap(fetchCover))
                let progress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, let index = self.items.firstIndex(where: { $0.id == id }),
                              case .downloading = self.items[index].state else { return }
                        self.items[index].state = .downloading(fraction)
                    }
                }
                let (resolver, session) = (resolver, session)
                let url = try await Task.detached(priority: .utility) {
                    try Self.write(stream: stream, trackId: id, resolver: resolver, session: session, to: destination, tags: edit,
                                   stop: stop, progress: progress)
                }.value
                try? database?.setTidalDownload(tidalId: id, path: url.path)
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
    nonisolated static func write(stream: TidalStream, trackId: Int, resolver: TidalStreamResolver, session: URLSession,
                                  to destination: URL, tags: TagEdit, stop: Stop, progress: @Sendable (Double) -> Void) throws -> URL {
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
                if stop.stopped { throw CancellationError() }
                let part = try reader.read(at: offset, count: 1 << 20)
                guard !part.isEmpty else { throw TidalError.malformedStream("the stream ended early") }
                try handle.write(contentsOf: part)
                offset += Int64(part.count)
                progress(Double(offset) / Double(max(1, reader.size)))
            }
            try handle.synchronize()
            try handle.close()
            try TagWriter.writeNewFileTags(tags, at: partial)
            if stop.stopped { throw CancellationError() }
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    // MARK: Names and tags

    /// `<folder>/<Album Artist>/<Album>/<disc>-<track, 2 digits> <Title>.<ext>`.
    nonisolated static func destination(for item: Item, in folder: URL, fileExtension: String) -> URL {
        let track = item.track
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
        let track = item.track
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
