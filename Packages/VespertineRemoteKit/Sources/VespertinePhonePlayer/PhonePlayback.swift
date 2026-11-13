//
// Vespertine: "Play on this phone" for one song: asks the Mac to open it (waiting while the Mac converts what the phone can't
// open), downloads the stream, and hands the file to the player.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import Foundation
import VespertineRemoteClient
import VespertineRemoteProtocol

@MainActor
public final class PhonePlayback {
    public enum Failure: Error, Equatable {
        /// The Mac said no, in words for showing as they are.
        case refused(String)
        /// The Mac was still converting the song when the wait ran out.
        case stillPreparing
        case notConnected
    }

    public let session: RemoteSession
    public let player: PhonePlayer
    public let cacheDirectory: URL
    /// How long to wait for a conversion on the Mac, and how often to ask again.
    public var preparingTimeout: Duration = .seconds(600)
    public var pollInterval: Duration = .seconds(1)

    public init(session: RemoteSession, player: PhonePlayer, cacheDirectory: URL) {
        self.session = session
        self.player = player
        self.cacheDirectory = cacheDirectory
    }

    /// Opens, downloads and plays library song `song`. `maxSampleRate`: what this phone's output can use (48000 for AirPods).
    public func play(song: Int64, maxSampleRate: Double?, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let descriptor = try await open(song: song, maxSampleRate: maxSampleRate)
        defer { Task { [session] in _ = await session.send(.streamClose(stream: descriptor.stream)) } }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let name = "\(song)-\(descriptor.tag.prefix(16)).\(descriptor.format.container)"
        let url = cacheDirectory.appendingPathComponent(name)
        // A file from an earlier play of this very stream (same tag) is used as it is, if it is whole.
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        if existing != descriptor.byteSize {
            try? FileManager.default.removeItem(at: url)
            let session = self.session
            let stream = descriptor.stream
            let downloader = StreamDownloader(descriptor: descriptor, destination: url) { offset, length in
                try await session.readStream(stream, offset: offset, length: length)
            }
            let size = descriptor.byteSize
            try await downloader.run { progress?($0, size) }
        }
        try player.load(url, format: descriptor.format)
        try player.play()
    }

    private func open(song: Int64, maxSampleRate: Double?) async throws -> StreamDescriptor {
        let deadline = ContinuousClock.now + preparingTimeout
        while true {
            guard session.isConnected else { throw Failure.notConnected }
            switch await session.send(.streamOpen(id: song, maxSampleRate: maxSampleRate)) {
            case .streamOpened(let descriptor): return descriptor
            case .streamPreparing:
                guard ContinuousClock.now < deadline else { throw Failure.stillPreparing }
                try await Task.sleep(for: pollInterval)
            case .failed(let reason): throw Failure.refused(reason)
            default: throw Failure.refused("")
            }
        }
    }
}
#endif
