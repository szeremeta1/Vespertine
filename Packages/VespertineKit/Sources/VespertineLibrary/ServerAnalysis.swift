//
// Vespertine — imports analysis results computed on the server behind a network share
// (`vespertine-analyze` writes `<share>/.vespertine/analysis.jsonl`), so the Mac never has to read
// every file over the network to learn which ones are genuine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// Progress of the server's analysis run (`.vespertine/status.json`).
public struct ServerAnalysisStatus: Codable, Sendable, Hashable {
    public var state: String
    public var started: Date
    public var updated: Date
    public var total: Int
    public var done: Int
    public var failures: Int
    public var isRunning: Bool { state == "running" }
}

public final class ServerAnalysisImporter: @unchecked Sendable {
    struct Record: Decodable {
        var path: String
        var size: Int64
        var mtime: Double
        var analysis: FileAnalysis
    }

    /// What matching a record to a track needs: decoded from every line, leaving the analysis (a spectrum of
    /// hundreds of values, and the forensics) to the few lines that match a track.
    private struct Head: Decodable {
        var path: String
        var size: Int64
        var mtime: Double
    }

    /// The latest line for one path: enough to match it to a track, and where to read the whole record when it does.
    struct Entry: Sendable, Hashable {
        var size: Int64
        var mtime: Double
        var offset: UInt64
        var length: Int
    }

    /// Per index file: what has been read so far. Shared by reference, so a read that outlasts its caller's
    /// deadline (it keeps running) still leaves its progress for the next one.
    private final class Cursor {
        let identity: String
        var offset: UInt64 = 0
        var entries: [String: Entry] = [:]
        init(identity: String) { self.identity = identity }
    }
    private var cursors: [String: Cursor] = [:]
    private let lock = NSLock()
    /// The index is read this much at a time: a large one, over a slow link, is never one huge read.
    static let chunkSize = 4 << 20
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
    /// A line isn't the record its entry says any more: the file was rewritten without its first line changing.
    private struct StaleIndex: Error {}

    public init() {}

    /// A file in the server's index folder: `.vespertine/`, or `.nocturne/` written by servers set up
    /// before the rename.
    static func indexFile(_ name: String, in root: URL) -> URL {
        let current = root.appendingPathComponent(".vespertine/" + name, isDirectory: false)
        let legacy = root.appendingPathComponent(".nocturne/" + name, isDirectory: false)
        return FileManager.default.fileExists(atPath: current.path) || !FileManager.default.fileExists(atPath: legacy.path) ? current : legacy
    }

    /// The folder holding `.vespertine/analysis.jsonl` (or the older `.nocturne/`) for this source: the source folder itself or
    /// one of its parents on the same volume (the share root when the source is a subfolder).
    public static func indexRoot(for source: LibrarySource) -> URL? {
        var dir = URL(fileURLWithPath: source.path, isDirectory: true)
        let volume = (try? dir.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: indexFile("analysis.jsonl", in: dir).path) { return dir }
            if dir.standardizedFileURL.path == volume || dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    public static func status(at root: URL) -> ServerAnalysisStatus? {
        guard let data = try? Data(contentsOf: indexFile("status.json", in: root)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ServerAnalysisStatus.self, from: data)
    }

    /// Reads what's new in the source's index and saves results for its tracks that don't have a
    /// current analysis yet. Returns how many tracks were updated. Blocking; call off the main thread.
    public func importNew(for source: LibrarySource, into database: LibraryDatabase) throws -> Int {
        guard let root = Self.indexRoot(for: source) else { return 0 }
        let url = Self.indexFile("analysis.jsonl", in: root)
        // A line that turns out not to be the record its entry says means the file was rewritten under the same first
        // line: it's read again in full, once.
        for attempt in 0..<2 {
            do {
                return try importNew(for: source, from: url, into: database)
            } catch is StaleIndex where attempt == 0 {
                forget(url)
            } catch is StaleIndex {
                forget(url)
                return 0
            }
        }
        return 0
    }

    private func importNew(for source: LibrarySource, from url: URL, into database: LibraryDatabase) throws -> Int {
        guard let root = Self.indexRoot(for: source) else { return 0 }
        let (entries, file) = try readIndex(url)
        defer { try? file.close() }
        guard !entries.isEmpty, let sourceID = source.id else { return 0 }

        let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        // A folder whose name SMB can't carry ("Morning Glory?", "Mozart: Requiem") reaches the Mac under a mangled
        // name ("_3018I~A"), so its path isn't in the server's index. Those files are found by size and date (within
        // 2 ms) instead, among records no track claims by path, when exactly one fits.
        // Only records that belong to no track by path are candidates.
        let known = Set(try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT filePath FROM track WHERE sourceId = ?", arguments: [sourceID])
        }.compactMap { $0.hasPrefix(base) ? String($0.dropFirst(base.count)).precomposedStringWithCanonicalMapping : nil })
        var bySize: [Int64: [(path: String, entry: Entry)]] = [:]
        for (path, e) in entries where !known.contains(path) { bySize[e.size, default: []].append((path, e)) }
        var matched: [(FileAnalysis, String)] = []
        for track in try database.tracksNeedingAnalysis() where track.sourceId == sourceID {
            guard track.filePath.hasPrefix(base) else { continue }
            let rel = String(track.filePath.dropFirst(base.count)).precomposedStringWithCanonicalMapping
            let byPath = entries[rel].flatMap { e in
                e.size == track.fileSize && abs(e.mtime - track.modifiedAt.timeIntervalSince1970) < 2 ? (path: rel, entry: e) : nil
            }
            let candidates = (bySize[track.fileSize] ?? []).filter { abs($0.entry.mtime - track.modifiedAt.timeIntervalSince1970) < 0.002 }
            guard let hit = byPath ?? (candidates.count == 1 ? candidates[0] : nil),
                  let r = try Self.record(hit.entry, path: hit.path, in: file) else { continue }
            // A server still on an older analyzer: its results are judged anew here from their measurements.
            let analysis = FileAnalyzer.rejudged(r.analysis)
            guard analysis.version >= FileAnalysis.currentVersion else { continue }
            matched.append((analysis, track.filePath))
        }
        try database.saveAnalyses(matched)
        return matched.count
    }

