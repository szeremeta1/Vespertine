//
// Vespertine: observable view of the library database.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import VespertineAudio
import VespertineLibrary
import VespertineTidal
import Observation

@Observable
@MainActor
final class LibraryStore {
    let database: LibraryDatabase
    let artwork: ArtworkStore
    let scanner: LibraryScanner
    let tagWriter: TagWriter
    let enricher: MetadataEnricher
    /// Finds a song's cover at play time when the library holds none for it, or a stale one (see `ArtworkResolver`).
    let artworkResolver: ArtworkResolver

    private(set) var albums: [Album] = [] {
        didSet {
            genres = Genres.summarize(albums)
            albumsByKey = Dictionary(albums.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            countCopies()
        }
    }
    /// The same albums by key.
    private(set) var albumsByKey: [String: Album] = [:]
    /// Every genre in the library (normalized), for the Genres page and filters.
    private(set) var genres: [GenreSummary] = []
    private(set) var artists: [LibraryDatabase.ArtistSummary] = []
    private(set) var playlists: [Playlist] = []
    /// Playlists with their own transitions (Smart Mix's per-playlist choice), by id.
    private(set) var playlistTransitions: [Int64: TransitionOverride] = [:]
    /// Every favorite song's track ID (missing files included, so their heart stays filled).
    private(set) var favoriteIDs: Set<Int64> = []
    /// Favorite songs whose files are present (a song in stereo and 5.1 counts once): the number in the sidebar.
    private(set) var favoriteCount = 0
    /// Albums with at least one favorite song (present), for the Favorites filter on album pages.
    private(set) var favoriteAlbumKeys: Set<String> = []
    /// The folders, drives and shares the library indexes. Never the TIDAL account: it is no folder or share, and the code that
    /// scans, watches, mounts or lists sources must not meet it (`tidalSource`).
    private(set) var sources: [LibrarySource] = []
    /// The TIDAL account's source, while TIDAL is switched on and the library has one.
    private(set) var tidalSource: LibrarySource?
    /// Whether the TIDAL account's songs are in every list, count and album (Settings › Online › TIDAL integration; off by default,
    /// and then the library reads exactly as one that never had a TIDAL account).
    private(set) var includesTidal = false
    /// What the library keeps of each TIDAL song (by track ID) beyond its row: the quality TIDAL lists, whether it streams here, and its
    /// download. Empty while TIDAL is off.
    private(set) var tidalRecords: [Int64: TidalTrackRecord] = [:] { didSet { tidalRecordsVersion += 1 } }
    /// Counts the changes of `tidalRecords` (cheap to compare, unlike the records).
    private(set) var tidalRecordsVersion = 0
    /// Albums whose songs are all streamed (none downloaded): they can't play without TIDAL. Empty while TIDAL is off.
    private(set) var streamOnlyAlbumKeys: Set<String> = []

    // MARK: Copies

    /// Which copy of each album plays, for albums where one was chosen (`AlbumCopyChoice`).
    private(set) var copyChoices: [String: AlbumCopyChoice] = [:]
    /// Tracks that are the preferred copy of their song.
    private(set) var preferredCopyIDs: Set<Int64> = []
    /// How many copies each album has, for albums with more than one (the "3 COPIES" on its card). Worked out in the
    /// background after the library changes.
    private(set) var copyCounts: [String: Int] = [:]
    /// Whether `copyCounts` has been worked out once.
    private(set) var copyCountsReady = false
    /// Settings › Playback › "Bundle copies of an album": albums with no choice of their own play as one, the output picking
    /// the copy. Off by default: one copy plays, the best for the output, and every other copy stays a copy.
    var bundlesCopiesByDefault = false {
        didSet { if bundlesCopiesByDefault != oldValue { favoriteVersions() } }
    }
    @ObservationIgnored private var copyCountTask: Task<Void, Never>?

    /// What plays for an album: a chosen copy, all copies bundled, or (no choice) the best copy for the output.
    func copyChoice(albumKey: String) -> AlbumCopyChoice {
        copyChoices[albumKey] ?? (bundlesCopiesByDefault ? .bundled : .automatic)
    }

    func isBundled(albumKey: String) -> Bool { copyChoice(albumKey: albumKey) == .bundled }

    /// The album's copies and its songs across them.
    func albumCopies(albumKey: String) -> AlbumCopies { LibraryCopies.analyze(tracks(albumKey: albumKey)) }

    func setCopyChoice(_ choice: AlbumCopyChoice, albumKey: String) {
        do { try database.setCopyChoice(choice, albumKey: albumKey) } catch { lastError = error.localizedDescription }
    }

    /// Makes `track` the copy its song plays whenever the output can, or (`preferred` false) no copy in particular.
    func setPreferredCopy(_ preferred: Bool, track: Track) {
        guard let id = track.id else { return }
        let song = versions(of: [track]).first?.compactMap(\.id) ?? []
        do { try database.setPreferredCopy(preferred, trackID: id, songTrackIDs: song) } catch { lastError = error.localizedDescription }
    }

    func isPreferredCopy(_ track: Track) -> Bool { track.id.map(preferredCopyIDs.contains) ?? false }

    /// For each track, the versions playback may pick among: every copy of its song when its album's copies are bundled,
    /// else just the track (a copy chosen plays as itself, on any output).
    func playbackVersions(of tracks: [Track]) -> [[Track]] {
        let bundled = tracks.map { isBundled(albumKey: $0.albumKey) }
        guard bundled.contains(true) else { return tracks.map { [$0] } }
        let songs = versions(of: tracks)
        return zip(tracks, zip(bundled, songs)).map { t, b in b.0 ? b.1 : [t] }
    }

    private func countCopies() {
        let first = copyCountTask == nil
        copyCountTask?.cancel()
        let database = database
        copyCountTask = Task { [weak self] in
            // A scan changes albums many times a second: count once things settle.
            if !first { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            let counts = await Task.detached(priority: .utility) { () -> [String: Int] in
                let tracks = (try? database.allTracks()) ?? []
                var counts: [String: Int] = [:]
                for (key, album) in Dictionary(grouping: tracks.filter { !$0.isMissing }, by: \.albumKey) {
                    let n = LibraryCopies.partition(album).count
                    if n > 1 { counts[key] = n }
                }
                return counts
            }.value
            guard !Task.isCancelled, let self else { return }
            self.copyCountsReady = true
            if self.copyCounts != counts { self.copyCounts = counts }
        }
    }

    /// A location as people should see it: files on a network share read "Music Share › Artist/Album"
    /// (never the mount folder, which carries the server's address); local files use ~ paths.
    func displayPath(_ path: String) -> String {
        if let share = sources.first(where: { $0.remoteURL != nil && (path == $0.path || path.hasPrefix($0.path + "/")) }) {
            let rest = String(path.dropFirst(share.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = share.name ?? String(localized: "Network share")
            return rest.isEmpty ? name : "\(name) › \(rest)"
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    /// For each track, every version and copy of its song on its album (stereo and multichannel, the same song
    /// in two places), or just the track. The albums are read at once, so a whole library queues in one read.
    func versions(of tracks: [Track]) -> [[Track]] {
        let albumTracks = self.tracks(albumKeys: Array(Set(tracks.map(\.albumKey))))
        var songByLocation: [String: [Track]] = [:]
        for songs in Dictionary(grouping: albumTracks, by: \.albumKey).values.map(TrackVersions.group) {
            for song in songs { for t in song { songByLocation[t.location] = song } }
        }
        return tracks.map { songByLocation[$0.location] ?? [$0] }
    }

    /// `tracks` as songs, in the order the songs first appear: each once, with the copies of it among `tracks`
    /// (`listed`: a favorite is the copy hearted; where an album's copies are bundled, all of them are) and every copy
    /// of it in the library (`all`). What Favorites lists, in the window and on a remote.
    func songs(listing tracks: [Track]) -> [(listed: [Track], all: [Track])] {
        var seen = Set<String>()
        var songs: [(listed: [Track], all: [Track])] = []
        let given = Set(tracks.map(\.location))
        for song in versions(of: tracks) {
            let key = song.map(\.location).sorted().joined(separator: "\u{1F}")
            guard seen.insert(key).inserted else { continue }
            songs.append((song.filter { given.contains($0.location) }, song))
        }
        return songs
    }

    /// Where an album lives, broadly: its source and the folder under it ("Music Share › Pink Floyd").
    /// A grouping folder like "_Spatial Extras" brings the next one along ("… › _Spatial Extras › Eagles").
    func albumLocation(_ path: String) -> String {
        guard let source = sources.filter({ path == $0.path || path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else {
            return ((path as NSString).abbreviatingWithTildeInPath as NSString).lastPathComponent
        }
        let name = source.displayName   // same as the sidebar
        var folders = String(path.dropFirst(source.path.count)).split(separator: "/").map(String.init)
        guard let first = folders.first else { return name }
        folders = first.hasPrefix("_") && folders.count > 1 ? [first, folders[1]] : [first]
        return ([name] + folders).joined(separator: " › ")
    }

    private(set) var stats = LibraryDatabase.Stats(albums: 0, tracks: 0, artists: 0, bytes: 0, duration: 0)
    /// Bumped whenever tracks change, so detail views can reload.
    private(set) var revision = 0
    /// Counts the changes that can alter a song's cover without its queue entry knowing (tag edits, reverts, enrichment).
    private(set) var artworkRevision = 0

    var albumSort: AlbumSort = .artist { didSet { observeAlbums() } }

    private(set) var scanProgress: ScanProgress?
    private(set) var lastError: String?
    /// Why the last scan of a source stopped before the end (its share stopped answering, its folder couldn't be read),
    /// by source ID, until a scan of it finishes. The banner goes after a few seconds; this stays by the source in the
    /// sidebar and in Settings, so a share whose scans keep failing doesn't look up to date.
    private(set) var scanFailures: [Int64: String] = [:]

    @ObservationIgnored private var albumTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    private var watcher: FolderWatcher?
    /// Local sources that changed while another scan was running: scanned when it ends, not dropped.
    @ObservationIgnored private var changedDuringScan: Set<String> = []
    @ObservationIgnored private var checkedAtLaunch = false
    @ObservationIgnored private var favoriteVersionsTask: Task<Void, Never>?
    /// Whether stored analyses from an older analyzer have been judged anew (see `storedAnalysesJudged`).
    @ObservationIgnored private(set) var analysesJudged = false
    @ObservationIgnored private var judging: Task<Void, Never>?

    /// Whether the library may look for new music by itself (Settings → Library → Scan for new music automatically):
    /// the folder watcher and the scan at launch. Asked each time; shares are kept current by NetworkShareManager.
    @ObservationIgnored var automaticScanning: () -> Bool
    /// How long the scan at launch waits (the window and the shares come first); tests shorten it.
    @ObservationIgnored var launchScanDelay: Duration = .seconds(3)

    init(dataDirectory: URL, automaticScanning: @escaping () -> Bool = { false }, includeTidal: Bool = false) throws {
        self.automaticScanning = automaticScanning
        database = try LibraryDatabase(url: dataDirectory.appendingPathComponent("Library.sqlite"))
        // Before anything reads: the TIDAL rows are hidden unless the switch is on.
        database.includeTidal = includeTidal
        includesTidal = includeTidal
        artwork = ArtworkStore(directory: dataDirectory.appendingPathComponent("Artwork", isDirectory: true))
        scanner = LibraryScanner(database: database, artwork: artwork)
        tagWriter = TagWriter(database: database, scanner: scanner,
                              backupDirectory: dataDirectory.appendingPathComponent("Tag Backups", isDirectory: true))
        enricher = MetadataEnricher(database: database)
        artworkResolver = ArtworkResolver(database: database, store: artwork)
        ArtworkCache.shared.store = artwork
        loadSidebarState()
        observe()
        Task { await tagWriter.pruneBackups() }
        // After an analyzer update, stored results are judged anew from their measurements: off the main thread (a large
        // library has many), and before the analysis queue asks what needs analyzing.
        let database = database
        judging = Task { [weak self] in
            await Task.detached(priority: .utility) { _ = try? database.rejudgeStoredAnalyses() }.value
            self?.analysesJudged = true
        }
    }

    /// Waits until stored analyses have been judged anew (`LibraryDatabase.rejudgeStoredAnalyses`), started at launch.
    func storedAnalysesJudged() async { await judging?.value }

    deinit {
        albumTask?.cancel()
        favoriteVersionsTask?.cancel()
        copyCountTask?.cancel()
        for task in tasks { task.cancel() }
    }

    func albums(genre key: String) -> [Album] { albums.filter { $0.facts.genres.contains(key) } }
    /// The albums with songs in a source, as its page lists them.
    func albums(inSource id: Int64) -> [Album] { albums.filter { $0.facts.sources.contains(id) } }
    /// The newest albums, newest first (the Recently Added page).
    func recentlyAddedAlbums(limit: Int) -> [Album] { Array(albums.sorted { $0.addedAt > $1.addedAt }.prefix(max(0, limit))) }

    // MARK: Observation

    /// The sidebar's rows and the choice between the library and the empty-library screen, read before the first
    /// frame. The observations below deliver their first values a moment after the window is up; until then the
    /// sidebar listed no playlists or sources and the window showed the empty library. Their rows then arrived in
    /// separate updates while the sidebar's outline view was still settling its first row heights, and AppKit logged
    /// "reentrant operation in its NSTableView delegate" (issue #54). Read here, the first frame already has every
    /// row, and the observations' first values change nothing. Three small queries; a failure leaves them to the
    /// observations.
    private func loadSidebarState() {
        let database = database
        guard let state = try? database.writer.read({ db in
            (try database.sources(db), try database.playlists(db), try database.stats(db))
        }) else { return }
        setSources(state.0)
        playlists = state.1
        if let stats = state.2 { self.stats = stats }
        loadPlaylistTransitions()
    }

    /// Keeps the TIDAL account's source out of `sources`, whatever the switch says.
    private func setSources(_ all: [LibrarySource]) {
        sources = all.filter { !$0.isTidal }
        tidalSource = includesTidal ? all.first { $0.isTidal } : nil
    }

    /// Settings › Online › TIDAL integration was switched. Every list, count, album and playlist is read again as the library
    /// is with that account in it, or as it is without. Nothing is deleted either way.
    func setIncludeTidal(_ on: Bool) {
        guard on != includesTidal else { return }
        includesTidal = on
        database.includeTidal = on
        if !on { tidalRecords = [:]; streamOnlyAlbumKeys = [] }
        for task in tasks { task.cancel() }
        tasks = []
        loadSidebarState()
        observe()
        revision += 1
        favoriteVersions()
    }

    private func observe() {
        observeAlbums()
        let writer = database.writer
        let database = database
        if includesTidal {
            tasks.append(Task { [weak self] in
                let obs = ValueObservation.tracking { db in
                    (try TidalTrackRecord.fetchAll(db),
                     Set(try String.fetchAll(db, sql: """
                        SELECT DISTINCT albumKey FROM track WHERE sourceId IN (SELECT id FROM source WHERE path = ?)
                        EXCEPT SELECT albumKey FROM track WHERE sourceId IS NULL OR sourceId NOT IN (SELECT id FROM source WHERE path = ?) OR filePath != ''
                        """, arguments: [LibrarySource.tidalPath, LibrarySource.tidalPath])))
                }
                do {
                    for try await (records, streamOnly) in obs.values(in: writer) {
                        guard !Task.isCancelled, let self, self.includesTidal else { continue }
                        let byTrack = Dictionary(records.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
                        if self.tidalRecords != byTrack { self.tidalRecords = byTrack }
                        if self.streamOnlyAlbumKeys != streamOnly { self.streamOnlyAlbumKeys = streamOnly }
                    }
                } catch {}
            })
        }
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in try database.artists(db) }
            // The count covers the whole track table, so every track write (an analysis saved, a play counted) wakes
            // this; only a real change reloads the views. Writes that change tracks without changing this bump
            // `revision` themselves (scans, tag edits, plays, a share relinked).
            do {
                for try await value in obs.values(in: writer) {
                    guard let self, self.artists != value else { continue }
                    self.artists = value
                    self.revision += 1
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in try database.playlists(db) }
            do {
                for try await value in obs.values(in: writer) where self?.playlists != value {
                    self?.playlists = value
                    self?.loadPlaylistTransitions()     // a deleted playlist's choice goes with it
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try Row.fetchAll(db, sql: "SELECT favorite.trackId AS id, track.isMissing AS missing, track.albumKey AS album FROM favorite JOIN track ON track.id = favorite.trackId WHERE \(try database.visibleTracksClause(db))")
                    .map { (id: $0["id"] as Int64, missing: $0["missing"] as Bool, album: $0["album"] as String?) }
            }
            do {
                for try await value in obs.values(in: writer) {
                    self?.favoriteIDs = Set(value.map(\.id))
                    self?.favoriteAlbumKeys = Set(value.filter { !$0.missing }.compactMap(\.album))
                    self?.favoriteVersions()
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in (try LibraryDatabase.copyChoices(db), Set(try Int64.fetchAll(db, sql: "SELECT trackId FROM preferredCopy"))) }
            do {
                for try await (choices, preferred) in obs.values(in: writer) {
                    guard let self else { continue }
                    let bundlingChanged = self.copyChoices.filter { $0.value == .bundled } != choices.filter { $0.value == .bundled }
                    self.copyChoices = choices
                    self.preferredCopyIDs = preferred
                    if bundlingChanged { self.favoriteVersions() }
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in try database.sources(db) }
            do {
                for try await all in obs.values(in: writer) {
                    // A share relinked to a new mount point rewrites its tracks' paths.
                    let value = all.filter { !$0.isTidal }
                    if let self, self.sources != value {
                        if !self.sources.isEmpty { self.revision += 1 }
                        self.sources = value
                    }
                    if let self { self.tidalSource = self.includesTidal ? all.first { $0.isTidal } : nil }
                    self?.updateWatcher()
                    self?.rescanLocalAtLaunch()
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            let obs = ValueObservation.tracking { db in try database.stats(db) }
            do { for try await value in obs.values(in: writer) { if let value, self?.stats != value { self?.stats = value } } } catch {}
        })
    }

    private func observeAlbums() {
        albumTask?.cancel()
        let writer = database.writer
        let database = database
        let sort = albumSort
        albumTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in try database.albums(db, sort: sort) }
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

    /// `restart`: asked for by the user (Rescan), so a scan of the source that has stalled is replaced and one still
    /// running is followed by another (`LibraryScanner.scan`). Scans the app starts by itself join the one running.
    func scan(_ source: LibrarySource, restart: Bool = false) async {
        scanProgress = ScanProgress(sourcePath: source.path, processed: 0, total: 0, added: 0, updated: 0)
        do {
            let summary = try await scanner.scan(source, restart: restart) { [weak self] progress in
                Task { @MainActor [weak self] in self?.scanProgress = progress }
            }
            if !summary.failed.isEmpty { lastError = String(localized: "Could not read \(summary.failed.count) files or folders: \(summary.failed.prefix(3).joined(separator: ", "))",
                                                         comment: "Followed by up to three of the paths that couldn't be read.") }
            if !summary.movedTracks.isEmpty { onTracksMoved?(summary.movedTracks) }
            // A share that went away shows as offline instead; anything else that ended has been read through.
            if !summary.interrupted, let id = source.id { scanFailures[id] = nil }
        } catch is CancellationError {
            return   // replaced by a Rescan, which reports for itself
        } catch {
            let message = Self.scanFailureMessage(error)
            lastError = message
            if let id = source.id { scanFailures[id] = message }
        }
        scanProgress = nil
        revision += 1
        onScanFinished?()
        if !changedDuringScan.isEmpty { Task { await scanChangedDuringScan() } }
    }

    private static func scanFailureMessage(_ error: Error) -> String {
        if case LibraryScanner.ScanError.notResponding(let path) = error {
            return String(localized: "The scan stopped because the share didn’t answer while reading “\((path as NSString).lastPathComponent)”. Nothing was marked missing. Rescan to try again.",
                          comment: "%@ is the name of the folder or file on a network share that didn't answer during a library scan.")
        }
        return error.localizedDescription
    }

    /// Scans `source` now, or once the scan that's running ends.
    private func scanWhenFree(_ source: LibrarySource) async {
        if scanProgress == nil { await scan(source) } else { changedDuringScan.insert(source.path) }
    }

    private func scanChangedDuringScan() async {
        while scanProgress == nil, let path = changedDuringScan.popFirst() {
            guard let source = sources.first(where: { $0.path == path }) else { continue }
            await scan(source)
        }
    }

    /// The folder watcher reports changes from the moment it starts, so whatever changed while Vespertine was closed
    /// (an album added in Finder, files moved by another app) is looked for once at launch. Incremental: only new or
    /// changed files are read, and a disk that isn't connected is marked offline, never emptied. Only when automatic
    /// scanning is on; shares are kept current by NetworkShareManager.
    private func rescanLocalAtLaunch() {
        guard !checkedAtLaunch else { return }
        checkedAtLaunch = true
        guard automaticScanning() else { return }
        let local = sources.filter { !$0.isNetwork }
        guard !local.isEmpty else { return }
        Task {
            try? await Task.sleep(for: launchScanDelay)   // the window and the shares first
            for source in local { await scanWhenFree(source) }
        }
    }

    /// Called after every scan (e.g. to analyze newly added music).
    var onScanFinished: (() -> Void)?
    /// Called when a scan found files that were moved or renamed: old track ID → new track ID.
    var onTracksMoved: (([Int64: Int64]) -> Void)?

    private var missingRescanAt: [Int64: Date] = [:]

    /// Whether a song's file is really gone: it answers "no such file" (ENOENT, ENOTDIR) while the folder of its source still
    /// lists something. A timeout or any other error, or a source folder that no longer lists or lists empty (a share whose mount
    /// dropped), is not "gone": the song must not be hidden as missing for it. Blocks for as long as a share that has stopped
    /// answering does: call it off the main thread. `stat` and `list` stand in for the file system in tests.
    nonisolated static func fileIsGone(_ path: String, sourceRoot root: String?,
                                       stat statPath: (String) -> Int32 = LibraryStore.statError,
                                       list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) }) -> Bool {
        let error = statPath(path)
        guard error == ENOENT || error == ENOTDIR, let root else { return false }
        return list(root)?.isEmpty == false
    }

    /// 0 when `path` can be stat'ed, else the error.
    nonisolated static func statError(_ path: String) -> Int32 {
        var info = stat()
        return stat(path, &info) == 0 ? 0 : errno
    }

    /// A file the library lists is gone (moved or deleted, e.g. by a library manager reorganizing a share):
    /// rescan its source now, so moved files are found again. At most every two minutes per source.
    /// With automatic scanning off nothing is rescanned: the song is only marked missing (hidden from the lists, its
    /// favorite and play count kept), and Rescan Library brings it back if the file returns.
    @discardableResult
    func rescanForMissingFile(_ track: Track) -> Bool {
        guard automaticScanning() else {
            try? database.markMissing(filePath: track.filePath, sourceID: track.sourceId)
            revision += 1
            return false
        }
        guard let id = track.sourceId, let source = sources.first(where: { $0.id == id }), scanProgress == nil,
              Date().timeIntervalSince(missingRescanAt[id] ?? .distantPast) > 120 else { return false }
        missingRescanAt[id] = Date()
        Task { await scan(source) }
        return true
    }

    func rescanAll() async {
        for source in sources { await scan(source, restart: true) }
    }

    func renameSource(_ source: LibrarySource, to name: String) {
        guard let id = source.id else { return }
        try? database.renameSource(id, to: name)
        revision += 1
    }

    func removeSource(_ source: LibrarySource) {
        guard let id = source.id else { return }
        try? database.removeSource(id)
        scanFailures[id] = nil
        revision += 1
    }

    /// "Scan for new music automatically" was switched. Turning it on looks at once for what was added while it was off
    /// (the folder watcher only reports from now on): every local source, incrementally. Shares are caught up by
    /// `NetworkShareManager.rescanStale`, which the switch calls too.
    func automaticScanningChanged() {
        updateWatcher()
        guard automaticScanning() else { return }
        let local = sources.filter { !$0.isNetwork }
        Task { for source in local { await scanWhenFree(source) } }
    }

    /// The songs whose files are gone, and what removing them loses (see `removeMissingSongs`).
    func missingSongsSummary() async -> MissingSongsSummary {
        let database = database
        return await Task.detached(priority: .userInitiated) { (try? database.missingSongsSummary()) ?? MissingSongsSummary(songs: 0, favorites: 0, played: 0) }.value
    }

    /// Takes the songs whose files are gone out of the library, with their favorites and play counts. Never touches a file.
    @discardableResult
    func removeMissingSongs() async -> Int {
        let database = database
        let removed = await Task.detached(priority: .userInitiated) { (try? database.removeMissingSongs()) ?? 0 }.value
        revision += 1
        return removed
    }

    func updateWatcher() {
        // File-system events don't cross the network; shares are re-checked by NetworkShareManager.
        let paths = sources.filter { !$0.isNetwork }.map(\.path)
        if watcher == nil {
            watcher = FolderWatcher { [weak self] changed in
                Task { @MainActor in
                    guard let self else { return }
                    for path in changed {
                        if let source = self.sources.first(where: { $0.path == path }) { await self.scanWhenFree(source) }
                    }
                }
            }
        }
        watcher?.watch(automaticScanning() ? paths : [])
    }

    func clearError() { lastError = nil }

    // MARK: Finding music and enriching metadata

    /// Music on this Mac that isn't in the library yet.
    func findMusic(progress: @escaping @Sendable (MusicFinder.Progress) -> Void) async -> [FoundFolder] {
        // QA hook: -VespertineFindMusicRoot <dir> searches that folder instead of asking Spotlight.
        let roots = LaunchArguments().string(forKey: "VespertineFindMusicRoot").map { [URL(fileURLWithPath: $0, isDirectory: true)] }
        return await MusicFinder.find(roots: roots, excludingRoots: sources.map(\.url), progress: progress)
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
    func enrichmentProposals(albumKeys: [String]?, correctExisting: Bool, fetchCovers: Bool,
                             progress: @escaping @MainActor (Int, Int) -> Void) async -> (proposals: [EnrichmentProposal], complete: Int) {
        await enricher.setCorrectExisting(correctExisting)
        await enricher.setFetchCovers(fetchCovers)
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
        artworkRevision += 1
        return (written, failed)
    }

    func setSkipsNonMusic(_ value: Bool) { Task { await scanner.setSkipsNonMusic(value) } }

    // MARK: Queries (synchronous, small)

    func tracks(albumKey: String) -> [Track] { (try? database.tracks(albumKey: albumKey)) ?? [] }
    func tracks(filePath: String) -> [Track] { (try? database.tracks(filePath: filePath)) ?? [] }
    func tracks(albumKeys: [String]) -> [Track] { (try? database.tracks(albumKeys: albumKeys)) ?? [] }
    func tracks(in playlist: Playlist) -> [Track] { (try? database.tracks(in: playlist)) ?? [] }
    func tracks(ids: [Int64]) -> [Track] { (try? database.tracks(ids: ids)) ?? [] }
    func allTracks() -> [Track] { (try? database.allTracks()) ?? [] }
    func search(_ text: String) -> [Track] { (try? database.search(text)) ?? [] }
    func albums(artist: String) -> [Album] { (try? database.albums(artist: artist)) ?? [] }
    func albums(underPath path: String) -> [Album] { (try? database.albums(underPath: path)) ?? [] }

    func album(key: String) -> Album? { albumsByKey[key] }

    /// The key of the cover to show for `track`: the library's current one, else the file's tags, the folder's image, the
    /// album's cover from another song. Nil when there is none yet. Off the main thread: it reads the file and the folder.
    func resolveArtwork(for track: Track) async -> String? {
        let resolver = artworkResolver
        return await Task.detached(priority: .userInitiated) { resolver.resolve(track).key }.value
    }

    // MARK: Editing

    func apply(_ edit: TagEdit, to tracks: [Track]) async -> TagWriteResult? {
        do {
            let result = try await tagWriter.apply(edit, to: tracks)
            revision += 1
            artworkRevision += 1
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
        artworkRevision += 1
        return restored
    }

    func createPlaylist(name: String, rules: SmartRules? = nil, trackIDs: [Int64] = []) -> Playlist? {
        guard let p = try? database.createPlaylist(name: name, rules: rules) else { return nil }
        if let id = p.id, !trackIDs.isEmpty { try? database.append(trackIDs: trackIDs, to: id) }
        return p
    }

    func append(_ trackIDs: [Int64], to playlist: Playlist) {
        guard let id = playlist.id, !playlist.isSmart else { return }
        // A TIDAL playlist takes TIDAL songs only; the router adds them (finding local songs' TIDAL versions) and tells TIDAL.
        if let router = tidalRouter, router.isTidalPlaylist(id) {
            router.append(trackIDs, to: id)
            return
        }
        try? database.append(trackIDs: trackIDs, to: id)
        revision += 1
    }

    func setPlaylistOrder(_ trackIDs: [Int64], playlist: Playlist) {
        guard let id = playlist.id else { return }
        let router = tidalRouter.flatMap { $0.isTidalPlaylist(id) ? $0 : nil }
        let before = router == nil ? [] : tidalIds(inPlaylist: id)
        try? database.setPlaylistTracks(trackIDs, playlistID: id)
        revision += 1
        router?.reordered(id, from: before, to: tidalIds(inPlaylist: id))
    }

    /// Lists that show playlists read them again.
    func bumpRevision() { revision += 1 }

    /// A playlist's TIDAL songs, in order, by TIDAL id.
    func tidalIds(inPlaylist id: Int64) -> [Int] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        return ((try? database.tracks(in: playlist)) ?? []).compactMap { $0.isTidalTrack ? URL(string: $0.location).flatMap(TidalPlayback.trackId(from:)) : nil }
    }

    func deletePlaylist(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        let uuid = tidalRouter != nil ? (try? database.tidalPlaylistUUID(playlistId: id)) ?? nil : nil
        try? database.deletePlaylist(id)
        if let uuid { tidalRouter?.deleted(uuid: uuid) }
    }

    /// Routes edits of TIDAL playlists to TIDAL (set by the app while TIDAL is on; nil otherwise, and everything stays local).
    @ObservationIgnored weak var tidalRouter: TidalPlaylistRouter?
    /// Told when hearts change on TIDAL songs (TIDAL ids), while TIDAL is on.
    @ObservationIgnored var tidalFavoritesChanged: (([Int], Bool) -> Void)?
    /// A playlist's own transitions; nil follows the app's setting.
    func setTransitions(_ choice: TransitionOverride?, for playlist: Playlist) {
        guard let id = playlist.id else { return }
        try? database.setTransitionStyle(choice?.storedValue, forPlaylist: id)
        loadPlaylistTransitions()
    }

    /// The own transitions of the playlist a list belongs to, nil for a list that isn't one (search results, an album
    /// opened while a playlist is still selected in the sidebar) or a playlist that follows the app's setting.
    func transitions(of playlist: Playlist?) -> TransitionOverride? { playlist?.id.flatMap { playlistTransitions[$0] } }

    private func loadPlaylistTransitions() {
        let stored = (try? database.playlistTransitionStyles()) ?? [:]
        playlistTransitions = stored.compactMapValues { TransitionOverride(storedValue: $0) }
    }

    /// A playlist always has a name: an empty one (or only spaces) is ignored and the playlist keeps the name it had.
    func renamePlaylist(_ playlist: Playlist, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let id = playlist.id else { return }
        try? database.renamePlaylist(id, to: name)
        if let router = tidalRouter, router.isTidalPlaylist(id) { router.renamed(id, to: name) }
    }
    func updateRules(_ playlist: Playlist, _ rules: SmartRules) {
        if let id = playlist.id { try? database.updateSmartRules(id, rules); revision += 1 }
    }

    // MARK: Playlists from and for other players

    /// A playlist file's text: M3U8 is UTF-8; an old .m3u is in the Windows or Latin-1 code page, where reading it as
    /// UTF-8 would turn every accented letter in a file name into a replacement character and match nothing.
    nonisolated static func playlistText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// Makes a playlist of each M3U / M3U8 file, from the songs of it already in the library.
    func importPlaylistFiles(_ urls: [URL]) async -> PlaylistImportResult {
        let database = database
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PlaylistImportResult, Error> in
            Result<PlaylistImportResult, Error> {
                var total = PlaylistImportResult()
                for url in urls {
                    let data = try Data(contentsOf: url)
                    let text = Self.playlistText(data)
                    let entries = M3U.entries(text, base: url.deletingLastPathComponent())
                    if let one = try database.importPlaylist(named: url.deletingPathExtension().lastPathComponent, entries: entries)?.1 {
                        total.playlists += one.playlists
                        total.songs += one.songs
                        total.unmatched += one.unmatched
                    } else {
                        total.unmatched += entries.count
                    }
                }
                return total
            }
        }.value
        revision += 1
        switch result {
        case .success(let r): return r
        case .failure(let error): lastError = error.localizedDescription; return PlaylistImportResult()
        }
    }

    /// Brings in the playlists, loved songs and play counts of a library exported from Apple Music.
    func importAppleMusicLibrary(_ url: URL) async -> PlaylistImportResult? {
        let database = database
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PlaylistImportResult, Error> in
            Result<PlaylistImportResult, Error> { try database.importAppleMusic(try AppleMusicLibrary(data: try Data(contentsOf: url))) }
        }.value
        revision += 1
        favoriteVersions()
        switch result {
        case .success(let r): return r
        case .failure(let error): lastError = error.localizedDescription; return nil
        }
    }

    // MARK: Favorites

    func isFavorite(_ track: Track?) -> Bool { track?.id.map(favoriteIDs.contains) ?? false }
    func favoriteTracks() -> [Track] { (try? database.favoriteTracks()) ?? [] }

    /// Where an album's copies are bundled, favoriting one copy of a song (its stereo copy, heard on headphones) favorites
    /// them all, and a copy scanned later joins in; elsewhere a favorite is the copy hearted. Counts favorite songs for the
    /// sidebar. Off the main thread, and once a scan's flurry of changes settles.
    private func favoriteVersions() {
        let first = favoriteVersionsTask == nil
        favoriteVersionsTask?.cancel()
        let database = database
        favoriteVersionsTask = Task { [weak self] in
            if !first { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let bundled = self?.bundlesCopiesByDefault ?? false
            let songs = await Task.detached(priority: .utility) { try? database.favoriteEveryVersion(bundledByDefault: bundled) }.value
            guard !Task.isCancelled, let songs else { return }
            self?.favoriteCount = songs
        }
    }

    /// Library state only: favorites are never written into the files.
    func setFavorite(_ favorite: Bool, trackIDs: [Int64]) {
        do { try database.setFavorite(favorite, trackIDs: trackIDs) } catch { lastError = error.localizedDescription }
        // For a TIDAL song the heart is the TIDAL favorite: shown at once, sent to TIDAL by the sync queue.
        guard includesTidal, let tell = tidalFavoritesChanged else { return }
        let songs = trackIDs.map { id in (id, (try? database.tidalRecord(trackId: id))??.tidalId) }
        let tidal = TidalRouting.favoriteTargets(songs, tidalOn: includesTidal)
        if !tidal.isEmpty { tell(tidal, favorite) }
    }

    func markPlayed(_ trackID: Int64) {
        try? database.markPlayed(trackID)
        revision += 1   // play counts in lists and the inspector
    }

    // MARK: Play history

    /// Bumped whenever the history changes, so History reloads.
    private(set) var historyRevision = 0

    func history(limit: Int = 1000) -> [LibraryDatabase.HistoryEntry] { (try? database.history(limit: limit)) ?? [] }

    func recordHistory(_ trackID: Int64) {
        do { try database.recordHistory(trackID); historyRevision += 1 } catch { lastError = error.localizedDescription }
    }

    func removeHistory(_ ids: [Int64]) {
        do { try database.removeHistory(ids); historyRevision += 1 } catch { lastError = error.localizedDescription }
    }

    func clearHistory() {
        do { try database.clearHistory(); historyRevision += 1 } catch { lastError = error.localizedDescription }
    }

    /// A saved analysis changes verdict tags in lists; refresh them at most every few seconds. Each refresh reloads the
    /// page shown (all of Songs, on that page), so a batch analyzing several files a second refreshes less often.
    func analysisSaved() {
        guard !analysisRefreshPending else { return }
        analysisRefreshPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            analysisRefreshPending = false
            revision += 1
        }
    }
    private var analysisRefreshPending = false

    func storedAnalysis(for track: Track) -> LibraryDatabase.StoredAnalysis? {
        try? database.storedAnalysis(for: track)
    }
}
