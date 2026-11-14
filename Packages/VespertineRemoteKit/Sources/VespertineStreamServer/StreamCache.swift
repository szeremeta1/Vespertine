//
// Vespertine: the cache of FLACs made for phones. A file is named by what it was made from and how, so the same song at the
// same settings is converted once; the least recently used go first when the folder is over its limit, never one a phone is reading.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public final class StreamCache: @unchecked Sendable {
    public let directory: URL
    public var limitBytes: Int64 { lock.withLock { limit } }
    private var limit: Int64
    private let lock = NSLock()

    /// Creates the folder, and removes what a crash left half written.
    public init(directory: URL, limitBytes: Int64) throws {
        self.directory = directory
        limit = limitBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func url(for key: String) -> URL { directory.appendingPathComponent(key).appendingPathExtension("flac") }
    public func partialURL(for key: String) -> URL { directory.appendingPathComponent(key).appendingPathExtension("partial") }
    public func metadataURL(for key: String) -> URL { directory.appendingPathComponent(key).appendingPathExtension("json") }

    /// A stable name for a conversion: everything the bytes depend on.
    public static func key(for request: TranscodeRequest) -> String {
        let text = ["v1", request.source.path, String(request.sourceSize), String(request.sourceModified.timeIntervalSince1970), request.regionKey ?? "",
                    String(request.sampleRate), String(request.bitDepth), String(request.channels)].joined(separator: "|")
        // Two FNV-1a passes with different bases: 128 bits of name, not a security boundary.
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            return hash
        }
        return String(format: "%016llx%016llx", fnv(0xcbf2_9ce4_8422_2325), fnv(0x8422_2325_cbf2_9ce4))
    }

    /// Marks a file as just used.
    public func touch(_ key: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: key).path)
    }

    /// The size of the cached FLACs.
    public var totalBytes: Int64 { entries().reduce(0) { $0 + $1.size } }

    /// Removes the least recently used FLACs (and their metadata) until the folder fits, except `keeping`.
    public func evict(keeping: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        evict(to: limit, keeping: keeping)
    }

    /// Changes how much the folder may hold, and makes it fit now.
    public func setLimit(_ bytes: Int64, keeping: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        limit = max(0, bytes)
        evict(to: limit, keeping: keeping)
    }

    /// Removes every FLAC except `keeping` (the ones phones are reading).
    public func clear(keeping: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        evict(to: 0, keeping: keeping)
    }

    private func evict(to limitBytes: Int64, keeping: Set<String>) {
        var all = entries().sorted { $0.used < $1.used }
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        while total > limitBytes, let index = all.firstIndex(where: { !keeping.contains($0.key) }) {
            let victim = all.remove(at: index)
            try? FileManager.default.removeItem(at: url(for: victim.key))
            try? FileManager.default.removeItem(at: metadataURL(for: victim.key))
            total -= victim.size
        }
    }

    private func entries() -> [(key: String, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []).compactMap { url in
            guard url.pathExtension == "flac", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
