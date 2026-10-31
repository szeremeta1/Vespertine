//
// Vespertine — observes device arrival/removal, default-output changes and hardware volume.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum OutputDevices {
    /// UIDs of the connected outputs: cheap, no formats read.
    public static func connectedUIDs() -> Set<String> { DeviceQuery.outputUIDs() }

    public static func list(dopEnabledUIDs: Set<String> = []) -> [OutputDevice] {
        DeviceQuery.outputDevices(dopEnabledUIDs: dopEnabledUIDs)
    }
}

/// What `DeviceMonitor` reads and listens to: Core Audio in the app, a fake in tests.
protocol DeviceProvider: AnyObject, Sendable {
    func deviceIDs() -> [AudioObjectID]
    /// Whether the device has output channels now, the test `DeviceQuery.snapshot` lists a device by.
    func hasOutput(_ device: AudioObjectID) -> Bool
    /// Calls `action` on `queue` when the device list or the default output changes; the result stops it.
    func observeSystem(on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void
    /// Calls `action` on `queue` when the device's output streams or their channels change; the result stops it.
    func observeStreams(of device: AudioObjectID, on queue: DispatchQueue,
                        _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

final class HALDeviceProvider: DeviceProvider {
    private static let systemAddresses: [AudioObjectPropertyAddress] = [
        .global(kAudioHardwarePropertyDevices),
        .global(kAudioHardwarePropertyDefaultOutputDevice),
    ]
    private static let streamAddresses: [AudioObjectPropertyAddress] = [
        .output(kAudioDevicePropertyStreams),
        .output(kAudioDevicePropertyStreamConfiguration),
    ]

    func deviceIDs() -> [AudioObjectID] { DeviceQuery.allDeviceIDs() }
    func hasOutput(_ device: AudioObjectID) -> Bool { DeviceQuery.outputChannelCount(device) > 0 }

    func observeSystem(on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        Self.listen(AudioObjectID(kAudioObjectSystemObject), Self.systemAddresses, queue, action)
    }

    func observeStreams(of device: AudioObjectID, on queue: DispatchQueue,
                        _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        Self.listen(device, Self.streamAddresses, queue, action)
    }

    private static func listen(_ object: AudioObjectID, _ addresses: [AudioObjectPropertyAddress], _ queue: DispatchQueue,
                               _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in action() }
        let added = addresses.filter { address in
            var a = address
            return AudioObjectAddPropertyListenerBlock(object, &a, queue, block) == noErr
        }
        return {
            for address in added {
                var a = address
                AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
            }
        }
    }
}

public final class DeviceMonitor: @unchecked Sendable {
    public enum Change: Sendable { case devices, volume }

    private let queue: DispatchQueue
    private let provider: DeviceProvider
    private let onChange: @Sendable (Change) -> Void
    private var stopSystem: (@Sendable () -> Void)?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var watchedVolume: (device: AudioObjectID, elements: [UInt32])?

    public convenience init(onChange: @escaping @Sendable (Change) -> Void) {
        self.init(provider: HALDeviceProvider(), queue: DispatchQueue(label: "org.szeremeta.vespertine.devices"),
                  onChange: onChange)
    }

    init(provider: DeviceProvider, queue: DispatchQueue, onChange: @escaping @Sendable (Change) -> Void) {
        self.provider = provider
        self.queue = queue
        self.onChange = onChange
        stopSystem = provider.observeSystem(on: queue) { onChange(.devices) }
    }

    deinit {
        stopSystem?()
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
