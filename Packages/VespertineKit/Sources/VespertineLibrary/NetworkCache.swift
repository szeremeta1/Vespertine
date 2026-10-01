//
// Vespertine — local copies of files on network shares.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two kinds of copies:
//   • cached — the playing and upcoming tracks, kept up to a size limit, least recently
//     played first out;
//   • offline — albums the user chose to keep; never evicted, not counted against the limit.
// A copy is used only while it matches the file on the share (same path, size and date).
//

import CryptoKit
import Foundation

public final class NetworkCache: @unchecked Sendable {
    public struct Usage: Sendable, Equatable {
        public var cachedBytes: Int64 = 0
        public var cachedFiles = 0
        public var offlineBytes: Int64 = 0
        public var offlineFiles = 0
        public var downloading = 0
        public var queued = 0
        public init() {}
    }

    struct Entry: Codable {
        var key: String
        var remotePath: String
        var fileName: String
        var size: Int64
        var pinned: Bool
        var lastUsed: Date
    }

    struct Job {
        var key: String
        var remote: URL
        var size: Int64
        var pinned: Bool
    }

    public let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var queue: [Job] = []
    /// Downloads in progress, by key.
    private var active: [String: Job] = [:]
    /// Downloads in progress that are no longer wanted: they stop at their next read.
    private var cancelled: Set<String> = []
    private var limit: Int64
    private var concurrentDownloads = 2

    /// How many files download at once. One while music streams from a share, so the song being
    /// played keeps most of the connection.
    public var maxConcurrentDownloads: Int {
        get { lock.lock(); defer { lock.unlock() }; return concurrentDownloads }
        set {
            lock.lock(); concurrentDownloads = max(1, newValue); lock.unlock()
            pump()
        }
    }

    /// Called (on any thread) when usage or download state changes.
    public var onChange: (@Sendable () -> Void)?

