//
// Vespertine — the playback engine.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// decoder → AVAudioConverter (format, and SRC only when needed) → lock-free ring → HAL IOProc
//
// One dedicated thread owns decoding and device configuration. The public API only
// posts commands, so callers never block on Core Audio or disk I/O.
//

import Accelerate
import AVFAudio
import CVespertineRT
import CoreAudio
import Foundation
import SFBAudioEngine
import Synchronization

public enum PlaybackState: String, Sendable { case stopped, playing, paused }

public struct EngineSnapshot: Sendable {
    public var state: PlaybackState = .stopped
    public var item: PlayableItem?
    public var position: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var signalPath: SignalPath?
    public var underruns: Int = 0
    public var outputDevice: OutputDevice?
    public var lastError: String?
    /// Output is paused while a stalled network read catches up (playback resumes by itself).
    public var isBuffering = false
    /// Playback is waiting for the chosen output (by name) to come back; it starts by itself when it does.
    public var waitingForDevice: String?
    /// The track being decoded is read live from a network share (not yet from its local copy).
    public var readingFromShare = false
    /// Set while macOS itself renders the track (Dolby Atmos); there's no Vespertine signal path then.
    public var systemRendering: SystemRendering?
}

public enum EngineEvent: Sendable {
    /// The item became audible (not merely decoded).
    case trackStarted(PlayableItem)
    case queueEnded
    case failed(PlayableItem?, String)
    case deviceLost(String)
    /// The chosen output isn't there (e.g. AirPods just put back on and not reconnected yet):
    /// playback waits for it instead of switching to another device.
    case waitingForDevice(String)
    /// The chosen output didn't come back in time; playback stays paused.
    case deviceUnavailable(String)
    /// The chosen output is connected but still won't start after the wait; playback stays paused.
    case deviceNotResponding(String)
}

public struct EngineSettings: Sendable, Equatable {
    public var exclusive = true
    public var deviceUID: String?                 // nil = follow system default output
    public var dopDeviceUIDs: Set<String> = []
    public var ratePolicies: [String: RatePolicy] = [:]
    public var releaseExclusiveAfterPause: TimeInterval = 30
    /// nil = no software volume (hardware or fixed).
    public var digitalVolumeDB: Double?
    /// Outputs with their own volume control get no digital volume. Decided for the output that's actually
    /// playing (see `digitalVolume(for:)`), so a change of the Mac's default output can't take it off a DAC.
    public var preferHardwareVolume = false
    /// Spatial Audio for multichannel music, per device UID. Unset: head tracked on AirPods and Beats, off elsewhere.
    public var spatialModes: [String: SpatialMode] = [:]
    /// Dolby Atmos: let macOS render the objects (true), or play the Dolby Digital Plus channel bed
    /// through Vespertine's own path (false).
    public var atmosBySystem = true
    /// Outputs with an AV receiver that decodes Dolby and DTS: those are sent untouched (IEC 61937).
    public var bitstreamDeviceUIDs: Set<String> = []
    /// Integer mode for devices that offer it (exclusive access only): PCM that needs no processing goes
    /// to the DAC as 32-bit integers with no float step, so 32-bit sources arrive exact.
    public var integerMode = false

    public init() {}

    public func spatialMode(for device: OutputDevice) -> SpatialMode {
        spatialModes[device.uid] ?? (device.isAppleHeadphones ? .headTracked : .off)
    }

    /// The digital volume (dB) applied on `device`; nil = none.
    public func digitalVolume(for device: OutputDevice?) -> Double? {
        preferHardwareVolume && device?.hasHardwareVolume == true ? nil : digitalVolumeDB
    }
}

public final class PlaybackEngine: @unchecked Sendable {
    /// Called on the engine thread when the current item has been fully decoded; return the next item for gapless playback.
    public var nextItemProvider: (@Sendable (PlayableItem) -> PlayableItem?)? {
        get { callbacks.withLock { $0.next } }
        set { callbacks.withLock { $0.next = newValue } }
    }
    /// Maps an item to the file to open, called on the engine thread each time an item is opened
    /// (e.g. a local cached copy of a file on a network share). nil opens `item.url`.
    public var urlResolver: (@Sendable (PlayableItem) -> URL)? {
        get { callbacks.withLock { $0.resolver } }
        set { callbacks.withLock { $0.resolver = newValue } }
    }
    private func resolve(_ item: PlayableItem) -> URL { urlResolver?(item) ?? item.url }
    /// Delivered on the main queue.
    public var eventHandler: (@Sendable @MainActor (EngineEvent) -> Void)? {
        get { callbacks.withLock { $0.event } }
        set { callbacks.withLock { $0.event = newValue } }
    }
    private struct Callbacks {
        var next: (@Sendable (PlayableItem) -> PlayableItem?)?
        var event: (@Sendable @MainActor (EngineEvent) -> Void)?
        var resolver: (@Sendable (PlayableItem) -> URL)?
    }
    private let callbacks = Mutex(Callbacks())

    enum Command {
        case play(PlayableItem)
        case pause, resume, stop
        case seek(TimeInterval)
        case settingsChanged(EngineSettings)
        case devicesChanged
        case queueChanged(reloadCurrent: Bool)
        case barrier(DispatchSemaphore)
    }

    private struct Shared {
        var commands: [Command] = []
        var snapshot = EngineSnapshot()
        var settings = EngineSettings()
    }

    private let shared = Mutex(Shared())
    private let wake = DispatchSemaphore(value: 0)
    private let sessionLock = NSLock()
    private var thread: Thread?

    // MARK: Engine-thread state

    private final class Decoding {
        let item: PlayableItem
        /// Read live from a network share (not a local cached copy): may stall and need rebuffering.
        var streaming = false
        /// Streaming, and can't move to the local copy (lossy, DSD converted to PCM, or the copy didn't match).
        var staysOnShare = false
        /// Both are replaced when playback moves from the share to a finished local copy.
        var probed: ProbedSource
        var decoder: PCMDecoding
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
        let path: SignalPath
        let gain: Float
        /// Spatial Audio on the source's own speakers: the converter keeps the file's channel order and this
        /// places each channel on the bed (`routed` is what reaches the ring).
        let router: BedRouter?
        let routed: AVAudioPCMBuffer?
        var inputExhausted = false
        var finished = false
        var framesProduced: UInt64 = 0
        var error: Error?

