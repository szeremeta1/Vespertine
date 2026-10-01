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
public final class VolumeRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.volume-relay")
    /// The device Vespertine plays on.
    private var target: AudioObjectID?
    /// The sound output standing in for it, with its own volume and mute to give back.
    private var standIn: (id: AudioObjectID, volume: Float32?, muted: UInt32?)?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var standInListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

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
        guard let device else { return }
        listen(&listeners, AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.evaluate() }
        listen(&listeners, device, .global(kAudioDevicePropertyHogMode)) { [weak self] in self?.evaluate() }
        listen(&listeners, device, Self.volume) { [weak self] in self?.copyLevels(toStandIn: true) }
        listen(&listeners, device, Self.mute) { [weak self] in self?.copyLevels(toStandIn: true) }
        evaluate()
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
        copyLevels(toStandIn: true)
        listen(&standInListeners, output, Self.volume) { [weak self] in self?.copyLevels(toStandIn: false) }
        listen(&standInListeners, output, Self.mute) { [weak self] in self?.copyLevels(toStandIn: false) }
        log.notice("Volume keys now adjust the exclusively held output (through device \(output))")
    }

    /// Copies volume and mute between the device and its stand-in. Unchanged values aren't written, so the echo
    /// of each write stops here.
    private func copyLevels(toStandIn: Bool) {
        guard let target, let standIn else { return }
        let (from, to) = toStandIn ? (target, standIn.id) : (standIn.id, target)
        if let v = try? HAL.get(from, Self.volume, initial: Float32(0)),
           let current = try? HAL.get(to, Self.volume, initial: Float32(0)), abs(v - current) > 0.0005 {
            try? HAL.set(to, Self.volume, v)
        }
        if let m = try? HAL.get(from, Self.mute, initial: UInt32(0)), HAL.isSettable(to, Self.mute),
           let current = try? HAL.get(to, Self.mute, initial: UInt32(0)), m != current {
            try? HAL.set(to, Self.mute, m)
        }
    }

    /// Ends relaying: the stand-in gets its own volume and mute back.
    private func release() {
        removeListeners(&standInListeners)
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
