//
// Vespertine: the phone's player. Decodes with Apple's decoders (`StreamDecoder`) a little ahead of what is being heard and
// hands the audio to an AVAudioEngine player node that feeds the main mixer at unity: no effects, no EQ, no sample-rate
// conversion of ours. The one thing it can be asked to do to the samples is a song's ReplayGain (`Item.gain`), which is
// 1, and so nothing at all, unless the listener turned ReplayGain on. What iOS then does with the signal (its own mixing, a fixed output rate, volume) is iOS's, and the app
// says so. A song starts while its stream is still arriving, a seek goes straight to its place, and the song after it carries
// on without a gap when it has the same rate and channels.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import Foundation
import Observation
import VespertineChannels
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
        case cannotOpen(String)
        case engine(String)
    }

    /// One song to play: where its bytes come from and what the Mac said they are.
    public struct Item: Sendable {
        public let id: String
        public let source: any ByteSource
        public let format: StreamFormat
        /// What every sample of the song is multiplied by (its ReplayGain, `AppliedGain.scale`). At 1, which it is unless
        /// asked otherwise, the samples are not touched: no multiplication is done. Never anything but 1 for DoP frames,
        /// which are DSD bits, not samples.
        public let gain: Float

        public init(id: String, source: any ByteSource, format: StreamFormat, gain: Float = 1) {
            self.id = id
            self.source = source
            self.format = format
            self.gain = gain.isFinite && gain > 0 ? gain : 1
        }
    }

    public private(set) var state: State = .idle
    /// The song being heard.
    public private(set) var currentID: String?
    public private(set) var format: StreamFormat?
    public private(set) var duration: Double = 0
    /// Playing, but the next audio hasn't arrived from the Mac yet.
    public private(set) var isBuffering = false
    /// The signal goes from the file to the output through a player node and a mixer at unity gain, with nothing else:
    /// stereo or mono, and nothing of Vespertine's changing the samples (`isProcessing`).
    public private(set) var isUntouchedPath = false
    /// Vespertine is changing the samples of the song being heard on purpose: its gain isn't 1 (ReplayGain is on and the
    /// song has a value). Whatever names the signal path reads this; nothing here words it.
    public private(set) var isProcessing = false
    /// What the samples of the song being heard are multiplied by: 1 when they are left as they are.
    public private(set) var gain: Float = 1

    /// What happens to the song's channels on the way out.
    public enum Rendering: Equatable, Sendable {
        /// Stereo or mono, with nothing in the path but a mixer at unity.
        case untouched
        /// Surround folded to the output's channels.
        case downmix
        /// Surround rendered for headphones by Apple's spatial mixer.
        case spatial(headTracked: Bool)
        /// Surround on a multichannel output, each channel on an output of its own, with no mixer in the path.
        case discrete(outputs: Int)
        /// Surround handed to iOS whole (iOS's sample buffer renderer), every channel and its layout, for iOS's own Spatial
        /// Audio to render. What iOS then does is read back from the audio session, not assumed here.
        case system(channels: Int)
    }
    public private(set) var rendering: Rendering = .untouched

    /// How surround songs are played: folded to stereo (Off, which it is until you choose otherwise), or rendered for
    /// headphones (Fixed, or Head Tracked on AirPods that follow your head). Stereo and mono songs, DSD sent as DoP and
    /// surround on an interface with an output per channel never go through the spatial mixer, whatever this says.
    /// Changing it while a surround song plays carries on from the same place.
    public var spatialMode: SpatialMode = .off {
        didSet {
            guard spatialMode != oldValue, !settingBoth, (pump.processingFormat()?.channelCount ?? 0) > 2 else { return }
            recoverFromConfigurationChange()
        }
    }
    /// Surround songs are handed to iOS whole, for iOS's Spatial Audio to render (`SurroundPath.system`), instead of going
    /// through the engine (where a Bluetooth route has two channels). Stereo and mono, and surround on an interface with an
    /// output per channel, never are. Changing it while a surround song plays carries on from the same place.
    public var systemSpatial = false {
        didSet {
            guard systemSpatial != oldValue, !settingBoth, (pump.processingFormat()?.channelCount ?? 0) > 2 else { return }
            recoverFromConfigurationChange()
        }
    }
    @ObservationIgnored private var settingBoth = false

    /// Sets both at once: a surround song playing is connected again once, not twice.
    public func setSurround(spatialMode: SpatialMode, systemSpatial: Bool) {
        let changed = spatialMode != self.spatialMode || systemSpatial != self.systemSpatial
        settingBoth = true
        self.spatialMode = spatialMode
        self.systemSpatial = systemSpatial
        settingBoth = false
        if changed, (pump.processingFormat()?.channelCount ?? 0) > 2 { recoverFromConfigurationChange() }
    }

    /// Makes the sink that hands audio to iOS whole (tests put a stand-in here).
    @ObservationIgnored var makeSystemSink: () -> PlayerSink = {
        #if os(iOS)
        RendererSink()
        #else
        // Only the package's tests run this off iOS: they must never make a sound on the machine running them.
        RendererSink(muted: true)
        #endif
    }
    @ObservationIgnored private var systemSink: PlayerSink?
    @ObservationIgnored private let nodeSink: NodeSink
    /// Where audio goes now.
    private var output: PlayerSink { pump.currentSink() }
    /// What iOS's renderer reports, for the readback: nil unless surround is being handed to iOS.
    public var systemRendererStatus: (status: Int, error: String?)? {
        guard case .system = rendering, let sink = systemSink as? RendererSink else { return nil }
        return (sink.status.rawValue, sink.error?.localizedDescription)
    }
    @ObservationIgnored private var environment: AVAudioEnvironmentNode?

    /// Whether Apple's spatial mixer can turn the scene with the listener's head on this system: it has had the switch
    /// since iOS 18 and macOS 15. Before that Head Tracked is rendered, and named, as Fixed.
    public nonisolated static var systemTracksHead: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { true } else { false }
    }
    /// `systemTracksHead`, unless a test says otherwise.
    @ObservationIgnored public let canTrackHead: Bool

    /// The speaker on each channel of the output, when it has more than two (`ChannelLayouts.outputSpeakers`): surround
    /// songs then go to those channels, one each, instead of being rendered for headphones or folded. nil for a stereo
    /// output. Changing it while a surround song plays carries on from the same place.
    public var outputSpeakers: [AudioChannelLabel]? {
        didSet {
            guard outputSpeakers != oldValue else { return }
            pump.setOutputs(outputSpeakers)
            if (format?.channels ?? 0) > 2 { reopen() }
        }
    }
    /// The player node feeds the output itself (discrete surround), with the main mixer out of the path.
    @ObservationIgnored private var direct = false

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

    /// Seconds of audio decoded ahead of what is being heard: what plays on if the Mac went away now.
    public var decodedAhead: Double { pump.ahead() }

    /// Returns once any fill already running on the decoding queue has handed its buffers to the output. `decodedAhead` counts a
    /// buffer a moment before it is handed over, so a test that waits on it and then renders must settle first, or a slow machine
    /// renders silence where the last buffer was about to be. Never called from the decoding queue.
    func settle() { pump.queue.sync {} }

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

    public init(engine: AVAudioEngine = AVAudioEngine(), canTrackHead: Bool = PhonePlayer.systemTracksHead) {
        self.engine = engine
        self.canTrackHead = canTrackHead
        engine.attach(node)
        // "Played back" allows for the output's latency (a Bluetooth route's is long); an engine rendering offline has no
        // output to wait for and only says "rendered".
        nodeSink = NodeSink(node: node, completion: engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack)
        pump = Pump(sink: nodeSink, engine: engine)
        pump.send = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    // MARK: Loading

    /// Opens a whole file on the phone for playing (a stream downloaded earlier). Ready when it returns.
    public func load(_ url: URL, format: StreamFormat) throws {
        halt()
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
    /// `seconds`: where in the song to start.
    public func start(_ item: Item, playing: Bool = true, at seconds: Double = 0) {
        halt()
        begin(item, playing: playing, at: Int64(max(0, seconds) * item.format.sampleRate))
    }

    /// Opens the current song again where it is: the way its channels are decoded depends on the output.
    private func reopen() {
        guard let item = current, state == .ready || state == .playing || state == .paused else { return }
        let was = state, place = position, rate = pump.sampleRate()
        output.stop()
        held = nil
        finished = false
        isBuffering = false
        begin(item, playing: was == .playing, at: Int64(place * rate))
        if was == .paused, state == .ready {
            state = .paused
            held = place
        }
    }

    private func begin(_ item: Item, playing: Bool, at frame: Int64) {
        if item.source.isComplete {
            do {
                try prime(item, at: frame)
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
                try pump.open(item, generation, at: frame)
                pump.send(.opened(generation))
            } catch {
                pump.send(.failed(generation, error))
            }
        }
    }

    /// What plays when the current song ends by itself, or nil. With the same rate and channels it follows without a gap;
    /// otherwise the player finishes and `onFinished` starts it.
    public func setFollowing(_ item: Item?) {
        pump.setNext(item)
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
        let discrete = pump.isDiscrete()
        let toSystem = systemSpatial && !discrete && processing.channelCount > 2
        // The output's own connection is about to change (or the node on it): not under a running engine.
        if discrete || direct || toSystem, engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(node)
        if let environment { engine.disconnectNodeOutput(environment) }
        if toSystem {
            // Surround handed to iOS whole: the engine is out of the path, and stays stopped.
            let sink = systemSink ?? {
                let made = makeSystemSink()
                if let renderer = made as? RendererSink {
                    renderer.onFlushed = { [weak self] in Task { @MainActor in self?.recoverFromConfigurationChange() } }
                    renderer.onFailed = { [weak self] error in
                        Task { @MainActor in
                            guard let self, case .system = self.rendering else { return }
                            self.halt()
                            self.onFailure?(Failure.engine(error.localizedDescription))
                        }
                    }
                }
                systemSink = made
                return made
            }()
            switchSink(to: sink)
            rendering = .system(channels: Int(processing.channelCount))
            noteGain()
            pump.setAhead(seconds: scheduleAhead)
            return
        }
        switchSink(to: nodeSink)
        engine.mainMixerNode.outputVolume = 1
        node.volume = 1
        node.pan = 0
        if discrete != direct {
            if !discrete { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil) }
            direct = discrete
        }
        if discrete {
            // Every channel to an output of its own: the player node feeds the output, and nothing mixes.
            engine.connect(node, to: engine.outputNode, format: processing)
            rendering = .discrete(outputs: Int(processing.channelCount))
        } else if processing.channelCount > 2, spatialMode != .off {
            // Surround for headphones: the song's bed into Apple's spatial mixer, two binaural channels out.
            let mixer = environment ?? {
                let made = AVAudioEnvironmentNode()
                engine.attach(made)
                environment = made
                return made
            }()
            // What the badge says is what the mixer was told: a system without the switch isn't said to track.
            let tracked = spatialMode == .headTracked && canTrackHead
            node.sourceMode = .ambienceBed
            node.renderingAlgorithm = .auto
            mixer.outputType = .headphones
            mixer.outputVolume = 1
            if #available(iOS 18.0, macOS 15.0, *) { mixer.isListenerHeadTrackingEnabled = tracked }
            engine.connect(node, to: mixer, format: processing)
            engine.connect(mixer, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: processing.sampleRate, channels: 2))
            rendering = .spatial(headTracked: tracked)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: processing)
            rendering = processing.channelCount > 2 ? .downmix : .untouched
        }
        noteGain()
        pump.setAhead(seconds: scheduleAhead)
    }

    /// Audio goes to `sink` from now on; what the other one had queued is dropped.
    private func switchSink(to sink: PlayerSink) {
        let old = pump.currentSink()
        guard old !== sink else { return }
        old.stop()
        pump.setSink(sink)
    }

    /// Reads the gain of the song being heard, and with it whether the path is still the untouched one.
    private func noteGain() {
        let now = current?.gain ?? 1
        if gain != now { gain = now }
        if isProcessing != (now != 1) { isProcessing = now != 1 }
        let untouched = rendering == .untouched && now == 1
        if isUntouchedPath != untouched { isUntouchedPath = untouched }
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
        if case .system = rendering {
            // iOS's renderer plays it; the engine would only add silence of its own to the output.
            if engine.isRunning { engine.stop() }
        } else if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { throw Failure.engine(error.localizedDescription) }
        }
        output.play()
        pump.setRunning(true)
        state = .playing
    }

    public func pause() {
        if state == .loading { wantsPlay = false; return }
        guard state == .playing else { return }
        // A paused node keeps its scheduled audio and its clock: play() carries on from here.
        held = position
        output.pause()
        state = .paused
    }

    /// Back to the start, not playing. A stream that isn't all on the phone is let go of instead.
    public func stop() {
        guard let item = current else { halt(); return }
        guard item.source.isComplete else { halt(); return }
        output.stop()
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
        output.stop()
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
        noteGain()
    }

    /// Stops, forgets the song and stops the engine too, so nothing of this player's reaches the output (not even
    /// silence) while something else plays to it. `play()` starts the engine again.
    public func rest() {
        halt()
        systemSink?.stop()
        if engine.isRunning { engine.stop() }
    }

    /// Moves to `seconds` and keeps playing if it was. Into a part of the stream that isn't here yet, that part is fetched first.
    public func seek(to seconds: Double) throws {
        guard let item = current, state == .ready || state == .playing || state == .paused else { return }
        let rate = pump.sampleRate()
        guard rate > 0 else { return }
        let was = state
        let target = max(0, min(seconds, duration))
        let frame = Int64(target * rate)
        output.stop()
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
            output.play()
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
                noteGain()
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
        output.stop()
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
            output.stop()
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

    /// Where the audio goes: the engine's node, or iOS's renderer. Swapped under `gate`, so a fill never hands a buffer
    /// to one it has stopped being.
    private var sink: PlayerSink
    let queue = DispatchQueue(label: "org.szeremeta.vespertine.phone-pump", qos: .userInitiated)
    private let prepare = DispatchQueue(label: "org.szeremeta.vespertine.phone-prepare", qos: .utility)
    var send: @Sendable (Event) -> Void = { _ in }

    private let lock = NSLock()
    /// Held while a buffer is handed to the node and while a new run starts, so audio of a run that is void can't reach the
    /// node after it was emptied. Taken before `lock`, never inside it; the node's callbacks don't take it.
    private let gate = NSLock()
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
    /// The speakers of a multichannel output: surround is decoded onto them.
    private var outputs: [AudioChannelLabel]?

    /// Held so the node keeps its engine for as long as a fill may be in flight: a buffer scheduled on a node whose engine
    /// has gone is an exception, and the player can be let go while the pump's queue is still decoding.
    private let engine: AVAudioEngine

    init(sink: PlayerSink, engine: AVAudioEngine) {
        self.sink = sink
        self.engine = engine
    }

    func currentSink() -> PlayerSink { gate.withLock { sink } }
    func setSink(_ new: PlayerSink) { gate.withLock { sink = new } }

    /// Seconds of audio decoded and not yet played.
    func ahead() -> Double {
        lock.withLock {
            guard let rate = decoder?.processingFormat.sampleRate, rate > 0 else { return 0 }
            return Double(max(0, scheduled - consumed)) / rate
        }
    }

    // MARK: From the main thread

    func isCurrent(_ mine: Int) -> Bool { lock.withLock { generation == mine } }
    func setRunning(_ on: Bool) { lock.withLock { running = on } }
    func setAhead(seconds: Double) { lock.withLock { aheadSeconds = max(0.25, seconds) } }
    func isStarving() -> Bool { lock.withLock { starving } }
    func processingFormat() -> AVAudioFormat? { lock.withLock { decoder?.processingFormat } }
    func isDiscrete() -> Bool { lock.withLock { decoder?.isDiscrete ?? false } }
    func setOutputs(_ speakers: [AudioChannelLabel]?) { lock.withLock { outputs = speakers } }
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
        let (mine, waiting): (Int, [any ByteSource]) = gate.withLock { lock.withLock { () -> (Int, [any ByteSource]) in
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
        } }
        // Emptied only now that nothing of the old run can be scheduled any more. Stopped before that, the node could be
        // handed more of the old audio by a fill still at work (a song's first seconds are decoded while it already
        // plays), and would play it first: the old place heard for a moment, and every place after it told wrong.
        currentSink().stop()
        // A decoder waiting for bytes must not hold up the seek or the next song.
        for source in waiting { source.interruptReads() }
        return mine
    }

    func setNext(_ item: PhonePlayer.Item?) {
        lock.withLock { next = item.map { ($0, nil) } }
        guard let item else { return }
        // Opened ahead of time, off the decoding thread: its first bytes may still be on their way.
        prepare.async { [self] in
            let outputs = lock.withLock { self.outputs }
            guard let opened = try? StreamDecoder(source: item.source, format: item.format, outputs: outputs) else { return }
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

    /// Frames the output has sounded since it last started, or nil while it isn't playing.
    private func rendered() -> Int64? { currentSink().rendered() }

    // MARK: On the decoding queue

    func open(_ item: PhonePlayer.Item, _ mine: Int, at frame: Int64) throws {
        let opened = try StreamDecoder(source: item.source, format: item.format, outputs: lock.withLock { outputs })
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
            let plan: (decoder: StreamDecoder, frames: AVAudioFrameCount, gain: Float)? = lock.withLock {
                guard generation == mine, !drained, let decoder else { return nil }
                let rate = decoder.processingFormat.sampleRate
                guard Double(scheduled - consumed) < aheadSeconds * rate else { return nil }
                starving = running && scheduled <= consumed
                // The gain of the song this buffer is read from: the one after it has its own from its first frame.
                return (decoder, AVAudioFrameCount(min(32_768, max(4_096, rate / 4))), item?.gain ?? 1)
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
            // ReplayGain, when the song has one: each sample times one number. At 1 the buffer is handed on as decoded.
            if plan.gain != 1, let planes = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let samples = UnsafeMutableBufferPointer(start: planes[channel], count: count)
                    for index in samples.indices { samples[index] *= plan.gain }
                }
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
            let handed: Bool = gate.withLock {
                guard lock.withLock({ generation == mine }) else { return false }
                sink.schedule(buffer) { [weak self] in
                    self?.played(Int64(count), mine)
                }
                return true
            }
            guard handed else { return }
            made += 1
        }
    }

    /// The song ended. Carries on into the one after it when that is open and has the same rate and channels.
    private func moveToNext(_ mine: Int, after ended: StreamDecoder) -> Bool {
        enum Outcome { case moved(String), finished, waiting, void }
        let outcome: Outcome = lock.withLock {
            guard generation == mine else { return .void }
            if let following = next, let opened = following.decoder,
               opened.processingFormat == ended.processingFormat {
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
