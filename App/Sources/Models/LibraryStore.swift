//
// Nocturne — observable view of the library database.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import NocturneAudio
import NocturneLibrary
import Observation

enum FormatFilter: String, CaseIterable, Identifiable {
    case all, flac, pcm, alac, dsd, lossy, bits24, rate96, multichannel
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All formats"
        case .flac: "FLAC"
        case .pcm: "WAV / AIFF"
        case .alac: "ALAC"
        case .dsd: "DSD"
        case .lossy: "Lossy"
        case .bits24: "≥ 24-bit"
        case .rate96: "≥ 88.2 kHz"
        case .multichannel: "Multichannel"
        }
    }

    func matches(_ a: Album) -> Bool {
        switch self {
        case .all: true
        case .flac: a.codec == "FLAC"
        case .pcm: a.codec == "WAV" || a.codec == "AIFF"
        case .alac: a.codec == "ALAC"
        case .dsd: a.isDSD
        case .lossy: ["MP3", "AAC", "Vorbis", "Opus", "Musepack"].contains(a.codec)
        case .bits24: (a.maxBitDepth ?? 0) >= 24 || a.isDSD
        case .rate96: a.maxSampleRate >= 88_200 || a.isDSD
        case .multichannel: a.isMultichannel
        }
    }
}

@Observable
@MainActor
final class LibraryStore {
    let database: LibraryDatabase
    let artwork: ArtworkStore
    let scanner: LibraryScanner
    let tagWriter: TagWriter
    let enricher: MetadataEnricher

    private(set) var albums: [Album] = [] { didSet { genres = Genres.summarize(albums) } }
    /// Every genre in the library (normalized), for the Genres page and filters.
    private(set) var genres: [GenreSummary] = []
    private(set) var artists: [LibraryDatabase.ArtistSummary] = []
    private(set) var playlists: [Playlist] = []
    private(set) var sources: [LibrarySource] = []

