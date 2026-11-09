// Vespertine: byte-exact, disk-backed network playback staging.
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
        /// Nothing arrived from the share for `noProgressLimit`, even with the file opened again.
        case notAnswering
        var errorDescription: String? {
            switch self {
            case .budgetExceeded: CocoaError(.fileReadTooLarge).localizedDescription
            case .unexpectedEOF: CocoaError(.fileReadCorruptFile).localizedDescription
            case .cancelled: CocoaError(.userCancelled).localizedDescription
            case .notAnswering:
                String(localized: "The share is mounted but isn’t answering. Eject it in Finder, then choose Reconnect.", comment: "Reconnect is a command on the share.")
            }
        }
    }

    /// How long a song waits for its share to send anything at all before it fails with `Failure.notAnswering`. A share that
    /// reconnects (SMB does so within seconds) carries on well inside it; one that is gone for good no longer leaves the song
    /// buffering for ever with the scans of every share held back.
    static let defaultNoProgressLimit: TimeInterval = 120

    /// Seconds the Mac has been awake: a sleep is not silence from the share (a wall clock would count it, and a song paused
    /// over night would fail the moment the Mac woke).
    static let awakeSeconds: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
    private let noProgressLimit: TimeInterval
    private let clock: @Sendable () -> TimeInterval
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

    init(directory: URL, budget: Int64 = 8 << 30, chunk: Int = 1 << 20, gate: ShareIOGate = .shared,
         noProgressLimit: TimeInterval = NetworkPlaybackCache.defaultNoProgressLimit,
         clock: @escaping @Sendable () -> TimeInterval = NetworkPlaybackCache.awakeSeconds) {
        self.clock = clock
        self.gate = gate
        self.noProgressLimit = noProgressLimit
        session = try? Session(root: directory)
        self.directory = session?.url ?? directory; self.budget = budget; self.chunk = max(1, chunk)
    }

    /// `foreground`: the song being played or about to be (its reads hold library scans of the share back, see
    /// `ShareIOGate`), not a prefetched next one, which waits its turn behind them.
    ///
    /// Opening the file is a network call too, and the kernel does not give up on it when the share stops answering,
    /// so it never runs on the caller's thread: `cancelled` is polled while it is waited for, and a caller that gives
    /// up gets `CancellationError` at once (the open itself finishes, or fails, in the background and is closed).
    /// For tests: the share's files, read through this instead of a mount.
    var readerFactory: (@Sendable (URL) -> (any PlaybackCacheReader)?)?
    /// For tests: the bytes free on the cache's volume, instead of asking the file system.
    var freeSpace: (@Sendable () -> Int64?)?

    /// Bytes free for this app's own files on the volume holding `url`, counting what macOS would free for it (purgeable
    /// space); the plain free size when the volume does not say. (`NetworkCache.freeBytes` in the library is the same.)
    static func freeBytes(at url: URL) -> Int64? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        if let important = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           important > 0 { return important }
        return (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    func entry(key: String, url: URL, reader: (any PlaybackCacheReader)? = nil, foreground: Bool = true,
               cancelled: () -> Bool = { false }) throws -> Entry {
        if let existing = lock.withLock({ entries[key]?.value }) {
            if foreground { existing.promote() }
            return existing
        }
        let source = try reader ?? readerFactory?(url) ?? openShare(key: key, url: url, cancelled: cancelled)
        // A handle can die under the copy (the share was mounted again after the link dropped): the file is opened again by
        // its path, the way it was opened first. A reader handed in by the caller has no path to open again.
        let reopen: Reopen? = reader != nil ? nil : Self.reopener(url: url, factory: readerFactory)
        return try lock.withLock {
            if let existing = entries[key]?.value {
                if foreground { existing.promote() }
                return existing
            }
            guard source.size >= 0, source.size <= budget - reservedBytes else { throw Failure.budgetExceeded }
            // The other copies' files are sparse: what they have yet to write takes no space now, but will.
            let unwritten = entries.values.compactMap(\.value).reduce(Int64(0)) { $0 + max(0, $1.size - $1.copiedBytes) }
            if let free = freeSpace?() ?? Self.freeBytes(at: directory),
               source.size + unwritten > max(0, free - (64 << 20)) { throw CocoaError(.fileWriteOutOfSpace) }
            let path = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            let size = source.size
            let storage = try Storage(url: path, reader: source, chunk: chunk, session: session, gate: gate, foreground: foreground,
                                      reopen: reopen, noProgressLimit: noProgressLimit, clock: clock) { [weak self] in
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

    typealias Reopen = @Sendable () throws -> any PlaybackCacheReader
    private static func reopener(url: URL, factory: (@Sendable (URL) -> (any PlaybackCacheReader)?)?) -> Reopen {
        { () throws -> any PlaybackCacheReader in
            if let fresh = factory?(url) { return fresh }
            let opened: any PlaybackCacheReader = try ShareFileReader(url)
            return opened
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

    /// Prefetches waiting for their file on the share to open (for tests).
    var waitingPrefetches: Int { prefetchWaits.withLock { $0 } }
    private let prefetchWaits = Locked(0)

    /// Current always gets the link first. Prefetch only after its required reserve is on disk.
    /// Opening the file can take as long as the share does: the wait ends when another next song is chosen (the open itself
    /// finishes, or fails, in the background).
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
            self.prefetchWaits.withLock { $0 += 1 }
            let opened = try? self.entry(key: key, url: url, foreground: false,
                                         cancelled: { self.lock.withLock { self.prefetchGeneration != generation } })
            self.prefetchWaits.withLock { $0 -= 1 }
            guard let entry = opened else { return }
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
            // A press on another song ends this wait (and the hold on the scans with it), even while the open hangs.
            guard let entry = try? self.entry(key: key, url: url, cancelled: { self.lock.withLock { self.warmGeneration != pressed } })
            else { return }
            kept = true
            self.lock.withLock {
                if self.prefetchGeneration == generation { self.next = entry }
            }
        }
    }
    private static let warmQueue = DispatchQueue(label: "org.szeremeta.vespertine.network-warm", qos: .userInitiated, attributes: .concurrent)

    /// Reads this thread makes inside `body` (through `Entry.read`: a decoder's guarded input source, `PlaybackFile`) give up
    /// with `CancellationError` once `cancelled` says so, instead of waiting for as long as the share stays quiet. The engine thread
    /// uses it where it reads a song that may still be arriving (a seek), so a skip, stop or another seek still gets through.
    /// Reads on other threads (the read-ahead's) are unaffected.
    static func cancellingReads<T>(when cancelled: @escaping () -> Bool, _ body: () throws -> T) rethrows -> T {
        let thread = Thread.current.threadDictionary
        let previous = thread[readCancellationKey]
        thread[readCancellationKey] = ReadCancellation(cancelled)
        defer { thread[readCancellationKey] = previous }
        return try body()
    }

    /// Whether the reads of this thread have been given up on (see `cancellingReads`). The check runs while a waiting read holds
    /// the copy's condition lock, and the engine's check takes the engine's lock: the engine thread, the only one that installs a
    /// check, never takes a copy's condition while holding its own lock, so the order is always condition, then engine.
    static var readsCancelled: Bool {
        (Thread.current.threadDictionary[readCancellationKey] as? ReadCancellation)?.check() ?? false
    }
    private static let readCancellationKey = "org.szeremeta.vespertine.read-cancellation"
    private final class ReadCancellation {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
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
        /// Bytes on disk so far.
        var copiedBytes: Int64 { storage.condition.withLock { min(storage.size, Int64(storage.ready.count) * Int64(storage.chunk)) } }
        /// How long this file has been copying: the copy's speed is `copiedBytes` over this.
        var copyElapsed: TimeInterval { Date().timeIntervalSince(storage.startedAt) }
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
            try storage.ensure(offset: offset, count: Int64(count), cancelled: { NetworkPlaybackCache.readsCancelled })
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
        /// Read by the copy thread only (it is replaced there when the file is opened again).
        var reader: any PlaybackCacheReader
        let reopen: Reopen?
        let noProgressLimit: TimeInterval
        /// On `clock`: when bytes last arrived from the share, the copy started, or a read began waiting with none waiting before.
        /// Under `condition`.
        var lastProgress: TimeInterval
        let clock: @Sendable () -> TimeInterval
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
        let startedAt = Date()

        init(url: URL, reader: any PlaybackCacheReader, chunk: Int, session: Session?, gate: ShareIOGate, foreground: Bool,
             reopen: Reopen? = nil,
             noProgressLimit: TimeInterval = NetworkPlaybackCache.defaultNoProgressLimit,
             clock: @escaping @Sendable () -> TimeInterval = NetworkPlaybackCache.awakeSeconds,
             release: @escaping @Sendable () -> Void) throws {
            self.clock = clock; lastProgress = clock()
            self.url = url; self.reader = reader; self.size = reader.size; self.chunk = chunk; self.release = release
            self.reopen = reopen; self.noProgressLimit = noProgressLimit
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

        /// Nothing has arrived for `noProgressLimit`: the song fails (every waiting read with it) and stops holding scans back.
        /// Called with the condition lock held; true when it gave up.
        private func giveUpIfSilent() -> Bool {
            guard error == nil, clock() - lastProgress >= noProgressLimit else { return false }
            error = Failure.notAnswering
            condition.broadcast()
            return true
        }

        private func readPart(at offset: Int64, count: Int) throws -> Data {
            var failingSince: Date?
            var reopenedAt = Date.distantPast
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
                    // A handle on a share that was mounted again fails for ever: after a second of errors, open the file again
                    // (every few seconds), and carry on with the new handle if it is the same size.
                    let now = Date()
                    let since = failingSince ?? now
                    failingSince = since
                    if let reopen, now.timeIntervalSince(since) >= 1, now.timeIntervalSince(reopenedAt) >= 3 {
                        reopenedAt = now
                        if let fresh = try? reopen() {
                            guard fresh.size == size else { throw Failure.unexpectedEOF }
                            reader = fresh
                            continue
                        }
                    }
                    condition.lock()
                    let gaveUp = giveUpIfSilent()
                    if !gaveUp, !cancelled { _ = condition.wait(until: Date().addingTimeInterval(0.25)) }
                    condition.unlock()
                    if gaveUp { throw Failure.notAnswering }
                }
            }
        }

        func ensure(offset: Int64, count: Int64, cancelled shouldCancel: () -> Bool) throws {
            guard count > 0 else { return }
            let range = Int(offset / Int64(chunk))..<Int((offset + count - 1) / Int64(chunk) + 1)
            condition.lock()
            if range.allSatisfy({ ready.contains($0) }) { condition.unlock(); return }
            // A read that starts waiting counts the silence from now: time with nothing asked of the share (paused) is not.
            if waiters == 0 { lastProgress = max(lastProgress, clock()) }
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
                _ = giveUpIfSilent()   // the copy can be stuck in a read the kernel never returns from
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
                        if cancelled || error != nil { return nil }
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
                            condition.withLock { lastProgress = clock() }
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
