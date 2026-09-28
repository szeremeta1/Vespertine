//
// Nocturne — owns one configured, optionally hogged, running output device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CNocturneRT
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
}

final class OutputSession: @unchecked Sendable {
    let deviceID: AudioObjectID
    let ring: OpaquePointer
    let context: OpaquePointer
    let applied: AppliedFormat
    let plan: OutputPlan
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
        let stream = DeviceQuery.outputStreams(deviceID).first
        let physical = stream.flatMap { try? HAL.get($0, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()) }
        let virtual = stream.flatMap { try? HAL.get($0, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) }
        let bufferFrames = (try? HAL.get(deviceID, .global(kAudioDevicePropertyBufferFrameSize), initial: UInt32(512))) ?? 512

        guard let virtual, virtual.mFormatID == kAudioFormatLinearPCM,
              virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0, virtual.mBitsPerChannel == 32,
              virtual.mChannelsPerFrame >= plan.channels, abs(virtual.mSampleRate - rate) < 0.5,
              rate.isFinite, rate > 0, rate <= 3_072_000 else {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "verify Float32 output format")
        }
        if plan.mode == .dop, (!hogged || (physical?.mBitsPerChannel ?? 0) < 24
            || abs(rate - plan.deviceSampleRate) >= 0.5) {
            if hogged { DeviceControl.releaseHog(deviceID) }
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "DoP requires exclusive, bit-transparent output")
        }

        applied = AppliedFormat(
            sampleRate: rate,
            physicalBitDepth: Int(physical?.mBitsPerChannel ?? UInt32(plan.physicalBitDepth)),
            physicalIsInteger: (physical?.mFormatFlags ?? kAudioFormatFlagIsSignedInteger) & kAudioFormatFlagIsSignedInteger != 0,
            virtualChannels: Int(virtual.mChannelsPerFrame),
            exclusive: hogged,
            bufferFrames: Int(bufferFrames))

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

    /// Switches the first output stream's physical format and the device's nominal rate to match `plan`.
    static func apply(plan: OutputPlan, to device: AudioObjectID) throws {
        let rate = plan.deviceSampleRate
        if let stream = DeviceQuery.outputStreams(device).first {
            let current = try? HAL.get(stream, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription())
            let candidates = DeviceQuery.physicalFormats(stream).filter {
                $0.mFormat.mFormatID == kAudioFormatLinearPCM
                    && rate >= $0.mSampleRateRange.mMinimum - 0.5 && rate <= $0.mSampleRateRange.mMaximum + 0.5
                    && $0.mFormat.mChannelsPerFrame >= plan.channels
            }
            let wantedChannels = current?.mChannelsPerFrame ?? UInt32(plan.channels)
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

        // The IOProc writes Float32; make sure the virtual format is Float32 at the new rate.
        if let stream = DeviceQuery.outputStreams(device).first,
           let virtual = try? HAL.get(stream, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()),
           !(virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0 && virtual.mBitsPerChannel == 32) {
            let available = (try? HAL.getArray(stream, .global(kAudioStreamPropertyAvailableVirtualFormats), of: AudioStreamRangedDescription.self)) ?? []
            if var float = available.first(where: {
                $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mFormat.mBitsPerChannel == 32
                    && rate >= $0.mSampleRateRange.mMinimum - 0.5 && rate <= $0.mSampleRateRange.mMaximum + 0.5
                    && $0.mFormat.mChannelsPerFrame >= plan.channels
            })?.mFormat {
                float.mSampleRate = rate
                try HAL.set(stream, .global(kAudioStreamPropertyVirtualFormat), float)
            } else {
                throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "no Float32 virtual format at \(rate) Hz")
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

    public static func hardwareVolumeDecibels(_ device: AudioObjectID) -> Float? {
        guard let element = DeviceQuery.volumeElements(device).first else { return nil }
        return try? HAL.get(device, .output(kAudioDevicePropertyVolumeDecibels, element: element), initial: Float32(0))
    }
}