    /// A location as people should see it: files on a network share read "High-Res Music › Artist/Album"
    /// (never the mount folder, which carries the server's address); local files use ~ paths.
    func displayPath(_ path: String) -> String {
        if let share = sources.first(where: { $0.remoteURL != nil && (path == $0.path || path.hasPrefix($0.path + "/")) }) {
            let rest = String(path.dropFirst(share.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = share.name ?? "Network share"
            return rest.isEmpty ? name : "\(name) › \(rest)"
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    private(set) var stats = LibraryDatabase.Stats(albums: 0, tracks: 0, artists: 0, bytes: 0, duration: 0)
    /// Bumped whenever tracks change, so detail views can reload.
    private(set) var revision = 0

    var albumSort: AlbumSort = .artist { didSet { observeAlbums() } }
    var formatFilter: FormatFilter = .all
    /// Albums page filters (nil = all): a genre key (see `Genres.key`) and a decade (1970 = the 1970s).
    var genreFilter: String?
    var decadeFilter: Int?

    private(set) var scanProgress: ScanProgress?
    private(set) var lastError: String?

    @ObservationIgnored private var albumTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    private var watcher: FolderWatcher?

    init(dataDirectory: URL) throws {
        database = try LibraryDatabase(url: dataDirectory.appendingPathComponent("Library.sqlite"))
        artwork = ArtworkStore(directory: dataDirectory.appendingPathComponent("Artwork", isDirectory: true))
        scanner = LibraryScanner(database: database, artwork: artwork)
        tagWriter = TagWriter(database: database, scanner: scanner,
                              backupDirectory: dataDirectory.appendingPathComponent("Tag Backups", isDirectory: true))
        enricher = MetadataEnricher(database: database)
        ArtworkCache.shared.store = artwork
        observe()
        Task { await tagWriter.purgeBackups() }
    }

    deinit {
        albumTask?.cancel()
        for task in tasks { task.cancel() }
    }

    var filteredAlbums: [Album] {
        albums.filter { a in
            (formatFilter == .all || formatFilter.matches(a))
                && (genreFilter.map { Genres.keys(a.genre).contains($0) } ?? true)
                && (decadeFilter.map { Genres.decade(a.year) == $0 } ?? true)
        }
    }

    func albums(genre key: String) -> [Album] { albums.filter { Genres.keys($0.genre).contains(key) } }

    /// Decades present in the library, newest first.
    var decades: [Int] { Array(Set(albums.compactMap { Genres.decade($0.year) })).sorted(by: >) }

    // MARK: Observation

    private func observe() {
        observeAlbums()
        let writer = database.writer
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try Row.fetchAll(db, sql: """
                    SELECT coalesce(albumArtist, artist, 'Unknown Artist') AS name, count(DISTINCT albumKey) AS albums,
                           count(*) AS tracks, max(artworkKey) AS art
                    FROM track WHERE isMissing = 0 GROUP BY lower(name) ORDER BY min(albumArtistSortKey)
                    """).map { LibraryDatabase.ArtistSummary(name: $0["name"], albumCount: $0["albums"], trackCount: $0["tracks"], artworkKey: $0["art"]) }
            }
            do { for try await value in obs.values(in: writer) { self?.artists = value; self?.revision += 1 } } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in try Playlist.order(Column("sortIndex"), Column("name")).fetchAll(db) }
            do { for try await value in obs.values(in: writer) { self?.playlists = value } } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in try LibrarySource.order(Column("path")).fetchAll(db) }
            do {
                for try await value in obs.values(in: writer) {
                    self?.sources = value
                    self?.updateWatcher()
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try Row.fetchOne(db, sql: """
                    SELECT count(DISTINCT albumKey) AS a, count(*) AS t, count(DISTINCT lower(coalesce(albumArtist, artist))) AS ar,
                           coalesce((SELECT sum(size) FROM (SELECT max(fileSize) AS size FROM track WHERE isMissing = 0 GROUP BY filePath)), 0) AS b, coalesce(sum(duration), 0) AS d FROM track WHERE isMissing = 0
                    """).map { LibraryDatabase.Stats(albums: $0["a"], tracks: $0["t"], artists: $0["ar"], bytes: $0["b"], duration: $0["d"]) }
            }
            do { for try await value in obs.values(in: writer) { if let value { self?.stats = value } } } catch {}
        })
    }

