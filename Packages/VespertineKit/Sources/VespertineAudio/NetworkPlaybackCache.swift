// Vespertine — byte-exact, disk-backed network playback staging.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

protocol PlaybackCacheReader: AnyObject, Sendable {
    var size: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

private final class ShareFileReader: PlaybackCacheReader, @unchecked Sendable {
    let file: FileHandle
    let size: Int64
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        size = Int64(try file.seekToEnd())
    }
    deinit { try? file.close() }
    func read(at offset: Int64, count: Int) throws -> Data {
        try file.seek(toOffset: UInt64(offset))
        return try file.read(upToCount: count) ?? Data()
    }
}

/// The playback cache is transient: leases keep current/next files alive; dropping a lease cancels its copy
/// and deletes it once an outstanding share read returns. Reservations include in-flight and cancelled reads.
/// A sparse file is NEVER handed unguarded to a decoder until every byte is present.
final class NetworkPlaybackCache: @unchecked Sendable {
    static let shared = NetworkPlaybackCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent((Bundle.main.bundleIdentifier ?? "org.szeremeta.Vespertine") + "/Playback", isDirectory: true))
    enum Failure: Error { case budgetExceeded, unexpectedEOF, cancelled }
    private final class WeakEntry { weak var value: Entry?; init(_ value: Entry) { self.value = value } }
    private static let registry = Locked([String: WeakEntry]())
    static func lookup(_ url: URL) -> Entry? { registry.withLock { $0[url.path]?.value } }

    /// A process may have another Vespertine instance open. Clean only sessions whose advisory lease
    /// can be acquired; decoder-held leases keep their directory alive after the engine moves on.
    fileprivate final class Session: @unchecked Sendable {
        let url: URL
        let descriptor: Int32
        init(root: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for old in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if old.pathExtension == "partial" { try? fm.removeItem(at: old); continue }
                guard UUID(uuidString: old.lastPathComponent) != nil else { continue }
                let fd = open(old.appendingPathComponent(".lease").path, O_RDWR | O_CREAT, 0o600)
                guard fd >= 0 else { continue }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: old) }
                close(fd)
            }
            url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            descriptor = open(url.appendingPathComponent(".lease").path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        deinit { close(descriptor); try? FileManager.default.removeItem(at: url) }
    }

    let directory: URL
    private let session: Session?
    private let budget: Int64
    private let chunk: Int
    private let lock = NSLock()
    private var entries: [String: WeakEntry] = [:]
    private let reserved = Locked(Int64(0))
    private var next: Entry?
    private var nextKey: String?
    private var prefetchGeneration = 0
    var reservedBytes: Int64 { reserved.withLock { $0 } }

    init(directory: URL, budget: Int64 = 8 << 30, chunk: Int = 1 << 20) {
        session = try? Session(root: directory)
        self.directory = session?.url ?? directory; self.budget = budget; self.chunk = max(1, chunk)
    }

    func entry(key: String, url: URL, reader: (any PlaybackCacheReader)? = nil) throws -> Entry {
        if let existing = lock.withLock({ entries[key]?.value }) { return existing }
        let source = try reader ?? ShareFileReader(url)
        return try lock.withLock {
            if let existing = entries[key]?.value { return existing }
            guard source.size >= 0, source.size <= budget - reservedBytes else { throw Failure.budgetExceeded }
            let path = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            let size = source.size
            let storage = try Storage(url: path, reader: source, chunk: chunk, session: session) { [weak self] in
                guard let self else { return }
                self.reserved.withLock { $0 -= size }
            }
            reserved.withLock { $0 += size }
            let entry = Entry(storage)
            entries = entries.filter { $0.value.value != nil }
            entries[key] = WeakEntry(entry)
            Self.registry.withLock {
                $0 = $0.filter { $0.value.value != nil }
                $0[path.path] = WeakEntry(entry)
            }
            storage.start()
            return entry
        }
    }

    /// Current always gets the link first. Prefetch only after its required reserve is on disk.
    func prefetch(key: String?, url: URL?) {
        let generation = lock.withLock { () -> Int in
            if nextKey == key { return -1 }
            if nextKey != key { next = nil }
            nextKey = key
            prefetchGeneration += 1
            return prefetchGeneration
        }
        guard generation >= 0, let key, let url else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.lock.withLock({ self.prefetchGeneration == generation }) else { return }
            guard let entry = try? self.entry(key: key, url: url) else { return }
            self.lock.withLock {
                if self.prefetchGeneration == generation { self.next = entry }
            }
        }
    }

    func discardPrefetch(except key: String? = nil) {
        let discarded: Entry? = lock.withLock {
            guard nextKey != key else { return nil }
            defer { next = nil; nextKey = nil; prefetchGeneration += 1 }
            return next
        }
        withExtendedLifetime(discarded) {}
    }

    final class DirectoryEntry {
        let url: URL
        private let files: [Entry]
        init(url: URL, files: [Entry]) { self.url = url; self.files = files }
        deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// VIDEO_TS playback addresses several IFO/VOB files by name. Stage the set and preserve that layout,
    /// rather than cache only its entry IFO and accidentally leave audio reads on the share.
    func directoryEntry(for url: URL, cancelled: () -> Bool) throws -> DirectoryEntry {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [Entry] = []
        do {
            let children = try fm.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { ["ifo", "vob", "bup"].contains($0.pathExtension.lowercased()) }
            for child in children {
                if cancelled() { throw CancellationError() }
                let file = try entry(key: child.path, url: child)
                files.append(file)
                try file.prepare(full: true, lead: 0, cancelled: cancelled)
                try fm.createSymbolicLink(at: folder.appendingPathComponent(child.lastPathComponent), withDestinationURL: file.url)
            }
            return DirectoryEntry(url: folder.appendingPathComponent(url.lastPathComponent), files: files)
        } catch { try? fm.removeItem(at: folder); throw error }
    }

    final class Entry: @unchecked Sendable {
        fileprivate let storage: Storage
        fileprivate init(_ storage: Storage) { self.storage = storage }
        deinit { storage.cancel() }
        var url: URL { storage.url }
        var size: Int64 { storage.size }
        var isComplete: Bool { storage.condition.withLock { storage.ready.count == storage.blocks } }
        var isWaiting: Bool { storage.condition.withLock { storage.starting || storage.waiters > 0 } }
        var lastRead: Int64 { storage.condition.withLock { storage.cursor } }
        func cancel() { storage.cancel() }

        func prepare(full: Bool, lead: Int64, at offset: Int64 = 0, cancelled: () -> Bool) throws {
            defer { storage.condition.withLock { storage.starting = false } }
            try storage.ensure(offset: full ? 0 : offset,
                               count: full ? size : min(max(0, lead), size - offset), cancelled: cancelled)
        }
        func read(at offset: Int64, count: Int) throws -> Data {
            defer { storage.condition.withLock { storage.starting = false } }
            guard offset >= 0, count >= 0 else { throw CocoaError(.fileReadUnknown) }
            let count = Int(min(Int64(count), max(0, size - offset)))
            try storage.ensure(offset: offset, count: Int64(count), cancelled: { false })
            storage.condition.withLock {
                storage.cursor = offset + Int64(count)
                storage.resumeAt = min(storage.blocks, Int(storage.cursor / Int64(storage.chunk)))
            }
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { buffer in
                pread(storage.file.fileDescriptor, buffer.baseAddress, count, off_t(offset))
            }
            guard n == count else { throw CocoaError(.fileReadUnknown) }
            return data
        }
    }

    fileprivate final class Storage: @unchecked Sendable {
        let condition = NSCondition()
        let url: URL
        let reader: any PlaybackCacheReader
        let file: FileHandle
        let size: Int64
        let chunk: Int
        let blocks: Int
        let session: Session?
        let release: @Sendable () -> Void
        var ready: Set<Int> = []
        var requests: [Range<Int>] = []
        var cursor: Int64 = 0
        var resumeAt: Int?
        var starting = true
        var waiters = 0
        var cancelled = false
        var error: Error?

        init(url: URL, reader: any PlaybackCacheReader, chunk: Int, session: Session?, release: @escaping @Sendable () -> Void) throws {
            self.url = url; self.reader = reader; self.size = reader.size; self.chunk = chunk; self.release = release
            self.session = session
            blocks = Int((reader.size + Int64(chunk) - 1) / Int64(chunk))
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            file = try FileHandle(forUpdating: url)
            try file.truncate(atOffset: UInt64(reader.size))
        }
        deinit { try? file.close(); try? FileManager.default.removeItem(at: url); release() }
        func cancel() { condition.withLock { cancelled = true; condition.broadcast() } }

        func ensure(offset: Int64, count: Int64, cancelled shouldCancel: () -> Bool) throws {
            guard count > 0 else { return }
            let range = Int(offset / Int64(chunk))..<Int((offset + count - 1) / Int64(chunk) + 1)
            condition.lock()
            defer { condition.unlock() }
            if range.allSatisfy({ ready.contains($0) }) { return }
            waiters += 1
            requests.append(range)
            defer { waiters -= 1; requests.removeAll { $0 == range } }
            while !range.allSatisfy({ ready.contains($0) }) {
                if shouldCancel() { throw CancellationError() }
                if cancelled { throw Failure.cancelled }
                if let error { throw error }
                _ = condition.wait(until: Date().addingTimeInterval(0.025))
            }
        }

        func start() {
            // Only this thread reads the share. Decoders and the audio callback never do duplicate remote reads.
            let thread = Thread { [self] in
                var sequential = 0
                while true {
                    let block: Int? = condition.withLock {
                        if cancelled { return nil }
                        if let demanded = requests.lazy.flatMap({ $0 }).first(where: { !ready.contains($0) }) { return demanded }
                        if let resumeAt { sequential = resumeAt; self.resumeAt = nil }
                        while sequential < blocks && ready.contains(sequential) { sequential += 1 }
                        if sequential >= blocks, ready.count < blocks {
                            sequential = (0..<blocks).first { !ready.contains($0) } ?? blocks
                        }
                        return sequential < blocks ? sequential : nil
                    }
                    guard let block else { return }
                    do {
                        let offset = Int64(block) * Int64(chunk)
                        let length = Int(min(Int64(chunk), size - offset))
                        var data = Data()
                        while data.count < length {
                            if condition.withLock({ cancelled }) { return }
                            let part = try reader.read(at: offset + Int64(data.count), count: length - data.count)
                            guard !part.isEmpty, part.count <= length - data.count else { throw Failure.unexpectedEOF }
                            data.append(part)
                        }
                        try file.seek(toOffset: UInt64(offset))
                        try file.write(contentsOf: data)
                        condition.withLock { ready.insert(block); condition.broadcast() }
                    } catch {
                        condition.withLock { self.error = error; condition.broadcast() }
                        return
                    }
                }
            }
            thread.name = "Vespertine Network Copy"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

/// FileHandle-shaped reader used by native DSD parsers. Missing sparse ranges block on the copy worker,
/// so they can never be mistaken for silence, damaged DSD or an early end of track.
final class PlaybackFile {
    private let file: FileHandle
    private let entry: NetworkPlaybackCache.Entry?
    private var offset: UInt64 = 0
    init(forReadingFrom url: URL) throws {
        entry = NetworkPlaybackCache.lookup(url)
        file = try FileHandle(forReadingFrom: url)
    }
    func close() throws { try file.close() }
    func seek(toOffset value: UInt64) throws { offset = value; if entry == nil { try file.seek(toOffset: value) } }
    func seekToEnd() throws -> UInt64 {
        if let entry { offset = UInt64(entry.size); return offset }
        offset = try file.seekToEnd(); return offset
    }
    func read(upToCount count: Int) throws -> Data? {
        let data = try entry.map { try $0.read(at: Int64(offset), count: count) } ?? file.read(upToCount: count)
        offset += UInt64(data?.count ?? 0)
        return data
    }
}
