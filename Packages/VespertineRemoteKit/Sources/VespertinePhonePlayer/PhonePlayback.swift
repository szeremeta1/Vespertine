//
// Vespertine: "Play on this iPhone". Keeps the phone's queue, asks the Mac to open each song (waiting while the Mac converts
// what the phone can't open), streams it into the player while it arrives, and has the song after it open ahead of time so
// that it follows without a gap. The Mac allows a phone its stream plus one more, so songs are let go of as soon as they
// have been heard.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import Foundation
import Observation
import VespertineRemoteClient
import VespertineRemoteProtocol

/// The Mac's side of a stream, as the phone's player needs it.
public struct PhoneStreamClient: Sendable {
    public var open: @Sendable (_ song: Int64, _ maxSampleRate: Double?) async -> RemoteReply
    public var read: @Sendable (_ stream: Int, _ offset: Int64, _ length: Int) async throws -> StreamFrame
    public var close: @Sendable (_ stream: Int) async -> Void
    public var isConnected: @Sendable @MainActor () -> Bool
    /// Opens a song to keep in its smaller form (lossless files above `maxSampleRate` converted down to it). nil: as `open`.
    public var openSmaller: (@Sendable (_ song: Int64, _ maxSampleRate: Double) async -> RemoteReply)?

    public init(open: @escaping @Sendable (Int64, Double?) async -> RemoteReply,
                read: @escaping @Sendable (Int, Int64, Int) async throws -> StreamFrame,
                close: @escaping @Sendable (Int) async -> Void,
                isConnected: @escaping @Sendable @MainActor () -> Bool) {
        self.open = open
        self.read = read
        self.close = close
        self.isConnected = isConnected
    }

    @MainActor
    public init(session: RemoteSession) {
        self.init(open: { [weak session] song, rate in await session?.send(.streamOpen(id: song, maxSampleRate: rate)) ?? .failed(reason: "") },
                  read: { [weak session] stream, offset, length in
                      guard let session else { throw RemoteLinkError.closed }
                      return try await session.readStream(stream, offset: offset, length: length)
                  },
                  close: { [weak session] stream in _ = await session?.send(.streamClose(stream: stream)) },
                  isConnected: { [weak session] in session?.isConnected ?? false })
        openSmaller = { [weak session] song, rate in await session?.send(.streamOpen(id: song, maxSampleRate: rate, smaller: true)) ?? .failed(reason: "") }
    }
}

@MainActor
@Observable
public final class PhonePlayback {
    public enum Failure: Error, Equatable {
        /// The Mac said no, in words for showing as they are.
        case refused(String)
        /// The Mac was still converting the song when the wait ran out.
        case stillPreparing
        case notConnected
        /// The phone itself won't fetch songs right now (cellular data, with playing over it turned off); the words say why.
        case held(String)
        /// The song isn't in the Mac's library, so the Mac can't be asked for it.
        case notInLibrary
    }

    public let player: PhonePlayer
    public let cacheDirectory: URL
    public private(set) var queue = PhoneQueue()
    /// The song being heard, or about to be.
    public private(set) var nowPlaying: PhoneQueue.Entry?
    /// What the Mac is sending for it: the original file or a FLAC it made, and the format.
    public private(set) var stream: StreamDescriptor?
    /// The Mac is converting the song before it can send it; `progress` 0…1 when the Mac knows.
    public private(set) var preparing: (entry: String, progress: Double?)?
    /// The last thing that went wrong, in words.
    public private(set) var notice: String?
    /// Where the song was when that last changed otherwise than by playing on (`positionAt`): see `PositionAnchor`.
    public var position: Double { anchor.position }
    public var positionAt: Date { anchor.at }
    /// Where the song is this instant.
    public var livePosition: Double { player.state == .playing || player.state == .paused ? player.position : anchor.position }
    public private(set) var anchor = PositionAnchor()
    private var advancing: Bool { player.state == .playing && !player.isBuffering }
    private func place(_ seconds: Double) { anchor.place(seconds, moving: advancing) }