    public init(directory: URL, limitBytes: Int64) {
        self.directory = directory
        self.limit = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    public static func key(for track: Track) -> String {
        let id = "\(track.filePath)|\(track.fileSize)|\(Int64(track.modifiedAt.timeIntervalSince1970))"
        return SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lookups (any thread)

    /// The complete local copy for `key`, if there is one. Marks it recently used.
    public func localURL(forKey key: String) -> URL? {
        lock.lock()
        guard var entry = entries[key] else { lock.unlock(); return nil }
        entry.lastUsed = .now
        entries[key] = entry
        lock.unlock()
        let url = directory.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isAvailable(_ track: Track) -> Bool {
        lock.withLock { entries[Self.key(for: track)] != nil }
    }

    public func isOffline(_ track: Track) -> Bool {
        lock.withLock { entries[Self.key(for: track)]?.pinned == true }
    }

    public func isPending(_ track: Track) -> Bool {
        let key = Self.key(for: track)
        return lock.withLock { active[key] != nil || queue.contains { $0.key == key } }
    }

    public func usage() -> Usage {
        lock.withLock {
            var u = Usage()
            for e in entries.values {
                if e.pinned { u.offlineBytes += e.size; u.offlineFiles += 1 } else { u.cachedBytes += e.size; u.cachedFiles += 1 }
            }
            u.downloading = active.count
            u.queued = queue.count
            return u
        }
    }

    // MARK: Changes

    public var limitBytes: Int64 {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue }; evict(); onChange?() }
    }

    /// Copies these tracks in the background (CUE tracks sharing a file are copied once).
    /// `offline` keeps them until they are removed with `setOffline(false, …)`.
    public func request(_ tracks: [Track], offline: Bool = false) {
        lock.lock()
        var seen = Set<String>()
        for t in tracks {
            let key = Self.key(for: t)
            guard seen.insert(key).inserted else { continue }
            if var e = entries[key] {
                if offline, !e.pinned { e.pinned = true; entries[key] = e }
                continue
            }
            if let i = queue.firstIndex(where: { $0.key == key }) {
                if offline { queue[i].pinned = true }
                continue
            }
            if active[key] != nil {
                if offline { pinAfterDownload.insert(key) }
                cancelled.remove(key)
                continue
            }
            queue.append(Job(key: key, remote: URL(fileURLWithPath: t.filePath, isDirectory: false), size: t.fileSize, pinned: offline))
        }
        lock.unlock()
        save()
        pump()
        onChange?()
    }

    /// Tracks played now should download before ones queued for later.
    public func prioritize(_ tracks: [Track]) {
        let keys = tracks.map(Self.key(for:))
        lock.withLock {
            let first = queue.filter { keys.contains($0.key) }.sorted { keys.firstIndex(of: $0.key)! < keys.firstIndex(of: $1.key)! }
            queue = first + queue.filter { !keys.contains($0.key) }
        }
    }

    /// Copies for other tracks are no longer wanted (you skipped past them): queued ones are dropped and
    /// ones in progress stop, so the share serves what you're about to hear. Keep Offline copies carry on.
    public func keepOnly(_ tracks: [Track]) {
        let keys = Set(tracks.map(Self.key(for:)))
        let changed = lock.withLock {
            let before = queue.count + cancelled.count
            queue.removeAll { !$0.pinned && !keys.contains($0.key) }
            for (key, job) in active where !job.pinned && !pinAfterDownload.contains(key) && !keys.contains(key) {
                cancelled.insert(key)
            }
            return queue.count + cancelled.count != before
        }
        guard changed else { return }
        save()
        onChange?()
    }

    public func setOffline(_ offline: Bool, for tracks: [Track]) {
        if offline { request(tracks, offline: true); return }
        lock.withLock {
            for t in tracks {
                let key = Self.key(for: t)
                if var e = entries[key] { e.pinned = false; e.lastUsed = .now; entries[key] = e }
                queue.removeAll { $0.key == key && $0.pinned }
                pinAfterDownload.remove(key)
            }
        }
        save()
        evict()
        onChange?()
    }

    /// Deletes cached copies, and offline ones too when `includingOffline`.
    public func clear(includingOffline: Bool) {
        lock.lock()
        let doomed = entries.values.filter { includingOffline || !$0.pinned }
        for e in doomed { entries[e.key] = nil }
        queue.removeAll { includingOffline || !$0.pinned }
        lock.unlock()
        for e in doomed { try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.fileName)) }
        save()
        onChange?()
    }

    // MARK: Downloading

    private var pinAfterDownload: Set<String> = []
    private var lastTransfer = Date.distantPast

    /// When a download last received data from the share (a slow share that still delivers isn't dead).
    public var lastTransferAt: Date { lock.withLock { lastTransfer } }

    private func pump() {
        lock.lock()
        var started: [Job] = []
        while active.count < concurrentDownloads, !queue.isEmpty {
            let job = queue.removeFirst()
            active[job.key] = job
            started.append(job)
        }
        lock.unlock()
        for job in started {
            Task.detached(priority: .utility) { [self] in
                finish(job, ok: download(job))
            }
        }
    }

    private func finish(_ job: Job, ok: Bool) {
        lock.lock()
        active[job.key] = nil
        cancelled.remove(job.key)
        if ok {
            let pinned = job.pinned || pinAfterDownload.remove(job.key) != nil
            entries[job.key] = Entry(key: job.key, remotePath: job.remote.path, fileName: fileName(job),
                                     size: job.size, pinned: pinned, lastUsed: .now)
        }
        lock.unlock()
        if ok { save(); evict() }
        onChange?()
        pump()
    }

    private func fileName(_ job: Job) -> String {
        let ext = job.remote.pathExtension
        return ext.isEmpty ? job.key : "\(job.key).\(ext)"
    }

    /// Streams the file in large reads to a temporary name, then renames it into place.
    private func download(_ job: Job) -> Bool {
        let final = directory.appendingPathComponent(fileName(job))
        let partial = final.appendingPathExtension("partial")
        let input = open(job.remote.path, O_RDONLY)
        guard input >= 0 else { return false }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)
        let output = open(partial.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard output >= 0 else { return false }
        var total: Int64 = 0
        let chunk = 4 * 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var ok = true
        while true {
            if lock.withLock({ cancelled.contains(job.key) }) { ok = false; break }
            let n = read(input, buffer, chunk)
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; ok = false; break }
            if write(output, buffer, n) != n { ok = false; break }
            total += Int64(n)
            lock.withLock { lastTransfer = .now }
        }
        close(output)
        guard ok, total == job.size, rename(partial.path, final.path) == 0 else {
            unlink(partial.path)
            return false
        }
        return true
    }

    /// Removes least recently used cached copies until they fit the limit.
    private func evict() {
        lock.lock()
        var cached = entries.values.filter { !$0.pinned }.sorted { $0.lastUsed < $1.lastUsed }
        var bytes = cached.reduce(Int64(0)) { $0 + $1.size }
        var doomed: [Entry] = []
        while bytes > limit, !cached.isEmpty {
            let e = cached.removeFirst()
            bytes -= e.size
            entries[e.key] = nil
            doomed.append(e)
        }
        lock.unlock()
        guard !doomed.isEmpty else { return }
        for e in doomed { try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.fileName)) }
        save()
    }

    // MARK: Persistence

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        let fm = FileManager.default
        entries = Dictionary(list.filter { fm.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }.map { ($0.key, $0) },
                             uniquingKeysWith: { a, _ in a })
        // Leftovers from an interrupted download.
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".partial") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func save() {
        let list = lock.withLock { Array(entries.values) }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: indexURL, options: .atomic) }
    }
}
