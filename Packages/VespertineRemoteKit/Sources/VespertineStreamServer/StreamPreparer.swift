//
// Vespertine: the Mac's side of the stream channel. Opens a song for a phone (its own file, or a FLAC made once and cached),
// and answers ranged reads. It only ever reads library files, never writes them, and a phone names songs by library ID: no
// path comes from the network.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public actor StreamPreparer {
    public enum Opened: Sendable, Equatable {
        case ready(StreamDescriptor)
        /// The Mac is converting it: ask again.
        case preparing(progress: Double?)
        case failed(String)
    }

    public enum Read: Sendable, Equatable {
        case chunk(StreamFrame)
        case failed(String)
    }

    /// A stream a phone has open, for the Mac's Settings to list.
    public struct Activity: Sendable, Equatable {
        /// The connection's name, as the server gave it to `open`.
        public var client: String
        /// The library song.
        public var song: Int64
        public var kind: StreamKind
    }

    private struct OpenStream {
        var descriptor: StreamDescriptor
        var file: StreamFile
        var cacheKey: String?
        var song: Int64
    }

    private struct Job {
        var progress: Double?
        var failure: String?
        var finished = false
    }

    private struct Cached: Codable {
        var format: StreamFormat
        var frames: Int64?
    }

    private let cache: StreamCache
    private let transcoder: any StreamTranscoding
    private let source: @Sendable (Int64) async -> StreamSourceFacts?
    private let maxStreamsPerClient: Int
    private var streams: [String: [OpenStream]] = [:]
    private var nextNumber: [String: Int] = [:]
    private var jobs: [String: Job] = [:]
    /// Reads run here, not on the actor: a share that stops answering holds up its own read and nobody else's.
    private let disk = DispatchQueue(label: "org.szeremeta.Vespertine.stream-reads", qos: .userInitiated, attributes: .concurrent)
    private var readHook: (@Sendable (Int64) -> Void)?

    /// For tests: called with the song's ID on the reading thread, before each read.
    func setReadHook(_ hook: (@Sendable (Int64) -> Void)?) { readHook = hook }

    /// `source` finds a library song by its ID. A phone has `maxStreamsPerClient` streams at once (the one it plays and the
    /// next one it prefetches); opening another closes its oldest.
    public init(cache: StreamCache, transcoder: any StreamTranscoding, source: @escaping @Sendable (Int64) async -> StreamSourceFacts?,
                maxStreamsPerClient: Int = 2) {
        self.cache = cache
        self.transcoder = transcoder
        self.source = source
        self.maxStreamsPerClient = max(1, maxStreamsPerClient)
    }

    // MARK: Info

    public func info(ids: [Int64], maxSampleRate: Double?) async -> [StreamInfo] {
        var out: [StreamInfo] = []
        for id in ids.prefix(500) {
            guard let facts = await source(id) else { continue }
            out.append(StreamPlanner.info(for: facts, maxSampleRate: maxSampleRate))
        }
        return out
    }

    // MARK: Open

    public func open(client: String, id: Int64, maxSampleRate: Double?) async -> Opened {
        guard let facts = await source(id) else { return .failed("That song isn’t in the Mac’s library.") }
        let plan = StreamPlanner.plan(facts, maxSampleRate: maxSampleRate)
        guard let kind = plan.kind, var delivered = plan.delivered else { return .failed(plan.macOnlyReason ?? "This can’t be streamed.") }
        switch kind {
        case .original:
            let url = facts.url
            guard let handle = StreamFile(url) else { return .failed("The Mac can’t read this file right now.") }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? facts.fileSize
            if facts.channels > 2 { delivered.channelLabels = await transcoder.channelLabels(of: facts) }
            let tag = StreamCache.key(for: TranscodeRequest(source: url, sourceSize: size, sourceModified: facts.modifiedAt, regionKey: nil, sampleRate: 0, bitDepth: 0, channels: 0))
            let frames = Int64((facts.duration * facts.sampleRate).rounded())
            return .ready(register(client: client, kind: .original, size: size, format: delivered, frames: frames, tag: tag, file: handle, cacheKey: nil, song: id))
        case .flac:
            guard let request = plan.transcode else { return .failed("This can’t be streamed.") }
            let key = StreamCache.key(for: request)
            if let ready = openCached(client: client, key: key, song: id) { return .ready(ready) }
            if var job = jobs[key] {
                if let failure = job.failure {
                    jobs[key] = nil
                    return .failed(failure)
                }
                job.progress = job.progress ?? 0
                return .preparing(progress: job.progress)
            }
            jobs[key] = Job(progress: 0)
            Task { [transcoder, cache] in
                let partial = cache.partialURL(for: key)
                try? FileManager.default.removeItem(at: partial)
                do {
                    let result = try await transcoder.transcode(request, to: partial) { value in
                        Task { await self.progress(key, value) }
                    }
                    try FileManager.default.moveItem(at: partial, to: cache.url(for: key))
                    try JSONEncoder().encode(Cached(format: result.format, frames: result.frames)).write(to: cache.metadataURL(for: key))
                    await self.finished(key, failure: nil)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    await self.finished(key, failure: (error as? TranscodeFailure)?.message ?? error.localizedDescription)
                }
            }
            return .preparing(progress: 0)
        }
    }

    private func progress(_ key: String, _ value: Double) {
        guard jobs[key]?.failure == nil, jobs[key] != nil else { return }
        jobs[key]?.progress = min(max(value, 0), 1)
    }

    private func finished(_ key: String, failure: String?) {
        if let failure { jobs[key] = Job(progress: nil, failure: failure, finished: true) } else { jobs[key] = nil }
        cache.evict(keeping: pinned().union([key]))
    }

    private func openCached(client: String, key: String, song: Int64) -> StreamDescriptor? {
        let url = cache.url(for: key)
        guard let meta = (try? Data(contentsOf: cache.metadataURL(for: key))).flatMap({ try? JSONDecoder().decode(Cached.self, from: $0) }),
              let handle = StreamFile(url) else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        cache.touch(key)
        return register(client: client, kind: .flac, size: size, format: meta.format, frames: meta.frames, tag: key, file: handle, cacheKey: key, song: song)
    }

    private func register(client: String, kind: StreamKind, size: Int64, format: StreamFormat, frames: Int64?, tag: String, file: StreamFile,
                          cacheKey: String?, song: Int64) -> StreamDescriptor {
        let number = (nextNumber[client] ?? 0) + 1
        nextNumber[client] = number
        let descriptor = StreamDescriptor(stream: number, kind: kind, byteSize: size, format: format, frames: frames, tag: tag,
                                          chunkSize: RemoteProtocol.defaultChunkSize)
        var mine = streams[client] ?? []
        while mine.count >= maxStreamsPerClient { mine.removeFirst() }
        mine.append(OpenStream(descriptor: descriptor, file: file, cacheKey: cacheKey, song: song))
        streams[client] = mine
        return descriptor
    }

    private func pinned() -> Set<String> {
        Set(streams.values.flatMap { $0.compactMap(\.cacheKey) })
    }

    // MARK: Read and close

    public func read(client: String, request: Int, stream: Int, offset: Int64, length: Int) async -> Read {
        guard let open = streams[client]?.first(where: { $0.descriptor.stream == stream }) else { return .failed("That stream isn’t open.") }
        guard offset >= 0, length > 0 else { return .failed("That range isn’t valid.") }
        let size = open.descriptor.byteSize
        guard offset < size else {
            return .chunk(StreamFrame(request: request, stream: stream, offset: offset, endOfStream: true, payload: Data()))
        }
        let count = Int(min(Int64(min(length, RemoteProtocol.maximumChunk)), size - offset))
        let file = open.file
        let song = open.song
        let hook = readHook
        // The actor is free while the disk (or a share) answers.
        return await withCheckedContinuation { (done: CheckedContinuation<Read, Never>) in
            disk.async {
                hook?(song)
                if let data = file.read(at: offset, count: count) {
                    done.resume(returning: .chunk(StreamFrame(request: request, stream: stream, offset: offset,
                                                              endOfStream: offset + Int64(data.count) >= size, payload: data)))
                } else {
                    done.resume(returning: .failed("The Mac couldn’t read the file."))
                }
            }
        }
    }

    public func close(client: String, stream: Int) {
        guard var mine = streams[client], let index = mine.firstIndex(where: { $0.descriptor.stream == stream }) else { return }
        mine.remove(at: index)
        streams[client] = mine.isEmpty ? nil : mine
    }

    public func closeAll(client: String) {
        streams[client] = nil
        nextNumber[client] = nil
    }

    /// Closes the streams of every connection a device has: the server names a connection "device#connection".
    public func closeAll(clientsOf device: String) {
        for client in streams.keys where client == device || client.hasPrefix(device + "#") { closeAll(client: client) }
    }

    // MARK: For the Mac's Settings

    public func activity() -> [Activity] {
        streams.flatMap { client, open in open.map { Activity(client: client, song: $0.song, kind: $0.descriptor.kind) } }
    }

    public func cacheBytes() -> Int64 { cache.totalBytes }
    public func setCacheLimit(_ bytes: Int64) { cache.setLimit(bytes, keeping: pinned()) }
    /// Deletes the converted copies, except the ones phones are reading now.
    public func clearCache() { cache.clear(keeping: pinned()) }
}

/// A file open for ranged reads from any thread (`pread` keeps no position). Closed when the last stream lets go of it, so a
/// read that is still running when its stream closes finishes on a descriptor that is still its own.
final class StreamFile: @unchecked Sendable {
    private let descriptor: Int32

    init?(_ url: URL) {
        let opened = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY) } ?? -1 }
        guard opened >= 0 else { return nil }
        descriptor = opened
    }

    deinit { close(descriptor) }

    func read(at offset: Int64, count: Int) -> Data? {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let got = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled)) }
            if got < 0 { if errno == EINTR { continue }; return nil }
            if got == 0 { break }
            filled += got
        }
        data.count = filled
        return data
    }
}
