//
// Vespertine: observes device arrival/removal, default-output changes and hardware volume.
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
    /// The elements whose volume is settable (`DeviceQuery.volumeElements`).
    func volumeElements(of device: AudioObjectID) -> [UInt32]
    /// Calls `action` on `queue` when any of `addresses` of the device changes; the result stops it.
    func observe(_ device: AudioObjectID, _ addresses: [AudioObjectPropertyAddress], on queue: DispatchQueue,
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

    func volumeElements(of device: AudioObjectID) -> [UInt32] { DeviceQuery.volumeElements(device) }

    func observe(_ device: AudioObjectID, _ addresses: [AudioObjectPropertyAddress], on queue: DispatchQueue,
                 _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        Self.listen(device, addresses, queue, action)
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
    /// `format`: the watched output's rate or channels changed (AirPods going into or out of call mode): the device list is
    /// out of date, though no device came or went.
    public enum Change: Sendable { case devices, volume, format }

    private let queue: DispatchQueue
    private let provider: DeviceProvider
    private let onChange: @Sendable (Change) -> Void
    private let recheckInterval: DispatchTimeInterval
    private let recheckWindow: TimeInterval
    private var stopSystem: (@Sendable () -> Void)?
    private var stopVolume: (@Sendable () -> Void)?
    private var stopFormat: (@Sendable () -> Void)?

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

    /// Follows hardware volume (and mute) changes of one device, e.g. from the keyboard or the DAC, and its rate and output
    /// channels (`Change.format`): a Bluetooth headset that macOS moves into call mode stays the same device, so nothing else
    /// says that what the device list holds for it (24 kHz, mono, the call-mode warning) has changed.
    public func watchVolume(of device: AudioObjectID?) {
        unwatchVolume()
        guard let device else { return }
        stopFormat = provider.observe(device, Self.formatAddresses, on: queue) { [onChange] in onChange(.format) }
        let elements = provider.volumeElements(of: device)
        guard !elements.isEmpty else { return }
        stopVolume = provider.observe(device, Self.volumeAddresses(elements: elements), on: queue) { [onChange] in onChange(.volume) }
    }

    /// What `watchVolume` listens to on a device whose volume is settable on `elements`: the volume there, and the mute,
    /// which a device has on its main control or per channel (the ones it lacks are not listened to).
    static func volumeAddresses(elements: [UInt32]) -> [AudioObjectPropertyAddress] {
        let muteElements = [kAudioObjectPropertyElementMain] + elements.filter { $0 != kAudioObjectPropertyElementMain }
        return elements.map { AudioObjectPropertyAddress.output(kAudioDevicePropertyVolumeScalar, element: $0) }
            + muteElements.map { AudioObjectPropertyAddress.output(kAudioDevicePropertyMute, element: $0) }
    }

    /// What the format watch listens to: the nominal rate and the output streams' channels.
    static let formatAddresses: [AudioObjectPropertyAddress] = [
        .global(kAudioDevicePropertyNominalSampleRate),
        .output(kAudioDevicePropertyStreamConfiguration),
    ]

    private func unwatchVolume() {
        stopVolume?()
        stopVolume = nil
        stopFormat?()
        stopFormat = nil
    }
}