    private func observeAlbums() {
        albumTask?.cancel()
        let writer = database.writer
        let sql = LibraryDatabase.albumsSQL(sort: albumSort)
        albumTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in try Row.fetchAll(db, sql: sql).map(LibraryDatabase.album(from:)) }
            do { for try await value in obs.values(in: writer) { self?.albums = value } } catch {}
        }
    }

    // MARK: Sources and scanning

    func addFolders(_ urls: [URL], mode: ImportMode, managedRoot: URL) async {
        do {
            switch mode {
            case .reference:
                for url in urls {
                    let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    let source = try database.addSource(LibrarySource(path: url.standardizedFileURL.path, bookmark: bookmark, mode: .reference))
                    await scan(source)
                }
            case .copyAndOrganize:
                try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
                let source = try database.addSource(LibrarySource(path: managedRoot.standardizedFileURL.path, mode: .managed))
                do { _ = try await Task.detached { try Importer.copyAndOrganize(urls, into: managedRoot) }.value }
                catch { await scan(source); throw error }
                await scan(source)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func scan(_ source: LibrarySource) async {
        scanProgress = ScanProgress(sourcePath: source.path, processed: 0, total: 0, added: 0, updated: 0)
        do {
            let summary = try await scanner.scan(source) { [weak self] progress in
                Task { @MainActor [weak self] in self?.scanProgress = progress }
            }
            if !summary.failed.isEmpty { lastError = "Could not read \(summary.failed.count) file(s): \(summary.failed.prefix(3).joined(separator: ", "))" }
            if !summary.movedTracks.isEmpty { onTracksMoved?(summary.movedTracks) }
        } catch {
            lastError = error.localizedDescription
        }
        scanProgress = nil
        revision += 1
        onScanFinished?()
    }

    /// Called after every scan (e.g. to analyze newly added music).
    var onScanFinished: (() -> Void)?
    /// Called when a scan found files that were moved or renamed: old track ID → new track ID.
    var onTracksMoved: (([Int64: Int64]) -> Void)?

    private var missingRescanAt: [Int64: Date] = [:]

    /// A file the library lists is gone (moved or deleted, e.g. by a library manager reorganizing a share):
    /// rescan its source now, so moved files are found again. At most every two minutes per source.
    @discardableResult
    func rescanForMissingFile(_ track: Track) -> Bool {
        guard let id = track.sourceId, let source = sources.first(where: { $0.id == id }), scanProgress == nil,
              Date().timeIntervalSince(missingRescanAt[id] ?? .distantPast) > 120 else { return false }
        missingRescanAt[id] = Date()
        Task { await scan(source) }
        return true
    }

    func rescanAll() async {
        for source in sources { await scan(source) }
    }

    func removeSource(_ source: LibrarySource) {
        guard let id = source.id else { return }
        try? database.removeSource(id)
        revision += 1
    }

    func updateWatcher() {
        // File-system events don't cross the network; shares are re-checked by NetworkShareManager.
        let paths = sources.filter { !$0.isNetwork }.map(\.path)
        if watcher == nil {
            watcher = FolderWatcher { [weak self] changed in
                Task { @MainActor in
                    guard let self else { return }
                    for path in changed {
                        if let source = self.sources.first(where: { $0.path == path }), self.scanProgress == nil {
                            await self.scan(source)
                        }
                    }
                }
            }
        }
        watcher?.watch(UserDefaults.standard.bool(forKey: "watchFolders") ? paths : [])
    }

    func clearError() { lastError = nil }

    // MARK: Finding music and enriching metadata

    /// Music on this Mac that isn't in the library yet.
    func findMusic(progress: @escaping @Sendable (MusicFinder.Progress) -> Void) async -> [FoundFolder] {
        await MusicFinder.find(excludingRoots: sources.map(\.url), progress: progress)
    }

    /// Adds found music. Import copies (APFS clones) just the chosen files; reference adds their folders.
    /// Returns the album keys that were added, for a follow-up enrichment pass.
    func add(found files: [URL], mode: ImportMode, managedRoot: URL) async -> [String] {
        let before = Set(albums.map(\.key))
        do {
            switch mode {
            case .copyAndOrganize:
                try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
                let source = try database.addSource(LibrarySource(path: managedRoot.standardizedFileURL.path, mode: .managed))
                let chosen = files
                _ = try await Task.detached { try Importer.copyAndOrganize(chosen, into: managedRoot) }.value
                await scan(source)
            case .reference:
                let folders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
                for folder in folders.sorted(by: { $0.path < $1.path }) {
                    let bookmark = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    let source = try database.addSource(LibrarySource(path: folder.path, bookmark: bookmark, mode: .reference))
                    await scan(source)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        let after = (try? database.albums()) ?? []
        return after.map(\.key).filter { !before.contains($0) }
    }

    /// Proposals for the given albums (or every album missing something).
    func enrichmentProposals(albumKeys: [String]?, correctExisting: Bool,
                             progress: @escaping @MainActor (Int, Int) -> Void) async -> (proposals: [EnrichmentProposal], complete: Int) {
        await enricher.setCorrectExisting(correctExisting)
        let keys = albumKeys ?? ((try? database.albums()) ?? []).map(\.key)
        var proposals: [EnrichmentProposal] = []
        var complete = 0
        for (i, key) in keys.enumerated() {
            progress(i, keys.count)
            let tracks = self.tracks(albumKey: key)
            guard MetadataEnricher.needsEnrichment(tracks) || correctExisting else { complete += 1; continue }
            if let p = await enricher.propose(albumKey: key, tracks: tracks) { proposals.append(p) } else { complete += 1 }
        }
        progress(keys.count, keys.count)
        return (proposals, complete)
    }

    func apply(_ proposals: [EnrichmentProposal]) async -> (written: Int, failed: Int) {
        var written = 0, failed = 0
        for p in proposals {
            let tracks = self.tracks(albumKey: p.albumKey)
            if let r = try? await tagWriter.apply(p, tracks: tracks) { written += r.written + r.databaseOnly; failed += r.failures.count }
            else { failed += tracks.count }
        }
        revision += 1
        return (written, failed)
    }

    func setSkipsNonMusic(_ value: Bool) { Task { await scanner.setSkipsNonMusic(value) } }

    // MARK: Queries (synchronous, small)

    func tracks(albumKey: String) -> [Track] { (try? database.tracks(albumKey: albumKey)) ?? [] }
    func tracks(in playlist: Playlist) -> [Track] { (try? database.tracks(in: playlist)) ?? [] }
    func tracks(ids: [Int64]) -> [Track] { (try? database.tracks(ids: ids)) ?? [] }
    func allTracks() -> [Track] { (try? database.allTracks()) ?? [] }
    func search(_ text: String) -> [Track] { (try? database.search(text)) ?? [] }
    func albums(artist: String) -> [Album] { (try? database.albums(artist: artist)) ?? [] }
    func albums(underPath path: String) -> [Album] { (try? database.albums(underPath: path)) ?? [] }

    func album(key: String) -> Album? { albums.first { $0.key == key } }

    // MARK: Editing

    func apply(_ edit: TagEdit, to tracks: [Track]) async -> TagWriteResult? {
        do {
            let result = try await tagWriter.apply(edit, to: tracks)
            revision += 1
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func revert(_ tracks: [Track]) async -> Int {
        var restored = 0
        for t in tracks {
            guard let id = t.id else { continue }
            do { if try await tagWriter.revertLastEdit(trackID: id) { restored += 1 } }
            catch { lastError = error.localizedDescription }
        }
        revision += 1
        return restored
    }

    func createPlaylist(name: String, rules: SmartRules? = nil, trackIDs: [Int64] = []) -> Playlist? {
        guard let p = try? database.createPlaylist(name: name, rules: rules) else { return nil }
        if let id = p.id, !trackIDs.isEmpty { try? database.append(trackIDs: trackIDs, to: id) }
        return p
    }

    func append(_ trackIDs: [Int64], to playlist: Playlist) {
        guard let id = playlist.id, !playlist.isSmart else { return }
        try? database.append(trackIDs: trackIDs, to: id)
        revision += 1
    }

    func setPlaylistOrder(_ trackIDs: [Int64], playlist: Playlist) {
        guard let id = playlist.id else { return }
        try? database.setPlaylistTracks(trackIDs, playlistID: id)
        revision += 1
    }

    func deletePlaylist(_ playlist: Playlist) { if let id = playlist.id { try? database.deletePlaylist(id) } }
    func renamePlaylist(_ playlist: Playlist, to name: String) { if let id = playlist.id { try? database.renamePlaylist(id, to: name) } }
    func updateRules(_ playlist: Playlist, _ rules: SmartRules) {
        if let id = playlist.id { try? database.updateSmartRules(id, rules); revision += 1 }
    }

    func markPlayed(_ trackID: Int64) { try? database.markPlayed(trackID) }

    /// A saved analysis changes verdict tags in lists; refresh them at most every couple of seconds.
    func analysisSaved() {
        guard !analysisRefreshPending else { return }
        analysisRefreshPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            analysisRefreshPending = false
            revision += 1
        }
    }
    private var analysisRefreshPending = false

    func storedAnalysis(for track: Track) -> LibraryDatabase.StoredAnalysis? {
        try? database.storedAnalysis(for: track)
    }
}
