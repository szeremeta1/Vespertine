//
// Vespertine — owns one configured, optionally hogged, running output device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import AVFAudio
import CoreAudio
import Foundation
import os

let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "audio")

/// The format the device actually ended up in (read back, not assumed).
public struct AppliedFormat: Sendable, Hashable {
    public var sampleRate: Double
    public var physicalBitDepth: Int
    public var physicalIsInteger: Bool
    public var virtualChannels: Int
    public var exclusive: Bool
    public var bufferFrames: Int
    /// Channels of the stream Vespertine sends, by speaker ("L", "R", "C", "LFE", "Ls", "Rs"…).
    public var channelNames: [String] = []
    /// The device's configured speaker layout, when it has one.
    public var speakerNames: [String] = []
    /// Separate hardware streams the channels are spread across (aggregates, some interfaces).
    public var streamCount: Int = 1
    /// Integer mode in effect: the device takes 32-bit integers directly (non-mixable), no float step.
    public var integerMode = false
}

final class OutputSession: @unchecked Sendable {
    let deviceID: AudioObjectID
    let ring: OpaquePointer
    let context: OpaquePointer
    let applied: AppliedFormat
    let plan: OutputPlan
    /// Layout the decoded stream is converted to: the standard bed for Spatial Audio, the device's
    /// speaker layout for discrete multichannel output, nil for mono/stereo.
    let decodedLayout: AVAudioChannelLayout?
    /// Apple's spatial mixer, run on the I/O thread (Spatial Audio plans only).
    private(set) var spatial: SpatialRenderer?
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    /// What the device still holds after the I/O proc's last buffer: its latency, safety offset and stream latency.
    /// A few milliseconds on a USB DAC; hundreds on Bluetooth and AirPlay, whose end of the last song was cut off
    /// when the device was stopped as soon as the ring ran dry.
    let latencyFrames: Int
    /// Set by Core Audio when the device's rate or a stream's format changes; read by `formatChanged()`.
    private let formatNotice = OSAllocatedUnfairLock(initialState: false)
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var watchedFormats: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private static let formatQueue = DispatchQueue(label: "org.szeremeta.vespertine.format-changes")

    /// Multichannel routing: the source's own speakers for Spatial Audio (the standard bed when it doesn't
    /// name them), the device's speaker layout for discrete output (placed by position), nil for mono/stereo.
    static func routeLayout(plan: OutputPlan, speakers: AVAudioChannelLayout?) -> AVAudioChannelLayout? {
        if plan.spatial != .off {
            return plan.spatialBed.flatMap { AVAudioChannelLayout(layoutTag: $0) } ?? ChannelLayouts.layout(channels: plan.channels)
        }
        guard plan.channels > 2 else { return nil }
        return speakers.flatMap { Int($0.channelCount) == plan.channels && $0.hasSpeakerPositions ? $0 : nil }
            ?? ChannelLayouts.layout(channels: plan.channels)
    }

    /// Configures the device for `plan` and prepares (but does not start) I/O.
    /// Ring size in frames: about 30 s of audio, so a network share that stalls for many seconds (a busy
    /// server's disks) is never heard, within a memory budget (fewer seconds for many channels at high
    /// rates), and never less than 5 s. A power of two, as the ring requires.
    static func ringFrames(rate: Double, channels: Int, seconds: Double = 30, budgetBytes: Int = 96 << 20) -> UInt32 {
        let perSecond = max(rate, 44_100)
        let budgetFrames = budgetBytes / (max(1, channels) * MemoryLayout<Float>.size)
        var frames = 1
        while frames * 2 <= min(Int(perSecond * seconds), budgetFrames) { frames *= 2 }
        while Double(frames) < perSecond * 5 { frames *= 2 }
        return UInt32(frames)
    }

