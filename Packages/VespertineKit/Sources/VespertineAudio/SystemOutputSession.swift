//
// Vespertine: Mac Sound Output (beta): one published group playing. What other apps play to the group's output arrives at the
// driver's capture side; a private aggregate puts that capture device (first, so its channels are the first inputs) together with
// the group's DACs (the clock leader as the time base, everything else drift-corrected to it). Each I/O cycle the input is routed
// onto the group's speakers and rendered through the same chain as music in Vespertine: room correction, speaker delays and trims.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two ways through:
//   direct   the I/O thread routes by a gain matrix in the cycle the sound arrived (`nrt_live_ioproc`). A worker only watches
//            the input's peaks to tell stereo from surround and swaps the matrix when that changes.
//   upmix    stereo is upmixed to 5.1 (`StereoUpmixer`), which can't run on the I/O thread, so the worker does all the routing:
//            the upmixer's 5.1 for a stereo source, the input itself (held back by the same amount) for a surround one, so the
//            delay never changes when the source does. The render ring starts with enough silence to cover the worker's turn.
//

import CVespertineRT
import CoreAudio
import Foundation
import os

private let systemOutputLog = Logger(subsystem: "org.szeremeta.vespertine", category: "SystemOutput")

final class SystemOutputSession: @unchecked Sendable {
    let entry: SystemOutputEntry
    let rate: Double
    /// Frames from an app handing a sample to the output until it leaves the speakers (an estimate: what the driver reports so
    /// players hold the picture back by as much).
    private(set) var latencyFrames = 0

    private let members: GroupMemberSession
    private let aggregate: GroupAggregateDevice
    private let captureRing: OpaquePointer
    private let renderRing: OpaquePointer
    private let capture: OpaquePointer
    private let context: OpaquePointer
    private let live: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private let inputLabels: [AudioChannelLabel]
    private let outputChannels: Int
    private let bufferFrames: Int
    private let upmixMode: Bool

    private let state = OSAllocatedUnfairLock(initialState: WorkerState())
    private var worker: Thread?

    private struct WorkerState {
        var running = true
        var content: SystemOutputContent = .stereo
    }

