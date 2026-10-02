//
// Vespertine — puts devices back when Vespertine quits: as they were before Vespertine changed them,
// or at a standard format (44.1 kHz / 16-bit, 48 kHz / 24-bit), or left as they are. After a crash,
// puts back what the volume relay changed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum DeviceOnQuit: String, CaseIterable, Sendable, Identifiable {
    case restore, cd, dat, leave
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .restore: "Put it back as it was"
        case .cd: "44.1 kHz · 16-bit"
        case .dat: "48 kHz · 24-bit"
        case .leave: "Leave it as it is"
        }
    }
}

public enum DeviceRestore {
    struct Original {
        var rate: Double
        var physical: AudioStreamBasicDescription?
        var virtual: AudioStreamBasicDescription?
    }
    nonisolated(unsafe) private static var originals: [String: Original] = [:]
    private static let lock = NSLock()

    /// Remembers the device's format the first time Vespertine is about to change it this session.
    static func remember(_ device: AudioObjectID) {
        guard let uid = HAL.getString(device, .global(kAudioDevicePropertyDeviceUID)) else { return }
        lock.lock(); defer { lock.unlock() }
        guard originals[uid] == nil else { return }
        let streams = DeviceQuery.outputStreams(device)
        let first = streams.count == 1 ? streams.first : nil
        originals[uid] = Original(
            rate: (try? HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0,
            physical: first.flatMap { try? HAL.get($0, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()) },
            virtual: first.flatMap { try? HAL.get($0, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) })
    }

    /// Devices Vespertine changed this session (UIDs).
    public static var changedDevices: [String] { lock.lock(); defer { lock.unlock() }; return Array(originals.keys) }

    /// Applies `mode` to every device Vespertine changed. Call after playback has stopped and
    /// exclusive access is released. Blocking (Core Audio format changes take a moment).
    public static func finish(_ mode: DeviceOnQuit) {
        guard mode != .leave else { return }
        lock.lock(); let saved = originals; lock.unlock()
        let present = OutputDevices.list(dopEnabledUIDs: [])
        for (uid, original) in saved {
            guard let device = present.first(where: { $0.uid == uid }) else { continue }
            switch mode {
            case .restore: restore(device.id, to: original)
            case .cd: standard(device.id, rate: 44_100, bits: 16)
            case .dat: standard(device.id, rate: 48_000, bits: 24)
            case .leave: break
            }
        }
    }

    /// Puts back what the volume relay changed when Vespertine last ended while relaying (a crash, a forced quit): the
    /// stand-in's own volume and mute, and the alert volume, each only if it is still what the relay left. What can't
    /// be put back yet (the stand-in isn't plugged in) is kept for the next launch. Call at launch, before anything
    /// plays. Quick, unless there is something to put back.
    public static func afterCrash() {
        var pending = RelayChanges.leftovers()
        if let left = RelayChanges.load() { pending.append(left) }
        guard !pending.isEmpty else { return }
        // Newest first: an older record is checked against what the newer one put back.
        let still = pending.reversed().compactMap(putBack).reversed()
        RelayChanges.storeLeftovers(Array(still))
        RelayChanges.store(nil)
    }

    /// Puts back what it can of `left`, and returns the rest.
    private static func putBack(_ left: RelayChanges) -> RelayChanges? {
        let device = DeviceQuery.allDeviceIDs().first { HAL.getString($0, .global(kAudioDevicePropertyDeviceUID)) == left.standIn }
        let nowVolume = device.flatMap { try? HAL.get($0, VolumeRelay.volume, initial: Float32(0)) }
        let nowMute = device.flatMap { try? HAL.get($0, VolumeRelay.mute, initial: UInt32(0)) }
        let nowAlert = left.alertSet == nil ? nil : AlertVolume.get()
        let back = left.putBack(volume: nowVolume, mute: nowMute, alert: nowAlert)
        // Read means settled (left as it is, or put back below), unless putting it back fails.
        var settled = (volume: nowVolume != nil, mute: nowMute != nil, alert: nowAlert != nil)
        if let device, let v = back.volume { settled.volume = (try? HAL.set(device, VolumeRelay.volume, v)) != nil }
        if let device, let m = back.mute { settled.mute = (try? HAL.set(device, VolumeRelay.mute, m)) != nil }
        if let a = back.alert, let set = left.alertSet { settled.alert = AlertVolume.set(a, ifStill: set) != nil }
        let rest = left.remaining(volume: settled.volume, mute: settled.mute, alert: settled.alert)
        log.notice("Vespertine last quit while relaying the volume keys; put back volume \(back.volume != nil), mute \(back.mute != nil), alert volume \(back.alert != nil); \(rest == nil ? "nothing left" : "the rest waits for the next launch")")
        return rest
    }

    private static func restore(_ device: AudioObjectID, to original: Original) {
        let streams = DeviceQuery.outputStreams(device)
        if streams.count == 1, let stream = streams.first {
            if let physical = original.physical { try? HAL.set(stream, .global(kAudioStreamPropertyPhysicalFormat), physical) }
            if let virtual = original.virtual { try? HAL.set(stream, .global(kAudioStreamPropertyVirtualFormat), virtual) }
        }
        if original.rate > 0 { try? DeviceControl.setNominalRate(original.rate, on: device) }
    }

    private static func standard(_ device: AudioObjectID, rate: Double, bits: Int) {
        let channels = max(2, (try? HAL.get(DeviceQuery.outputStreams(device).first ?? 0, .global(kAudioStreamPropertyVirtualFormat),
                                             initial: AudioStreamBasicDescription())).map { Int($0.mChannelsPerFrame) } ?? 2)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: bits,
                              channels: min(channels, 2), dsdConvertedToPCM: false, reason: "")
        try? DeviceControl.apply(plan: plan, to: device)
    }

    /// Hardware check (vespertine-probe restore-test): switch like playback, then try each quit option.
    /// Returns the device's rate and bit depth after each step; the last step is "restore".
    public static func exercise(_ d: OutputDevice) -> [(step: String, rate: Double, bits: UInt32)] {
        func now(_ step: String) -> (step: String, rate: Double, bits: UInt32) {
            let rate = (try? HAL.get(d.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
            let bits = DeviceQuery.outputStreams(d.id).first.flatMap {
                try? HAL.get($0, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()).mBitsPerChannel
            } ?? 0
            return (step, rate, bits)
        }
        var out = [now("before")]
        let target = d.capabilities.sampleRates.last { abs($0 - out[0].rate) > 1 } ?? out[0].rate
        try? DeviceControl.apply(plan: OutputPlan(mode: .pcm, deviceSampleRate: target, decodedSampleRate: target, physicalBitDepth: 24,
                                                  channels: 2, dsdConvertedToPCM: false, reason: ""), to: d.id)
        out.append(now("playing"))
        for mode in [DeviceOnQuit.cd, .dat, .restore] { finish(mode); out.append(now("quit: \(mode.label)")) }
        return out
    }
}
