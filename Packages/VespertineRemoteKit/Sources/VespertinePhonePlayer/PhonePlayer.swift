//
// Vespertine: the phone's player. Decodes with Apple's decoders (`StreamDecoder`) a little ahead of what is being heard and
// hands the audio to an AVAudioEngine player node that feeds the main mixer at unity: no effects, no EQ, no sample-rate
// conversion of ours. What iOS then does with the signal (its own mixing, a fixed output rate, volume) is iOS's, and the app
// says so. A song starts while its stream is still arriving, a seek goes straight to its place, and the song after it carries
// on without a gap when it has the same rate and channels.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import Foundation
import Observation
import VespertineRemoteProtocol

@MainActor
@Observable
public final class PhonePlayer {
    public enum State: Equatable, Sendable {
        case idle
        /// A stream is being opened: its first bytes are on their way.
        case loading
        /// A song is loaded, at its start or at its end.
        case ready
        case playing
        case paused
    }

    public enum Failure: Error, Equatable {
        /// Not yet: more than two channels needs the Spatial Audio path.
        case multichannelNotYet(Int)
        case cannotOpen(String)
        case engine(String)
    }

    /// One song to play: where its bytes come from and what the Mac said they are.
    public struct Item: Sendable {
        public let id: String
        public let source: any ByteSource
        public let format: StreamFormat

        public init(id: String, source: any ByteSource, format: StreamFormat) {
            self.id = id
            self.source = source
            self.format = format
        }
    }

    public private(set) var state: State = .idle
    /// The song being heard.
    public private(set) var currentID: String?
    public private(set) var format: StreamFormat?
    public private(set) var duration: Double = 0
    /// Playing, but the next audio hasn't arrived from the Mac yet.
    public private(set) var isBuffering = false
    /// The signal goes from the file to the output through a player node and a mixer at unity gain, with nothing else.
    public private(set) var isUntouchedPath = false

    /// Seconds of audio decoded ahead of what is being heard.
    @ObservationIgnored public var scheduleAhead: Double = 2 { didSet { pump.setAhead(seconds: scheduleAhead) } }
    /// The song after the current one began to sound (gapless): its id.
    @ObservationIgnored public var onAdvance: ((String) -> Void)?
    /// The song after the current one is now being decoded: time to say what follows it (`setFollowing`).
    @ObservationIgnored public var onScheduledNext: ((String) -> Void)?
    /// The last audio was played and nothing followed without a gap.
    @ObservationIgnored public var onFinished: (() -> Void)?
    /// A song couldn't be opened or read. Playback of it has stopped.
    @ObservationIgnored public var onFailure: ((Error) -> Void)?

    /// Where the song is, in seconds.
    public var position: Double {
        if state == .paused, let held { return held }
        return pump.audible(running: state == .playing).seconds
    }

    @ObservationIgnored private let engine: AVAudioEngine
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let pump: Pump
    @ObservationIgnored private var current: Item?
    /// Where a paused song is.
    @ObservationIgnored private var held: Double?
    /// A stream that is still opening should play as soon as it can.
    @ObservationIgnored private var wantsPlay = false
    /// The song played to its end: Play starts it over.
    @ObservationIgnored private var finished = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(node)
        pump = Pump(node: node)
        pump.send = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    // MARK: Loading

    /// Opens a whole file on the phone for playing (a stream downloaded earlier). Ready when it returns.
    public func load(_ url: URL, format: StreamFormat) throws {
        halt()
        guard format.channels <= 2 else { throw Failure.multichannelNotYet(format.channels) }
        let source: FileByteSource
        do { source = try FileByteSource(url: url) } catch { throw Failure.cannotOpen(error.localizedDescription) }
        let item = Item(id: url.absoluteString, source: source, format: format)
        do { try prime(item, at: 0) } catch {
            halt()
            throw Failure.cannotOpen((error as? StreamDecoder.Failure).map(Self.words) ?? error.localizedDescription)
        }
        state = .ready
    }