        init(item: PlayableItem, probed: ProbedSource, decoder: PCMDecoding, path: SignalPath, chunk: AVAudioFrameCount,
             layout: AVAudioChannelLayout? = nil) throws {
            self.item = item
            self.probed = probed
            self.decoder = decoder
            self.path = path
            let own = decoder.processingFormat.channelLayout
            var router: BedRouter?
            let channels = Int(decoder.processingFormat.channelCount)
            if path.plan.spatialBed != nil, let bed = layout?.channelLabels,
               let speakers = ChannelLayouts.speakerLabels(own) ?? ChannelLayouts.standardLabels(channels: channels) {
                router = BedRouter(source: speakers, bed: bed)
            }
            self.router = router
            // Integer mode: straight to 32-bit integers (the device takes them as they are).
            let float = router.flatMap { AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: $0.sourceChannels, interleaved: true, layout: own) }
                ?? AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: path.plan.channels, interleaved: true, layout: layout)
            let integer = float.flatMap { f in
                AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: f.sampleRate, interleaved: true, channelLayout: f.channelLayout
                              ?? AVAudioChannelLayout(layoutTag: f.channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)!)
            }
            guard let outFormat = path.applied.integerMode ? integer : float,
                  let converter = AVAudioConverter(from: decoder.processingFormat, to: outFormat) else {
                throw SourceOpenerError.unsupported(item.url)
            }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
            converter.downmix = true
            converter.dither = false
            self.converter = converter
            let inCapacity = AVAudioFrameCount(Double(chunk) * decoder.processingFormat.sampleRate / path.plan.deviceSampleRate) + 1024
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: inCapacity),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
                throw SourceOpenerError.unsupported(item.url)
            }
            input = inBuffer
            output = outBuffer
            routed = router.flatMap { r in
                AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: r.bedChannels, interleaved: true, layout: layout)
                    .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: chunk) }
            }
            if let db = item.replayGainDB, db != 0, path.plan.mode == .pcm {
                gain = Float(pow(10, db / 20))
            } else {
                gain = 1
            }
        }

        var durationSeconds: Double {
            let rate = decoder.processingFormat.sampleRate
            return rate > 0 ? Double(decoder.length) / rate : 0
        }
    }

    private struct Segment {
        let id = UUID()
        let item: PlayableItem
        let path: SignalPath
        let startRingFrame: UInt64
        let startOffsetSeconds: Double
        let durationSeconds: Double
    }

    private var session: OutputSession?
    private var sessionDevice: OutputDevice?
    private var decoding: Decoding?
    private var pending: (item: PlayableItem, probed: ProbedSource, plan: OutputPlan, device: OutputDevice)?
    /// The next track, for macOS's renderer (Dolby Atmos), once this one has played out.
    private var pendingSystem: PlayableItem?
    private var segments: [Segment] = []
    private var state: PlaybackState = .stopped
    private var settings = EngineSettings()
    private var draining = false
    /// Output paused while a stalled network read refills the ring.
    private var buffering = false
    private var rebuffer: (context: OpaquePointer, frames: UInt32)?

    private func isStreaming(_ item: PlayableItem) -> Bool {
        item.cacheKey != nil && resolve(item) == item.url
    }

    /// Network stalls: the output callback holds in silence when a streamed track's ring runs dry
    /// (even while the decoder is blocked in a read) and resumes once five seconds are buffered
    /// (enough that one slow read doesn't turn into a string of stops).
    /// Nothing is skipped, so the position stays exact. Off once the file is fully read.
    private func updateRebuffering() {
        guard let session else { buffering = false; rebuffer = nil; return }
        let active = decoding.map { $0.streaming && !$0.finished } ?? false
        let want = active && !draining ? UInt32(session.applied.sampleRate * 5) : 0
        if rebuffer?.context != session.context || rebuffer?.frames != want {
            nrt_context_set_rebuffer(session.context, want)
            rebuffer = (session.context, want)
        }
        let starved = nrt_context_is_starved(session.context)
        if starved, !buffering { log.notice("Network read stalled; holding until 5 s are buffered") }
        buffering = starved
    }

    /// Shared mode: whether another app is sending sound to the same device (checked about once a second).
    private var othersPlaying = false
    private var othersCheckedAt = Date.distantPast
    private var othersDevice: AudioObjectID?
    private var drainedAt: Date?
    private var pausedAt: Date?
    private var parked: (item: PlayableItem, position: TimeInterval)?
    /// Dolby Atmos being rendered by macOS (instead of `session`).
    private var atmos: SystemRendererSession?
    /// Playback asked for while the chosen output is missing: held (parked) until it's back or `until` passes.
    private var awaitingDevice: (uid: String, until: Date, checkedAt: Date)?
    /// How long playback waits for a missing output (AirPods take several seconds to reconnect).
    private let deviceWait: TimeInterval
    /// Names of outputs seen, for messages about ones that are gone.
    private var deviceNames: [String: String] = [:]
    private var lastAudibleSegmentID: UUID?
    private var underrunTotal = 0
    private var emptyTransitions = 0
    private let chunkFrames: AVAudioFrameCount = 4096

    public convenience init() { self.init(deviceWait: 60) }

    init(deviceWait: TimeInterval) {
        self.deviceWait = deviceWait
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                guard let self else { return }
                self.runIteration()
            }
        }
        thread.name = "Vespertine Engine"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    deinit {
        thread?.cancel()
        teardown(releaseHog: true)
    }

    // MARK: Public API

    // Skip, seek, pause, stop and a change of output silence the old audio right away, on the caller's
    // thread: the engine thread may be busy (a network read) and the buffer holds 20–30 s. It clears the
    // mute when it starts (or resumes) playing.
    public func play(_ item: PlayableItem) { silenceNow(); post(.play(item)) }
    public func pause() { silenceNow(); post(.pause) }
    public func resume() { post(.resume) }
    public func stop() { silenceNow(); post(.stop) }

    private func silenceNow() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let session { nrt_context_set_muted(session.context, true) }
    }

    /// The engine thread is about to play: let the audio through again.
    private func unmute() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let session { nrt_context_set_muted(session.context, false) }
    }
    /// Stops and releases the device, waiting (up to `timeout`) until it's done. For quitting.
    public func stopAndWait(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        post(.stop)
        post(.barrier(done))
        _ = done.wait(timeout: .now() + timeout)
    }
    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        silenceNow()
        post(.seek(max(0, seconds)))
    }
    /// Discards decoded look-ahead after the play order changes.
    /// The queue changed. `reloadCurrent` reopens the song that's playing (e.g. its gain changed);
    /// otherwise it plays on without a break and only what follows it is re-planned.
    public func queueChanged(reloadCurrent: Bool = false) { post(.queueChanged(reloadCurrent: reloadCurrent)) }
    public func devicesChanged() { post(.devicesChanged) }

    public func update(settings: EngineSettings) {
        let (changed, newOutput) = shared.withLock { s -> (Bool, Bool) in
            guard s.settings != settings else { return (false, false) }
            let newOutput = s.settings.deviceUID != settings.deviceUID
            s.settings = settings
            return (true, newOutput)
        }
        if newOutput { silenceNow() }   // the old output stops now, not when the new one is ready
        if changed { post(.settingsChanged(settings)) }
    }

    public var snapshot: EngineSnapshot { shared.withLock { $0.snapshot } }

    /// Peak levels (linear) since the previous call.
    public func takePeaks() -> (left: Float, right: Float) {
        let all = takeChannelPeaks()
        return (all.first ?? 0, all.count > 1 ? all[1] : (all.first ?? 0))
    }

    /// Peak level (linear) of every decoded channel since the previous call, in the stream's channel
    /// order (see `SignalPath.channelLabels`). Up to 16 channels.
    public func takeChannelPeaks() -> [Float] {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let session else { return [] }
        let n = min(session.plan.channels, Int(NRT_METER_CHANNELS))
        return (0..<n).map { nrt_context_take_peak(session.context, UInt32($0)) }
    }

    /// Copies the latest mono samples sent to the DAC. Returns the device sample rate, or nil when idle.
    public func copyTap(into buffer: inout [Float]) -> Double? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let session, !buffer.isEmpty else { return nil }
        let n = UInt32(min(buffer.count, Int(NRT_TAP_SIZE)))
        buffer.withUnsafeMutableBufferPointer { _ = nrt_context_copy_tap(session.context, $0.baseAddress!, n) }
        return session.applied.sampleRate
    }

    /// A probed file whose start failed before its decoder was used (the output wasn't ready).
    private var unusedProbe: (item: UUID, probed: ProbedSource)?
    /// The open decoder of the song that's restarting on another output. Opening the file again is the slow
    /// part of a switch on a busy share (seconds, while the cache copies the same file); the decoder can
    /// simply seek back to where playback is, if the new output needs the same kind of decoding.
    private var carried: (item: UUID, probed: ProbedSource, decoder: PCMDecoding, mode: OutputPlan.Mode)?

    private var hasPendingCommands: Bool { shared.withLock { !$0.commands.isEmpty } }

    private func post(_ command: Command) {
        shared.withLock { $0.commands.append(command) }
        wake.signal()
    }

    private func emit(_ event: EngineEvent) {
        guard let handler = eventHandler else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }

    // MARK: Engine thread

    private func runIteration() {
        do {
            let commands = shared.withLock { s -> [Command] in
                defer { s.commands.removeAll() }
                return s.commands
            }
            for command in Self.coalesce(commands) { handle(command) }

            var didWork = false
            if state == .playing, let atmos {
                checkSystemRenderer(atmos)
            } else if state == .playing {
                switchToLocalCopyIfReady()
                didWork = fill()
                checkTransitions()
                updateRebuffering()
            } else if awaitingDevice != nil {
                checkAwaitedDevice()
            } else if state == .paused, let pausedAt, session?.applied.exclusive == true,
                      Date().timeIntervalSince(pausedAt) > settings.releaseExclusiveAfterPause {
                park()
            }
            publishSnapshot()

            if !didWork {
                _ = wake.wait(timeout: .now() + (state == .playing ? .milliseconds(8) : .milliseconds(100)))
            }
        }
    }

    /// Commands that piled up while the engine was busy (opening a file on a slow share), reduced to the
    /// ones that still matter, in order:
    /// - Skips: only the last song asked for is opened. A play or stop makes every earlier play, seek,
    ///   pause and resume moot; opening each skipped song in turn took seconds apiece on a share.
    /// - Seeks: only the last one before the next play or stop.
    /// - Output changes (quick clicks): only the last one restarts playback. Each carries the complete
    ///   settings, and each comes with a queue update (other versions of upcoming songs), so those
    ///   collapse into one too.
    static func coalesce(_ commands: [Command]) -> [Command] {
        let lastStart = commands.lastIndex { switch $0 { case .play, .stop: true; default: false } }
        let lastSettings = commands.lastIndex { if case .settingsChanged = $0 { true } else { false } }
        let lastQueue = commands.lastIndex { if case .queueChanged = $0 { true } else { false } }
        let reload = commands.contains { if case .queueChanged(true) = $0 { true } else { false } }
        return commands.enumerated().compactMap { i, command in
            switch command {
            case .play, .pause, .resume:
                if let lastStart, i < lastStart { return nil }
                return command
            case .seek:
                if let lastStart, i < lastStart { return nil }
                let later = commands[(i + 1)...].contains { if case .seek = $0 { true } else { false } }
                return later ? nil : command
            case .settingsChanged: return i == lastSettings ? command : nil
            case .queueChanged: return i == lastQueue ? .queueChanged(reloadCurrent: reload) : nil
            default: return command
            }
        }
    }

    /// Another song (or stop) was asked for while this one was opening: finishing it would only delay that.
    private var superseded: Bool {
        shared.withLock { $0.commands.contains { switch $0 { case .play, .stop: true; default: false } } }
    }
    private struct Superseded: Error {}

    private func handle(_ command: Command) {
        switch command {
        case .barrier(let done):
            done.signal()
        case .play(let item):
            shared.withLock { $0.snapshot.lastError = nil }
            carried = nil
            teardownDecoding()
            session?.flush()
            parked = nil
            start(item, at: 0, autoplay: true)
        case .pause:
            awaitingDevice = nil
            guard state == .playing else { return }
            atmos?.pause()
            session?.stop()
            state = .paused
            pausedAt = Date()
        case .resume:
            if state == .paused, let atmos {
                atmos.play(); state = .playing; pausedAt = nil
            } else if state == .paused, let session {
                do { try session.start(); unmute(); state = .playing; pausedAt = nil }
                catch { restartFromCurrentPosition() }
            } else if state == .paused || state == .stopped, let parked {
                self.parked = nil
                start(parked.item, at: parked.position, autoplay: true)
            }
        case .stop:
            carried = nil
            teardown(releaseHog: true)
            parked = nil
            awaitingDevice = nil
            state = .stopped
            lastAudibleSegmentID = nil
        case .seek(let seconds):
            guard let current = currentItem() else { return }
            let resume = state == .playing || awaitingDevice != nil
            teardownDecoding()
            session?.flush()
            parked = nil
            start(current, at: seconds, autoplay: resume)
        case .settingsChanged(let new):
            let old = settings
            settings = new
            applyGain()
            let deviceChanged = old.deviceUID != new.deviceUID || old.exclusive != new.exclusive
                || old.dopDeviceUIDs != new.dopDeviceUIDs || old.ratePolicies != new.ratePolicies
                || old.atmosBySystem != new.atmosBySystem || (atmos != nil && old.spatialModes != new.spatialModes)
                || old.bitstreamDeviceUIDs != new.bitstreamDeviceUIDs || old.integerMode != new.integerMode
            if deviceChanged, state != .stopped {
                log.notice("Output settings changed (\(old.deviceUID ?? "system", privacy: .public) → \(new.deviceUID ?? "system", privacy: .public)); restarting at the current position")
                restartFromCurrentPosition()
            }
        case .queueChanged(let reloadCurrent):
            guard state != .stopped else { return }
            if reloadCurrent { restartFromCurrentPosition() } else { replanUpcoming() }
        case .devicesChanged:
            if awaitingDevice != nil { checkAwaitedDevice(force: true); return }
            guard let device = sessionDevice else { return }
            let alive = DeviceQuery.allDeviceIDs().contains(device.id)
            if !alive {
                log.notice("\(device.name, privacy: .public) disappeared while in use")
                let position = currentPosition()
                let item = currentItem()
                let wasPlaying = state == .playing
                teardown(releaseHog: false)
                if let item { parked = (item, position) }
                state = parked == nil ? .stopped : .paused
                if wasPlaying, parked != nil, let uid = settings.deviceUID, uid == device.uid {
                    // The chosen output dropped out mid-song (a DAC re-enumerating, AirPods reconnecting):
                    // carry on when it's back rather than on some other device.
                    awaitingDevice = (uid, Date().addingTimeInterval(deviceWait), Date())
                    emit(.waitingForDevice(device.name))
                } else if wasPlaying {
                    emit(.deviceLost(device.name))
                }
            }
            // Deliberately *not* following system-default changes mid-playback: hogging the default device makes
            // macOS move the default elsewhere, and chasing it would restart playback in a loop. The new default
            // is picked up at the next play.
        }
    }

    // MARK: Starting and stopping

    /// The output to play to. A chosen output that isn't there is never swapped for another one
    /// (AirPods taken off and put back on would otherwise start playing out of the speakers).
    private func resolveDevice() throws -> OutputDevice? {
        let devices = DeviceQuery.outputDevices(dopEnabledUIDs: settings.dopDeviceUIDs)
        for device in devices { deviceNames[device.uid] = device.name }
        if let uid = settings.deviceUID {
            if let chosen = devices.first(where: { $0.uid == uid }) { return chosen }
            throw ChosenDeviceMissing(uid: uid)
        }
        // Following the default: stay on the device we already hold (our hog moved the system default away from it).
        if settings.deviceUID == nil, let current = sessionDevice, let alive = devices.first(where: { $0.id == current.id }) { return alive }
        return devices.first(where: \.isDefault) ?? devices.first
    }

    private struct ChosenDeviceMissing: Error { let uid: String }
    /// The chosen output is listed but won't start yet (e.g. AirPods still reconnecting).
    private struct ChosenDeviceNotReady: Error { let uid: String; var reason = "" }

    private func deviceName(_ uid: String) -> String { deviceNames[uid] ?? "The selected output" }

    /// While waiting for the chosen output: start as soon as it's back, or give up after `deviceWait`.
    private func checkAwaitedDevice(force: Bool = false) {
        guard let awaiting = awaitingDevice else { return }
        guard awaiting.uid == settings.deviceUID else { awaitingDevice = nil; return }
        let now = Date()
        guard force || now.timeIntervalSince(awaiting.checkedAt) >= 0.5 else { return }
        awaitingDevice?.checkedAt = now
        if DeviceQuery.outputDevices(dopEnabledUIDs: settings.dopDeviceUIDs).contains(where: { $0.uid == awaiting.uid }) {
            // start() keeps the original deadline if the output isn't ready yet and it has to wait again.
            guard let parked else { awaitingDevice = nil; return }
            self.parked = nil
            start(parked.item, at: parked.position, autoplay: true)
        } else if now > awaiting.until {
            awaitingDevice = nil
            emit(.deviceUnavailable(deviceName(awaiting.uid)))
        }
    }

    private func start(_ item: PlayableItem, at seconds: TimeInterval, autoplay: Bool) {
        let previousWait = awaitingDevice
        awaitingDevice = nil
        var candidate: PlayableItem? = item
        var offset = seconds
        var attempts = 0
        let startedAt = Date()
        while let current = candidate, attempts < 8 {
            attempts += 1
            do {
                try begin(current, at: offset)
                if let atmos {
                    if autoplay { atmos.play(); state = .playing } else { state = .paused; pausedAt = Date() }
                    emit(.trackStarted(atmos.item))
                    return
                }
                if autoplay {
                    do { try session?.start() } catch {
                        if let uid = settings.deviceUID { throw ChosenDeviceNotReady(uid: uid, reason: "start: \(error.localizedDescription)") }
                        throw error
                    }
                    log.notice("Playing on \(self.sessionDevice?.name ?? "?", privacy: .public) from \(String(format: "%.1f", offset), privacy: .public) s after \(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public) ms")
                    unmute()
                    state = .playing
                } else {
                    state = .paused
                    pausedAt = Date()
                }
                return
            } catch is Superseded {
                // The next command starts what was asked for instead.
                log.info("Skipped past \(current.url.lastPathComponent, privacy: .public) while it opened")
                teardownDecoding()
                return
            } catch let error where error is ChosenDeviceMissing || error is ChosenDeviceNotReady {
                // Hold the song where it was and wait for the output to come back (or to be ready).
                let uid = (error as? ChosenDeviceMissing)?.uid ?? (error as? ChosenDeviceNotReady)?.uid ?? ""
                log.notice("\(self.deviceName(uid), privacy: .public) \(error is ChosenDeviceMissing ? "isn't listed" : "won't start (\((error as? ChosenDeviceNotReady)?.reason ?? "?"))", privacy: .public); waiting for it")
                teardown(releaseHog: true)
                parked = (current, offset)
                state = .paused
                pausedAt = nil
                if autoplay || previousWait != nil {
                    let now = Date()
                    let until = previousWait?.until ?? now.addingTimeInterval(deviceWait)
                    if error is ChosenDeviceNotReady, now > until {
                        // Connected all along and still won't start: stop trying (each try can block the engine
                        // for seconds, so pause and skip would barely respond) and say so.
                        emit(.deviceNotResponding(deviceName(uid)))
                        return
                    }
                    awaitingDevice = (uid, until, now)
                    if previousWait == nil { emit(.waitingForDevice(deviceName(uid))) }
                }
                return
            } catch {
                emit(.failed(current, error.localizedDescription))
                shared.withLock { $0.snapshot.lastError = error.localizedDescription }
                teardownDecoding()
                candidate = nextItemProvider?(current)
                offset = 0
            }
        }
        teardown(releaseHog: true)
        state = .stopped
    }

    /// Opens `item`, (re)configures the device if needed, positions and prefills.
    private func begin(_ item: PlayableItem, at seconds: TimeInterval) throws {
        var marks: [(String, Date)] = [("start", Date())]
        func mark(_ name: String) { marks.append((name, Date())) }
        defer {
            let steps = zip(marks, marks.dropFirst()).map { "\($1.0) \(Int($1.1.timeIntervalSince($0.1) * 1000))" }.joined(separator: ", ")
            log.info("Opening \(item.url.lastPathComponent, privacy: .public) (ms): \(steps, privacy: .public)")
        }
        guard let device = try resolveDevice() else { throw CoreAudioError(kAudioHardwareBadDeviceError, "find an output device") }
        mark("device")
        // Retrying an output that wasn't ready reuses the file already opened: on a share, opening it again
        // costs seconds each time, and only the device needs another try.
        let url = resolve(item)
        let probed: ProbedSource
        let carry = carried.flatMap { $0.item == item.id && $0.probed.url == url ? $0 : nil }
        if carried != nil, carry == nil { carried = nil }
        if let carry { probed = carry.probed }
        else if let reuse = unusedProbe, reuse.item == item.id, reuse.probed.url == url { probed = reuse.probed }
        else { probed = try SourceOpener.probe(url) }
        unusedProbe = (item.id, probed)
        mark("probe")
        // Opening the file is the slow part on a busy share: if you've skipped on meanwhile, stop here,
        // before the output is reconfigured for a song that won't play.
        if superseded { throw Superseded() }
        let bitstream = settings.bitstreamDeviceUIDs.contains(device.uid) && SourceInspector.canBitstream(probed.url, codec: probed.format.codec)
        if probed.format.codec == DolbyAtmos.codecName, settings.atmosBySystem, !bitstream {
            try beginSystemRendering(item, url: resolve(item), device: device, at: seconds)
            return
        }
        atmos?.stop()
        atmos = nil
        var plan = FormatPlanner.plan(source: probed.format, device: device.capabilities,
                                      policy: settings.ratePolicies[device.uid] ?? .matchSource,
                                      spatial: settings.spatialMode(for: device), bitstream: bitstream)
        plan.integerSamples = wantsIntegerMode(plan, source: probed, item: item, device: device)
        if session == nil || sessionDevice?.id != device.id || !(session!.plan.isDeviceCompatible(with: plan)) {
            do { try replaceSession(device: device, plan: plan) } catch {
                if let uid = settings.deviceUID { throw ChosenDeviceNotReady(uid: uid, reason: "configure: \(error.localizedDescription)") }
                throw error
            }
        } else {
            session?.flush()
        }
        mark("output")
        guard let session else { return }
        unusedProbe = nil   // its decoder is about to be used
        let reused = carry.flatMap { $0.mode == plan.mode ? $0.decoder : nil }
        carried = nil
        let decoder = try reused ?? SourceOpener.decoder(for: probed, plan: plan, item: item)
        mark(reused == nil ? "decoder" : "decoder (kept open)")
        var actualOffset = 0.0
        if seconds > 0 || reused != nil, decoder.supportsSeeking, decoder.length > 0 {
            let bounded = min(seconds * decoder.processingFormat.sampleRate, Double(max(0, decoder.length - 1)))
            let frame = AVAudioFramePosition(bounded)
            try decoder.seek(to: frame)
            actualOffset = Double(frame) / decoder.processingFormat.sampleRate
        }
        Self.alignDoPMarkers(decoder, at: session.totalWritten)
        let decoding = try Decoding(item: item, probed: probed, decoder: decoder,
                                    path: makePath(probed: probed, plan: plan, device: device, session: session, item: item),
                                    chunk: chunkFrames, layout: session.decodedLayout)
        mark("seek+converter")
        decoding.streaming = isStreaming(item)
        self.decoding = decoding
        segments = [Segment(item: item, path: decoding.path, startRingFrame: session.totalWritten,
                            startOffsetSeconds: actualOffset, durationSeconds: decoding.durationSeconds)]
        draining = false
        nrt_context_set_draining(session.context, false)
        lastAudibleSegmentID = nil
        prefill()
        mark("prefill")
    }

    private func replaceSession(device: OutputDevice, plan: OutputPlan) throws {
        sessionLock.lock()
        let old = session
        session = nil
        sessionLock.unlock()
        // DSD over DoP only survives untouched with sole access, so it always takes the device.
        let exclusive = (settings.exclusive && !device.alwaysShared) || plan.isPassthrough
        // A new format on the device already held (a skip to another rate): keep holding it and leave its format
        // to the new session. Letting go and taking it back reconfigures the device several times in a row, and
        // macOS can lose track of its own pause/resume pairs then: the device stays paused for this process and
        // never starts again (AudioDeviceStart times out with error 35) until the app quits.
        let keep = old.map { $0.deviceID == device.id && $0.applied.exclusive && exclusive } ?? false
        old?.invalidate(releaseHog: !keep, restoreFormat: !keep)
        let new = try OutputSession(deviceID: device.id, plan: plan, exclusive: exclusive)
        sessionLock.lock()
        session = new
        sessionDevice = device
        sessionLock.unlock()
        applyGain()
    }

    private func makePath(probed: ProbedSource, plan: OutputPlan, device: OutputDevice, session: OutputSession, item: PlayableItem) -> SignalPath {
        let volume: SignalPath.VolumeStage
        if let db = settings.digitalVolume(for: device), plan.mode == .pcm { volume = .digital(dB: db) }
        else if device.hasHardwareVolume { volume = .hardware }
        else { volume = .fixed }
        return SignalPath(source: probed.format, decoderName: probed.decoderName, plan: plan, applied: session.applied,
                          deviceName: device.name, deviceUID: device.uid, deviceProfile: device.profile, volume: volume,
                          replayGainDB: plan.mode == .pcm ? item.replayGainDB : nil)
    }

    private func applyGain() {
        let digital = settings.digitalVolume(for: sessionDevice)
        atmos?.setVolume(Float(digital.map { pow(10, $0 / 20) } ?? 1))
        guard let session else { return }
        let db = session.plan.isPassthrough ? 0 : (digital ?? 0)
        nrt_context_set_gain(session.context, db == 0 ? 1.0 : pow(10, db / 20), UInt32(session.applied.physicalBitDepth))
    }

    private func teardownDecoding() {
        decoding = nil
        pending = nil
        pendingSystem = nil
        segments.removeAll()
        draining = false
        drainedAt = nil
        buffering = false
    }

    private func teardown(releaseHog: Bool) {
        teardownDecoding()
        atmos?.stop()
        atmos = nil
        sessionLock.lock()
        let old = session
        session = nil
        sessionDevice = nil
        sessionLock.unlock()
        old?.invalidate(releaseHog: releaseHog)
    }

    /// Frees the device after a long pause but remembers where we were.
    private func park() {
        let position = currentPosition()
        if let item = currentItem() { parked = (item, position) }
        teardown(releaseHog: true)
        pausedAt = nil
    }

    private func restartFromCurrentPosition() {
        guard let item = currentItem() else { return }
        let position = parked?.position ?? currentPosition()
        let wasPlaying = state == .playing || awaitingDevice != nil
        if let d = decoding, d.item.id == item.id, d.decoder.supportsSeeking, d.path.plan.mode != .bitstream {
            carried = (item.id, d.probed, d.decoder, d.path.plan.mode)
        }
        teardown(releaseHog: true)
        parked = nil
        start(item, at: position, autoplay: wasPlaying)
    }

    /// The queue changed (shuffle, repeat, edits). The song that's playing carries on untouched; only what
    /// was already lined up after it is taken back and chosen again from the new queue.
    private func replanUpcoming() {
        // Parked or not started: the next start reads the new queue anyway.
        guard let session, let audible = audibleSegment() else { return }
        let read = session.totalRead
        if let next = segments.first(where: { $0.startRingFrame > read }) {
            // The next song is already partly decoded into the ring. Take it back, unless it's about to be
            // heard (then it plays, and the new order applies from the song after it).
            let margin = max(UInt32(session.applied.sampleRate / 4), UInt32(session.applied.bufferFrames * 4))
            guard nrt_ring_rewind(session.ring, next.startRingFrame, margin) else { return }
            segments.removeAll { $0.startRingFrame >= next.startRingFrame }
        } else if !draining {
            // Still decoding the song that's playing: the next one is picked from the new queue when it ends.
            return
        }
        decoding = nil
        pending = nil
        draining = false
        drainedAt = nil
        nrt_context_set_draining(session.context, false)
        advance(after: audible.item, produced: 1)
    }

    /// Integer mode applies only where nothing would change the samples: plain PCM at its own rate and
    /// channel count, no Spatial Audio, digital volume or ReplayGain, on a device with a non-mixable Int32 format.
    /// Float files aren't integers, so they'd be changed on the way: they keep the float path (and its label).
    private func wantsIntegerMode(_ plan: OutputPlan, source probed: ProbedSource, item: PlayableItem, device: OutputDevice) -> Bool {
        let source = probed.format
        return settings.integerMode && settings.exclusive && !device.alwaysShared && plan.mode == .pcm && !plan.resamples && plan.spatial == .off
            && plan.channels == source.channels && source.encoding == .pcm && probed.exactAsIntegers
            && settings.digitalVolume(for: device) == nil && (item.replayGainDB ?? 0) == 0
            && device.capabilities.physicalFormats.contains { $0.isInteger && !$0.isMixable && $0.bitDepth == 32 }
    }

    /// The item playing (or paused), whichever path plays it.
    private func currentItem() -> PlayableItem? { audibleSegment()?.item ?? atmos?.item ?? parked?.item }

    // MARK: Dolby Atmos (rendered by macOS)

    private func beginSystemRendering(_ item: PlayableItem, url: URL, device: OutputDevice, at seconds: TimeInterval) throws {
        // macOS's renderer needs the device to itself: drop Vespertine's own session first.
        teardown(releaseHog: true)
        let volume = Float(settings.digitalVolume(for: device).map { pow(10, $0 / 20) } ?? 1)
        let session = try SystemRendererSession(item: item, url: url, deviceUID: device.uid,
                                                spatial: settings.spatialMode(for: device) != .off,
                                                volume: volume)
        try session.prepare(at: seconds)
        sessionLock.lock()
        atmos = session
        sessionDevice = device
        sessionLock.unlock()
        lastAudibleSegmentID = nil
    }

    /// Moves on when macOS has played the Atmos track out (or couldn't).
    private func checkSystemRenderer(_ session: SystemRendererSession) {
        if let failure = session.failure {
            emit(.failed(session.item, failure.localizedDescription))
        } else if !session.finished {
            return
        }
        let finished = session.item
        teardown(releaseHog: true)
        if let next = nextItemProvider?(finished) { start(next, at: 0, autoplay: true) } else { finishQueue() }
    }

    // MARK: Decoding

    private var localCopyCheckedAt = Date.distantPast

    /// A track streaming from a network share moves to its local copy as soon as the copy is complete
    /// (the cache downloads the playing track first), continuing from the exact frame it had reached:
    /// the rest of the track no longer depends on the network or the server's disks. Only for decoders
    /// whose output after a seek is identical to continuous decoding (lossless PCM and DoP).
    private func switchToLocalCopyIfReady() {
        guard let decoding, decoding.streaming, !decoding.staysOnShare, !decoding.finished, !decoding.inputExhausted,
              Date().timeIntervalSince(localCopyCheckedAt) >= 1 else { return }
        localCopyCheckedAt = Date()
        let local = resolve(decoding.item)
        guard local != decoding.item.url else { return }
        do {
            guard let (probed, decoder) = try Self.reopen(decoding.probed, decoder: decoding.decoder, at: local,
                                                          plan: decoding.path.plan, item: decoding.item) else {
                decoding.staysOnShare = true      // lossy, DSD converted to PCM, or a copy that doesn't match
                return
            }
            decoding.probed = probed
            decoding.decoder = decoder
            decoding.streaming = false
            log.notice("Streaming track moved to its local copy at frame \(decoder.position, privacy: .public)")
        } catch {
            decoding.staysOnShare = true
            log.error("Couldn't move to the local copy: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the same audio from `url` (a complete local copy) positioned exactly where `decoder` is, so
    /// decoding continues seamlessly. Nil when that can't be guaranteed to be sample-identical: lossy
    /// decoders and DSD→PCM conversion carry state across a seek, and the copy must match the original.
    static func reopen(_ probed: ProbedSource, decoder current: PCMDecoding, at url: URL, plan: OutputPlan,
                       item: PlayableItem) throws -> (ProbedSource, PCMDecoding)? {
        guard probed.format.encoding == .pcm || (probed.format.encoding == .dsd && plan.mode == .dop),
              current.supportsSeeking else { return nil }
        let local = try SourceOpener.probe(url)
        guard local.format == probed.format else { return nil }
        let decoder = try SourceOpener.decoder(for: local, plan: plan, item: item)
        let position = current.position
        guard decoder.length == current.length, position >= 0, position <= decoder.length else { return nil }
        try decoder.seek(to: position)
        guard decoder.position == position else { return nil }
        if let dop = decoder as? RawDoPDecoder, let was = current as? RawDoPDecoder { dop.nextMarker = was.nextMarker }
        return (local, decoder)
    }

    /// DoP markers alternate frame by frame through the whole output buffer (one decoded frame is one buffer
    /// frame): a DoP track starting at `ringFrame` takes up that sequence, so a gapless join never sends two
    /// 0x05 in a row (a DAC drops out of DSD for a moment, a click). A fresh buffer starts on 0x05.
    private static func alignDoPMarkers(_ decoder: PCMDecoding, at ringFrame: UInt64) {
        (decoder as? RawDoPDecoder)?.nextMarker = AVAudioFramePosition(ringFrame & 1)
    }


    private func prefill() {
        guard let session else { return }
        // Network files (streamed, not yet cached) start with more in hand: a slow first read from
        // a share must not become an audible gap.
        let seconds = decoding?.streaming == true ? 1.5 : 0.3
        let target = min(Int(session.applied.sampleRate * seconds), Int(nrt_ring_capacity(session.ring)) / 2)
        // Bound work so a repeating empty/corrupt track cannot monopolize the engine thread.
        for _ in 0..<256 {
            // A command waiting (another output, pause, skip) goes first: it would throw this work away,
            // and on a slow share the rest of the prefill can take seconds. Playback rebuffers as usual.
            if session.readableFrames >= target || hasPendingCommands || !fill() { break }
        }
    }

    /// Decodes one chunk into the ring. Returns true when it did any work.
    @discardableResult
    private func fill() -> Bool {
        guard let session else { return false }
        guard let decoding else {
            return false
        }
        if decoding.finished {
            advance(after: decoding.item, produced: decoding.framesProduced)
            return true
        }
        guard session.writableFrames >= Int(chunkFrames) else { return false }

        decoding.output.frameLength = 0
        var conversionError: NSError?
        let status = decoding.converter.convert(to: decoding.output, error: &conversionError) { requested, inputStatus in
            if decoding.inputExhausted {
                inputStatus.pointee = .endOfStream
                return nil
            }
            decoding.input.frameLength = 0
            do {
                try decoding.decoder.decode(into: decoding.input, length: min(requested, decoding.input.frameCapacity))
            } catch {
                decoding.error = error
                decoding.inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if decoding.input.frameLength == 0 {
                decoding.inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return decoding.input
        }

        let frames = decoding.output.frameLength
        var raw = decoding.output.floatChannelData?[0]
            ?? decoding.output.int32ChannelData.map { UnsafeMutableRawPointer($0[0]).assumingMemoryBound(to: Float.self) }
        if let router = decoding.router, let routed = decoding.routed, let source = raw, let bed = routed.floatChannelData?[0] {
            router.route(source, into: bed, frames: Int(frames))
            raw = bed
        }
        if frames > 0, let data = raw {
            decoding.framesProduced += UInt64(frames)
            emptyTransitions = 0
            if decoding.gain != 1, !decoding.path.applied.integerMode {
                var g = decoding.gain
                vDSP_vsmul(data, 1, &g, data, 1, vDSP_Length(frames) * vDSP_Length(decoding.path.plan.channels))
            }
            _ = nrt_ring_write(session.ring, data, frames)
        }
        if status == .error || status == .endOfStream || (decoding.inputExhausted && frames == 0) {
            decoding.finished = true
            if let error = conversionError ?? decoding.error {
                emit(.failed(decoding.item, error.localizedDescription))
            }
        }
        return true
    }

    /// The current item is fully decoded: line up the next one gaplessly, or wait for a device change.
    private func advance(after finished: PlayableItem, produced: UInt64) {
        decoding = nil
        guard let session, let device = sessionDevice else { return }
        if produced == 0 {
            emptyTransitions += 1
            if emptyTransitions >= 8 {
                draining = true
                nrt_context_set_draining(session.context, true)
                return
            }
        }
        var candidate = nextItemProvider?(finished)
        var attempts = 0
        while let next = candidate, attempts < 8 {
            attempts += 1
            do {
                let probed = try SourceOpener.probe(resolve(next))
                let bitstream = settings.bitstreamDeviceUIDs.contains(device.uid) && SourceInspector.canBitstream(probed.url, codec: probed.format.codec)
                if probed.format.codec == DolbyAtmos.codecName, settings.atmosBySystem, !bitstream {
                    // macOS renders Atmos: let this track play out, then hand the next one over.
                    pendingSystem = next
                    draining = true
                    nrt_context_set_draining(session.context, true)
                    return
                }
                var plan = FormatPlanner.plan(source: probed.format, device: device.capabilities,
                                              policy: settings.ratePolicies[device.uid] ?? .matchSource,
                                              spatial: settings.spatialMode(for: device), bitstream: bitstream)
                plan.integerSamples = wantsIntegerMode(plan, source: probed, item: next, device: device)
                if session.plan.isDeviceCompatible(with: plan) {
                    let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: next)
                    Self.alignDoPMarkers(decoder, at: session.totalWritten)
                    let d = try Decoding(item: next, probed: probed, decoder: decoder,
                                         path: makePath(probed: probed, plan: plan, device: device, session: session, item: next),
                                         chunk: chunkFrames, layout: session.decodedLayout)
                    d.streaming = isStreaming(next)
                    decoding = d
                    segments.append(Segment(item: next, path: d.path, startRingFrame: session.totalWritten,
                                            startOffsetSeconds: 0, durationSeconds: d.durationSeconds))
                } else {
                    // Different rate/format: let the ring play out, then reconfigure (a short gap is unavoidable).
                    pending = (next, probed, plan, device)
                    draining = true
                    nrt_context_set_draining(session.context, true)
                }
                return
            } catch {
                emit(.failed(next, error.localizedDescription))
                candidate = nextItemProvider?(next)
            }
        }
        draining = true
        nrt_context_set_draining(session.context, true)
    }

    private func checkTransitions() {
        guard let session else { return }
        underrunTotal += Int(nrt_context_take_underruns(session.context))

        if let segment = audibleSegment(), segment.id != lastAudibleSegmentID {
            lastAudibleSegmentID = segment.id
            emit(.trackStarted(segment.item))
            // Drop segments that are fully in the past.
            let read = session.totalRead
            if let index = segments.lastIndex(where: { $0.startRingFrame <= read }), index > 0 {
                segments.removeFirst(index)
            }
        }

        guard draining, session.readableFrames == 0 else { drainedAt = nil; return }
        // Let the device play out its own buffer before touching it.
        if drainedAt == nil { drainedAt = Date() }
        let tail = Double(session.applied.bufferFrames * 3) / session.applied.sampleRate + 0.05
        guard Date().timeIntervalSince(drainedAt!) >= tail else { return }
        drainedAt = nil
        if let next = pendingSystem {
            teardown(releaseHog: true)
            start(next, at: 0, autoplay: true)
            return
        }
        if let pending {
            self.pending = nil
            let startedAt = Date()
            do {
                try replaceSession(device: pending.device, plan: pending.plan)
                guard let session = self.session else { return }
                let decoder = try SourceOpener.decoder(for: pending.probed, plan: pending.plan, item: pending.item)
                let d = try Decoding(item: pending.item, probed: pending.probed, decoder: decoder,
                                     path: makePath(probed: pending.probed, plan: pending.plan, device: pending.device,
                                                    session: session, item: pending.item),
                                     chunk: chunkFrames, layout: session.decodedLayout)
                d.streaming = isStreaming(pending.item)
                decoding = d
                buffering = false
                segments = [Segment(item: pending.item, path: d.path, startRingFrame: session.totalWritten,
                                    startOffsetSeconds: 0, durationSeconds: d.durationSeconds)]
                draining = false
                prefill()
                try session.start()
                log.notice("Next song plays on \(pending.device.name, privacy: .public) at \(SampleRate.format(session.applied.sampleRate), privacy: .public) kHz after \(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public) ms")
            } catch {
                log.error("Next song couldn't start on \(pending.device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                emit(.failed(pending.item, error.localizedDescription))
                if let next = nextItemProvider?(pending.item) { start(next, at: 0, autoplay: true) }
                else { finishQueue() }
            }
        } else {
            finishQueue()
        }
    }

    private func finishQueue() {
        teardown(releaseHog: true)
        state = .stopped
        lastAudibleSegmentID = nil
        emit(.queueEnded)
    }

    // MARK: Position

    private func audibleSegment() -> Segment? {
        guard let session else { return segments.first }
        let read = session.totalRead
        return segments.last(where: { $0.startRingFrame <= read }) ?? segments.first
    }

    private func currentPosition() -> TimeInterval {
        if let atmos { return atmos.position }
        guard let session, let segment = audibleSegment() else { return parked?.position ?? 0 }
        let read = session.totalRead
        let played = read > segment.startRingFrame ? Double(read - segment.startRingFrame) / session.applied.sampleRate : 0
        return min(segment.startOffsetSeconds + played, segment.durationSeconds)
    }

    private func publishSnapshot() {
        let segment = audibleSegment()
        let position = currentPosition()
        var path = segment?.path
        if path?.plan.mode == .pcm {
            if let db = settings.digitalVolume(for: sessionDevice) { path?.volume = .digital(dB: db) }
            else { path?.volume = sessionDevice?.hasHardwareVolume == true ? .hardware : .fixed }
        }
        if let path, !path.applied.exclusive, let device = sessionDevice {
            if Date().timeIntervalSince(othersCheckedAt) > 1 || othersDevice != device.id {
                othersPlaying = DeviceControl.otherProcessesPlaying(to: device.id)
                othersCheckedAt = Date()
                othersDevice = device.id
            }
        } else {
            othersPlaying = false
        }
        path?.otherAppsPlaying = othersPlaying
        let device = sessionDevice
        let st = state
        let underruns = underrunTotal
        let parkedItem = parked
        let waiting = awaitingDevice.map { deviceName($0.uid) }
        let fromShare = decoding?.streaming == true
        let system = atmos
        shared.withLock { s in
            s.snapshot.state = st
            s.snapshot.item = segment?.item ?? system?.item ?? parkedItem?.item
            s.snapshot.position = segment == nil && system == nil ? (parkedItem?.position ?? 0) : position
            s.snapshot.duration = segment?.durationSeconds ?? system?.duration ?? s.snapshot.duration
            s.snapshot.systemRendering = system?.rendering
            s.snapshot.signalPath = path
            s.snapshot.underruns = underruns
            s.snapshot.isBuffering = buffering
            s.snapshot.waitingForDevice = waiting
            s.snapshot.readingFromShare = fromShare
            s.snapshot.outputDevice = device
            if st == .stopped && parkedItem == nil { s.snapshot.item = nil; s.snapshot.position = 0; s.snapshot.signalPath = nil }
        }
    }
}
