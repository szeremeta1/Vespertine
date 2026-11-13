//
// Vespertine: incremental folder scanning.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit
import GRDB
import os
import VespertineAudio

private let scanLog = Logger(subsystem: "org.szeremeta.vespertine.library", category: "scan")

public struct ScanProgress: Sendable {
    public enum Phase: String, Sendable { case listing = "Listing", reading = "Reading" }
    public var phase: Phase
    public var sourcePath: String
    public var processed: Int
    public var total: Int
    public var added: Int
    public var updated: Int

    public init(phase: Phase = .reading, sourcePath: String, processed: Int, total: Int, added: Int, updated: Int) {
        self.phase = phase
        self.sourcePath = sourcePath
        self.processed = processed
        self.total = total
        self.added = added
        self.updated = updated
    }
}

public struct ScanSummary: Sendable {
    public var added = 0
    public var updated = 0
    public var missing = 0
    /// Missing files found again under a new name or folder (folded into the new entry): old ID → new ID.
    public var movedTracks: [Int64: Int64] = [:]
    public var moved: Int { movedTracks.count }
    public var skipped = 0
    public var failed: [String] = []
    /// The source went away mid-scan (a network share dropped); nothing was marked missing.
    public var interrupted = false
}

public actor LibraryScanner {
    let database: LibraryDatabase
    let artwork: ArtworkStore
    /// Leave out voice recordings, telephony audio and short clips (same rules as MusicFinder) found in folders the
    /// library only references. The managed folder holds only what was imported on purpose, so it keeps everything.
    public var skipsNonMusic = true
    private var activeScans: [Int64: RunningScan] = [:]

    /// A scan in progress, and when it last heard from its source.
    private struct RunningScan {
        let id = UUID()
        let task: Task<ScanSummary, Error>
        let activity: ScanActivity
    }

    /// How long one request to a source (is it there, list a folder, read a file) may go unanswered before the scan
    /// stops with `ScanError.notResponding`. On a share that stops answering such a call blocks until the system gives
    /// up, which can be never: the scan then never ended, and every later scan of the share waited on it.
    public private(set) var responseTimeout: TimeInterval = 90
    /// How long a running scan may go without listing a folder or reading a file before a Rescan replaces it.
    public private(set) var stallLimit: TimeInterval = 20
    /// Lists a folder's contents (tests stand in a share that stops answering).
    private(set) var readFolder: FolderReader = LibraryScanner.contentsOfFolder
    /// Runs on the I/O thread just before a file is read (tests stand in a share that stops answering for one file).
    private(set) var beforeRead: @Sendable (URL) -> Void = { _ in }
    /// Reads in a row that got no answer within `responseTimeout` before the source is taken for gone. One file that
    /// doesn't answer is skipped; a source that answers nothing stops the scan.
    static let silentReadsBeforeStopping = 3
    /// A scan saves what it has read at least this often, so a scan that ends early leaves what it read behind.
    static let flushInterval: TimeInterval = 2

    public typealias FolderReader = @Sendable (URL, [URLResourceKey]) throws -> [URL]
    public static let contentsOfFolder: FolderReader = { folder, keys in
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    }

    public enum ScanError: Error, Equatable {
        /// The source didn't answer within `responseTimeout` while this was being listed or read. The scan stopped
        /// there and marked nothing missing.
        case notResponding(path: String)
    }

    public func setSkipsNonMusic(_ value: Bool) { skipsNonMusic = value }
    func setTimeouts(response: TimeInterval, stall: TimeInterval) { responseTimeout = response; stallLimit = stall }
    func setFolderReader(_ reader: @escaping FolderReader) { readFolder = reader }
    func setReadHook(_ hook: @escaping @Sendable (URL) -> Void) { beforeRead = hook }

    /// Blocking file I/O runs here, not on Swift's cooperative pool (sized to the CPU count, so a
    /// few blocked reads would stall the rest). GCD adds threads while they wait on the network.
    static let ioQueue = DispatchQueue(label: "org.szeremeta.vespertine.scan-io", qos: .utility, attributes: .concurrent)

    /// `network`: the work reads a network share, so it waits its turn while a song streams from one (`ShareIOGate`).
    static func onIOQueue<T: Sendable>(network: Bool = false, gate: ShareIOGate = .shared, _ work: @escaping @Sendable () -> T) async -> T {
        if network { await gate.enter() }
        defer { if network { gate.leave() } }
        return await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    private static let deadlines = DispatchQueue(label: "org.szeremeta.vespertine.scan-deadlines", qos: .userInitiated)

    /// The same, giving up once the work has run for `timeout` without returning: nil then. The clock starts when the
    /// work does, so a busy machine's wait for a thread isn't taken for a share that stopped answering. A call blocked
    /// on such a share can't be interrupted, so its thread is left to return whenever the system lets it.
    static func onIOQueue<T: Sendable>(network: Bool = false, gate: ShareIOGate = .shared, timeout: TimeInterval,
                                       _ work: @escaping @Sendable () -> T) async -> T? {
        if network { await gate.enter() }
        defer { if network { gate.leave() } }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce()
            ioQueue.async {
                deadlines.asyncAfter(deadline: .now() + timeout) {
                    if once.claim() { continuation.resume(returning: nil) }
                }
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
        }
    }

    /// Files read concurrently. Local disks gain little past 6; network shares hide
    /// round-trip latency with more requests in flight.
    public static func readWidth(for root: URL) -> Int {
        NetworkVolume.isNetwork(root) ? 32 : 6
    }

    public init(database: LibraryDatabase, artwork: ArtworkStore) {
        self.database = database
        self.artwork = artwork
    }

    public static var audioExtensions: Set<String> {
        SourceInspector.supportedExtensions.subtracting(["cue", "txt", "log"])
    }

    /// What the tag reader called a file no decoder opened ("MP4"; the decoders' own names never are). Rows saved with it
    /// before the file's real format could be read are read again, once the scanner knows better.
    static func isFallbackLabel(_ codec: String) -> Bool { codec == "MP4" }

    /// Rescans a source. Unchanged files (same size and modification date) are skipped.
    ///
    /// A scan of a source that is already being scanned joins that scan. `restart` (the user pressed Rescan) looks
    /// again instead: a scan that hasn't heard from its source for `stallLimit` is cancelled and a new one starts;
    /// one that is still moving is left to finish, then the source is scanned again, so a file added after it listed
    /// that folder is found. Before, Rescan joined whatever was running, so a scan stuck on a share that stopped
    /// answering swallowed every Rescan until the app quit.
    @discardableResult
    public func scan(_ source: LibrarySource, restart: Bool = false,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanSummary {
        // The TIDAL account is no folder: there is nothing to list, and it must never be found "offline" or its tracks "missing".
        guard let sourceID = source.id, !source.isTidal else { return ScanSummary() }
        if let running = activeScans[sourceID] {
            guard restart else { return try await running.task.value }
            if running.activity.quiet < stallLimit {
                _ = try? await running.task.value
                // Someone else's Rescan may have started the next scan meanwhile: one is enough.
                if let next = activeScans[sourceID], next.id != running.id { return try await next.task.value }
            } else {
                // Cancelled, it writes nothing more; a request still blocked returns by its deadline.
                running.task.cancel()
            }
        }
        let activity = ScanActivity()
        let task = Task { try await self.performScan(source, activity: activity, progress: progress) }
        let scan = RunningScan(task: task, activity: activity)
        activeScans[sourceID] = scan
        defer { if activeScans[sourceID]?.id == scan.id { activeScans[sourceID] = nil } }
        return try await task.value
    }

    private func performScan(_ source: LibrarySource, activity: ScanActivity,
                             progress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanSummary {
        guard let sourceID = source.id else { return ScanSummary() }
        var summary = ScanSummary()
        let root = source.url
        let timeout = responseTimeout, readFolder = readFolder

        // Whether it's there and whether it's a share: both ask the file system, which a dead share can keep waiting.
        guard let probe = await Self.onIOQueue(timeout: timeout, { (Self.isReachable(root), NetworkVolume.isNetwork(root)) })
        else { throw ScanError.notResponding(path: root.path) }
        let (online, remote) = probe
        try Task.checkCancellation()
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE source SET isOnline = ? WHERE id = ?", arguments: [online, sourceID])
        }
        guard online else { summary.interrupted = true; return summary }

        let listing = try await Self.list(root, network: remote, timeout: timeout, found: { count in
            activity.touch()
            progress?(ScanProgress(phase: .listing, sourcePath: source.path, processed: count, total: 0, added: 0, updated: 0))
        }, readFolder: readFolder)
        try Task.checkCancellation()
        let cueByAudio = Self.cueSheets(listing.cue)
        let priorCues: [String: String] = try await database.writer.read { db in
            var signatures: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT filePath, signature FROM cueScanState WHERE sourceId = ?", arguments: [sourceID]) {
                signatures[row["filePath"]] = row["signature"]
            }
            return signatures
        }

        struct Known: Sendable { var id: Int64; var codec: String; var size: Int64; var modified: Date; var isMissing: Bool; var hasArt: Bool }
        let known: [String: Known] = try await database.writer.read { db in
            var map: [String: Known] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, location, codec, fileSize, modifiedAt, isMissing, artworkKey IS NOT NULL AS hasArt FROM track WHERE sourceId = ?", arguments: [sourceID]) {
                map[row["location"]] = Known(id: row["id"], codec: row["codec"], size: row["fileSize"], modified: row["modifiedAt"], isMissing: row["isMissing"], hasArt: row["hasArt"])
            }
            return map
        }

        // Files that list several tracks of their own, by file: a disc image's (SACD "<image>#2ch-1" … "<image>#mch-6",
        // DVD-Video "<image or VIDEO_TS.IFO>#dvd-…"), a Matroska file's audio streams ("<file>#audio-1"), and the tracks of
        // a CUE sheet inside the file ("<file>#2"), told from an external sheet's by there having been none.
        var imageTracks: [String: [String]] = [:]
        for location in known.keys {
            guard let hash = location.lastIndex(of: "#") else { continue }
            let path = String(location[..<hash])
            let suffix = location[location.index(after: hash)...]
            if SACDArea(location: location) != nil || DVDStreamRef(location: location) != nil || AudioStreamRef(location: location) != nil
                || (!suffix.isEmpty && suffix.allSatisfy(\.isNumber) && priorCues[path] == nil) {
                imageTracks[path, default: []].append(location)
            }
        }

        // Decide what needs reading. Size and date come from the listing (no per-file stat).
        var toRead: [URL] = []
        var listed: [String: ListedFile] = [:]
        var seen = Set<String>()
        // A track without a cover is read again once an image turns up in its folder (or above its disc folder).
        func coverAppeared(_ k: Known, _ url: URL) -> Bool {
            guard !k.hasArt, !listing.imageDirs.isEmpty else { return false }
            let dir = url.deletingLastPathComponent()
            return listing.imageDirs.contains(dir.path)
                || (ArtworkStore.isDiscFolder(dir.lastPathComponent) && listing.imageDirs.contains(dir.deletingLastPathComponent().path))
        }
        for file in listing.audio {
            let url = file.url, size = file.size, modified = file.modified
            if remote { listed[url.path] = file }
            if let cue = cueByAudio[url.path] {
                let locations = cue.tracks.map { "\(url.path)#\($0.number)" }
                locations.forEach { seen.insert($0) }
                if priorCues[url.path] == cue.signature, locations.allSatisfy({ location in
                    guard let k = known[location] else { return false }
                    return k.size == size && abs(k.modified.timeIntervalSince(modified)) < 0.001 && !k.isMissing && !coverAppeared(k, url)
                }) { continue }
                toRead.append(url)
            } else if let locations = imageTracks[url.path] {
                // A disc image (or VIDEO_TS) read before: unchanged when every one of its tracks is.
                locations.forEach { seen.insert($0) }
                if locations.allSatisfy({ location in
                    guard let k = known[location] else { return false }
                    return k.size == size && abs(k.modified.timeIntervalSince(modified)) < 0.001 && !k.isMissing && !coverAppeared(k, url)
                }) { continue }
                toRead.append(url)
            } else {
                seen.insert(url.path)
                if let k = known[url.path], k.size == size, abs(k.modified.timeIntervalSince(modified)) < 0.001, !k.isMissing, !coverAppeared(k, url),
                   !Self.isFallbackLabel(k.codec) { continue }
                toRead.append(url)
            }
        }

        // Files the library has never seen first, so a new album arrives whole instead of a track per pass behind
        // thousands of files that only changed. On a network share, macOS looks up never-seen files in a folder one
        // at a time, so within each group keep the reads in flight spread across folders (round-robin).
        toRead = Self.readOrder(toRead, isNew: { url in
            if cueByAudio[url.path] != nil || imageTracks[url.path] != nil { return false }
            return known[url.path] == nil
        }, spreadAcrossFolders: remote)

        let total = toRead.count
        scanLog.info("Scanning \(source.path, privacy: .public): \(listing.audio.count) files listed, \(total) to read (\(remote ? "share" : "local", privacy: .public))")
        var processed = 0
        let artwork = self.artwork
        let folderArt = FolderArtCache()
        var batch: [Track] = []
        var lastFlush = Date()
        var silentReads = 0
        var silentPath = ""
        let database = self.database
        let beforeRead = self.beforeRead

        do {
            try await withThrowingTaskGroup(of: ReadResult.self) { group in
                var iterator = toRead.makeIterator()
                func start(_ url: URL) {
                    let cue = cueByAudio[url.path], file = listed[url.path]
                    group.addTask {
                        try await Self.read(url, network: remote, timeout: timeout) {
                            beforeRead(url)
                            return Self.readTracks(url, cue: cue, artwork: artwork, folderArt: folderArt, remote: file)
                        }
                    }
                }
                for _ in 0..<(remote ? 32 : 6) {
                    guard let url = iterator.next() else { break }
                    start(url)
                }
                let skipping = self.skipsNonMusic && source.mode != .managed
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    let url = result.url
                    processed += 1
                    if result.answered {
                        activity.touch()
                        silentReads = 0
                    } else {
                        // The source didn't answer for this file. Skip it (it is read again by the next scan); only a
                        // source that answers nothing for several files in a row stops the scan.
                        silentReads += 1
                        silentPath = url.path
                        scanLog.error("No answer within \(timeout, format: .fixed(precision: 0)) s reading \(url.path, privacy: .public) (\(silentReads) in a row)")
                        if silentReads >= Self.silentReadsBeforeStopping { throw ScanError.notResponding(path: silentPath) }
                    }
                    if let tracks = result.tracks {
                        // An invalid CUE may fall back to the whole file. Track what was actually indexed.
                        if let cue = cueByAudio[url.path] {
                            for entry in cue.tracks { seen.remove("\(url.path)#\(entry.number)") }
                        }
                        // Likewise an SACD image re-read with fewer tracks (or none: it's no longer an SACD).
                        for location in imageTracks[url.path] ?? [] { seen.remove(location) }
                        for track in tracks { seen.insert(track.location) }
                        let kept = skipping ? tracks.filter(MusicFinder.keepsInLibrary) : tracks
                        summary.skipped += tracks.count - kept.count
                        batch.append(contentsOf: kept)
                    } else { summary.failed.append(url.path) }
                    if batch.count >= 200 || Date().timeIntervalSince(lastFlush) >= Self.flushInterval { try await Self.save(&batch, into: &summary, since: &lastFlush, sourceID: sourceID, database: database) }
                    if processed % 25 == 0 || processed == total {
                        progress?(ScanProgress(sourcePath: source.path, processed: processed, total: total, added: summary.added, updated: summary.updated))
                    }
                    if let next = iterator.next() { start(next) }
                }
            }
        } catch let error as ScanError {
            // What was read before the source stopped answering is kept; the scan still doesn't count as finished.
            scanLog.error("Scan of \(source.path, privacy: .public) stopped after \(processed) of \(total) files: \(String(describing: error), privacy: .public)")
            try? await Self.save(&batch, into: &summary, since: &lastFlush, sourceID: sourceID, database: database)
            throw error
        }
        try Task.checkCancellation()
        try await Self.save(&batch, into: &summary, since: &lastFlush, sourceID: sourceID, database: database)

        // A share that dropped mid-scan lists (and reads) nothing: never mistake that for deletions.
        guard let stillThere = await Self.onIOQueue(timeout: timeout, { Self.isReachable(root) })
        else { throw ScanError.notResponding(path: root.path) }
        try Task.checkCancellation()
        guard stillThere else {
            summary.interrupted = true
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE source SET isOnline = 0 WHERE id = ?", arguments: [sourceID])
            }
            return summary
        }

        // Flag files that disappeared (kept so playlists and play counts survive a re-plug).
        // Nor are files under a folder that couldn't be listed (they may well still be there).
        let unlisted = listing.unreadable.map { $0 + "/" }
        let missing = known.filter { k in
            !seen.contains(k.key) && !k.value.isMissing && !unlisted.contains { k.key.hasPrefix($0) }
        }.map(\.value.id)
        summary.missing = missing.count
        summary.failed.append(contentsOf: listing.unreadable.sorted())
        let failedPaths = Set(summary.failed)
        let moved = try await database.writer.write { db -> [Int64: Int64] in
            for (path, cue) in cueByAudio where !failedPaths.contains(path) {
                try db.execute(sql: "INSERT OR REPLACE INTO cueScanState (sourceId, filePath, signature) VALUES (?, ?, ?)",
                               arguments: [sourceID, path, cue.signature])
            }
            for id in missing { try db.execute(sql: "UPDATE track SET isMissing = 1 WHERE id = ?", arguments: [id]) }
            // Moved or renamed files: the new copy takes over the old entry's playlists, plays and analysis.
            let moved = try LibraryDatabase.reconcileMovedTracks(db, sourceID: sourceID)
            try db.execute(sql: "UPDATE source SET lastScannedAt = ? WHERE id = ?", arguments: [Date(), sourceID])
            return moved
        }
        summary.movedTracks = moved
        summary.missing -= min(summary.missing, moved.count)
        progress?(ScanProgress(sourcePath: source.path, processed: total, total: total, added: summary.added, updated: summary.updated))
        return summary
    }

    /// Writes the tracks read so far (if any) and counts them.
    private static func save(_ batch: inout [Track], into summary: inout ScanSummary, since lastFlush: inout Date,
                             sourceID: Int64, database: LibraryDatabase) async throws {
        guard !batch.isEmpty else { return }
        let pending = batch
        batch.removeAll()
        lastFlush = Date()
        let (a, u) = try await upsert(pending, sourceID: sourceID, database: database)
        summary.added += a
        summary.updated += u
    }

    /// One file read: its tracks (nil when it can't be read), or `answered: false` when the source didn't answer in time.
    struct ReadResult: Sendable { var url: URL; var tracks: [Track]?; var answered: Bool }

    /// Reads one file within the deadline. A file the source doesn't answer for comes back unanswered (the caller
    /// decides whether that ends the scan); its blocked thread returns whenever the system lets it.
    private static func read(_ url: URL, network: Bool, timeout: TimeInterval,
                             _ work: @escaping @Sendable () -> [Track]?) async throws -> ReadResult {
        guard let tracks = await onIOQueue(network: network, timeout: timeout, work) else {
            return ReadResult(url: url, tracks: nil, answered: false)
        }
        return ReadResult(url: url, tracks: tracks, answered: true)
    }

    /// The order files are read in: those `isNew` (never in the library) first, then the rest. With
    /// `spreadAcrossFolders` each group is dealt out one file per folder in turn (`interleavedByFolder`).
    static func readOrder(_ urls: [URL], isNew: (URL) -> Bool, spreadAcrossFolders: Bool) -> [URL] {
        var fresh: [URL] = [], rest: [URL] = []
        for url in urls { if isNew(url) { fresh.append(url) } else { rest.append(url) } }
        guard spreadAcrossFolders else { return fresh + rest }
        // New files are spread too, but never behind the others: a new folder's files are all in the first group.
        return interleavedByFolder(fresh) + interleavedByFolder(rest)
    }

    static func interleavedByFolder(_ urls: [URL]) -> [URL] {
        var groups: [String: [URL]] = [:], order: [String] = []
        for url in urls {
            let dir = url.deletingLastPathComponent().path
            if groups[dir] == nil { order.append(dir) }
            groups[dir, default: []].append(url)
        }
        var result: [URL] = []
        result.reserveCapacity(urls.count)
        var round = 0
        while result.count < urls.count {
            for dir in order where round < groups[dir]!.count { result.append(groups[dir]![round]) }
            round += 1
        }
        return result
    }

    /// True when the folder (or single-file source) exists and can be read. A dead network mount
    /// fails here rather than looking like an empty folder.
    static func isReachable(_ root: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return audioExtensions.contains(root.pathExtension.lowercased()) }
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil
    }

    public struct ListedFile: Sendable { public var url: URL; public var size: Int64; public var modified: Date }

    /// Lists audio and CUE files with their size and date. Folders are listed concurrently so a
    /// high-latency share costs one round trip per folder level, not per folder. If the source's own folder can't be
    /// listed, the listing fails; a folder inside it that can't be (no permission, gone mid-scan) is returned in
    /// `unreadable`, so the files under it are neither mistaken for deleted ones nor stop the rest being scanned.
    /// A request the source doesn't answer within `timeout` stops the listing with `ScanError.notResponding`.
    static func list(_ root: URL, network forced: Bool? = nil, gate: ShareIOGate = .shared, timeout: TimeInterval = 90,
                     found: (@Sendable (Int) -> Void)? = nil, readFolder: @escaping FolderReader = contentsOfFolder) async throws
        -> (audio: [ListedFile], cue: [URL], imageDirs: Set<String>, unreadable: Set<String>) {
        let exts = audioExtensions
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        // A single-file source: the file plus any CUE sheets beside it.
        typealias Single = (start: URL, file: ListedFile?, cues: [URL])
        guard let first = await onIOQueue(timeout: timeout, { () -> Result<Single, Error> in
            Result {
                let start = root.resolvingSymlinksInPath()
                guard try start.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return (start, nil, []) }
                let v = try start.resourceValues(forKeys: Set(keys))
                let siblings = try FileManager.default.contentsOfDirectory(at: start.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                return (start, ListedFile(url: start, size: Int64(v.fileSize ?? -1), modified: v.contentModificationDate ?? .distantPast),
                        siblings.filter { $0.pathExtension.lowercased() == "cue" })
            }
        }) else { throw ScanError.notResponding(path: root.path) }
        let single = try first.get()
        let start = single.start
        if let file = single.file { return ([file], single.cues, [], []) }
        typealias Listed = (dir: URL, result: Result<(files: [ListedFile], cues: [URL], dirs: [URL], hasImage: URL?), Error>)
        let network = forced ?? NetworkVolume.isNetwork(start)
        let width = network ? 12 : 4
        var audio: [ListedFile] = [], cue: [URL] = [], imageDirs: [URL] = [], unreadable: [URL] = []
        var pending: [URL] = [start]
        // Folders already listed, by path (symlinked ones resolved): a link back up the tree would loop forever.
        var visited: Set<String> = [start.path]
        var failure: Error?
        await withTaskGroup(of: Listed.self) { group in
            var running = 0
            func begin(_ dir: URL) {
                running += 1
                group.addTask { await onIOQueue(network: network, gate: gate, timeout: timeout) {
                    (dir: dir, result: Result {
                        var files: [ListedFile] = [], cues: [URL] = [], dirs: [URL] = [], images: [URL] = []
                        let items = try readFolder(dir, keys)
                        for item in items {
                            var url = item
                            // An item that vanished (or can't be read) since the folder was listed is skipped.
                            guard var v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                            if v.isSymbolicLink == true {
                                url = url.resolvingSymlinksInPath()
                                guard let resolved = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                                v = resolved
                            }
                            if v.isDirectory == true {
                                if v.isPackage != true { dirs.append(url) }
                                continue
                            }
                            guard v.isRegularFile == true else { continue }
                            let ext = url.pathExtension.lowercased()
                            if ext == "cue" { cues.append(url) }
                            else if ArtworkStore.imageExtensions.contains(ext) { images.append(url) }
                            else if exts.contains(ext) {
                                files.append(ListedFile(url: url, size: Int64(v.fileSize ?? -1), modified: v.contentModificationDate ?? .distantPast))
                            }
                        }
                        return (files, cues, dirs, ArtworkStore.pickCover(images) != nil ? dir : nil)
                    })
                } ?? (dir: dir, result: .failure(ScanError.notResponding(path: dir.path))) }
            }
            while running < width, let dir = pending.popLast() { begin(dir) }
            while let (dir, result) = await group.next() {
                running -= 1
                switch result {
                case .failure(let error as ScanError):
                    // The source stopped answering: no point asking it for more folders.
                    failure = error
                    pending.removeAll()
                case .success(let r):
                    audio.append(contentsOf: r.files)
                    cue.append(contentsOf: r.cues)
                    pending.append(contentsOf: r.dirs.filter { visited.insert($0.path).inserted })
                    if let dir = r.hasImage { imageDirs.append(dir) }
                    found?(audio.count)
                case .failure(let error) where dir == start:
                    failure = error
                    pending.removeAll()
                case .failure:
                    unreadable.append(dir)
                }
                while failure == nil, !Task.isCancelled, running < width, let dir = pending.popLast() { begin(dir) }
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        // Same canonical paths as the rest of the library (resolvingSymlinksInPath, which also
        // drops a leading /private), rewritten by prefix: resolving every file would cost a
        // network round trip each on a share.
        let physical = start.withUnsafeFileSystemRepresentation { $0.flatMap { realpath($0, nil) } }.map { p in
            defer { free(p) }
            return String(cString: p)
        } ?? start.path
        let canonical = start.path
        func canon(_ url: URL) -> URL {
            let path = url.path
            guard physical != canonical, path.hasPrefix(physical + "/") else { return url }
            // isDirectory stated: without it Foundation lstat()s every path (a round trip each on a share).
            return URL(fileURLWithPath: canonical + path.dropFirst(physical.count), isDirectory: false)
        }
        // URL.path decodes the whole path on every call; compute each once before sorting 10k+ files.
        let files = audio.map { ListedFile(url: canon($0.url), size: $0.size, modified: $0.modified) }
            .map { ($0.url.path, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        return (files, cue.map(canon), Set(imageDirs.map { canon($0).path }), Set(unreadable.map { canon($0).path }))
    }

    public static func enumerate(_ root: URL) -> (audio: [URL], cue: [URL]) {
        (try? enumerateChecked(root)) ?? ([], [])
    }

    static func enumerateChecked(_ root: URL) throws -> (audio: [URL], cue: [URL]) {
        let exts = audioExtensions
        if try root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let siblings = try FileManager.default.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            return ([root.resolvingSymlinksInPath()], siblings.filter { $0.pathExtension.lowercased() == "cue" })
        }
        var audio: [URL] = []
        var cue: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        var enumerationError: Error?
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    enumerationError = error; return false
                }) else { throw CocoaError(.fileReadNoPermission) }
        for case let url as URL in e {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "cue" { cue.append(url.resolvingSymlinksInPath()) }
            else if exts.contains(ext) { audio.append(url.resolvingSymlinksInPath()) }
        }
        if let enumerationError { throw enumerationError }
        return (audio.sorted { $0.path < $1.path }, cue)
    }

    /// Maps an audio file path to the CUE file (and its tracks) that splits it.
    static func cueSheets(_ cueFiles: [URL]) -> [String: (sheet: CueSheet, tracks: [CueSheet.Entry], signature: String)] {
        var map: [String: (CueSheet, [CueSheet.Entry], String)] = [:]
        for cueURL in cueFiles.sorted(by: { $0.path < $1.path }) {
            guard let sheet = CueSheet.load(cueURL) else { continue }
            // Only single-file sheets with more than one track are split.
            guard sheet.files.count == 1, let file = sheet.files.first, file.tracks.count > 1 else { continue }
            guard let audio = CueSheet.audioFile(named: file.name, besideSheet: cueURL) else { continue }
            let starts = file.tracks.map(\.startCDFrames)
            guard Set(file.tracks.map(\.number)).count == file.tracks.count,
                  file.tracks.allSatisfy({ $0.number > 0 }),
                  zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }),
                  let data = try? Data(contentsOf: cueURL) else { continue }
            map[audio.resolvingSymlinksInPath().path] = (sheet, file.tracks, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return map
    }

    static func readTracks(_ url: URL, cue: (sheet: CueSheet, tracks: [CueSheet.Entry], signature: String)?, artwork: ArtworkStore,
                           folderArt: FolderArtCache? = nil, remote: ListedFile? = nil) -> [Track]? {
        let ext = url.pathExtension.lowercased()
        if SourceInspector.discImageExtensions.contains(ext) || SourceInspector.dvdFolderExtensions.contains(ext) {
            // An SACD image or a DVD-Video (image, or VIDEO_TS folder by its VIDEO_TS.IFO) lists its own tracks;
            // any other disc image or IFO has none. A damaged one fails.
            if ext == "iso", SACDImage.isSACD(url) {
                return try? SACDTracks.read(url: url, artwork: artwork, folderArt: folderArt, size: remote?.size, modified: remote?.modified)
            }
            return try? DVDTracks.read(url: url, artwork: artwork, folderArt: folderArt, size: remote?.size, modified: remote?.modified)
        }
        let read: Track?
        if let remote {
            read = try? RemoteMetadata.readTrack(url: url, size: remote.size, modified: remote.modified, artwork: artwork, folderArt: folderArt)
        } else {
            read = try? MetadataReader.read(url: url, artwork: artwork, folderArt: folderArt)
        }
        guard let base = read else { return nil }
        // No sheet beside the file: one inside it (a FLAC CUESHEET block, a CUESHEET tag), or several audio streams.
        var cue = cue
        if cue == nil, let embedded = EmbeddedCue.sheet(for: url, tags: base.extraTags), let file = embedded.files.first {
            cue = (embedded, file.tracks, "embedded")
        }
        guard let cue else {
            if remote == nil, ["mka", "mkv", "webm"].contains(ext) {
                return ContainerStreamTracks.split(base, url: url, streams: SourceInspector.audioStreams(in: url))
            }
            return [base]
        }
        let rate = base.sampleRate
        let frameCount = base.duration * rate
        guard rate.isFinite, rate > 0, frameCount.isFinite, frameCount > 0,
              frameCount < Double(Int64.max) else { return [base] }
        let totalFrames = Int64(frameCount)
        guard cue.tracks.allSatisfy({ ($0.startSample ?? CueSheet.sampleFrame(cdFrames: $0.startCDFrames, sampleRate: rate)) < totalFrames }) else { return [base] }
        return cue.tracks.enumerated().map { index, entry in
            var t = base
            func sample(_ e: CueSheet.Entry) -> Int64 { e.startSample ?? CueSheet.sampleFrame(cdFrames: e.startCDFrames, sampleRate: rate) }
            let start = sample(entry)
            let end = index + 1 < cue.tracks.count ? sample(cue.tracks[index + 1]) : totalFrames
            t.location = "\(url.path)#\(entry.number)"
            t.cueStartFrame = start
            t.cueFrameLength = max(0, end - start)
            t.duration = Double(max(0, end - start)) / rate
            t.title = entry.title ?? "Track \(entry.number)"
            t.artist = entry.performer ?? cue.sheet.performer ?? base.artist
            t.album = cue.sheet.title ?? base.album
            t.albumArtist = cue.sheet.performer ?? base.albumArtist
            t.genre = cue.sheet.genre ?? base.genre
            t.releaseDate = cue.sheet.date ?? base.releaseDate
            t.year = (cue.sheet.date).flatMap(MetadataReader.year(from:)) ?? base.year
            t.trackNumber = entry.number
            t.trackTotal = cue.tracks.count
            t.isrc = entry.isrc
            t.bitrate = base.bitrate
            return t
        }
    }

    /// Inserts new tracks; updates changed ones while keeping library state (play counts, ratings, date added).
    static func upsert(_ tracks: [Track], sourceID: Int64, database: LibraryDatabase, preserveAnalysis: Bool = false) async throws -> (added: Int, updated: Int) {
        guard !tracks.isEmpty else { return (0, 0) }
        return try await database.writer.write { db in
            var added = 0, updated = 0
            for var track in tracks {
                track.sourceId = sourceID
                if let existing = try Track.filter(Column("location") == track.location).fetchOne(db) {
                    track.id = existing.id
                    track.addedAt = existing.addedAt
                    track.playCount = existing.playCount
                    track.lastPlayedAt = existing.lastPlayedAt
                    if track.rating == nil { track.rating = existing.rating }
                    // Re-read but unchanged (a forced re-read, a tag-only look): its analysis still holds.
                    let stored = existing.codec == track.codec ? try Data.fetchOne(db, sql: """
                        SELECT data FROM analysis WHERE trackId = ? AND fileSize = ? AND modifiedAt = ?
                        """, arguments: [existing.id, track.fileSize, track.modifiedAt]) : nil
                    // The stored analysis still describes the file: take the verdict from it, not from the old row
                    // (which may have lost it), so a re-read can never drop a badge.
                    if let stored, let analysis = try? LibraryDatabase.analysisDecoder().decode(FileAnalysis.self, from: stored) {
                        track.effectiveBitDepth = analysis.effectiveBitDepth
                        track.bandwidthHz = analysis.bandwidthHz
                        track.analysisVerdict = analysis.verdict.rawValue
                    } else if preserveAnalysis {
                        track.effectiveBitDepth = existing.effectiveBitDepth
                        track.bandwidthHz = existing.bandwidthHz
                        track.analysisVerdict = existing.analysisVerdict
                    }
                    // Library-only edits (CUE tracks, files on read-only shares) outlast the file's own tags.
                    if let data = try Data.fetchOne(db,
                        sql: "SELECT metadata FROM cueTagOverride WHERE trackId = ?", arguments: [existing.id]) {
                        track.copyMetadata(from: try JSONDecoder().decode(Track.self, from: data))
                    }
                    track.isMissing = false
                    try track.update(db)
                    updated += 1
                } else {
                    try track.insert(db)
                    added += 1
                }
            }
            return (added, updated)
        }
    }

    /// Re-reads specific files (after a tag edit) without walking the whole source.
    public func refresh(trackIDs: [Int64]) async throws {
        let tracks = try database.tracks(ids: trackIDs)
        let files = Dictionary(grouping: tracks, by: \.filePath)
        for (path, group) in files {
            guard let sourceID = group.first?.sourceId else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: false)
            let cue = group.contains { $0.cueStartFrame != nil }
                ? Self.cueSheets(Self.enumerate(url.deletingLastPathComponent()).cue)[path] : nil
            if let fresh = Self.readTracks(url, cue: cue, artwork: artwork) {
                _ = try await Self.upsert(fresh, sourceID: sourceID, database: database, preserveAnalysis: true)
            }
        }
    }
}

/// When a scan last heard from its source (a folder listed, a file read), readable from any thread.
final class ScanActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.lock(); last = Date(); lock.unlock() }
    /// Seconds since the source last answered.
    var quiet: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}
