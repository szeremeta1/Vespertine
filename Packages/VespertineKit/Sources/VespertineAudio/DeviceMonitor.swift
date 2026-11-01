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

/// Reports device arrival and removal, default-output changes and hardware volume.
///
/// Core Audio announces a new device (`kAudioHardwarePropertyDevices`) before every device has published its output
/// streams: AirPods Max on USB-C join the list with none, and a read of the list at that moment leaves them out
/// (`DeviceQuery.snapshot` lists devices with output channels only). Nothing else changes after that, so the device
/// stayed missing until the default output moved. Every device without output is therefore watched for streams
/// arriving, and one that just joined is also re-checked a few times a second for a while, in case no notice comes.
public final class DeviceMonitor: @unchecked Sendable {
    public enum Change: Sendable { case devices, volume }

    private let queue: DispatchQueue
    private let provider: DeviceProvider
    private let onChange: @Sendable (Change) -> Void
    private let recheckInterval: DispatchTimeInterval
    private let recheckWindow: TimeInterval
    private var stopSystem: (@Sendable () -> Void)?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var watchedVolume: (device: AudioObjectID, elements: [UInt32])?

    // On `queue` only.
    private var known: Set<AudioObjectID> = []
    /// Devices without output yet, with the listener on their streams and when re-checking them ends.
    private var waiting: [AudioObjectID: (stop: @Sendable () -> Void, recheckUntil: Date?)] = [:]

    public convenience init(onChange: @escaping @Sendable (Change) -> Void) {
        self.init(provider: HALDeviceProvider(), queue: DispatchQueue(label: "org.szeremeta.vespertine.devices"),
                  onChange: onChange)
    }

    init(provider: DeviceProvider, queue: DispatchQueue, recheckInterval: DispatchTimeInterval = .milliseconds(250),
         recheckWindow: TimeInterval = 15, onChange: @escaping @Sendable (Change) -> Void) {
        self.provider = provider
        self.queue = queue
        self.recheckInterval = recheckInterval
        self.recheckWindow = recheckWindow
        self.onChange = onChange
        stopSystem = provider.observeSystem(on: queue) { [weak self] in
            onChange(.devices)
            self?.scan(arrivals: true)
        }
        // At once, so a device that joins right after this counts as new. One cheap read, like the list at launch.
        queue.sync { scan(arrivals: false) }
    }

    deinit {
        stopSystem?()
        for entry in waiting.values { entry.stop() }
        unwatchVolume()
    }

    /// Starts watching devices without output and stops watching those that are gone. `arrivals`: devices new since
    /// the last scan are re-checked too (at launch nothing is new, but a device mid-arrival still gets its listener).
    private func scan(arrivals: Bool) {
        let ids = provider.deviceIDs()
        let present = Set(ids)
        for (id, entry) in waiting where !present.contains(id) {
            entry.stop()
            waiting[id] = nil
        }
        for id in ids where waiting[id] == nil && !provider.hasOutput(id) {
            let isNew = arrivals && !known.contains(id)
            let stop = provider.observeStreams(of: id, on: queue) { [weak self] in self?.check(id) }
            waiting[id] = (stop, isNew ? Date().addingTimeInterval(recheckWindow) : nil)
            if isNew { scheduleRecheck(id) }
        }
        known = present
    }

    private func scheduleRecheck(_ id: AudioObjectID) {
        queue.asyncAfter(deadline: .now() + recheckInterval) { [weak self] in
            guard let self, let until = self.waiting[id]?.recheckUntil else { return }
            if !self.check(id), Date() < until { self.scheduleRecheck(id) }
        }
    }

    /// Reports a device change once a watched device has output.
    @discardableResult
    private func check(_ id: AudioObjectID) -> Bool {
        guard let entry = waiting[id], provider.hasOutput(id) else { return false }
        entry.stop()
        waiting[id] = nil
        onChange(.devices)
        return true
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