    /// How long to wait for a conversion on the Mac, and how often to ask again.
    @ObservationIgnored public var preparingTimeout: Duration = .seconds(600)
    @ObservationIgnored public var pollInterval: Duration = .seconds(1)
    /// Asked before a song is fetched: words when the phone shouldn't fetch right now (the app's cellular setting), else nil.
    @ObservationIgnored public var holdReason: @MainActor () -> String? = { nil }
    /// How long a song waits for a Mac that stopped answering before it gives up.
    @ObservationIgnored public var patience: Duration = .seconds(120)
    /// How long a song that is being opened waits for a Mac that isn't connected right now.
    @ObservationIgnored public var reconnectWait: Duration = .seconds(20)
    /// A stream is waiting for the Mac to come back (the connection dropped mid-song).
    public private(set) var waitingForMac = false
    @ObservationIgnored private var waits = 0
    /// Bytes fetched from the Mac for songs already let go of; `bytesReceived` adds the ones still open.
    @ObservationIgnored private var received: Int64 = 0
    /// How much this phone has fetched from the Mac since the player was made (the data counter).
    public var bytesReceived: Int64 { open.values.reduce(received) { $0 + ($1.stream?.bufferedBytes ?? 0) } }
    /// A song kept on this device: its file and what the Mac sent it as. Such a song plays from the file, Mac or no Mac.
    @ObservationIgnored public var kept: @MainActor (Int64) -> (file: URL, descriptor: StreamDescriptor)? = { _ in nil }

    private func lineWaits(_ waiting: Bool) {
        waits = max(0, waits + (waiting ? 1 : -1))
        if waitingForMac != (waits > 0) { waitingForMac = waits > 0 }
    }
    /// What this phone's output can use right now (48000 for AirPods; a USB DAC's top rate): the Mac caps conversions at it.
    @ObservationIgnored public var maxSampleRate: @MainActor () -> Double? = { nil }
    /// How far past the listener to fetch (nil: the whole song, which then stays on the phone for the next play).
    @ObservationIgnored public var readAhead: Int64?
    /// How often the place in the song is read while playing.
    @ObservationIgnored public var tickInterval: Duration = .milliseconds(250)