    /// Starts `item` in place of whatever is playing. A stream still arriving opens off the main thread (`state` is `.loading`
    /// until its first audio is decoded); a failure arrives through `onFailure`.
    public func start(_ item: Item, playing: Bool = true) {
        halt()
        guard item.format.channels <= 2 else {
            onFailure?(Failure.multichannelNotYet(item.format.channels))
            return
        }
        if item.source.isComplete {
            do {
                try prime(item, at: 0)
                state = .ready
                if playing { try play() }
            } catch {
                halt()
                onFailure?(error)
            }
            return
        }
        current = item
        currentID = item.id
        format = item.format
        wantsPlay = playing
        state = .loading
        let generation = pump.reset(keepingNext: false)
        pump.queue.async { [pump] in
            do {
                try pump.open(item, generation, at: 0)
                pump.send(.opened(generation))
            } catch {
                pump.send(.failed(generation, error))
            }
        }
    }

    /// What plays when the current song ends by itself, or nil. With the same rate and channels it follows without a gap;
    /// otherwise the player finishes and `onFinished` starts it.
    public func setFollowing(_ item: Item?) {
        pump.setNext(item?.format.channels ?? 0 <= 2 ? item : nil)
    }

    /// Opens, connects and decodes the first audio of a song whose bytes are all here.
    private func prime(_ item: Item, at frame: Int64) throws {
        let generation = pump.reset(keepingNext: false)
        try pump.queue.sync { try pump.open(item, generation, at: frame) }
        current = item
        currentID = item.id
        format = item.format
        connect()
        pump.queue.sync { pump.fill(generation) }
    }

