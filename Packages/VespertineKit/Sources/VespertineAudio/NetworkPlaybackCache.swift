// Vespertine — byte-exact, disk-backed network playback staging.
// SPDX-License-Identifier: GPL-3.0-or-later

import CVespertineGuard
import Foundation
import SFBAudioEngine

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
    enum Failure: LocalizedError {
        case budgetExceeded, unexpectedEOF, cancelled
        var errorDescription: String? {
            switch self {
            case .budgetExceeded: CocoaError(.fileReadTooLarge).localizedDescription
            case .unexpectedEOF: CocoaError(.fileReadCorruptFile).localizedDescription
            case .cancelled: CocoaError(.userCancelled).localizedDescription
            }
        }
    }
    private final class WeakEntry { weak var value: Entry?; init(_ value: Entry) { self.value = value } }
    private static let registry = Locked([String: WeakEntry]())
    private static let delivered = Locked(Date.distantPast)
    static var lastDelivery: Date { delivered.withLock { $0 } }
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
    /// Library scans of network shares wait on this while a song is being read from one.
    let gate: ShareIOGate
    private let lock = NSLock()
    private var entries: [String: WeakEntry] = [:]
    private let reserved = Locked(Int64(0))
    private var next: Entry?
    private var nextKey: String?
    private var prefetchGeneration = 0
    private var warmGeneration = 0
    var reservedBytes: Int64 { reserved.withLock { $0 } }

    init(directory: URL, budget: Int64 = 8 << 30, chunk: Int = 1 << 20, gate: ShareIOGate = .shared) {
        self.gate = gate
        session = try? Session(root: directory)
        self.directory = session?.url ?? directory; self.budget = budget; self.chunk = max(1, chunk)
    }

    /// `foreground`: the song being played or about to be (its reads hold library scans of the share back, see
    /// `ShareIOGate`), not a prefetched next one, which waits its turn behind them.
    ///
    /// Opening the file is a network call too, and the kernel does not give up on it when the share stops answering,
    /// so it never runs on the caller's thread: `cancelled` is polled while it is waited for, and a caller that gives
    /// up gets `CancellationError` at once (the open itself finishes, or fails, in the background and is closed).
    func entry(key: String, url: URL, reader: (any PlaybackCacheReader)? = nil, foreground: Bool = true,
               cancelled: () -> Bool = { false }) throws -> Entry {
        if let existing = lock.withLock({ entries[key]?.value }) {
            if foreground { existing.promote() }
            return existing
        }
        let source = try reader ?? openShare(key: key, url: url, cancelled: cancelled)
        return try lock.withLock {
            if let existing = entries[key]?.value {
                if foreground { existing.promote() }
                return existing
            }
            guard source.size >= 0, source.size <= budget - reservedBytes else { throw Failure.budgetExceeded }
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
               let free = attributes[.systemFreeSize] as? NSNumber,
               source.size > max(0, free.int64Value - (64 << 20)) { throw CocoaError(.fileWriteOutOfSpace) }
            let path = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            let size = source.size
            let storage = try Storage(url: path, reader: source, chunk: chunk, session: session, gate: gate, foreground: foreground) { [weak self] in
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

    /// One open of a share file, shared by everyone who wants it (the press-time warm-up and the engine thread).
    private final class Opening: @unchecked Sendable {
        private let done = NSCondition()
        private var result: Result<ShareFileReader, Error>?
        func finish(_ value: Result<ShareFileReader, Error>) { done.withLock { result = value; done.broadcast() } }
        func wait(cancelled: () -> Bool) throws -> ShareFileReader {
            try done.withLock {
                while true {
                    if let result { return try result.get() }
                    if cancelled() { throw CancellationError() }
                    _ = done.wait(until: Date().addingTimeInterval(0.025))
                }
            }
        }
    }
    private let openings = Locked([String: Opening]())
    private static let openQueue = DispatchQueue(label: "org.szeremeta.vespertine.network-open", qos: .userInitiated, attributes: .concurrent)

    private func openShare(key: String, url: URL, cancelled: () -> Bool) throws -> ShareFileReader {
        let (job, starts) = openings.withLock { table -> (Opening, Bool) in
            if let running = table[key] { return (running, false) }
            let job = Opening(); table[key] = job
            return (job, true)
        }
        if starts {
            Self.openQueue.async { [openings] in
                let result = Result { try ShareFileReader(url) }
                openings.withLock { if $0[key] === job { $0[key] = nil } }
                job.finish(result)
            }
        }
        return try job.wait(cancelled: cancelled)
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
            guard let entry = try? self.entry(key: key, url: url, foreground: false) else { return }
            self.lock.withLock {
                if self.prefetchGeneration == generation { self.next = entry }
            }
        }
    }

    /// Play was pressed: the engine thread may be busy for a while (opening the previous song, choosing the
    /// output), so open the share file and start its copy now, on a queue of its own at the priority of the
    /// interface, and hold library scans back from this instant. The engine thread picks the entry up by key.
    /// `press`: the song is known to be on a share, so scans hold back before the file is even opened.
    /// `mayStage` is asked on that queue: false when the song turns out to play from a local copy.
    func warm(key: String, url: URL, press: Bool, mayStage: @escaping @Sendable () -> Bool) {
        let owner = "press-\(key)"
        if press { gate.setPlaybackDemand(true, from: owner) }
        let pressed = lock.withLock { () -> Int in warmGeneration += 1; return warmGeneration }
        Self.warmQueue.async { [weak self] in
            guard let self else { return }
            // The entry's own demand takes over from the press's, with no gap, once it exists.
            var kept = false
            defer { if press { self.gate.setPlaybackDemand(false, from: owner, grace: kept) } }
            guard self.lock.withLock({ self.warmGeneration == pressed }), mayStage() else { return }
            let generation = self.lock.withLock { () -> Int in
                if self.nextKey != key { self.next = nil }
                self.nextKey = key
                self.prefetchGeneration += 1
                return self.prefetchGeneration
            }
            guard let entry = try? self.entry(key: key, url: url) else { return }
            kept = true
            self.lock.withLock {
                if self.prefetchGeneration == generation { self.next = entry }
            }
        }
    }
    private static let warmQueue = DispatchQueue(label: "org.szeremeta.vespertine.network-warm", qos: .userInitiated, attributes: .concurrent)

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
        /// Bytes on disk so far.
        var copiedBytes: Int64 { storage.condition.withLock { min(storage.size, Int64(storage.ready.count) * Int64(storage.chunk)) } }
        /// `report` is told how many bytes are on disk each time one more chunk arrives, from the copy thread (nil: stop telling).
        func setProgress(_ report: (@Sendable (Int64) -> Void)?) { storage.condition.withLock { storage.progress = report } }
        func cancel() { storage.cancel() }
        /// The prefetched next song became the one being played.
        func promote() { storage.promote() }

        /// An input source for SFBAudioEngine's decoders over this file, which may still be arriving: a read waits for its
        /// bytes to be on disk (the copy fetches what is asked for first), so a decoder can start on the first megabytes
        /// of a song and never sees an unwritten range as zeros or as the end of the file. It keeps the entry alive.
        func inputSource() -> InputSource {
            VTCacheInputSource(url: url, length: size) { [self] offset, buffer, count in
                guard let data = try? read(at: offset, count: count) else { return -1 }
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                return data.count
            }
        }

        func prepare(full: Bool, lead: Int64, at offset: Int64 = 0, cancelled: () -> Bool) throws {
            defer { storage.condition.withLock { storage.starting = false }; storage.publishDemand() }
            if !full { storage.condition.withLock { storage.leadTarget = max(storage.leadTarget, lead) } }
            try storage.ensure(offset: full ? 0 : offset,
                               count: full ? size : min(max(0, lead), size - offset), cancelled: cancelled)
        }
        func read(at offset: Int64, count: Int) throws -> Data {
            defer { storage.condition.withLock { storage.starting = false }; storage.publishDemand() }
            guard offset >= 0, count >= 0 else { throw CocoaError(.fileReadUnknown) }
            let count = Int(min(Int64(count), max(0, size - offset)))
            try storage.ensure(offset: offset, count: Int64(count), cancelled: { false })
            storage.condition.withLock {
                storage.cursor = offset + Int64(count)
                storage.resumeAt = min(storage.blocks, Int(storage.cursor / Int64(storage.chunk)))
            }
            storage.publishDemand()
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { buffer in
                var done = 0
                while done < count {
                    let n = pread(storage.file.fileDescriptor, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw CocoaError(.fileReadUnknown) }
                    done += n
                }
            }
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
        let gate: ShareIOGate
        let owner = "copy-" + UUID().uuidString
        /// Serialises demand reports so the gate always ends up with the latest state.
        private let publishing = NSLock()
        var foreground: Bool
        /// The reserve a progressive copy keeps on disk ahead of the decoder (0: the whole file is wanted).
        var leadTarget: Int64 = 0
        var ready: Set<Int> = []
        var requests: [Range<Int>] = []
        var cursor: Int64 = 0
        var resumeAt: Int?
        var starting = true
        var waiters = 0
        var cancelled = false
        var error: Error?
        var progress: (@Sendable (Int64) -> Void)?

        init(url: URL, reader: any PlaybackCacheReader, chunk: Int, session: Session?, gate: ShareIOGate, foreground: Bool,
             release: @escaping @Sendable () -> Void) throws {
            self.url = url; self.reader = reader; self.size = reader.size; self.chunk = chunk; self.release = release
            self.session = session; self.gate = gate; self.foreground = foreground
            blocks = Int((reader.size + Int64(chunk) - 1) / Int64(chunk))
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            file = try FileHandle(forUpdating: url)
            try file.truncate(atOffset: UInt64(reader.size))
        }
        deinit {
            gate.setPlaybackDemand(false, from: owner)
            try? file.close(); try? FileManager.default.removeItem(at: url); release()
        }
        func cancel() { condition.withLock { cancelled = true; condition.broadcast() }; publishDemand() }
        func promote() { condition.withLock { foreground = true }; publishDemand() }

        /// Library scans of the share wait while this song's bytes are the ones being waited for: its copy is
        /// starting, a read is queued, or (a progressive copy) the reserve ahead of the decoder is under half.
        /// Called with the condition lock held.
        private func demandsLink() -> Bool {
            guard foreground, !cancelled, error == nil, ready.count < blocks else { return false }
            if starting || waiters > 0 || leadTarget == 0 { return true }
            var ahead: Int64 = 0
            var block = min(blocks, Int(cursor / Int64(chunk)))
            while block < blocks, ready.contains(block), ahead < leadTarget { ahead += Int64(chunk); block += 1 }
            return ahead < leadTarget / 2
        }

        /// Tells the gate whether scans must hold back. Never call with the condition lock held.
        func publishDemand() {
            publishing.withLock {
                let demanding = condition.withLock { demandsLink() }
                gate.setPlaybackDemand(demanding, from: owner)
            }
        }

        private func readPart(at offset: Int64, count: Int) throws -> Data {
            while true {
                if condition.withLock({ cancelled }) { throw Failure.cancelled }
                do { return try reader.read(at: offset, count: count) }
                catch {
                    // SMB/NFS can return a temporary POSIX failure during reconnection. Keep the local
                    // lead playing and retry the same bytes; disk-write failures are never retried here.
                    var cause = error as NSError
                    var transient = false
                    for _ in 0..<5 {
                        if cause.domain == NSPOSIXErrorDomain,
                           [Int(EIO), Int(EINTR), Int(ETIMEDOUT), Int(ENETDOWN), Int(ENETRESET),
                            Int(ENOTCONN), Int(ECONNRESET), Int(EHOSTUNREACH)].contains(cause.code) {
                            transient = true; break
                        }
                        guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                        cause = underlying
                    }
                    guard transient else { throw error }
                    condition.lock()
                    if !cancelled { _ = condition.wait(until: Date().addingTimeInterval(0.25)) }
                    condition.unlock()
                }
            }
        }

        func ensure(offset: Int64, count: Int64, cancelled shouldCancel: () -> Bool) throws {
            guard count > 0 else { return }
            let range = Int(offset / Int64(chunk))..<Int((offset + count - 1) / Int64(chunk) + 1)
            condition.lock()
            if range.allSatisfy({ ready.contains($0) }) { condition.unlock(); return }
            waiters += 1
            requests.append(range)
            condition.unlock()
            publishDemand()
            defer {
                condition.withLock { waiters -= 1; requests.removeAll { $0 == range } }
                publishDemand()
            }
            condition.lock()
            defer { condition.unlock() }
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
                            let part = try readPart(at: offset + Int64(data.count), count: length - data.count)
                            guard !part.isEmpty, part.count <= length - data.count else { throw Failure.unexpectedEOF }
                            NetworkPlaybackCache.delivered.withLock { $0 = .now }
                            data.append(part)
                        }
                        try file.seek(toOffset: UInt64(offset))
                        try file.write(contentsOf: data)
                        let (report, copied) = condition.withLock { () -> ((@Sendable (Int64) -> Void)?, Int64) in
                            ready.insert(block); condition.broadcast()
                            return (progress, min(size, Int64(ready.count) * Int64(chunk)))
                        }
                        report?(copied)
                        publishDemand()
                    } catch {
                        condition.withLock { self.error = error; condition.broadcast() }
                        publishDemand()
                        return
                    }
                }
            }
            thread.name = "Vespertine Network Copy"
            thread.qualityOfService = .userInitiated
            thread.start()
            publishDemand()
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
    func currentOffset() -> UInt64 { offset }
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