    init(deviceID: AudioObjectID, plan: OutputPlan, exclusive: Bool) throws {
        self.deviceID = deviceID
        self.plan = plan

        let hogged = exclusive ? DeviceControl.acquireHog(deviceID) : false
        if exclusive, !hogged {
            log.notice("Exclusive access unavailable (another process holds the device); continuing shared")
        }
        do {
            try DeviceControl.apply(plan: plan, to: deviceID)
        } catch {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw error
        }

        let rate = (try? HAL.get(deviceID, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? plan.deviceSampleRate
        let streams = DeviceQuery.outputStreams(deviceID)
        let physicals = streams.compactMap { try? HAL.get($0, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()) }
        // Integer mode needs the device to ourselves and a non-mixable Int32 virtual format.
        let integerMode = plan.integerSamples && hogged && plan.mode == .pcm && DeviceControl.setIntegerFormat(on: deviceID, plan: plan, rate: rate)
        let virtuals = streams.compactMap { try? HAL.get($0, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) }
        // The shallowest stream decides what the device as a whole can carry.
        let physical = physicals.min { $0.mBitsPerChannel < $1.mBitsPerChannel }
        let bufferFrames = (try? HAL.get(deviceID, .global(kAudioDevicePropertyBufferFrameSize), initial: UInt32(512))) ?? 512
        let deviceLatency = (try? HAL.get(deviceID, .output(kAudioDevicePropertyLatency), initial: UInt32(0))) ?? 0
        let safetyOffset = (try? HAL.get(deviceID, .output(kAudioDevicePropertySafetyOffset), initial: UInt32(0))) ?? 0
        let streamLatency = streams.compactMap { try? HAL.get($0, .global(kAudioStreamPropertyLatency), initial: UInt32(0)) }.max() ?? 0
        latencyFrames = Int(deviceLatency) + Int(safetyOffset) + Int(streamLatency)
        let totalChannels = virtuals.reduce(0) { $0 + Int($1.mChannelsPerFrame) }

        let floatStreams = !virtuals.isEmpty && virtuals.count == streams.count
            && virtuals.allSatisfy { Self.renders(into: $0, rate: rate, integer: integerMode) }
        guard floatStreams, totalChannels >= plan.deviceChannels, rate.isFinite, rate > 0, rate <= 3_072_000 else {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError,
                                 totalChannels < plan.deviceChannels
                                    ? "open \(plan.deviceChannels) channels (the device offers \(totalChannels))"
                                    : "set the device to Float32 at \(SampleRate.format(plan.deviceSampleRate)) kHz")
        }
        if plan.isPassthrough, (!hogged || (physical?.mBitsPerChannel ?? 0) < (plan.mode == .dop ? 24 : 16)
            || abs(rate - plan.deviceSampleRate) >= 0.5) {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError,
                                 plan.mode == .dop ? "DoP requires exclusive, bit-transparent output" : "Bitstream requires exclusive, bit-transparent output")
        }

        let speakers = DeviceQuery.speakerLayout(deviceID)
        let routeLayout = Self.routeLayout(plan: plan, speakers: speakers)
        applied = AppliedFormat(
            sampleRate: rate,
            physicalBitDepth: Int(physical?.mBitsPerChannel ?? UInt32(plan.physicalBitDepth)),
            physicalIsInteger: (physical?.mFormatFlags ?? kAudioFormatFlagIsSignedInteger) & kAudioFormatFlagIsSignedInteger != 0,
            virtualChannels: totalChannels,
            exclusive: hogged,
            bufferFrames: Int(bufferFrames),
            channelNames: routeLayout?.shortNames ?? (plan.channels == 1 ? ["M"] : ["L", "R"]),
            speakerNames: speakers.flatMap { $0.hasSpeakerPositions ? $0.shortNames : nil } ?? [],
            streamCount: streams.count,
            integerMode: integerMode)

        guard let ring = nrt_ring_create(Self.ringFrames(rate: rate, channels: plan.channels), UInt32(plan.channels)) else {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(-1, "allocate ring buffer")
        }
        guard let ctx = nrt_context_create(ring, max(bufferFrames * 2, 4096)) else {
            nrt_ring_destroy(ring)
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(-1, "allocate render context")
        }
        self.ring = ring
        self.context = ctx
        nrt_context_set_passthrough(ctx, plan.isPassthrough)
        nrt_context_set_dop(ctx, plan.mode == .dop)
        nrt_context_set_integer(ctx, integerMode)

        // Multichannel routing.
        decodedLayout = routeLayout
        if plan.spatial != .off {
            let bed = routeLayout
            do {
                guard let bed else { throw SpatialError.unavailable(-1, "layout") }
                let renderer = try SpatialRenderer(inputLayout: bed, channels: plan.channels, sampleRate: rate,
                                                   maxFrames: max(bufferFrames * 2, 4096), mode: plan.spatial)
                guard renderer.attach(to: ctx) else { throw SpatialError.unavailable(-1, "attach") }
                spatial = renderer
            } catch {
                nrt_context_destroy(ctx)
                nrt_ring_destroy(ring)
                if hogged { DeviceControl.releaseHog(deviceID) }
                throw error
            }
        }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(deviceID, nrt_device_ioproc, UnsafeMutableRawPointer(ctx), &procID)
        guard status == noErr, let procID else {
            nrt_context_destroy(ctx)
            nrt_ring_destroy(ring)
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(status, "AudioDeviceCreateIOProcID")
        }
        ioProcID = procID

        // Installed once the device is configured; late notices of our own changes read back as no change.
        let block: AudioObjectPropertyListenerBlock = { [formatNotice] _, _ in formatNotice.withLock { $0 = true } }
        formatListener = block
        let addresses = [(deviceID, AudioObjectPropertyAddress.global(kAudioDevicePropertyNominalSampleRate))]
            + streams.flatMap { [($0, AudioObjectPropertyAddress.global(kAudioStreamPropertyPhysicalFormat)),
                                 ($0, AudioObjectPropertyAddress.global(kAudioStreamPropertyVirtualFormat))] }
        for (object, address) in addresses {
            var a = address
            if AudioObjectAddPropertyListenerBlock(object, &a, Self.formatQueue, block) == noErr { watchedFormats.append((object, address)) }
        }
    }

