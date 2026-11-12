//
// Vespertine: plays the DoP test clip to one DAC, quietly, and stops at any sign of trouble.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

/// One run of the first-DSD test for an output that isn't on the known-DoP list. It
/// - lowers the DAC's own volume to `DoPTestConstants.hardwareVolumeCap` when it is higher (and puts it back after),
/// - plays the clip through its own engine, forced to DoP for this output only, with nothing else in the chain
///   (no EQ, room correction, spatial or transitions: anything that changes the samples would stop DoP being DoP),
/// - checks the engine really planned DoP, and that the audio device list and default output never change,
/// - and only then lets the listener answer. Any doubt ends it, silences it and saves nothing.
///
/// The caller pauses its own playback first: the DAC is this session's alone while the clip plays.
public final class DoPTestSession: @unchecked Sendable {
    public enum Reason: Equatable, Sendable {
        case deviceChanged
        case notPlayedAsDoP
        case failed(String)
        case cancelled
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case playing
        case awaitingAnswer
        case aborted(Reason)
        case done
    }

    public let device: OutputDevice
    private let exclusive: Bool
    private let state = Locked(State())
    /// Called on a private queue whenever the phase changes.
    public var onPhase: (@Sendable (Phase) -> Void)?

    private struct State {
        var phase = Phase.idle
        var playedAsDoP = false
        var maxPosition: TimeInterval = 0
        var startedAt = Date.distantPast
        var guardStart: DoPTestGuard.Snapshot?
        var engine: PlaybackEngine?
        var timer: DispatchSourceTimer?
        var savedVolumes: [(element: UInt32, value: Float)] = []
        var file: URL?
    }

    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.dop-test")

    public init(device: OutputDevice, exclusive: Bool) {
        self.device = device
        self.exclusive = exclusive
    }

    public var phase: Phase { state.withLock { $0.phase } }

    private func set(_ phase: Phase) {
        state.withLock { $0.phase = phase }
        onPhase?(phase)
    }

    private func snapshot() -> DoPTestGuard.Snapshot {
        let defaultUID = DeviceQuery.defaultOutputDeviceID().flatMap { HAL.getString($0, .global(kAudioDevicePropertyDeviceUID)) }
        return DoPTestGuard.Snapshot(outputUIDs: DeviceQuery.outputUIDs(), defaultOutput: defaultUID, target: device.uid)
    }

    public func start() {
        queue.async { [self] in
            guard phase == .idle else { return }
            set(.starting)
            let start = snapshot()
            guard start.outputUIDs.contains(device.uid) else { return finish(.aborted(.deviceChanged)) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-dop-test-\(UUID().uuidString).dsf")
            do { try DoPTestClip.make().dsfData.write(to: url) } catch { return finish(.aborted(.failed("couldn't write the test clip"))) }
            lowerVolume()
            var settings = EngineSettings()
            settings.exclusive = exclusive
            settings.deviceUID = device.uid
            settings.deviceName = device.name
            settings.dopDeviceUIDs = [device.uid]
            settings.outputFallback = .waitForChosen        // never play the clip on some other output
            settings.releaseExclusiveAfterPause = 0
            let engine = PlaybackEngine()
            engine.update(settings: settings)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
            timer.setEventHandler { [weak self] in self?.poll() }
            state.withLock {
                $0.guardStart = start; $0.engine = engine; $0.timer = timer; $0.file = url; $0.startedAt = Date()
            }
            timer.resume()
            engine.play(PlayableItem(url: url))
        }
    }

    public func cancel() {
        queue.async { [self] in
            switch phase {
            case .starting, .playing: finish(.aborted(.cancelled))
            case .awaitingAnswer: finish(.aborted(.cancelled))
            default: break
            }
        }
    }

    /// The listener's answer, if one may be taken now: the clip played as DoP, to the end, with no device change.
    /// Returns the outcome to save, or nil (and saves nothing) otherwise.
    public func answer(_ outcome: DoPTestOutcome) -> DoPTestOutcome? {
        queue.sync {
            let (played, aborted) = state.withLock { ($0.playedAsDoP, { if case .aborted = $0.phase { return true } else { return false } }($0)) }
            guard phase == .awaitingAnswer, DoPTestGuard.mayAnswer(playedAsDoP: played, aborted: aborted) else { return nil }
            finish(.done)
            return outcome
        }
    }

    // MARK: Running

    private func poll() {
        let (start, engine, startedAt) = state.withLock { ($0.guardStart, $0.engine, $0.startedAt) }
        guard let start, let engine, phase == .starting || phase == .playing else { return }
        if DoPTestGuard.shouldAbort(start: start, now: snapshot()) { return finish(.aborted(.deviceChanged)) }
        let snap = engine.snapshot
        if let error = snap.lastError, !error.isEmpty { return finish(.aborted(.failed(error))) }
        if let path = snap.signalPath {
            if path.plan.mode == .dop {
                state.withLock { $0.playedAsDoP = true }
                if phase == .starting { set(.playing) }
            } else {
                return finish(.aborted(.notPlayedAsDoP))
            }
        } else if phase == .starting, Date().timeIntervalSince(startedAt) > 8 {
            return finish(.aborted(.notPlayedAsDoP))
        }
        let (played, furthest) = state.withLock { s -> (Bool, TimeInterval) in
            s.maxPosition = max(s.maxPosition, snap.position)
            return (s.playedAsDoP, s.maxPosition)
        }
        guard played else { return }
        if furthest >= DoPTestConstants.clipSeconds - 0.15 || (snap.state == .stopped && furthest > 0) {
            if furthest < DoPTestConstants.clipSeconds - 0.5 { return finish(.aborted(.failed("the clip stopped early"))) }
            // Played to its end: silence and tidy up first, then ask.
            tearDown()
            set(.awaitingAnswer)
        }
    }

    private func finish(_ phase: Phase) {
        tearDown()
        set(phase)
    }

    /// Stops the engine, gives the DAC back and puts its volume where it was. Safe to call more than once.
    private func tearDown() {
        let (engine, timer, file) = state.withLock { s -> (PlaybackEngine?, DispatchSourceTimer?, URL?) in
            defer { s.engine = nil; s.timer = nil; s.file = nil }
            return (s.engine, s.timer, s.file)
        }
        timer?.cancel()
        engine?.stopAndWait(timeout: 2)
        restoreVolume()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Level cap

    private func lowerVolume() {
        let id = device.id
        let elements = DeviceQuery.volumeElements(id)
        var saved: [(UInt32, Float)] = []
        for element in elements {
            guard let value = try? HAL.get(id, .output(kAudioDevicePropertyVolumeScalar, element: element), initial: Float32(0)),
                  let target = DoPTestSafety.volumeToSet(current: value, cap: DoPTestConstants.hardwareVolumeCap) else { continue }
            saved.append((element, value))
            try? HAL.set(id, .output(kAudioDevicePropertyVolumeScalar, element: element), Float32(target))
        }
        state.withLock { $0.savedVolumes = saved.map { (element: $0.0, value: $0.1) } }
    }

    private func restoreVolume() {
        let saved = state.withLock { s -> [(element: UInt32, value: Float)] in defer { s.savedVolumes = [] }; return s.savedVolumes }
        for (element, value) in saved {
            try? HAL.set(device.id, .output(kAudioDevicePropertyVolumeScalar, element: element), Float32(value))
        }
    }
}
