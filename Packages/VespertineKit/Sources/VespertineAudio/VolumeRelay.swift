//
// Vespertine — carries volume keys and Control Center to a device held with exclusive access.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AudioToolbox
import CoreAudio
import Foundation

/// macOS never makes a device another process holds exclusively the Mac's sound output: it moves the output to some
/// other device, and the volume keys, Control Center and the AirPods Max crown adjust that one instead. While Vespertine
/// holds the device it plays on, the relay ties the two together: volume and mute changes on the sound output go to
/// Vespertine's device, and the sound output takes the device's level, so the keys step from where it really is.
/// When Vespertine lets the device go, the sound output gets its own volume and mute back.
///
/// Each copy comes back as a change notification from the other side, and that notification can still carry the level
/// from before the copy. Copied back, it pulled nearly every step of the AirPods Max crown to the old level. So for a
/// moment after a write, a side showing the level it had just before or just after it is taken as an echo.
public final class VolumeRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.volume-relay")
    /// The device Vespertine plays on.
    private var target: AudioObjectID?
    /// The sound output standing in for it, with its own volume and mute to give back.
    private var standIn: (id: AudioObjectID, volume: Float32?, muted: UInt32?)?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var standInListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// The levels each side had just before and after the relay wrote to it, kept for `echoWindow`.
    private var written: [AudioObjectID: [(levels: Levels, at: DispatchTime)]] = [:]
    private static let echoWindow = 0.5
    /// Closer than a volume key step (1/16, or 1/64 with Option-Shift), wider than a device's rounding of a copied
    /// level (AirPods Max: 1/127).
    private static let echoTolerance: Float32 = 0.01

    private struct Levels {
        var volume: Float32?
        var mute: UInt32?

        func matches(_ other: Levels) -> Bool {
            mute == other.mute && {
                guard let a = volume, let b = other.volume else { return volume == other.volume }
                return abs(a - b) < VolumeRelay.echoTolerance
            }()
        }
    }

    private static let volume = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    private static let mute = AudioObjectPropertyAddress.output(kAudioDevicePropertyMute)

    public init() {}

    /// The device Vespertine plays on (nil: none). The relay only acts while Vespertine holds it exclusively.
    public func follow(_ device: AudioObjectID?) {
        queue.async { [self] in
            guard device != target else { return }
            retarget(device)
        }
    }

    /// Stops relaying and gives the sound output its own volume back. Blocking, for quitting.
    public func stop() {
        queue.sync { retarget(nil) }
    }

    // MARK: On the relay queue

    private func retarget(_ device: AudioObjectID?) {
        removeListeners(&listeners)
        release()
        target = device
        attach()
    }

    private func attach() {
        guard let device = target else { return }
        listen(&listeners, AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.evaluate() }
        // A device that leaves (AirPods Max taken off) loses its listeners and can come back under the same ID.
        listen(&listeners, AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDevices)) { [weak self] in self?.reattach() }
        listen(&listeners, device, .global(kAudioDevicePropertyHogMode)) { [weak self] in self?.evaluate() }
        listen(&listeners, device, Self.volume) { [weak self] in self?.changed(on: device) }
        listen(&listeners, device, Self.mute) { [weak self] in self?.changed(on: device) }
        evaluate()
    }

    private func reattach() {
        removeListeners(&listeners)
        attach()
    }

    /// Starts, moves or ends the relay after the hold or the sound output changed.
    private func evaluate() {
        guard let target, DeviceControl.hogOwner(target) == getpid(),
              let output = DeviceControl.systemOutputDevice(), output != target,
              HAL.isSettable(output, Self.volume), HAL.isSettable(target, Self.volume) else {
            release()
            return
        }
        guard standIn?.id != output else { return }
        release()
        standIn = (output, try? HAL.get(output, Self.volume, initial: Float32(0)), try? HAL.get(output, Self.mute, initial: UInt32(0)))
        copyLevels(from: target, to: output)
        listen(&standInListeners, output, Self.volume) { [weak self] in self?.changed(on: output) }
        listen(&standInListeners, output, Self.mute) { [weak self] in self?.changed(on: output) }
        log.notice("Volume keys now adjust the exclusively held output (through device \(output))")
    }

    /// Volume or mute changed on the device or its stand-in.
    private func changed(on device: AudioObjectID) {
        guard let target, let standIn else { return }
        let now = DispatchTime.now()
        let recent = (written[device] ?? []).filter { now.uptimeNanoseconds - $0.at.uptimeNanoseconds < UInt64(Self.echoWindow * 1e9) }
        written[device] = recent
        let levels = levels(of: device)
        if recent.contains(where: { $0.levels.matches(levels) }) { return }
        copyLevels(from: device, to: device == target ? standIn.id : target)
    }

    private func levels(of device: AudioObjectID) -> Levels {
        Levels(volume: try? HAL.get(device, Self.volume, initial: Float32(0)), mute: try? HAL.get(device, Self.mute, initial: UInt32(0)))
    }

    /// Copies volume and mute from one side to the other. Unchanged values aren't written.
    private func copyLevels(from: AudioObjectID, to: AudioObjectID) {
        let before = levels(of: to)
        var after = before
        if let v = try? HAL.get(from, Self.volume, initial: Float32(0)), let current = before.volume, abs(v - current) > 0.0005 {
            try? HAL.set(to, Self.volume, v)
            after.volume = v
        }
        if let m = try? HAL.get(from, Self.mute, initial: UInt32(0)), HAL.isSettable(to, Self.mute),
           let current = before.mute, m != current {
            try? HAL.set(to, Self.mute, m)
            after.mute = m
        }
        guard after.volume != before.volume || after.mute != before.mute else { return }
        written[to, default: []] += [(before, .now()), (after, .now())]
    }

    /// Ends relaying: the stand-in gets its own volume and mute back.
    private func release() {
        removeListeners(&standInListeners)
        written = [:]
        guard let standIn else { return }
        self.standIn = nil
        if let v = standIn.volume { try? HAL.set(standIn.id, Self.volume, v) }
        if let m = standIn.muted, HAL.isSettable(standIn.id, Self.mute) { try? HAL.set(standIn.id, Self.mute, m) }
        log.notice("Volume keys back on the Mac's sound output")
    }

    private func listen(_ list: inout [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)],
                        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { @Sendable _, _ in action() }
        var a = address
        guard AudioObjectAddPropertyListenerBlock(object, &a, queue, block) == noErr else { return }
        list.append((object, address, block))
    }

    private func removeListeners(_ list: inout [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)]) {
        for l in list {
            var a = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &a, queue, l.block)
        }
        list = []
    }
}
