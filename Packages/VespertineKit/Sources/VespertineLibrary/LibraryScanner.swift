//
// Vespertine — incremental folder scanning.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit
import GRDB
import VespertineAudio

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
    private var activeScans: [Int64: Task<ScanSummary, Error>] = [:]

    public func setSkipsNonMusic(_ value: Bool) { skipsNonMusic = value }

    /// Blocking file I/O runs here, not on Swift's cooperative pool (sized to the CPU count, so a
    /// few blocked reads would stall the rest). GCD adds threads while they wait on the network.
    static let ioQueue = DispatchQueue(label: "org.szeremeta.vespertine.scan-io", qos: .utility, attributes: .concurrent)

    static func onIOQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
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

    /// Rescans a source. Unchanged files (same size and modification date) are skipped.
    @discardableResult
    public func scan(_ source: LibrarySource, progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanSummary {
        guard let sourceID = source.id else { return ScanSummary() }
        if let active = activeScans[sourceID] { return try await active.value }
        let task = Task { try await self.performScan(source, progress: progress) }
        activeScans[sourceID] = task
        defer { activeScans[sourceID] = nil }
        return try await task.value
    }

    private func performScan(_ source: LibrarySource, progress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanSummary {
        guard let sourceID = source.id else { return ScanSummary() }
        var summary = ScanSummary()
        let root = source.url

        let online = Self.isReachable(root)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE source SET isOnline = ? WHERE id = ?", arguments: [online, sourceID])
        }
        guard online else { summary.interrupted = true; return summary }

        let listing = try await Self.list(root) { count in
            progress?(ScanProgress(phase: .listing, sourcePath: source.path, processed: count, total: 0, added: 0, updated: 0))
        }
        let cueByAudio = Self.cueSheets(listing.cue)
        let priorCues: [String: String] = try await database.writer.read { db in
            var signatures: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT filePath, signature FROM cueScanState WHERE sourceId = ?", arguments: [sourceID]) {
                signatures[row["filePath"]] = row["signature"]
            }
            return signatures
        }

        struct Known: Sendable { var id: Int64; var size: Int64; var modified: Date; var isMissing: Bool; var hasArt: Bool }
        let known: [String: Known] = try await database.writer.read { db in
            var map: [String: Known] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, location, fileSize, modifiedAt, isMissing, artworkKey IS NOT NULL AS hasArt FROM track WHERE sourceId = ?", arguments: [sourceID]) {
                map[row["location"]] = Known(id: row["id"], size: row["fileSize"], modified: row["modifiedAt"], isMissing: row["isMissing"], hasArt: row["hasArt"])
            }
            return map
        }

        // Decide what needs reading. Size and date come from the listing (no per-file stat).
        var toRead: [URL] = []
        var listed: [String: ListedFile] = [:]
        let remote = NetworkVolume.isNetwork(root)
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
            } else {
                seen.insert(url.path)
                if let k = known[url.path], k.size == size, abs(k.modified.timeIntervalSince(modified)) < 0.001, !k.isMissing, !coverAppeared(k, url) { continue }
                toRead.append(url)
            }
        }

        // On a network share, macOS looks up never-seen files in a folder one at a time, so keep
        // the reads in flight spread across folders (round-robin) rather than one album at a time.
        if remote { toRead = Self.interleavedByFolder(toRead) }

        let total = toRead.count
        var processed = 0
        let artwork = self.artwork
        let folderArt = FolderArtCache()
        var batch: [Track] = []
        let database = self.database

        try await withThrowingTaskGroup(of: (URL, [Track]?).self) { group in
            var iterator = toRead.makeIterator()
            for _ in 0..<Self.readWidth(for: root) {
                guard let url = iterator.next() else { break }
                let cue = cueByAudio[url.path], file = listed[url.path]
                group.addTask { (url, await Self.onIOQueue { Self.readTracks(url, cue: cue, artwork: artwork, folderArt: folderArt, remote: file) }) }
            }
            let skipping = self.skipsNonMusic && source.mode != .managed
            while let (url, tracks) = try await group.next() {
                processed += 1
                if let tracks {
                    // An invalid CUE may fall back to the whole file. Track what was actually indexed.
                    if let cue = cueByAudio[url.path] {
                        for entry in cue.tracks { seen.remove("\(url.path)#\(entry.number)") }
                    }
                    for track in tracks { seen.insert(track.location) }
                    let kept = skipping ? tracks.filter(MusicFinder.keepsInLibrary) : tracks
                    summary.skipped += tracks.count - kept.count
                    batch.append(contentsOf: kept)
                } else { summary.failed.append(url.path) }
                if batch.count >= 200 {
                    let pending = batch
                    batch.removeAll()
                    let (a, u) = try await Self.upsert(pending, sourceID: sourceID, database: database)
                    summary.added += a
                    summary.updated += u
                }
                if processed % 25 == 0 || processed == total {
                    progress?(ScanProgress(sourcePath: source.path, processed: processed, total: total, added: summary.added, updated: summary.updated))
                }
                if let next = iterator.next() {
                    let cue = cueByAudio[next.path], file = listed[next.path]
                    group.addTask { (next, await Self.onIOQueue { Self.readTracks(next, cue: cue, artwork: artwork, folderArt: folderArt, remote: file) }) }
                }
            }
        }
        let (a, u) = try await Self.upsert(batch, sourceID: sourceID, database: database)
        summary.added += a
        summary.updated += u

        // A share that dropped mid-scan lists (and reads) nothing: never mistake that for deletions.
        guard Self.isReachable(root) else {
            summary.interrupted = true
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE source SET isOnline = 0 WHERE id = ?", arguments: [sourceID])
            }
            return summary
        }

        // Flag files that disappeared (kept so playlists and play counts survive a re-plug).
        let missing = known.filter { !seen.contains($0.key) && !$0.value.isMissing }.map(\.value.id)
        summary.missing = missing.count
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
    /// high-latency share costs one round trip per folder level, not per folder. Any folder that
    /// can't be listed fails the whole listing, so its files are never mistaken for deleted ones.
    static func list(_ root: URL, found: (@Sendable (Int) -> Void)? = nil) async throws -> (audio: [ListedFile], cue: [URL], imageDirs: Set<String>) {
        let exts = audioExtensions
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let start = root.resolvingSymlinksInPath()
        // A single-file source: the file plus any CUE sheets beside it.
        if try start.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let v = try start.resourceValues(forKeys: Set(keys))
            let siblings = try FileManager.default.contentsOfDirectory(at: start.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            return ([ListedFile(url: start, size: Int64(v.fileSize ?? -1), modified: v.contentModificationDate ?? .distantPast)],
                    siblings.filter { $0.pathExtension.lowercased() == "cue" }, [])
        }
        typealias Listed = Result<(files: [ListedFile], cues: [URL], dirs: [URL], hasImage: URL?), Error>
        let width = NetworkVolume.isNetwork(start) ? 12 : 4
        var audio: [ListedFile] = [], cue: [URL] = [], imageDirs: [URL] = []
        var pending: [URL] = [start]
        // Folders already listed, by path (symlinked ones resolved): a link back up the tree would loop forever.
        var visited: Set<String> = [start.path]
        var failure: Error?
        await withTaskGroup(of: Listed.self) { group in
            var running = 0
            func begin(_ dir: URL) {
                running += 1
                group.addTask { await onIOQueue {
                    Result {
                        var files: [ListedFile] = [], cues: [URL] = [], dirs: [URL] = [], images: [URL] = []
                        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                        for item in items {
                            var url = item
                            var v = try url.resourceValues(forKeys: Set(keys))
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
                    }
                } }
            }
            while running < width, let dir = pending.popLast() { begin(dir) }
            while let result = await group.next() {
                running -= 1
                switch result {
                case .success(let r):
                    audio.append(contentsOf: r.files)
                    cue.append(contentsOf: r.cues)
                    pending.append(contentsOf: r.dirs.filter { visited.insert($0.path).inserted })
                    if let dir = r.hasImage { imageDirs.append(dir) }
                    found?(audio.count)
                case .failure(let error):
                    failure = failure ?? error
                    pending.removeAll()
                }
                while failure == nil, running < width, let dir = pending.popLast() { begin(dir) }
            }
        }
        if let failure { throw failure }
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
        return (files, cue.map(canon), Set(imageDirs.map { canon($0).path }))
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
        let read: Track?
        if let remote {
            read = try? RemoteMetadata.readTrack(url: url, size: remote.size, modified: remote.modified, artwork: artwork, folderArt: folderArt)
        } else {
            read = try? MetadataReader.read(url: url, artwork: artwork, folderArt: folderArt)
        }
        guard let base = read else { return nil }
        guard let cue else { return [base] }
        let rate = base.sampleRate
        let frameCount = base.duration * rate
        guard rate.isFinite, rate > 0, frameCount.isFinite, frameCount > 0,
              frameCount < Double(Int64.max) else { return [base] }
        let totalFrames = Int64(frameCount)
        guard cue.tracks.allSatisfy({ CueSheet.sampleFrame(cdFrames: $0.startCDFrames, sampleRate: rate) < totalFrames }) else { return [base] }
        return cue.tracks.enumerated().map { index, entry in
            var t = base
            let start = CueSheet.sampleFrame(cdFrames: entry.startCDFrames, sampleRate: rate)
            let end = index + 1 < cue.tracks.count
                ? CueSheet.sampleFrame(cdFrames: cue.tracks[index + 1].startCDFrames, sampleRate: rate) : totalFrames
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
                    if let stored, let analysis = try? JSONDecoder().decode(FileAnalysis.self, from: stored) {
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
