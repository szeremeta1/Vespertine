//
// Nocturne — the playback engine.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// decoder → AVAudioConverter (format, and SRC only when needed) → lock-free ring → HAL IOProc
//
// One dedicated thread owns decoding and device configuration. The public API only
// posts commands, so callers never block on Core Audio or disk I/O.
//

import Accelerate
import AVFAudio
import CNocturneRT
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
}

public enum EngineEvent: Sendable {
    /// The item became audible (not merely decoded).
    case trackStarted(PlayableItem)
    case queueEnded
    case failed(PlayableItem?, String)
    case deviceLost(String)
}

public struct EngineSettings: Sendable, Equatable {
    public var exclusive = true
    public var deviceUID: String?                 // nil = follow system default output
    public var dopDeviceUIDs: Set<String> = []
    public var ratePolicies: [String: RatePolicy] = [:]
    public var releaseExclusiveAfterPause: TimeInterval = 30
    /// nil = no software volume (hardware or fixed).
    public var digitalVolumeDB: Double?

    public init() {}
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

    private enum Command {
        case play(PlayableItem)
        case pause, resume, stop
        case seek(TimeInterval)
        case settingsChanged(EngineSettings)
        case devicesChanged, queueChanged
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
        let probed: ProbedSource
        let decoder: PCMDecoding
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
        let path: SignalPath
        let gain: Float
        var inputExhausted = false
        var finished = false
        var framesProduced: UInt64 = 0
        var error: Error?

        init(item: PlayableItem, probed: ProbedSource, decoder: PCMDecoding, path: SignalPath, chunk: AVAudioFrameCount) throws {
            self.item = item
            self.probed = probed
            self.decoder = decoder
            self.path = path
            guard let outFormat = AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: path.plan.channels, interleaved: true),
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
    private var segments: [Segment] = []
    private var state: PlaybackState = .stopped
    private var settings = EngineSettings()
    private var draining = false
    private var drainedAt: Date?
    private var pausedAt: Date?
    private var parked: (item: PlayableItem, position: TimeInterval)?
    private var lastAudibleSegmentID: UUID?
    private var underrunTotal = 0
    private var emptyTransitions = 0
    private let chunkFrames: AVAudioFrameCount = 4096

    public init() {
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                guard let self else { return }
                self.runIteration()
            }
        }
        thread.name = "Nocturne Engine"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    deinit {
        thread?.cancel()
        teardown(releaseHog: true)
    }

    // MARK: Public API

