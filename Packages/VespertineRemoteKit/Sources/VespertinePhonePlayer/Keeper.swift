//
// Vespertine: fetches what is kept on this iPhone. One song at a time, whole, from the Mac that has it; it stops when the Mac
// goes away or the room runs out and carries on when asked again (the Mac is back, a list was added).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import Foundation
import Observation
import VespertineRemoteProtocol

@MainActor
@Observable
public final class Keeper {
    /// The most a "smaller for this device" song runs at.
    public static let smallerSampleRate: Double = 48_000

    public let store: KeptStore
    /// The Mac's stream channel while it is connected. Setting it carries on fetching.
    @ObservationIgnored public var client: PhoneStreamClient? { didSet { resume() } }
    /// The most bytes kept songs may take (nil: no limit).
    @ObservationIgnored public var limitBytes: Int64?
    /// Words when the phone shouldn't fetch right now (cellular data, with it turned off), else nil.
    @ObservationIgnored public var holdReason: @MainActor () -> String? = { nil }
    @ObservationIgnored public var pollInterval: Duration = .seconds(1)
    @ObservationIgnored public var preparingTimeout: Duration = .seconds(900)

    /// The song arriving now, and how much of it is here (0…1).
    public private(set) var fetching: (song: Int64, fraction: Double)?
    /// Songs the Mac wouldn't send (they play on the Mac only, or left its library). Asked again the next time the app opens.
    public private(set) var unavailable: Set<Int64> = []
    /// There is more to fetch than room for it.
    public private(set) var isFull = false
    /// Why fetching stopped, in words, when it wasn't finished.
    public private(set) var notice: String?
    /// How many bytes this keeper has fetched since it was made (for the data counter).
    public private(set) var bytesReceived: Int64 = 0

    @ObservationIgnored private var worker: Task<Void, Never>?

    public init(store: KeptStore) {
        self.store = store
    }

    public var isIdle: Bool { worker == nil }

    public func progress(of id: String) -> KeptProgress { store.progress(of: id) }
    public func isKept(_ id: String) -> Bool { store.list(id) != nil }

    /// Keeps a list (or replaces it) and starts fetching what isn't here.
    public func keep(_ list: KeptList) {
        store.put(list)
        resume()
    }

    public func remove(_ id: String) {
        store.remove(id)
        if store.missing.isEmpty { isFull = false; notice = nil }
    }

    /// The list as the Mac has it now: songs that left it are let go of, new ones are fetched.
    public func update(_ id: String, tracks: [TrackSummary]) {
        guard var list = store.list(id), list.tracks != tracks else { return }
        list.tracks = tracks
        store.put(list)
        resume()
    }

    /// Carries on with whatever is missing. Does nothing while already fetching.
    public func resume() {
        guard worker == nil, client != nil, !next().isEmpty else { return }
        worker = Task { [weak self] in
            await self?.work()
            self?.worker = nil
            self?.fetching = nil
        }
    }

    private func next() -> [(track: TrackSummary, smaller: Bool)] {
        store.missing.filter { !unavailable.contains($0.track.id ?? -1) }
    }

    private func work() async {
        isFull = false
        notice = nil
        while let (track, smaller) = next().first, let song = track.id, !Task.isCancelled {
            guard let client, client.isConnected() else { return }
            if let reason = holdReason() { notice = reason; return }
            let descriptor: StreamDescriptor
            do {
                descriptor = try await open(song, rate: smaller ? Self.smallerSampleRate : nil, client: client)
            } catch Refusal.refused {
                unavailable.insert(song)
                continue
            } catch {
                return
            }
            let carriesOn = await fetch(song, descriptor, from: client)
            await client.close(descriptor.stream)
            if !carriesOn { return }
        }
    }

    /// Fetches one open stream into the store. False: stop here (no room, the Mac went away, the file couldn't be written).
    private func fetch(_ song: Int64, _ descriptor: StreamDescriptor, from client: PhoneStreamClient) async -> Bool {
        if let limitBytes, store.bytes + descriptor.byteSize > limitBytes {
            isFull = true
            return false
        }
        let part = store.partFile(for: song)
        try? FileManager.default.removeItem(at: part)
        let number = descriptor.stream
        let size = max(1, descriptor.byteSize)
        fetching = (song, 0)
        let downloader = StreamDownloader(descriptor: descriptor, destination: part, read: { offset, length in
            try await client.read(number, offset, length)
        })
        do {
            try await downloader.run { [weak self] done in
                Task { @MainActor in
                    guard let self, self.fetching?.song == song else { return }
                    self.fetching = (song, min(1, Double(done) / Double(size)))
                }
            }
            bytesReceived += descriptor.byteSize
            try store.arrived(song, descriptor: descriptor)
            return true
        } catch {
            if !(error is CancellationError), client.isConnected() { notice = error.localizedDescription }
            return false
        }
    }

    private enum Refusal: Error { case refused, away }

    private func open(_ song: Int64, rate: Double?, client: PhoneStreamClient) async throws -> StreamDescriptor {
        let deadline = ContinuousClock.now + preparingTimeout
        while true {
            try Task.checkCancellation()
            switch await client.open(song, rate) {
            case .streamOpened(let descriptor): return descriptor
            case .streamPreparing:
                guard ContinuousClock.now < deadline else { throw Refusal.refused }
                try await Task.sleep(for: pollInterval)
            default:
                // An answer while connected is the Mac saying no; no connection is not.
                if client.isConnected() { throw Refusal.refused }
                throw Refusal.away
            }
        }
    }
}
#endif
