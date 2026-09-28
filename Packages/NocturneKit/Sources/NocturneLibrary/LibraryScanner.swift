//
// Nocturne — incremental folder scanning.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import NocturneAudio

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
    public var skipped = 0
    public var failed: [String] = []
    /// The source went away mid-scan (a network share dropped); nothing was marked missing.
    public var interrupted = false
}

public actor LibraryScanner {
    let database: LibraryDatabase
    let artwork: ArtworkStore
    /// Leave out voice recordings, telephony audio and short clips (same rules as MusicFinder).
    public var skipsNonMusic = true

    public func setSkipsNonMusic(_ value: Bool) { skipsNonMusic = value }

    /// Files read concurrently. Local disks gain little past 6; network shares hide
    /// round-trip latency with more requests in flight.
    /// Blocking file I/O runs here, not on Swift's cooperative pool (sized to the CPU count, so a
    /// few blocked reads would stall the rest). GCD adds threads while they wait on the network.
    static let ioQueue = DispatchQueue(label: "org.nocturne.scan-io", qos: .utility, attributes: .concurrent)

    static func onIOQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    public static func readWidth(for root: URL) -> Int {
        return NetworkVolume.isNetwork(root) ? 32 : 6
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
        var summary = ScanSummary()
        let root = source.url

        let online = Self.isReachable(root)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE source SET isOnline = ? WHERE id = ?", arguments: [online, sourceID])
        }
        guard online else { summary.interrupted = true; return summary }

        let listing = await Self.list(root) { count in
            progress?(ScanProgress(phase: .listing, sourcePath: source.path, processed: count, total: 0, added: 0, updated: 0))
        }
        let cueByAudio = Self.cueSheets(listing.cue)

        struct Known: Sendable { var id: Int64; var size: Int64; var modified: Date; var isMissing: Bool }
        let known: [String: Known] = try await database.writer.read { db in
            var map: [String: Known] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, location, fileSize, modifiedAt, isMissing FROM track WHERE sourceId = ?", arguments: [sourceID]) {
                map[row["location"]] = Known(id: row["id"], size: row["fileSize"], modified: row["modifiedAt"], isMissing: row["isMissing"])
            }
            return map
        }

        // Decide what needs reading. Size and date come from the listing (no per-file stat).
        var toRead: [URL] = []
        var listed: [String: ListedFile] = [:]
        let remote = NetworkVolume.isNetwork(root)
        var seen = Set<String>()
        for file in listing.audio {
            let url = file.url, size = file.size, modified = file.modified
            if remote { listed[url.path] = file }
            if let cue = cueByAudio[url.path] {
                let locations = cue.tracks.map { "\(url.path)#\($0.number)" }
                locations.forEach { seen.insert($0) }
                if let first = locations.first, let k = known[first], k.size == size, abs(k.modified.timeIntervalSince(modified)) < 1, !k.isMissing { continue }
                toRead.append(url)
            } else {
                seen.insert(url.path)
                if let k = known[url.path], k.size == size, abs(k.modified.timeIntervalSince(modified)) < 1, !k.isMissing { continue }
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
            let skipping = self.skipsNonMusic
            while let (url, tracks) = try await group.next() {
                processed += 1
                if let tracks {
                    let kept = skipping ? tracks.filter { MusicFinder.kind(sampleRate: $0.sampleRate, channels: $0.channels, duration: $0.duration, isDSD: $0.isDSD) == .music || $0.cueStartFrame != nil } : tracks
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
        try await database.writer.write { db in
            for id in missing { try db.execute(sql: "UPDATE track SET isMissing = 1 WHERE id = ?", arguments: [id]) }
            try db.execute(sql: "UPDATE source SET lastScannedAt = ? WHERE id = ?", arguments: [Date(), sourceID])
        }
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

    /// True when the folder exists and can be listed (a dead network mount fails here, not with an empty folder).
    static func isReachable(_ root: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil
    }

    public struct ListedFile: Sendable { public var url: URL; public var size: Int64; public var modified: Date }

    /// Lists audio and CUE files with their size and date. Folders are listed concurrently so a
    /// high-latency share costs one round trip per folder level, not per folder.
    static func list(_ root: URL, found: (@Sendable (Int) -> Void)? = nil) async -> (audio: [ListedFile], cue: [URL]) {
        let exts = audioExtensions
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let width = NetworkVolume.isNetwork(root) ? 12 : 4
        var audio: [ListedFile] = [], cue: [URL] = []
        var pending: [URL] = [root]
        await withTaskGroup(of: (files: [ListedFile], cues: [URL], dirs: [URL]).self) { group in
            var running = 0
            func start(_ dir: URL) {
                running += 1
                group.addTask { await onIOQueue {
                    var files: [ListedFile] = [], cues: [URL] = [], dirs: [URL] = []
                    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                    for url in items {
                        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                        if v.isDirectory == true {
                            if v.isPackage != true { dirs.append(url) }
                            continue
                        }
                        guard v.isRegularFile == true else { continue }
                        let ext = url.pathExtension.lowercased()
                        if ext == "cue" { cues.append(url) }
                        else if exts.contains(ext) {
                            files.append(ListedFile(url: url, size: Int64(v.fileSize ?? -1), modified: v.contentModificationDate ?? .distantPast))
                        }
                    }
                    return (files, cues, dirs)
                } }
            }
            while running < width, let dir = pending.popLast() { start(dir) }
            while let result = await group.next() {
                running -= 1
                audio.append(contentsOf: result.files)
                cue.append(contentsOf: result.cues)
                pending.append(contentsOf: result.dirs)
                found?(audio.count)
                while running < width, let dir = pending.popLast() { start(dir) }
            }
        }
        return (audio.sorted { $0.url.path < $1.url.path }, cue)
    }

    public static func enumerate(_ root: URL) -> (audio: [URL], cue: [URL]) {
        let exts = audioExtensions
        var audio: [URL] = []
        var cue: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            if ext == "cue" { cue.append(url) }
            else if exts.contains(ext) { audio.append(url) }
        }
        return (audio.sorted { $0.path < $1.path }, cue)
    }

    /// Maps an audio file path to the CUE file (and its tracks) that splits it.
    static func cueSheets(_ cueFiles: [URL]) -> [String: (sheet: CueSheet, tracks: [CueSheet.Entry])] {
        var map: [String: (CueSheet, [CueSheet.Entry])] = [:]
        for cueURL in cueFiles {
            guard let sheet = CueSheet.load(cueURL) else { continue }
            // Only single-file sheets with more than one track are split.
            guard sheet.files.count == 1, let file = sheet.files.first, file.tracks.count > 1 else { continue }
            let audio = cueURL.deletingLastPathComponent().appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: audio.path) { map[audio.path] = (sheet, file.tracks) }
        }
        return map
    }

    static func readTracks(_ url: URL, cue: (sheet: CueSheet, tracks: [CueSheet.Entry])?, artwork: ArtworkStore,
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
        let totalFrames = Int64(base.duration * rate)
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
    static func upsert(_ tracks: [Track], sourceID: Int64, database: LibraryDatabase) async throws -> (added: Int, updated: Int) {
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
            let url = URL(fileURLWithPath: path)
            let cue = group.contains { $0.cueStartFrame != nil }
                ? Self.cueSheets(Self.enumerate(url.deletingLastPathComponent()).cue)[path] : nil
            if let fresh = Self.readTracks(url, cue: cue, artwork: artwork) {
                _ = try await Self.upsert(fresh, sourceID: sourceID, database: database)
            }
        }
    }
}