    @ObservationIgnored private let client: PhoneStreamClient
    private struct Open {
        let song: Int64
        let descriptor: StreamDescriptor
        let source: any ByteSource
        /// The stream from the Mac behind `source`; nil for a song kept on this device.
        var stream: StreamSource?
        var line: StreamLine?
    }
    /// Streams open on the Mac, by queue entry.
    @ObservationIgnored private var open: [String: Open] = [:]
    @ObservationIgnored private var opening: [String: Task<Open, Error>] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The entry the player is decoding (ahead of the one being heard, near a song's end).
    @ObservationIgnored private var decoding: String?
    /// The entry given to the player as what follows.
    @ObservationIgnored private var followingEntry: String?

    public init(client: PhoneStreamClient, player: PhonePlayer, cacheDirectory: URL) {
        self.client = client
        self.player = player
        self.cacheDirectory = cacheDirectory
        player.onScheduledNext = { [weak self] id in
            guard let self else { return }
            decoding = id
            followingEntry = nil
            prepareFollowing(after: id)
        }
        player.onAdvance = { [weak self] id in self?.arrived(at: id) }
        player.onFinished = { [weak self] in self?.finished() }
        player.onFailure = { [weak self] error in
            guard let self, let entry = nowPlaying else { return }
            failed(entry, error)
        }
    }

    public convenience init(session: RemoteSession, player: PhonePlayer, cacheDirectory: URL) {
        self.init(client: PhoneStreamClient(session: session), player: player, cacheDirectory: cacheDirectory)
        session.onStreamsClosed = { [weak self] reason in self?.cutOff(saying: reason) }
    }

    /// Playing, or about to: a song that was started counts from the tap, while its stream is still being opened.
    public var isPlaying: Bool { player.state == .playing || (loading != nil && startsPlaying) }
    private var startsPlaying = true
    /// Whether the song a step leads to should sound: not when you had paused.
    private var staysPlaying: Bool { loading != nil ? startsPlaying : player.state != .paused }
    public var duration: Double { player.duration > 0 ? player.duration : (nowPlaying?.track.duration ?? 0) }

    // MARK: Starting songs

    /// Plays `tracks` on this phone from `index`, in place of the phone's queue. `shuffled`: as the Mac's Play and Shuffle buttons.
    public func play(_ tracks: [TrackSummary], startAt index: Int = 0, shuffled: Bool? = nil) {
        if let entry = queue.play(tracks, startAt: index, shuffled: shuffled) { start(entry) }
    }

    public func playNext(_ tracks: [TrackSummary]) {
        if let entry = queue.playNext(tracks) { start(entry) } else { queueChanged() }
    }

    public func addToQueue(_ tracks: [TrackSummary]) {
        if let entry = queue.addToQueue(tracks) { start(entry) } else { queueChanged() }
    }

    public func jump(to entry: String) {
        if let entry = queue.jump(to: entry) { start(entry) }
    }

    private func start(_ entry: PhoneQueue.Entry, playing: Bool = true) {
        loading?.cancel()
        following?.cancel()
        player.halt()
        nowPlaying = entry
        startsPlaying = playing
        decoding = entry.id
        followingEntry = nil
        stream = nil
        notice = nil
        place(0)
        release(keeping: [entry.id])
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await opened(entry)
                guard !Task.isCancelled, nowPlaying?.id == entry.id else { return }
                stream = opened.descriptor
                player.start(item(entry, opened), playing: startsPlaying)
                prepareFollowing(after: entry.id)
                startTicker()
            } catch is CancellationError {
                return
            } catch {
                guard nowPlaying?.id == entry.id else { return }
                failed(entry, error)
            }
            loading = nil
        }
    }

    private func item(_ entry: PhoneQueue.Entry, _ opened: Open) -> PhonePlayer.Item {
        PhonePlayer.Item(id: entry.id, source: opened.source, format: opened.descriptor.format)
    }

    /// The stream for `entry`: the one already open, or a new one (asking again while the Mac converts).
    private func opened(_ entry: PhoneQueue.Entry) async throws -> Open {
        if let have = open[entry.id] { return have }
        if let running = opening[entry.id] { return try await running.value }
        guard let song = entry.track.id else { throw Failure.notInLibrary }
        if let kept = kept(song), let file = try? FileByteSource(url: kept.file) {
            let result = Open(song: song, descriptor: kept.descriptor, source: file)
            open[entry.id] = result
            return result
        }
        let task = Task { [weak self] () throws -> Open in
            guard let self else { throw CancellationError() }
            let descriptor = try await openStream(song: song, entry: entry.id)
            let client = self.client
            let number = descriptor.stream
            // Nobody wants it any more (another song was chosen while the Mac was opening this one): give it back.
            if Task.isCancelled {
                Task { await client.close(number) }
                throw CancellationError()
            }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let name = "\(song)-\(descriptor.tag.prefix(16)).\(descriptor.format.container)"
            let line = StreamLine(client: client, song: song, descriptor: descriptor, maxSampleRate: maxSampleRate(), patience: patience)
            await line.onWaiting { [weak self] waiting in Task { @MainActor in self?.lineWaits(waiting) } }
            let source = try StreamSource(descriptor: descriptor, file: cacheDirectory.appendingPathComponent(name),
                                          read: { offset, length in try await line.read(offset: offset, length: length) }, readAhead: readAhead)
            // The decoder waits as long as the line does (and a little more, so the line's own words win).
            source.readTimeout = Double(patience.components.seconds) + 10
            source.start()
            return Open(song: song, descriptor: descriptor, source: source, stream: source, line: line)
        }
        opening[entry.id] = task
        defer { opening[entry.id] = nil }
        let result = try await task.value
        open[entry.id] = result
        return result
    }

    private func openStream(song: Int64, entry: String) async throws -> StreamDescriptor {
        let deadline = ContinuousClock.now + preparingTimeout
        defer { if preparing?.entry == entry { preparing = nil } }
        while true {
            try Task.checkCancellation()
            if let reason = holdReason() { throw Failure.held(reason) }
            try await waitForMac()
            switch await client.open(song, maxSampleRate()) {
            case .streamOpened(let descriptor): return descriptor
            case .streamPreparing(let progress):
                if nowPlaying?.id == entry { preparing = (entry, progress) }
                guard ContinuousClock.now < deadline else { throw Failure.stillPreparing }
                try await Task.sleep(for: pollInterval)
            case .failed(let reason): throw Failure.refused(reason)
            default: throw Failure.refused("")
            }
        }
    }

    /// A song opened while the connection is being made again (the network just changed) waits for it rather than failing:
    /// up to `reconnectWait`, with "Waiting for … to connect" showing.
    private func waitForMac() async throws {
        if client.isConnected() { return }
        lineWaits(true)
        defer { lineWaits(false) }
        let deadline = ContinuousClock.now + reconnectWait
        while !client.isConnected() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.notConnected }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Opens what plays after `id` and hands it to the player, so it follows without a gap.
    private func prepareFollowing(after id: String) {
        following?.cancel()
        guard let next = queue.following(after: id) else {
            followingEntry = nil
            player.setFollowing(nil)
            return
        }
        following = Task { [weak self] in
            guard let self, let opened = try? await opened(next), !Task.isCancelled else { return }
            guard queue.following(after: id)?.id == next.id else { return }
            followingEntry = next.id
            player.setFollowing(item(next, opened))
        }
    }

    /// The queue was edited: what follows may be another song now.
    private func queueChanged() {
        guard let anchor = decoding ?? nowPlaying?.id else { return }
        let next = queue.following(after: anchor)?.id
        guard next != followingEntry || next == nil else { return }
        player.setFollowing(nil)
        followingEntry = nil
        release(keeping: Set([nowPlaying?.id, decoding, next].compactMap { $0 }))
        prepareFollowing(after: anchor)
    }

    /// Closes the streams of every entry but `keeping`. A song that arrived whole stays on the phone as a file.
    private func release(keeping: Set<String>) {
        for (entry, task) in opening where !keeping.contains(entry) { task.cancel() }
        for (entry, stream) in open where !keeping.contains(entry) {
            open[entry] = nil
            stream.stream?.close()
            received += stream.stream?.bufferedBytes ?? 0
            if let line = stream.line { Task { await line.close() } }
        }
    }

    // MARK: What the player reports

    private func arrived(at id: String) {
        queue.arrive(at: id)
        nowPlaying = queue.current
        stream = open[id]?.descriptor
        release(keeping: Set([id, decoding, followingEntry].compactMap { $0 }))
    }

    private func finished() {
        place(0)
        switch queue.advance() {
        case .start(let entry): start(entry)
        case .restart, .end:
            ticker?.cancel()
            ticker = nil
        }
    }

    private func failed(_ entry: PhoneQueue.Entry, _ error: Error) {
        notice = Self.words(error, title: entry.track.title)
        preparing = nil
        player.halt()
        // A song the Mac won't send (it plays on the Mac only) is passed over, as the Mac passes over a file it can't open.
        // Anything else (the Mac went away, the network) stops here, so nothing is skipped by a bad connection.
        guard case Failure.refused = error else { return }
        let text = notice
        if case .start(let next) = queue.next() {
            start(next)
            notice = text
        }
    }

    static func words(_ error: Error, title: String) -> String {
        switch error {
        case Failure.refused(let reason) where !reason.isEmpty:
            return reason
        case Failure.held(let reason):
            return reason
        case Failure.refused:
            return String(localized: "“\(title)” can’t be played on this device.", comment: "Phone player: the Mac refused to send a song and gave no reason.")
        case Failure.stillPreparing:
            return String(localized: "The Mac is still converting “\(title)”. Try again in a moment.", comment: "Phone player: a conversion on the Mac took longer than the phone waits.")
        case Failure.notConnected, StreamSource.Failure.unreachable, StreamSource.Failure.timedOut, StreamSource.Failure.closed:
            return String(localized: "The Mac stopped answering while “\(title)” was playing.", comment: "Phone player: the stream from the Mac broke off.")
        case Failure.notInLibrary:
            return String(localized: "“\(title)” isn’t in the Mac’s library, so it can’t be played on this device.", comment: "Phone player: a file played on the Mac from outside its library.")
        case StreamSource.Failure.brokenStream(let text), StreamSource.Failure.cannotWrite(let text),
             StreamDecoder.Failure.cannotOpen(let text), StreamDecoder.Failure.cannotRead(let text), PhonePlayer.Failure.cannotOpen(let text),
             PhonePlayer.Failure.engine(let text):
            return text
        default:
            return error.localizedDescription
        }
    }

    // MARK: Transport

    public func playPause() {
        if isPlaying || player.state == .loading { pause() } else { resume() }
    }

    public func resume() {
        // Still opening the stream: it starts playing when it is here.
        if loading != nil { startsPlaying = true; return }
        if player.state == .idle {
            if let entry = queue.current { start(entry) }
            return
        }
        do { try player.play() } catch { notice = Self.words(error, title: nowPlaying?.track.title ?? "") }
        place(player.position)
        startTicker()
    }

    public func pause() {
        if loading != nil { startsPlaying = false }
        player.pause()
        place(player.position)
    }

    public func next() {
        if case .start(let entry) = queue.next() { start(entry, playing: staysPlaying) }
    }

    public func previous() {
        switch queue.previous(position: player.position) {
        case .start(let entry): start(entry, playing: staysPlaying)
        case .restart: seek(to: 0)
        case .end: break
        }
    }

    public func seek(to seconds: Double) {
        do {
            try player.seek(to: seconds)
            place(player.position)
        } catch {
            notice = Self.words(error, title: nowPlaying?.track.title ?? "")
        }
    }

    /// Stops and lets go of every stream. The queue stays.
    public func stop() {
        loading?.cancel()
        loading = nil
        following?.cancel()
        ticker?.cancel()
        ticker = nil
        player.halt()
        release(keeping: [])
        preparing = nil
        decoding = nil
        followingEntry = nil
        place(0)
    }

    /// The Mac won't send songs here any more: whatever came from it stops now, the song fetched ahead included. A song kept
    /// on this device plays on (it is the phone's own), with nothing from the Mac lined up after it.
    public func cutOff(saying reason: String?) {
        let fromMac = Set(open.filter { $0.value.stream != nil }.keys).union(opening.keys)
        let heard = [nowPlaying?.id, decoding].compactMap { $0 }
        let wasBusy = loading != nil || heard.contains(where: fromMac.contains)
        guard wasBusy || !fromMac.isEmpty else { return }
        if wasBusy {
            stop()
        } else {
            following?.cancel()
            player.setFollowing(nil)
            followingEntry = nil
            release(keeping: Set(open.filter { $0.value.stream == nil }.keys))
        }
        // What had arrived whole is given up too.
        try? FileManager.default.removeItem(at: cacheDirectory)
        if wasBusy {
            notice = reason.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "The Mac stopped sending songs to this device.", comment: "Phone player: playing here was turned off on the Mac while a song from it played.")
        }
    }

    // MARK: Editing the queue

    public func remove(_ entries: [String]) { queue.remove(entries); queueChanged() }
    public func clearUpcoming() { queue.clearUpcoming(); queueChanged() }
    public func moveUpcoming(_ entries: [String], before target: String?) { queue.moveUpcoming(entries, before: target); queueChanged() }
    public func setShuffle(_ on: Bool) { queue.setShuffle(on); queueChanged() }
    public func setRepeat(_ mode: RepeatModeValue) { queue.repeatMode = mode; queueChanged() }

    // MARK: Following the song

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                tick()
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    /// Reads where the song is (and whether the next one has begun).
    public func tick() {
        player.tick()
        if player.state == .playing || player.state == .paused {
            var next = anchor
            if next.read(player.position, moving: advancing) { anchor = next }
        }
    }
}
#endif