    private func connect() {
        guard let processing = pump.processingFormat() else { return }
        duration = pump.duration(of: currentID)
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: processing)
        engine.mainMixerNode.outputVolume = 1
        node.volume = 1
        node.pan = 0
        isUntouchedPath = true
        pump.setAhead(seconds: scheduleAhead)
    }

    // MARK: Transport

    public func play() throws {
        guard current != nil else { return }
        if state == .loading { wantsPlay = true; return }
        guard state != .idle, state != .playing else { return }
        if finished { try seek(to: 0) }
        held = nil
        #if os(iOS)
        do { try PhoneAudioSession.activate() } catch { throw Failure.engine(error.localizedDescription) }
        #endif
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { throw Failure.engine(error.localizedDescription) }
        }
        node.play()
        pump.setRunning(true)
        state = .playing
    }

    public func pause() {
        if state == .loading { wantsPlay = false; return }
        guard state == .playing else { return }
        // A paused node keeps its scheduled audio and its clock: play() carries on from here.
        held = position
        node.pause()
        state = .paused
    }

    /// Back to the start, not playing. A stream that isn't all on the phone is let go of instead.
    public func stop() {
        guard let item = current else { halt(); return }
        guard item.source.isComplete else { halt(); return }
        node.stop()
        held = nil
        finished = false
        wantsPlay = false
        do {
            try prime(item, at: 0)
            state = .ready
        } catch {
            halt()
        }
    }

    /// Stops and forgets the song.
    public func halt() {
        node.stop()
        _ = pump.reset(keepingNext: false)
        pump.setNext(nil)
        current = nil
        currentID = nil
        format = nil
        duration = 0
        held = nil
        wantsPlay = false
        finished = false
        isBuffering = false
        state = .idle
    }

    /// Moves to `seconds` and keeps playing if it was. Into a part of the stream that isn't here yet, that part is fetched first.
    public func seek(to seconds: Double) throws {
        guard let item = current, state == .ready || state == .playing || state == .paused else { return }
        let rate = pump.sampleRate()
        guard rate > 0 else { return }
        let was = state
        let target = max(0, min(seconds, duration))
        let frame = Int64(target * rate)
        node.stop()
        finished = false
        let generation = pump.reset(keepingNext: true, id: item.id, at: frame)
        if item.source.isComplete {
            try pump.queue.sync {
                try pump.seek(to: frame, generation)
                pump.fill(generation)
            }
        } else {
            pump.queue.async { [pump] in
                do {
                    try pump.seek(to: frame, generation)
                    pump.fill(generation)
                } catch {
                    pump.send(.failed(generation, error))
                }
            }
        }
        switch was {
        case .playing:
            node.play()
            pump.setRunning(true)
        case .paused:
            held = target
        default:
            break
        }
    }

    /// Reads what is being heard now: the owner calls it a few times a second while playing (and after rendering, in tests).
    public func tick() {
        let audible = pump.audible(running: state == .playing)
        if state == .playing || state == .paused, let id = audible.id, id != currentID {
            currentID = id
            duration = pump.duration(of: id)
            if let next = pump.item(id) {
                current = next
                format = next.format
            }
            onAdvance?(id)
        }
        let buffering = state == .playing && pump.isStarving()
        if buffering != isBuffering { isBuffering = buffering }
    }

    /// The output changed under the engine (another route, another rate): connects again and carries on from the same place.
    public func recoverFromConfigurationChange() {
        guard current != nil, state == .playing || state == .paused || state == .ready else { return }
        let was = state
        let place = position
        node.stop()
        connect()
        state = was == .playing ? .paused : was
        held = place
        try? seek(to: place)
        if was == .playing { try? play() }
    }

    // MARK: Events from the decoding thread

    private func handle(_ event: Pump.Event) {
        switch event {
        case .opened(let generation):
            guard pump.isCurrent(generation), state == .loading else { return }
            connect()
            pump.queue.async { [pump] in
                // Ready as soon as the first audio is decoded; the rest of the look-ahead follows.
                pump.fill(generation, buffers: 1)
                pump.send(.primed(generation))
                pump.fill(generation)
            }
        case .primed(let generation):
            guard pump.isCurrent(generation), state == .loading else { return }
            state = .ready
            if wantsPlay {
                do { try play() } catch { onFailure?(error) }
            }
        case .scheduledNext(let generation, let id):
            guard pump.isCurrent(generation) else { return }
            onScheduledNext?(id)
        case .finished(let generation):
            guard pump.isCurrent(generation), state == .playing || state == .paused else { return }
            tick()
            node.stop()
            pump.setRunning(false)
            finished = true
            held = nil
            isBuffering = false
            state = .ready
            onFinished?()
        case .failed(let generation, let error):
            guard pump.isCurrent(generation) else { return }
            halt()
            onFailure?(error)
        }
    }

    private static func words(_ failure: StreamDecoder.Failure) -> String {
        switch failure {
        case .cannotOpen(let text), .cannotRead(let text): text
        }
    }
}

/// The decoding side: owns the decoder, keeps the node fed, and knows which song each stretch of the node's clock belongs to.
private final class Pump: @unchecked Sendable {
    /// A run of audio on the node's clock: `frames` frames of song `id` from its frame `fileFrame`, starting at `nodeStart`.
    struct Segment {
        var nodeStart: Int64
        var id: String
        var fileFrame: Int64
        var frames: Int64
    }

    enum Event: Sendable {
        case opened(Int)
        case primed(Int)
        case scheduledNext(Int, String)
        case finished(Int)
        case failed(Int, Error)
    }

    let node: AVAudioPlayerNode
    let queue = DispatchQueue(label: "org.szeremeta.vespertine.phone-pump", qos: .userInitiated)
    private let prepare = DispatchQueue(label: "org.szeremeta.vespertine.phone-prepare", qos: .utility)
    var send: @Sendable (Event) -> Void = { _ in }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var generation = 0
    private var segments: [Segment] = []
    /// Frames handed to the node, and frames it has played, since the last reset.
    private var scheduled: Int64 = 0
    private var consumed: Int64 = 0
    /// Where on the node's clock the next buffer starts to sound.
    private var clockEnd: Int64 = 0
    private var drained = false
    private var starving = false
    private var running = false
    private var aheadSeconds: Double = 2
    private var item: PhonePlayer.Item?
    private var next: (item: PhonePlayer.Item, decoder: StreamDecoder?)?
    private var known: [String: (item: PhonePlayer.Item, frames: Int64, rate: Double)] = [:]
    private var decoder: StreamDecoder?