    /// Whether the device has left the format this session set up under it: another app, Audio MIDI Setup or an
    /// AirPods microphone switch changed its rate, a stream's physical format (the bit depth the signal path names)
    /// or the format the I/O proc is handed. The I/O proc would go on sending samples made for the old rate, so the
    /// song plays too fast or too slow while the signal path still names the old format. Reads the device only after
    /// Core Audio said something changed.
    func formatChanged() -> Bool {
        guard formatNotice.withLock({ noticed in defer { noticed = false }; return noticed }) else { return false }
        let rate = (try? HAL.get(deviceID, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
        if abs(rate - applied.sampleRate) >= 0.5 { return true }
        let streams = DeviceQuery.outputStreams(deviceID)
        let physicals = streams.compactMap { try? HAL.get($0, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()) }
        if let shallowest = physicals.map(\.mBitsPerChannel).min(), Int(shallowest) != applied.physicalBitDepth { return true }
        let virtuals = streams.compactMap { try? HAL.get($0, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) }
        // Same rate and depth can still hide a switch between Float32 and Int32, or a different channel count,
        // either of which the render context would write wrongly.
        if virtuals.count != applied.streamCount
            || virtuals.reduce(0, { $0 + Int($1.mChannelsPerFrame) }) != applied.virtualChannels { return true }
        return !virtuals.allSatisfy { Self.renders(into: $0, rate: rate, integer: applied.integerMode) }
    }

    /// Whether the render context can write `virtual` as set up: 32-bit linear PCM at `rate`, float, or
    /// packed signed integers in integer mode.
    static func renders(into virtual: AudioStreamBasicDescription, rate: Double, integer: Bool) -> Bool {
        virtual.mFormatID == kAudioFormatLinearPCM && virtual.mBitsPerChannel == 32 && abs(virtual.mSampleRate - rate) < 0.5
            && (integer ? virtual.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && virtual.mFormatFlags & kAudioFormatFlagIsFloat == 0
                            && virtual.mBytesPerFrame == 4 * virtual.mChannelsPerFrame
                        : virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    private func unwatchFormats() {
        guard let formatListener else { return }
        for (object, address) in watchedFormats {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, Self.formatQueue, formatListener)
        }
        watchedFormats = []
        self.formatListener = nil
    }

    func start() throws {
        guard !isRunning, let ioProcID else { return }
        try check(AudioDeviceStart(deviceID, ioProcID), "AudioDeviceStart")
        isRunning = true
    }

    /// DSD over PCM: a DAC stays in DSD only while every frame carries the DoP marker. While muted, holding for data or
    /// run dry, the I/O proc sends DSD silence behind the markers (see `nrt_context_set_dop`), so a DoP output keeps
    /// running through pauses, seeks and skips: stopping it makes the DAC drop out of DSD and lock again with a pop.
    var isDoP: Bool { plan.mode == .dop }

    func stop() {
        guard isRunning, let ioProcID else { return }
        // DoP: the last frames the DAC gets are DSD silence, not a cut in the middle of the music.
        if isDoP { idleOut() }
        AudioDeviceStop(deviceID, ioProcID)
        isRunning = false
    }

    /// Mutes and waits a few I/O cycles, so idle frames reach the device before it stops.
    private func idleOut() {
        nrt_context_set_muted(context, true)
        let seconds = Self.idleOutSeconds(bufferFrames: applied.bufferFrames, sampleRate: applied.sampleRate)
        if seconds > 0 { usleep(useconds_t(seconds * 1_000_000)) }
    }

    /// Three I/O buffers (one being played, one queued, one more), at most 50 ms.
    static func idleOutSeconds(bufferFrames: Int, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return min(0.05, Double(max(bufferFrames, 1) * 3) / sampleRate)
    }

    /// How long a flush waits for the I/O proc to drop what's buffered before stopping the device instead.
    static let discardWait: TimeInterval = 0.25

    /// Discards buffered audio (seeks, skips). A DoP output that's running keeps running, muted: the I/O proc drops what's
    /// buffered on its next cycle and sends DSD silence until playback is unmuted, so the DAC stays locked in DSD.
    /// Anything else stops the device, as does a DoP output whose I/O proc doesn't get to it in time.
    func flush() {
        if isRunning, isDoP {
            nrt_context_set_muted(context, true)
            let target = nrt_context_discard(context)
            let deadline = Date().addingTimeInterval(Self.discardWait)
            while totalRead < target, Date() < deadline { usleep(1_000) }
            if totalRead >= target { return }
            log.notice("The DoP output didn't drop its buffer in time; stopping it")
        }
        stop()
        nrt_context_cancel_discard(context)
        nrt_ring_reset(ring)
    }

    /// `restoreFormat` false: the next session configures the same device straight away (it keeps the hold).
    /// `idle`: the engine is letting the device go (a long pause, a stop, the end of the queue), not handing it to the
    /// next song's session.
    func invalidate(releaseHog: Bool, restoreFormat: Bool = true, idle: Bool = false) {
        unwatchFormats()
        stop()
        if let ioProcID { AudioDeviceDestroyIOProcID(deviceID, ioProcID) }
        ioProcID = nil
        nrt_context_destroy(context)
        nrt_ring_destroy(ring)
        // Leave the device on an ordinary (mixable Float32) format for whoever uses it next.
        if applied.integerMode, restoreFormat { try? DeviceControl.apply(plan: OutputPlan(mode: .pcm, deviceSampleRate: applied.sampleRate,
            decodedSampleRate: applied.sampleRate, physicalBitDepth: applied.physicalBitDepth, channels: plan.deviceChannels,
            dsdConvertedToPCM: false, reason: ""), to: deviceID) }
        // DoP's carrier rate (176.4 kHz and up for DSD64) is no music rate: a DAC let go at it shows it, and whatever
        // plays next is resampled to it. Put back the rate it had before Vespertine changed it, while still held.
        if idle, releaseHog, plan.mode == .dop, applied.exclusive, let rate = DeviceRestore.originalRate(deviceID),
           abs(rate - applied.sampleRate) >= 0.5 {
            try? DeviceControl.setNominalRate(rate, on: deviceID)
        }
        if releaseHog, applied.exclusive { DeviceControl.releaseHog(deviceID) }
    }

    var readableFrames: Int { Int(nrt_ring_readable(ring)) }
    var writableFrames: Int { Int(nrt_ring_writable(ring)) }
    var totalWritten: UInt64 { nrt_ring_total_written(ring) }
    var totalRead: UInt64 { nrt_ring_total_read(ring) }
}

/// Stateless device operations.
public enum DeviceControl {
    // MARK: Exclusive access

    public static func hogOwner(_ device: AudioObjectID) -> pid_t {
        (try? HAL.get(device, .global(kAudioDevicePropertyHogMode), initial: pid_t(-1))) ?? -1
    }

    /// Takes exclusive (hog) access. Returns true when this process owns the device.
    @discardableResult
    static func acquireHog(_ device: AudioObjectID) -> Bool {
        let me = getpid()
        let owner = hogOwner(device)
        if owner == me { return true }
        if owner != -1 { return false }
        try? HAL.set(device, .global(kAudioDevicePropertyHogMode), me)
        return hogOwner(device) == me
    }

    static func releaseHog(_ device: AudioObjectID) {
        guard hogOwner(device) == getpid() else { return }
        try? HAL.set(device, .global(kAudioDevicePropertyHogMode), pid_t(-1))
    }

    // MARK: Format

    /// Switches the device's nominal rate (and, for single-stream devices, the physical format) to
    /// match `plan`. Multi-stream devices (aggregates, many interfaces and receivers) keep each
    /// stream's channel layout; channels are spread across the streams in order.
    static func apply(plan: OutputPlan, to device: AudioObjectID) throws {
        DeviceRestore.remember(device)
        let rate = plan.deviceSampleRate
        let streams = DeviceQuery.outputStreams(device)
        if streams.count == 1, let stream = streams.first {
            let current = try? HAL.get(stream, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription())
            let candidates = DeviceQuery.physicalFormats(stream).filter {
                $0.mFormat.mFormatID == kAudioFormatLinearPCM
                    && rate >= $0.mSampleRateRange.mMinimum - 0.5 && rate <= $0.mSampleRateRange.mMaximum + 0.5
                    && $0.mFormat.mChannelsPerFrame >= plan.deviceChannels
            }
            let wantedChannels = max(current?.mChannelsPerFrame ?? 0, UInt32(plan.deviceChannels))
            func score(_ r: AudioStreamRangedDescription) -> Int {
                var s = 0
                if r.mFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 { s += 1000 }
                if Int(r.mFormat.mBitsPerChannel) == plan.physicalBitDepth { s += 500 }
                s += Int(r.mFormat.mBitsPerChannel)
                if r.mFormat.mChannelsPerFrame == wantedChannels { s += 200 }
                if r.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable == 0 { s += 50 } // we render Float32 through the mixer-less HAL path
                return s
            }
            if var best = candidates.max(by: { score($0) < score($1) })?.mFormat {
                best.mSampleRate = rate
                let same = current.map { $0.mSampleRate == best.mSampleRate && $0.mBitsPerChannel == best.mBitsPerChannel
                    && $0.mFormatFlags == best.mFormatFlags && $0.mChannelsPerFrame == best.mChannelsPerFrame } ?? false
                if !same {
                    do {
                        try HAL.set(stream, .global(kAudioStreamPropertyPhysicalFormat), best)
                        // Physical format changes are asynchronous: wait until the hardware reports it.
                        let deadline = Date().addingTimeInterval(2)
                        while Date() < deadline {
                            let now = try? HAL.get(stream, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription())
                            if let now, now.mBitsPerChannel == best.mBitsPerChannel, abs(now.mSampleRate - rate) < 0.5 { break }
                            usleep(10_000)
                        }
                        settle()
                    } catch {
                        log.error("physical format change refused: \(String(describing: error))")
                    }
                }
            }
        }

        try setNominalRate(rate, on: device)

        // The IOProc writes Float32; make sure every stream's virtual format is Float32 at the new rate.
        let single = streams.count == 1
        for stream in streams {
            guard let virtual = try? HAL.get(stream, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()),
                  !(virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0 && virtual.mBitsPerChannel == 32) else { continue }
            let available = (try? HAL.getArray(stream, .global(kAudioStreamPropertyAvailableVirtualFormats), of: AudioStreamRangedDescription.self)) ?? []
            if var float = available.first(where: {
                $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mFormat.mBitsPerChannel == 32
                    && rate >= $0.mSampleRateRange.mMinimum - 0.5 && rate <= $0.mSampleRateRange.mMaximum + 0.5
                    && (!single || $0.mFormat.mChannelsPerFrame >= plan.deviceChannels)
                    && $0.mFormat.mChannelsPerFrame == (single ? $0.mFormat.mChannelsPerFrame : virtual.mChannelsPerFrame)
            })?.mFormat {
                float.mSampleRate = rate
                try HAL.set(stream, .global(kAudioStreamPropertyVirtualFormat), float)
                settle()
            } else {
                throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "set a Float32 format at \(SampleRate.format(rate)) kHz")
            }
        }
    }

    /// Switches a single-stream device to non-mixable 32-bit integer (integer mode). Only possible while
    /// hogged. Devices take it through the physical format (the virtual format follows); setting only the
    /// virtual format is accepted but ignored by some (e.g. USB Audio Class DACs). Returns whether it took.
    static func setIntegerFormat(on device: AudioObjectID, plan: OutputPlan, rate: Double) -> Bool {
        let streams = DeviceQuery.outputStreams(device)
        guard streams.count == 1, let stream = streams.first else { return false }
        func isInteger32NonMixable(_ f: AudioStreamBasicDescription) -> Bool {
            f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
                && f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 && f.mFormatFlags & kAudioFormatFlagIsFloat == 0
                && f.mBitsPerChannel == 32 && f.mBytesPerFrame == 4 * f.mChannelsPerFrame
        }
        func current() -> AudioStreamBasicDescription? {
            try? HAL.get(stream, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription())
        }
        func took() -> Bool { current().map { isInteger32NonMixable($0) && abs($0.mSampleRate - rate) < 0.5 } ?? false }
        if took() { return true }   // kept from the previous song
        func matching(_ list: [AudioStreamRangedDescription]) -> AudioStreamBasicDescription? {
            guard var f = list.first(where: {
                isInteger32NonMixable($0.mFormat) && Int($0.mFormat.mChannelsPerFrame) >= plan.deviceChannels
                    && rate >= $0.mSampleRateRange.mMinimum - 0.5 && rate <= $0.mSampleRateRange.mMaximum + 0.5
            })?.mFormat else { return nil }
            f.mSampleRate = rate
            return f
        }
        let physical = matching(DeviceQuery.physicalFormats(stream))
        let virtual = matching((try? HAL.getArray(stream, .global(kAudioStreamPropertyAvailableVirtualFormats), of: AudioStreamRangedDescription.self)) ?? [])
        for (selector, format) in [(kAudioStreamPropertyPhysicalFormat, physical), (kAudioStreamPropertyVirtualFormat, virtual)] {
            guard let format, (try? HAL.set(stream, .global(selector), format)) != nil else { continue }
            // Format changes are asynchronous: wait (bounded) for the device to report it.
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline { if took() { settle(); return true }; usleep(10_000) }
        }
        return took()
    }

    static func setNominalRate(_ rate: Double, on device: AudioObjectID) throws {
        let current = try HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
        guard abs(current - rate) > 0.5 else { return }
        try HAL.set(device, .global(kAudioDevicePropertyNominalSampleRate), Float64(rate))
        // Rate changes are asynchronous; wait (bounded) until the hardware reports the new rate.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let now = (try? HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
            if abs(now - rate) < 0.5 { settle(); return }
            usleep(10_000)
        }
        throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "device did not switch to \(rate) Hz")
    }