    public func play(_ item: PlayableItem) { post(.play(item)) }
    public func pause() { post(.pause) }
    public func resume() { post(.resume) }
    public func stop() { post(.stop) }
    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        post(.seek(max(0, seconds)))
    }
    /// Discards decoded look-ahead after the play order changes.
    public func queueChanged() { post(.queueChanged) }
    public func devicesChanged() { post(.devicesChanged) }

    public func update(settings: EngineSettings) {
        let changed = shared.withLock { s -> Bool in
            guard s.settings != settings else { return false }
            s.settings = settings
            return true
        }
        if changed { post(.settingsChanged(settings)) }
    }

    public var snapshot: EngineSnapshot { shared.withLock { $0.snapshot } }

    /// Peak levels (linear) since the previous call.
    public func takePeaks() -> (left: Float, right: Float) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let ctx = session?.context else { return (0, 0) }
        return (nrt_context_take_peak(ctx, 0), nrt_context_take_peak(ctx, 1))
    }

    /// Copies the latest mono samples sent to the DAC. Returns the device sample rate, or nil when idle.
    public func copyTap(into buffer: inout [Float]) -> Double? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let session, !buffer.isEmpty else { return nil }
        let n = UInt32(min(buffer.count, Int(NRT_TAP_SIZE)))
        buffer.withUnsafeMutableBufferPointer { _ = nrt_context_copy_tap(session.context, $0.baseAddress!, n) }
        return session.applied.sampleRate
    }

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
            for command in commands { handle(command) }

            var didWork = false
            if state == .playing {
                didWork = fill()
                checkTransitions()
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

    private func handle(_ command: Command) {
        switch command {
        case .play(let item):
            teardownDecoding()
            session?.flush()
            parked = nil
            start(item, at: 0, autoplay: true)
        case .pause:
            guard state == .playing else { return }
            session?.stop()
            state = .paused
            pausedAt = Date()
        case .resume:
            if state == .paused, let session {
                do { try session.start(); state = .playing; pausedAt = nil }
                catch { restartFromCurrentPosition() }
            } else if state == .paused || state == .stopped, let parked {
                self.parked = nil
                start(parked.item, at: parked.position, autoplay: true)
            }
        case .stop:
            teardown(releaseHog: true)
            parked = nil
            state = .stopped
            lastAudibleSegmentID = nil
        case .seek(let seconds):
            guard let current = audibleSegment()?.item ?? parked?.item else { return }
            let resume = state == .playing
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
            if deviceChanged, state != .stopped { restartFromCurrentPosition() }
        case .queueChanged:
            if state != .stopped { restartFromCurrentPosition() }
        case .devicesChanged:
            guard let device = sessionDevice else { return }
            let alive = DeviceQuery.allDeviceIDs().contains(device.id)
            if !alive {
                let position = currentPosition()
                let item = audibleSegment()?.item
                teardown(releaseHog: false)
                if let item { parked = (item, position) }
                state = parked == nil ? .stopped : .paused
                emit(.deviceLost(device.name))
            }
            // Deliberately *not* following system-default changes mid-playback: hogging the default device makes
            // macOS move the default elsewhere, and chasing it would restart playback in a loop. The new default
            // is picked up at the next play.
        }
    }

    // MARK: Starting and stopping

    private func resolveDevice() -> OutputDevice? {
        let devices = DeviceQuery.outputDevices(dopEnabledUIDs: settings.dopDeviceUIDs)
        if let uid = settings.deviceUID, let chosen = devices.first(where: { $0.uid == uid }) { return chosen }
        // Following the default: stay on the device we already hold (our hog moved the system default away from it).
        if settings.deviceUID == nil, let current = sessionDevice, let alive = devices.first(where: { $0.id == current.id }) { return alive }
        return devices.first(where: \.isDefault) ?? devices.first
    }

    private func start(_ item: PlayableItem, at seconds: TimeInterval, autoplay: Bool) {
        var candidate: PlayableItem? = item
        var offset = seconds
        var attempts = 0
        while let current = candidate, attempts < 8 {
            attempts += 1
            do {
                try begin(current, at: offset)
                if autoplay {
                    try session?.start()
                    state = .playing
                } else {
                    state = .paused
                    pausedAt = Date()
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
        guard let device = resolveDevice() else { throw CoreAudioError(kAudioHardwareBadDeviceError, "find an output device") }
        let probed = try SourceOpener.probe(resolve(item))
        let plan = FormatPlanner.plan(source: probed.format, device: device.capabilities,
                                      policy: settings.ratePolicies[device.uid] ?? .matchSource)
        if session == nil || sessionDevice?.id != device.id || !(session!.plan.isDeviceCompatible(with: plan)) {
            try replaceSession(device: device, plan: plan)
        } else {
            session?.flush()
        }
        guard let session else { return }
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
        var actualOffset = 0.0
        if seconds > 0, decoder.supportsSeeking, decoder.length > 0 {
            let bounded = min(seconds * decoder.processingFormat.sampleRate, Double(max(0, decoder.length - 1)))
            let frame = AVAudioFramePosition(bounded)
            try decoder.seek(to: frame)
            actualOffset = Double(frame) / decoder.processingFormat.sampleRate
        }
        let decoding = try Decoding(item: item, probed: probed, decoder: decoder,
                                    path: makePath(probed: probed, plan: plan, device: device, session: session, item: item),
                                    chunk: chunkFrames)
        self.decoding = decoding
        segments = [Segment(item: item, path: decoding.path, startRingFrame: session.totalWritten,
                            startOffsetSeconds: actualOffset, durationSeconds: decoding.durationSeconds)]
        draining = false
        nrt_context_set_draining(session.context, false)
        lastAudibleSegmentID = nil
        prefill()
    }

    private func replaceSession(device: OutputDevice, plan: OutputPlan) throws {
        sessionLock.lock()
        let old = session
        session = nil
        sessionLock.unlock()
        old?.invalidate(releaseHog: true)
        let new = try OutputSession(deviceID: device.id, plan: plan, exclusive: settings.exclusive)
        sessionLock.lock()
        session = new
        sessionDevice = device
        sessionLock.unlock()
        applyGain()
    }

    private func makePath(probed: ProbedSource, plan: OutputPlan, device: OutputDevice, session: OutputSession, item: PlayableItem) -> SignalPath {
        let volume: SignalPath.VolumeStage
        if let db = settings.digitalVolumeDB, plan.mode == .pcm { volume = .digital(dB: db) }
        else if device.hasHardwareVolume { volume = .hardware }
        else { volume = .fixed }
        return SignalPath(source: probed.format, decoderName: probed.decoderName, plan: plan, applied: session.applied,
                          deviceName: device.name, deviceUID: device.uid, deviceProfile: device.profile, volume: volume,
                          replayGainDB: plan.mode == .pcm ? item.replayGainDB : nil)
    }

    private func applyGain() {
        guard let session else { return }
        let db = session.plan.mode == .dop ? 0 : (settings.digitalVolumeDB ?? 0)
        nrt_context_set_gain(session.context, db == 0 ? 1.0 : pow(10, db / 20), UInt32(session.applied.physicalBitDepth))
    }

    private func teardownDecoding() {
        decoding = nil
        pending = nil
        segments.removeAll()
        draining = false
        drainedAt = nil
    }

    private func teardown(releaseHog: Bool) {
        teardownDecoding()
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
        if let item = audibleSegment()?.item { parked = (item, position) }
        teardown(releaseHog: true)
        pausedAt = nil
    }

    private func restartFromCurrentPosition() {
        guard let item = audibleSegment()?.item ?? parked?.item else { return }
        let position = parked?.position ?? currentPosition()
        let wasPlaying = state == .playing
        teardown(releaseHog: true)
        parked = nil
        start(item, at: position, autoplay: wasPlaying)
    }

    // MARK: Decoding

    private func prefill() {
        guard let session else { return }
        let target = min(Int(session.applied.sampleRate * 0.3), Int(nrt_ring_capacity(session.ring)) / 2)
        // Bound work so a repeating empty/corrupt track cannot monopolize the engine thread.
        for _ in 0..<256 {
            if session.readableFrames >= target || !fill() { break }
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
            advance(after: decoding)
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
        if frames > 0, let data = decoding.output.floatChannelData?[0] {
            decoding.framesProduced += UInt64(frames)
            emptyTransitions = 0
            if decoding.gain != 1 {
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
    private func advance(after finished: Decoding) {
        decoding = nil
        guard let session, let device = sessionDevice else { return }
        if finished.framesProduced == 0 {
            emptyTransitions += 1
            if emptyTransitions >= 8 {
                draining = true
                nrt_context_set_draining(session.context, true)
                return
            }
        }
        var candidate = nextItemProvider?(finished.item)
        var attempts = 0
        while let next = candidate, attempts < 8 {
            attempts += 1
            do {
                let probed = try SourceOpener.probe(resolve(next))
                let plan = FormatPlanner.plan(source: probed.format, device: device.capabilities,
                                              policy: settings.ratePolicies[device.uid] ?? .matchSource)
                if session.plan.isDeviceCompatible(with: plan) {
                    let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: next)
                    let d = try Decoding(item: next, probed: probed, decoder: decoder,
                                         path: makePath(probed: probed, plan: plan, device: device, session: session, item: next),
                                         chunk: chunkFrames)
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
        if let pending {
            self.pending = nil
            do {
                try replaceSession(device: pending.device, plan: pending.plan)
                guard let session = self.session else { return }
                let decoder = try SourceOpener.decoder(for: pending.probed, plan: pending.plan, item: pending.item)
                let d = try Decoding(item: pending.item, probed: pending.probed, decoder: decoder,
                                     path: makePath(probed: pending.probed, plan: pending.plan, device: pending.device,
                                                    session: session, item: pending.item),
                                     chunk: chunkFrames)
                decoding = d
                segments = [Segment(item: pending.item, path: d.path, startRingFrame: session.totalWritten,
                                    startOffsetSeconds: 0, durationSeconds: d.durationSeconds)]
                draining = false
                prefill()
                try session.start()
            } catch {
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
            if let db = settings.digitalVolumeDB { path?.volume = .digital(dB: db) }
            else { path?.volume = sessionDevice?.hasHardwareVolume == true ? .hardware : .fixed }
        }
        let device = sessionDevice
        let st = state
        let underruns = underrunTotal
        let parkedItem = parked
        shared.withLock { s in
            s.snapshot.state = st
            s.snapshot.item = segment?.item ?? parkedItem?.item
            s.snapshot.position = segment == nil ? (parkedItem?.position ?? 0) : position
            s.snapshot.duration = segment?.durationSeconds ?? s.snapshot.duration
            s.snapshot.signalPath = path
            s.snapshot.underruns = underruns
            s.snapshot.outputDevice = device
            if st == .stopped && parkedItem == nil { s.snapshot.item = nil; s.snapshot.position = 0; s.snapshot.signalPath = nil }
        }
    }
}