    init(node: AVAudioPlayerNode) { self.node = node }

    // MARK: From the main thread

    func isCurrent(_ mine: Int) -> Bool { lock.withLock { generation == mine } }
    func setRunning(_ on: Bool) { lock.withLock { running = on } }
    func setAhead(seconds: Double) { lock.withLock { aheadSeconds = max(0.25, seconds) } }
    func isStarving() -> Bool { lock.withLock { starving } }
    func processingFormat() -> AVAudioFormat? { lock.withLock { decoder?.processingFormat } }
    func sampleRate() -> Double { lock.withLock { decoder?.processingFormat.sampleRate ?? 0 } }
    func item(_ id: String) -> PhonePlayer.Item? { lock.withLock { known[id]?.item } }

    func duration(of id: String?) -> Double {
        lock.withLock {
            guard let id, let entry = known[id], entry.rate > 0 else { return 0 }
            return Double(entry.frames) / entry.rate
        }
    }

    /// Starts a new run of the node's clock: everything scheduled before is void. With `id`, the song stays and its place is
    /// `frame` (a seek); without, the song goes too.
    func reset(keepingNext: Bool, id: String? = nil, at frame: Int64 = 0) -> Int {
        let (mine, waiting): (Int, [any ByteSource]) = lock.withLock {
            generation += 1
            scheduled = 0
            consumed = 0
            clockEnd = 0
            drained = false
            starving = false
            running = false
            var waiting: [any ByteSource] = []
            if let item { waiting.append(item.source) }
            if let id {
                segments = [Segment(nodeStart: 0, id: id, fileFrame: frame, frames: 0)]
            } else {
                segments = []
                item = nil
                decoder = nil
                known = [:]
            }
            if !keepingNext { next = nil }
            return (generation, waiting)
        }
        // A decoder waiting for bytes must not hold up the seek or the next song.
        for source in waiting { source.interruptReads() }
        return mine
    }

    func setNext(_ item: PhonePlayer.Item?) {
        lock.withLock { next = item.map { ($0, nil) } }
        guard let item else { return }
        // Opened ahead of time, off the decoding thread: its first bytes may still be on their way.
        prepare.async { [self] in
            guard let opened = try? StreamDecoder(source: item.source, format: item.format) else { return }
            let revive: Int? = lock.withLock {
                guard next?.item.id == item.id, next?.decoder == nil else { return nil }
                next?.decoder = opened
                // The current song was already decoded to its end, but not yet heard to it: carry on into this one.
                guard drained, consumed < scheduled else { return nil }
                drained = false
                return generation
            }
            if let revive { queue.async { [self] in fill(revive) } }
        }
    }

    /// What the node is sounding now: the song and the place in it.
    func audible(running isPlaying: Bool) -> (id: String?, seconds: Double) {
        let now = isPlaying ? rendered() : nil
        return lock.withLock {
            guard let first = segments.first else { return (nil, 0) }
            var segment = first
            if let now {
                for candidate in segments where candidate.nodeStart <= now { segment = candidate }
            }
            let rate = known[segment.id]?.rate ?? decoder?.processingFormat.sampleRate ?? 0
            guard rate > 0 else { return (segment.id, 0) }
            let into = now.map { min(max(0, $0 - segment.nodeStart), segment.frames) } ?? 0
            return (segment.id, Double(segment.fileFrame + into) / rate)
        }
    }

    /// Frames the node has rendered since it last started, or nil while it isn't playing.
    private func rendered() -> Int64? {
        guard let time = node.lastRenderTime, time.isSampleTimeValid, let player = node.playerTime(forNodeTime: time) else { return nil }
        return max(0, player.sampleTime)
    }

    // MARK: On the decoding queue