    /// A format or rate change reads back before macOS has finished telling this process about it (it pauses and
    /// resumes the device's I/O around each one). Starting the next change, or the device, while that is still going
    /// on is how the device ended up paused for good; a short pause lets each change finish first.
    private static func settle() { usleep(60_000) }

    // MARK: Hardware volume

    public static func hardwareVolume(_ device: AudioObjectID) -> Float? {
        let elements = DeviceQuery.volumeElements(device)
        guard !elements.isEmpty else { return nil }
        let values = elements.compactMap {
            try? HAL.get(device, .output(kAudioDevicePropertyVolumeScalar, element: $0), initial: Float32(0))
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    public static func setHardwareVolume(_ device: AudioObjectID, _ value: Float) {
        let v = max(0, min(1, value))
        for element in DeviceQuery.volumeElements(device) {
            try? HAL.set(device, .output(kAudioDevicePropertyVolumeScalar, element: element), Float32(v))
        }
    }

    // MARK: The Mac's sound output

    /// The device macOS sends system sound to, and applies volume keys / headphone controls to.
    public static func systemOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Makes `device` the Mac's sound output (what choosing it in Control Center does).
    @discardableResult
    public static func setSystemOutputDevice(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    /// Whether any other process is currently sending audio to `device` (shared mode mixes it in).
    public static func otherProcessesPlaying(to device: AudioObjectID) -> Bool {
        let me = getpid()
        let processes = (try? HAL.getArray(AudioObjectID(kAudioObjectSystemObject),
                                           .global(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        for process in processes {
            guard let pid = try? HAL.get(process, .global(kAudioProcessPropertyPID), initial: pid_t(0)), pid != me,
                  (try? HAL.get(process, .global(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0))) == 1 else { continue }
            let devices = (try? HAL.getArray(process, .output(kAudioProcessPropertyDevices), of: AudioObjectID.self)) ?? []
            if devices.contains(device) { return true }
        }
        return false
    }

    public static func hardwareVolumeDecibels(_ device: AudioObjectID) -> Float? {
        guard let element = DeviceQuery.volumeElements(device).first else { return nil }
        return try? HAL.get(device, .output(kAudioDevicePropertyVolumeDecibels, element: element), initial: Float32(0))
    }
}