    /// Opens the group for `entry` and starts playing what arrives at `captureDevice`. `rate`: the output's own rate (what apps
    /// send at); the DACs are set to it.
    init(entry: SystemOutputEntry, captureDevice: AudioObjectID, rate: Double) throws {
        self.entry = entry
        self.rate = rate
        let group = entry.group
        inputLabels = entry.labels
        outputChannels = group.totalChannels
        upmixMode = entry.choice.stereo == .upmix && inputLabels.count > 2
        guard outputChannels > 0, outputChannels <= SystemOutput.maxChannels, !inputLabels.isEmpty else {
            throw CoreAudioError(kAudioHardwareIllegalOperationError, "route \(inputLabels.count) channels onto \(outputChannels)")
        }

        // The DACs, in the group's order, at the output's rate.
        let listed = DeviceQuery.outputDevices(dopEnabledUIDs: [])
        var devices: [OutputDevice] = []
        for member in group.members {
            guard let device = listed.first(where: { $0.uid == member.deviceUID }) else { throw GroupMemberError.gone(member.name) }
            devices.append(device)
        }
        let members = try GroupMemberSession.begin(devices: devices, rate: rate, exclusive: entry.exclusive)
        if let wrong = GroupApplied.memberNotAt(rate, members.members) {
            members.release()
            throw GroupMemberError.rateRefused(uid: wrong, name: devices.first { $0.uid == wrong }?.name ?? wrong, rate: rate)
        }
        self.members = members
        DriverRate.set(rate, on: captureDevice)

        let aggregate: GroupAggregateDevice
        do {
            let plan = try GroupAggregate.plan(for: group, capture: entry.captureUID, clockDomain: { GroupAggregateDevice.clockDomain(uid: $0) })
            aggregate = try GroupAggregateDevice.create(plan)
        } catch {
            members.release()
            throw error
        }
        self.aggregate = aggregate

        let buffer = Int((try? HAL.get(aggregate.id, .global(kAudioDevicePropertyBufferFrameSize), initial: UInt32(512))) ?? 512)
        bufferFrames = buffer
        let maxSlice = UInt32(max(buffer * 2, 4096))
        let ringFrames = UInt32(max(rate, 44_100) * 2)
        guard let captureRing = nrt_ring_create(ringFrames, UInt32(inputLabels.count)),
              let renderRing = nrt_ring_create(ringFrames, UInt32(outputChannels)) else {
            aggregate.destroy(); members.release()
            throw CoreAudioError(-1, "allocate ring buffers")
        }
        guard let capture = nrt_capture_create(captureRing, maxSlice), let context = nrt_context_create(renderRing, maxSlice) else {
            nrt_ring_destroy(captureRing); nrt_ring_destroy(renderRing)
            aggregate.destroy(); members.release()
            throw CoreAudioError(-1, "allocate render context")
        }
        guard let live = nrt_live_create(capture, captureRing, context, renderRing, maxSlice) else {
            nrt_capture_destroy(capture); nrt_context_destroy(context)
            nrt_ring_destroy(captureRing); nrt_ring_destroy(renderRing)
            aggregate.destroy(); members.release()
            throw CoreAudioError(-1, "allocate live router")
        }
        self.captureRing = captureRing
        self.renderRing = renderRing
        self.capture = capture
        self.context = context
        self.live = live

        // Room correction, speaker delays, trims and polarity: the group's chain, as music plays it.
        let resampled = Set(zip(aggregate.plan.members, aggregate.plan.drift).filter { !$0.0.inputOnly && $0.1 }.map(\.0.uid))
        let room = GroupDelay.chain(entry.room, group: group, resampled: resampled, rate: rate)
        RoomCorrectionPlayback.install(room, on: context, sampleRate: rate, channelCount: outputChannels)
        if !RoomCorrectionPlayback.installFilters(room?.impulseTaps(sampleRate: rate, channelCount: outputChannels), on: context) {
            systemOutputLog.error("Not enough memory for the room correction filters; playing without them")
        }

        // The routing to start with: a stereo source until the input says otherwise.
        var upmixLatency = 0
        if upmixMode {
            nrt_live_set_diverted(live, true)
            upmixLatency = UpmixRouting.latency(rate: rate) + UpmixRouting.prefill(rate: rate, bufferFrames: buffer)
        } else {
            applyMatrix(for: .stereo)
        }

        // Latency: the driver's own (about a buffer each way), the aggregate's buffer, the DACs' reported latency, and the upmixer's.
        let outputLatency = (try? HAL.get(aggregate.id, .output(kAudioDevicePropertyLatency), initial: UInt32(0))) ?? 0
        let safety = (try? HAL.get(aggregate.id, .output(kAudioDevicePropertySafetyOffset), initial: UInt32(0))) ?? 0
        latencyFrames = Int(outputLatency) + Int(safety) + 3 * buffer + upmixLatency

        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(aggregate.id, nrt_live_ioproc, UnsafeMutableRawPointer(live), &id)
        guard status == noErr, let id else {
            teardown()
            throw CoreAudioError(status, "AudioDeviceCreateIOProcID")
        }
        procID = id
        startWorker()
        let started = AudioDeviceStart(aggregate.id, id)
        guard started == noErr else {
            stop()
            throw CoreAudioError(started, "AudioDeviceStart")
        }
        systemOutputLog.info("Mac Sound Output playing \(group.name, privacy: .private) at \(Int(rate)) Hz, \(self.inputLabels.count) channels in, \(self.outputChannels) out")
    }

    /// The group's DACs are all still there and running in the aggregate.
    var membersPresent: Bool {
        let atStart = aggregate.plan.members.filter { !$0.inputOnly }.map(\.uid)
        return GroupAggregateDevice.membersPresent(atStart: atStart, now: GroupAggregateDevice.activeMemberUIDs(of: aggregate.id),
                                                   connected: GroupAggregateDevice.isConnected(uid:))
    }