    func open(_ item: PhonePlayer.Item, _ mine: Int, at frame: Int64) throws {
        let opened = try StreamDecoder(source: item.source, format: item.format)
        if frame > 0 { try opened.seek(to: frame) }
        lock.withLock {
            guard generation == mine else { return }
            decoder = opened
            self.item = item
            known[item.id] = (item, opened.length, opened.processingFormat.sampleRate)
            segments = [Segment(nodeStart: 0, id: item.id, fileFrame: frame, frames: 0)]
        }
    }

    func seek(to frame: Int64, _ mine: Int) throws {
        guard let decoder = lock.withLock({ generation == mine ? decoder : nil }) else { return }
        try decoder.seek(to: frame)
    }

    /// Decodes and schedules until enough audio is ahead of the listener, the song (and what follows it) ends, or this run is void.
    func fill(_ mine: Int, buffers: Int = .max) {
        var made = 0
        while made < buffers {
            let plan: (decoder: StreamDecoder, frames: AVAudioFrameCount)? = lock.withLock {
                guard generation == mine, !drained, let decoder else { return nil }
                let rate = decoder.processingFormat.sampleRate
                guard Double(scheduled - consumed) < aheadSeconds * rate else { return nil }
                starving = running && scheduled <= consumed
                return (decoder, AVAudioFrameCount(min(32_768, max(4_096, rate / 4))))
            }
            guard let plan, let buffer = AVAudioPCMBuffer(pcmFormat: plan.decoder.processingFormat, frameCapacity: plan.frames) else { return }
            let before = plan.decoder.position
            let count: Int
            do { count = try plan.decoder.read(into: buffer) } catch {
                let live = lock.withLock { () -> Bool in
                    starving = false
                    return generation == mine
                }
                if live { send(.failed(mine, error)) }
                return
            }
            if count == 0 {
                guard moveToNext(mine, after: plan.decoder) else { return }
                continue
            }
            let now = rendered()
            let live: Bool = lock.withLock {
                guard generation == mine else { return false }
                starving = false
                // The listener heard silence while this audio was on its way: it starts where the clock is now.
                if running, let now, now > clockEnd, let last = segments.last {
                    clockEnd = now
                    segments.append(Segment(nodeStart: now, id: last.id, fileFrame: before, frames: 0))
                }
                if !segments.isEmpty { segments[segments.count - 1].frames += Int64(count) }
                clockEnd += Int64(count)
                scheduled += Int64(count)
                return true
            }
            guard live else { return }
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.played(Int64(count), mine)
            }
            made += 1
        }
    }

    /// The song ended. Carries on into the one after it when that is open and has the same rate and channels.
    private func moveToNext(_ mine: Int, after ended: StreamDecoder) -> Bool {
        enum Outcome { case moved(String), finished, waiting, void }
        let outcome: Outcome = lock.withLock {
            guard generation == mine else { return .void }
            if let following = next, let opened = following.decoder,
               opened.processingFormat.sampleRate == ended.processingFormat.sampleRate,
               opened.processingFormat.channelCount == ended.processingFormat.channelCount {
                decoder = opened
                item = following.item
                next = nil
                known[following.item.id] = (following.item, opened.length, opened.processingFormat.sampleRate)
                segments.append(Segment(nodeStart: clockEnd, id: following.item.id, fileFrame: 0, frames: 0))
                return .moved(following.item.id)
            }
            drained = true
            return consumed >= scheduled ? .finished : .waiting
        }
        switch outcome {
        case .moved(let id):
            send(.scheduledNext(mine, id))
            return true
        case .finished:
            send(.finished(mine))
            return false
        case .waiting, .void:
            return false
        }
    }

    private func played(_ frames: Int64, _ mine: Int) {
        let done: Bool? = lock.withLock {
            guard generation == mine else { return nil }
            consumed += frames
            return drained && consumed >= scheduled
        }
        guard let done else { return }
        if done { send(.finished(mine)) } else { queue.async { [self] in fill(mine) } }
    }
}
#endif
