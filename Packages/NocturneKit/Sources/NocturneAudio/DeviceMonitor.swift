//
// Nocturne — observes device arrival/removal, default-output changes and hardware volume.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum OutputDevices {
    public static func list(dopEnabledUIDs: Set<String> = []) -> [OutputDevice] {
        DeviceQuery.outputDevices(dopEnabledUIDs: dopEnabledUIDs)
    }
}

public final class DeviceMonitor: @unchecked Sendable {
    public enum Change: Sendable { case devices, volume }

    private let queue = DispatchQueue(label: "org.nocturne.devices")
    private let onChange: @Sendable (Change) -> Void
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var watchedVolume: (device: AudioObjectID, elements: [UInt32])?

    private static let systemAddresses: [AudioObjectPropertyAddress] = [
        .global(kAudioHardwarePropertyDevices),
        .global(kAudioHardwarePropertyDefaultOutputDevice),
    ]

    public init(onChange: @escaping @Sendable (Change) -> Void) {
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [onChange] _, _ in onChange(.devices) }
        systemBlock = block
        for var address in Self.systemAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    deinit {
        if let systemBlock {
            for var address in Self.systemAddresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, systemBlock)
            }
        }
        unwatchVolume()
    }

    /// Follows hardware volume (and mute) changes of one device, e.g. from the keyboard or the DAC.
    public func watchVolume(of device: AudioObjectID?) {
        unwatchVolume()
        guard let device else { return }
        let elements = DeviceQuery.volumeElements(device)
        guard !elements.isEmpty else { return }
        let block: AudioObjectPropertyListenerBlock = { [onChange] _, _ in onChange(.volume) }
        volumeBlock = block
        for element in elements {
            var address = AudioObjectPropertyAddress.output(kAudioDevicePropertyVolumeScalar, element: element)
            AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        }
        watchedVolume = (device, elements)
    }

    private func unwatchVolume() {
        guard let watched = watchedVolume, let volumeBlock else { return }
        for element in watched.elements {
            var address = AudioObjectPropertyAddress.output(kAudioDevicePropertyVolumeScalar, element: element)
            AudioObjectRemovePropertyListenerBlock(watched.device, &address, queue, volumeBlock)
        }
        watchedVolume = nil
        self.volumeBlock = nil
    }
}
