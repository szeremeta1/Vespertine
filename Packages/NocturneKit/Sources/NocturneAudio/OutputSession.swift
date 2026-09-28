//
// Nocturne — owns one configured, optionally hogged, running output device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CNocturneRT
import AVFAudio
import CoreAudio
import Foundation
import os

let log = Logger(subsystem: "org.nocturne.player", category: "audio")

/// The format the device actually ended up in (read back, not assumed).
public struct AppliedFormat: Sendable, Hashable {
    public var sampleRate: Double
    public var physicalBitDepth: Int
    public var physicalIsInteger: Bool
    public var virtualChannels: Int
    public var exclusive: Bool
    public var bufferFrames: Int
    /// Channels of the stream Nocturne sends, by speaker ("L", "R", "C", "LFE", "Ls", "Rs"…).
    public var channelNames: [String] = []
    /// The device's configured speaker layout, when it has one.
    public var speakerNames: [String] = []
    /// Separate hardware streams the channels are spread across (aggregates, some interfaces).
    public var streamCount: Int = 1
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

    /// Configures the device for `plan` and prepares (but does not start) I/O.
    init(deviceID: AudioObjectID, plan: OutputPlan, exclusive: Bool, ringSeconds: Double = 5) throws {
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
        let virtuals = streams.compactMap { try? HAL.get($0, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) }
        // The shallowest stream decides what the device as a whole can carry.
        let physical = physicals.min { $0.mBitsPerChannel < $1.mBitsPerChannel }
        let bufferFrames = (try? HAL.get(deviceID, .global(kAudioDevicePropertyBufferFrameSize), initial: UInt32(512))) ?? 512
        let totalChannels = virtuals.reduce(0) { $0 + Int($1.mChannelsPerFrame) }

        let floatStreams = !virtuals.isEmpty && virtuals.count == streams.count && virtuals.allSatisfy {
            $0.mFormatID == kAudioFormatLinearPCM && $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mBitsPerChannel == 32
                && abs($0.mSampleRate - rate) < 0.5
        }
        guard floatStreams, totalChannels >= plan.deviceChannels, rate.isFinite, rate > 0, rate <= 3_072_000 else {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError,
                                 totalChannels < plan.deviceChannels
                                    ? "open \(plan.deviceChannels) channels (the device offers \(totalChannels))"
                                    : "set the device to Float32 at \(SampleRate.format(plan.deviceSampleRate)) kHz")
        }
        if plan.mode == .dop, (!hogged || (physical?.mBitsPerChannel ?? 0) < 24
            || abs(rate - plan.deviceSampleRate) >= 0.5) {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "DoP requires exclusive, bit-transparent output")
        }

        // Multichannel routing: the standard bed for Spatial Audio, the device's speaker layout for
        // discrete output (placed by position), nil for mono/stereo.
        let speakers = DeviceQuery.speakerLayout(deviceID)
        let routeLayout: AVAudioChannelLayout?
        if plan.spatial != .off {
            routeLayout = ChannelLayouts.layout(channels: plan.channels)
        } else if plan.channels > 2 {
            routeLayout = speakers.flatMap { Int($0.channelCount) == plan.channels && $0.hasSpeakerPositions ? $0 : nil }
                ?? ChannelLayouts.layout(channels: plan.channels)
        } else {
            routeLayout = nil
        }
        applied = AppliedFormat(
            sampleRate: rate,
            physicalBitDepth: Int(physical?.mBitsPerChannel ?? UInt32(plan.physicalBitDepth)),
            physicalIsInteger: (physical?.mFormatFlags ?? kAudioFormatFlagIsSignedInteger) & kAudioFormatFlagIsSignedInteger != 0,
            virtualChannels: totalChannels,
            exclusive: hogged,
            bufferFrames: Int(bufferFrames),
            channelNames: routeLayout?.shortNames ?? (plan.channels == 1 ? ["M"] : ["L", "R"]),
            speakerNames: speakers.flatMap { $0.hasSpeakerPositions ? $0.shortNames : nil } ?? [],
            streamCount: streams.count)

        let frames = UInt32(max(rate, 44_100) * ringSeconds)
        guard let ring = nrt_ring_create(frames, UInt32(plan.channels)) else {
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
        nrt_context_set_passthrough(ctx, plan.mode == .dop)

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
    }

    func start() throws {
        guard !isRunning, let ioProcID else { return }
        try check(AudioDeviceStart(deviceID, ioProcID), "AudioDeviceStart")
        isRunning = true
    }

    func stop() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(deviceID, ioProcID)
        isRunning = false
    }

    /// Stops I/O and discards buffered audio (used for seeks).
    func flush() {
        stop()
        nrt_ring_reset(ring)
    }

    func invalidate(releaseHog: Bool) {
        stop()
        if let ioProcID { AudioDeviceDestroyIOProcID(deviceID, ioProcID) }
        ioProcID = nil
        nrt_context_destroy(context)
        nrt_ring_destroy(ring)
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
            } else {
                throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "set a Float32 format at \(SampleRate.format(rate)) kHz")
            }
        }
    }

    static func setNominalRate(_ rate: Double, on device: AudioObjectID) throws {
        let current = try HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
        guard abs(current - rate) > 0.5 else { return }
        try HAL.set(device, .global(kAudioDevicePropertyNominalSampleRate), Float64(rate))
        // Rate changes are asynchronous; wait (bounded) until the hardware reports the new rate.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let now = (try? HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
            if abs(now - rate) < 0.5 { return }
            usleep(10_000)
        }
        throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "device did not switch to \(rate) Hz")
    }

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