    /// `keepHolding`: hand the DACs' exclusive access on (Vespertine takes the group over).
    func stop(keepHolding: Bool = false) {
        state.withLock { $0.running = false }
        if let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            self.procID = nil
        }
        while worker?.isFinished == false { usleep(1000) }
        worker = nil
        teardown(keepHolding: keepHolding)
    }

    private var tornDown = false
    private func teardown(keepHolding: Bool = false) {
        guard !tornDown else { return }
        tornDown = true
        aggregate.destroy()
        members.release(keepHolding: keepHolding)
        nrt_live_destroy(live)
        nrt_capture_destroy(capture)
        nrt_context_destroy(context)
        nrt_ring_destroy(captureRing)
        nrt_ring_destroy(renderRing)
    }

    deinit { stop() }

    // MARK: Routing

    private func applyMatrix(for content: SystemOutputContent) {
        guard let gains = SystemOutputRouting.matrix(input: inputLabels, group: entry.group, content: content, stereo: entry.choice.stereo) else { return }
        // Direct mode never takes the upmixer's six inputs: stereo under `upmix` on a two-channel output plays as the group does.
        let inputs = gains.count / max(outputChannels, 1)
        if inputs == inputLabels.count {
            gains.withUnsafeBufferPointer { _ = nrt_live_set_matrix(live, $0.baseAddress!, UInt32(outputChannels), UInt32(inputs)) }
        } else if let plain = SystemOutputRouting.matrix(input: inputLabels, group: entry.group, content: content, stereo: .asGroup) {
            plain.withUnsafeBufferPointer { _ = nrt_live_set_matrix(live, $0.baseAddress!, UInt32(outputChannels), UInt32(inputLabels.count)) }
        }
    }

    private func startWorker() {
        let thread = Thread { [unowned self] in
            if self.upmixMode { self.runUpmix() } else { self.runDirect() }
        }
        thread.name = "Mac Sound Output"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()
    }

    private var running: Bool { state.withLock { $0.running } }

    /// Direct mode: watch the peaks every 50 ms and swap the matrix when stereo turns into surround or back.
    private func runDirect() {
        var detector = SystemOutputContentDetector(input: inputLabels)
        var peaks = [Float](repeating: 0, count: inputLabels.count)
        let interval = 0.05
        while running {
            usleep(UInt32(interval * 1_000_000))
            for c in peaks.indices { peaks[c] = nrt_live_take_peak(live, UInt32(c)) }
            if detector.update(peaks: peaks, seconds: interval) {
                let content = detector.content
                state.withLock { $0.content = content }
                applyMatrix(for: content)
            }
        }
    }

    /// Upmix mode: the worker routes everything, a hop at a time.
    private func runUpmix() {
        guard var routing = UpmixRouting(input: inputLabels, group: entry.group, rate: rate, settings: entry.upmix) else {
            // No upmixer at this rate: play as the group does, in the I/O cycle.
            applyMatrix(for: .stereo)
            nrt_live_set_diverted(live, false)
            runDirect()
            return
        }
        let prefill = UpmixRouting.prefill(rate: rate, bufferFrames: bufferFrames)
        let silence = [Float](repeating: 0, count: prefill * outputChannels)
        silence.withUnsafeBufferPointer { _ = nrt_ring_write(renderRing, $0.baseAddress!, UInt32(prefill)) }
        var input = [Float](repeating: 0, count: routing.hop * inputLabels.count)
        var output = [Float](repeating: 0, count: routing.hop * outputChannels)
        while running {
            guard nrt_ring_readable(captureRing) >= UInt32(routing.hop) else { usleep(1000); continue }
            let got = input.withUnsafeMutableBufferPointer { nrt_ring_read(captureRing, $0.baseAddress!, UInt32(routing.hop)) }
            guard Int(got) == routing.hop else { continue }
            let changed = input.withUnsafeBufferPointer { inBuffer in
                output.withUnsafeMutableBufferPointer { outBuffer in
                    routing.process(inBuffer.baseAddress!, into: outBuffer.baseAddress!)
                }
            }
            if changed {
                let content = routing.content
                state.withLock { $0.content = content }
            }
            output.withUnsafeBufferPointer { _ = nrt_ring_write(renderRing, $0.baseAddress!, UInt32(routing.hop)) }
        }
    }
}

/// The driver's output and its capture side share a clock: setting one sets both. A wrapper so a failed set is just ignored
/// (the aggregate resamples the capture side then).
private enum DriverRate {
    static func set(_ rate: Double, on device: AudioObjectID) {
        if abs(SystemOutputDriver.nominalRate(device) - rate) >= 0.5 { SystemOutputDriver.setNominalRate(rate, on: device) }
    }
}

// MARK: - Upmix routing (pure: tested without a device)

/// Upmix mode's routing of one hop of input: the stereo source upmixed to 5.1 and placed on the group, or the surround source
/// held back by the upmixer's latency and placed as it is; which one, the peaks decide. A change crossfades over one hop.
struct UpmixRouting {
    let hop: Int
    private let inputChannels: Int
    private let outputChannels: Int
    private let upmixer: StereoUpmixer
    private let upmixRouter: PositionRouter?
    private let surroundRouter: PositionRouter?
    private let front: (left: Int, right: Int)
    private var detector: SystemOutputContentDetector
    private(set) var content: SystemOutputContent
    /// What `content` was before the hop now being played (they differ for the one hop that crossfades).
    private var previous: SystemOutputContent
    // The input held back by the upmixer's latency, as a ring of whole frames.
    private var delay: [Float]
    private var delayPosition = 0
    // Scratch, sized once.
    private var stereo: [Float]
    private var upmixed: [Float] = []
    private var held: [Float]
    private var fromUpmix: [Float]
    private var fromSurround: [Float]
    private var peaks: [Float]

    /// The upmixer's STFT frame at `rate` (as `StereoUpmixer` picks it: about 43 ms).
    static func frameSize(rate: Double) -> Int {
        var n = 2048
        while Double(n) / rate < 0.03 && n < 32_768 { n *= 2 }
        return n
    }

    /// The upmixer's latency at `rate`: its frame less a hop.
    static func latency(rate: Double) -> Int { frameSize(rate: rate) - frameSize(rate: rate) / 4 }

