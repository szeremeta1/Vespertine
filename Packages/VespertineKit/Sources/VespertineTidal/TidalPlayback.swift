//
// Vespertine: TIDAL tracks in the player. A track is the item `tidal://track/<id>` with cache key `tidal:<id>`; the playback
// cache opens it through the reader registered here, which resolves the stream through the gate (playback first) and reads it
// from the CDN: one file by ranges, or a DASH stream as the FLAC it remuxes to.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public enum TidalPlayback {
    public static let scheme = "tidal"

    public static func url(trackId: Int) -> URL { URL(string: "\(scheme)://track/\(trackId)")! }

    public static func cacheKey(trackId: Int) -> String { "\(scheme):\(trackId)" }

    /// The track ID of `tidal://track/<id>`; nil for anything else.
    public static func trackId(from url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "track" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, let id = Int(parts[0]), id > 0 else { return nil }
        return id
    }

    /// Registers `tidal` with the playback cache (call once at launch; a second call replaces the first). Opening a track resolves
    /// it (blocking the cache's open thread, never the main actor), and an expired URL is resolved again the same way. Failures
    /// are thrown, so the engine reports them as it does any song that can't be opened (`TidalError.localizedDescription`).
    public static func register(resolver: TidalStreamResolver, session: URLSession = TidalCDN.session) {
        NetworkPlaybackCache.registerRemoteReader(scheme: scheme, notAnsweringMessage: TidalError.notAnsweringMessage) { url in
            guard let id = trackId(from: url) else { throw TidalError.malformedStream("\(url.absoluteString) is not a TIDAL track") }
            let renew: @Sendable () throws -> TidalStream = {
                let stream = try resolveBlocking(resolver, trackId: id, priority: .playback)
                resolved.withLock { $0[id] = stream }
                return stream
            }
            return try reader(for: try renew(), renew: renew, session: session)
        }
    }

    /// Forgets the reader (TIDAL switched off): `tidal://` songs no longer open.
    public static func unregister() {
        NetworkPlaybackCache.unregisterRemoteReader(scheme: scheme)
        resolved.withLock { $0.removeAll() }
    }

    /// The stream track `trackId` last resolved to for playback (its kind, codec and listed format), for the signal path; nil
    /// before it has been played in this run.
    public static func lastStream(trackId: Int) -> TidalStream? { resolved.withLock { $0[trackId] } }

    private static let resolved = Locked([Int: TidalStream]())

    /// The reader for a resolved stream: FLAC over DASH is remuxed; one file (FLAC, AAC, or Dolby Atmos as E-AC-3) is read as it
    /// is. Atmos is staged as `.m4a`, so the probe hands it to the system renderer as it does a local Atmos file.
    static func reader(for stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream,
                       session: URLSession) throws -> any RemoteCacheReader {
        var stream = stream
        if isAtmos(stream) { stream.fileExtension = "m4a" }
        switch stream.kind {
        case .file:
            return try TidalHTTPReader(stream: stream, renew: { () throws -> TidalStream in
                var fresh = try renew()
                if isAtmos(fresh) { fresh.fileExtension = "m4a" }
                return fresh
            }, session: session)
        case .dash:
            guard stream.codec.lowercased().contains("flac") else {
                throw TidalError.malformedStream("a DASH stream of \(stream.codec): only FLAC is read from DASH")
            }
            return try DASHFLACReader(stream: stream, renew: renew, session: session)
        }
    }

    static func isAtmos(_ stream: TidalStream) -> Bool {
        stream.audioMode.uppercased() == "DOLBY_ATMOS" && stream.codec.lowercased().contains("eac3")
    }

    /// `resolver.resolve` from a thread that may block (the cache's open queue, a copy lane, a download's worker).
    /// Refuses to run on a thread of the cooperative pool (inside a task): waiting there for a task that needs a pool thread
    /// could leave none to run it.
    static func resolveBlocking(_ resolver: TidalStreamResolver, trackId: Int, priority: TidalPriority) throws -> TidalStream {
        if withUnsafeCurrentTask(body: { $0 != nil }) { throw BlockingInTask() }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<TidalStream, Error>?
        Task.detached(priority: .userInitiated) {
            do { result = .success(try await resolver.resolve(trackId: trackId, priority: priority)) }
            catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }
}

/// `TidalPlayback.resolveBlocking` was called from inside a task (a programming error: it must run on a thread of its own).
struct BlockingInTask: LocalizedError {
    var errorDescription: String? { "A TIDAL stream was resolved from a task thread instead of a thread of its own." }
}
