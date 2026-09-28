//
// Nocturne — imports analysis results computed on the server behind a network share
// (`nocturne-analyze` writes `<share>/.nocturne/analysis.jsonl`), so the Mac never has to read
// every file over the network to learn which ones are genuine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneAudio

/// Progress of the server's analysis run (`.nocturne/status.json`).
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

    /// Per index file: what has been read so far.
    private struct Cursor {
        var identity: String
        var offset: UInt64
        var records: [String: Record]
    }
    private var cursors: [String: Cursor] = [:]
    private let lock = NSLock()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    public init() {}

    /// The folder holding `.nocturne/analysis.jsonl` for this source: the source folder itself or
    /// one of its parents on the same volume (the share root when the source is a subfolder).
    public static func indexRoot(for source: LibrarySource) -> URL? {
        var dir = URL(fileURLWithPath: source.path, isDirectory: true)
        let volume = (try? dir.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(".nocturne/analysis.jsonl", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) { return dir }
            if dir.standardizedFileURL.path == volume || dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    public static func status(at root: URL) -> ServerAnalysisStatus? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".nocturne/status.json", isDirectory: false)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ServerAnalysisStatus.self, from: data)
    }

    /// Reads what's new in the source's index and saves results for its tracks that don't have a
    /// current analysis yet. Returns how many tracks were updated. Blocking; call off the main thread.
    public func importNew(for source: LibrarySource, into database: LibraryDatabase) throws -> Int {
        guard let root = Self.indexRoot(for: source) else { return 0 }
        let records = try readIndex(root.appendingPathComponent(".nocturne/analysis.jsonl", isDirectory: false))
        guard !records.isEmpty, let sourceID = source.id else { return 0 }

        let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        var matched: [(FileAnalysis, String)] = []
        for track in try database.tracksNeedingAnalysis() where track.sourceId == sourceID {
            guard track.filePath.hasPrefix(base) else { continue }
            let rel = String(track.filePath.dropFirst(base.count)).precomposedStringWithCanonicalMapping
            guard let r = records[rel], r.size == track.fileSize,
                  abs(r.mtime - track.modifiedAt.timeIntervalSince1970) < 2,
                  r.analysis.version >= FileAnalysis.currentVersion else { continue }
            matched.append((r.analysis, track.filePath))
        }
        try database.saveAnalyses(matched)
        return matched.count
    }

    /// All records in the index, reading only the part appended since the last call when the
    /// file was just appended to (the server rewrites it only when compacting).
    private func readIndex(_ url: URL) throws -> [String: Record] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values.fileSize ?? 0)
        // The file's first line identifies it: appending never changes it, and the server's compaction
        // (sorted, rewritten) does, so a rewrite is always read in full, whatever its size.
        let identity: String = {
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            let head = (try? h.read(upToCount: 4096)) ?? Data()
            return String(decoding: head.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        }()
        lock.lock()
        var cursor = cursors[url.path] ?? Cursor(identity: identity, offset: 0, records: [:])
        lock.unlock()
        if cursor.identity != identity || size < cursor.offset {
            cursor = Cursor(identity: identity, offset: 0, records: [:])
        }
        if size > cursor.offset {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: cursor.offset)
            let data = try handle.read(upToCount: Int(size - cursor.offset)) ?? Data()
            // Complete lines only; a line still being written is picked up next time.
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = data[data.startIndex...lastNewline]
                for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    if let r = try? Self.decoder.decode(Record.self, from: Data(line)) {
                        cursor.records[r.path.precomposedStringWithCanonicalMapping] = r
                    }
                }
                cursor.offset += UInt64(complete.count)
            }
        }
        lock.lock()
        cursors[url.path] = cursor
        lock.unlock()
        return cursor.records
    }
}