    /// Silence the render ring starts with in upmix mode: a hop (the worker waits for a whole one) and two buffers of slack.
    static func prefill(rate: Double, bufferFrames: Int) -> Int {
        frameSize(rate: rate) / 4 + 2 * max(bufferFrames, 64)
    }

    init?(input: [AudioChannelLabel], group: SpeakerGroup, rate: Double, settings: UpmixSettings) {
        guard let upmixer = StereoUpmixer(inputChannels: 2, sampleRate: rate, settings: settings) else { return nil }
        self.upmixer = upmixer
        hop = upmixer.hop
        inputChannels = input.count
        outputChannels = group.totalChannels
        upmixRouter = SystemOutputRouting.router(input: input, group: group, content: .stereo, stereo: .upmix)
        surroundRouter = SystemOutputRouting.router(input: input, group: group, content: .multichannel, stereo: .upmix)
        front = SystemOutputRouting.frontPair(input)
        detector = SystemOutputContentDetector(input: input)
        content = detector.content
        previous = content
        delay = [Float](repeating: 0, count: upmixer.latency * input.count)
        stereo = [Float](repeating: 0, count: hop * 2)
        held = [Float](repeating: 0, count: hop * input.count)
        fromUpmix = [Float](repeating: 0, count: hop * group.totalChannels)
        fromSurround = fromUpmix
        peaks = [Float](repeating: 0, count: input.count)
        upmixed.reserveCapacity(hop * StereoUpmixer.outputChannels * 2)
    }

    /// Frames of delay from input to output.
    var latency: Int { upmixer.latency }

    /// One hop of interleaved input in, one hop of interleaved group channels out. True when the content changed.
    mutating func process(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>) -> Bool {
        // Peaks for the detector.
        for c in 0..<inputChannels { peaks[c] = 0 }
        for f in 0..<hop {
            for c in 0..<inputChannels { peaks[c] = max(peaks[c], abs(input[f * inputChannels + c])) }
        }
        let changed = detector.update(peaks: peaks, seconds: Double(hop) / max(upmixer.sampleRate, 1))
        previous = content
        content = detector.content

        // The stereo pair through the upmixer: exactly a hop comes out once its latency has passed (silence before).
        for f in 0..<hop {
            stereo[f * 2] = input[f * inputChannels + front.left]
            stereo[f * 2 + 1] = input[f * inputChannels + front.right]
        }
        upmixed.removeAll(keepingCapacity: true)
        stereo.withUnsafeBufferPointer { upmixer.process($0.baseAddress!, frames: hop, into: &upmixed) }
        let ready = upmixed.count / StereoUpmixer.outputChannels
        if ready < hop {
            upmixed.append(contentsOf: repeatElement(0, count: (hop - ready) * StereoUpmixer.outputChannels))
        }

        // The input itself, held back by the same latency.
        let length = delay.count / max(inputChannels, 1)
        if length == 0 {
            for i in 0..<(hop * inputChannels) { held[i] = input[i] }
        } else {
            for f in 0..<hop {
                for c in 0..<inputChannels {
                    let at = delayPosition * inputChannels + c
                    held[f * inputChannels + c] = delay[at]
                    delay[at] = input[f * inputChannels + c]
                }
                delayPosition += 1
                if delayPosition == length { delayPosition = 0 }
            }
        }

        let wantUpmix = content == .stereo, wasUpmix = previous == .stereo
        if wantUpmix || wasUpmix {
            if let router = upmixRouter {
                upmixed.withUnsafeBufferPointer { src in fromUpmix.withUnsafeMutableBufferPointer { router.route(src.baseAddress!, into: $0.baseAddress!, frames: hop) } }
            } else {
                for i in fromUpmix.indices { fromUpmix[i] = 0 }
            }
        }
        if !wantUpmix || !wasUpmix {
            if let router = surroundRouter {
                held.withUnsafeBufferPointer { src in fromSurround.withUnsafeMutableBufferPointer { router.route(src.baseAddress!, into: $0.baseAddress!, frames: hop) } }
            } else {
                for i in fromSurround.indices { fromSurround[i] = 0 }
            }
        }
        let total = hop * outputChannels
        switch (wasUpmix, wantUpmix) {
        case (true, true): for i in 0..<total { output[i] = fromUpmix[i] }
        case (false, false): for i in 0..<total { output[i] = fromSurround[i] }
        default:
            for f in 0..<hop {
                let t = Float(f + 1) / Float(hop)
                let a: Float = wantUpmix ? 1 - t : t     // the surround path's share
                for o in 0..<outputChannels {
                    let i = f * outputChannels + o
                    output[i] = fromSurround[i] * a + fromUpmix[i] * (1 - a)
                }
            }
        }
        return changed
    }
}