    /// The whole record on an entry's line, read from the index file the entry came from; nil when it can't be decoded.
    private static func record(_ entry: Entry, path: String, in file: FileHandle) throws -> Record? {
        try file.seek(toOffset: entry.offset)
        let line = try file.read(upToCount: entry.length) ?? Data()
        func same(_ p: String, _ size: Int64, _ mtime: Double) -> Bool {
            p.precomposedStringWithCanonicalMapping == path && size == entry.size && mtime == entry.mtime
        }
        guard line.count == entry.length else { throw StaleIndex() }
        if let r = try? decoder.decode(Record.self, from: line) {
            guard same(r.path, r.size, r.mtime) else { throw StaleIndex() }
            return r
        }
        guard let head = try? decoder.decode(Head.self, from: line), same(head.path, head.size, head.mtime) else { throw StaleIndex() }
        return nil
    }

    private func forget(_ url: URL) {
        lock.lock()
        cursors[url.path] = nil
        lock.unlock()
    }

    /// Where the latest record for each path (NFC) is in the index, reading only the part appended since the last
    /// call when the file was just appended to (the server rewrites it only when compacting), a chunk at a time.
    /// Also returns the file, open, for reading the records that match.
    private func readIndex(_ url: URL) throws -> (entries: [String: Entry], file: FileHandle) {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            // The file's first line identifies it: appending never changes it, and the server's compaction
            // (sorted, rewritten) does, so a rewrite is always read in full, whatever its size.
            let head = try handle.read(upToCount: 4096) ?? Data()
            let identity = String(decoding: head.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
            let size = try handle.seekToEnd()
            lock.lock()
            var cursor = cursors[url.path] ?? Cursor(identity: identity)
            if cursor.identity != identity || size < cursor.offset { cursor = Cursor(identity: identity) }
            cursors[url.path] = cursor
            let start = cursor.offset
            lock.unlock()

            var position = start      // where the next chunk starts
            var lineStart = start     // where `carry` (a line not finished in the chunks so far) starts
            var carry = Data()
            try handle.seek(toOffset: start)
            reading: while position < size {
                // Each chunk is let go of as soon as it's parsed, not when the (GCD) thread's pool drains at the end.
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: Int(min(UInt64(Self.chunkSize), size - position))) ?? Data()
                }
                if chunk.isEmpty { break }
                position += UInt64(chunk.count)
                var buffer = carry
                buffer.append(chunk)
                var batch: [(String, Entry)] = []
                var from = buffer.startIndex
                while let newline = buffer[from...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[from..<newline]
                    if !line.isEmpty, let h = try? Self.decoder.decode(Head.self, from: Data(line)) {
                        let offset = lineStart + UInt64(from - buffer.startIndex)
                        batch.append((h.path.precomposedStringWithCanonicalMapping,
                                      Entry(size: h.size, mtime: h.mtime, offset: offset, length: line.count)))
                    }
                    from = newline + 1
                }
                let committed = lineStart
                lineStart += UInt64(from - buffer.startIndex)
                // Complete lines only; a line still being written is picked up next time.
                carry = Data(buffer[from...])
                lock.lock()
                // Another read of the same file got further meanwhile (or the file was replaced): its progress stands.
                guard cursors[url.path] === cursor, cursor.offset == committed else { lock.unlock(); break reading }
                for (path, entry) in batch { cursor.entries[path] = entry }
                cursor.offset = lineStart
                lock.unlock()
            }
            lock.lock()
            let entries = cursor.entries
            lock.unlock()
            return (entries, handle)
        } catch {
            try? handle.close()
            throw error
        }
    }
}
