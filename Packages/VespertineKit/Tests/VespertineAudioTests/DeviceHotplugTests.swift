//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

/// Core Audio as `DeviceMonitor` sees it, driven by hand. Notices are delivered on the queue the monitor gave.
private final class FakeDeviceProvider: DeviceProvider, @unchecked Sendable {
    private struct Observer { let device: AudioObjectID?; let queue: DispatchQueue; let action: @Sendable () -> Void }
    private let state = Locked((outputs: [AudioObjectID: Bool](), observers: [Int: Observer](), next: 0))

    init(_ devices: [AudioObjectID: Bool]) { state.withLock { $0.outputs = devices } }

    func deviceIDs() -> [AudioObjectID] { state.withLock { $0.outputs.keys.sorted() } }
    func hasOutput(_ device: AudioObjectID) -> Bool { state.withLock { $0.outputs[device] ?? false } }

    func observeSystem(on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        observe(nil, queue, action)
    }

    func observeStreams(of device: AudioObjectID, on queue: DispatchQueue,
                        _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        observe(device, queue, action)
    }

    private func observe(_ device: AudioObjectID?, _ queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let key = state.withLock { s in
            s.next += 1
            s.observers[s.next] = Observer(device: device, queue: queue, action: action)
            return s.next
        }
        return { [weak self] in self?.state.withLock { _ = $0.observers.removeValue(forKey: key) } }
    }

    /// Stream listeners currently installed on `device`.
    func streamObservers(of device: AudioObjectID) -> Int {
        state.withLock { $0.observers.values.filter { $0.device == device }.count }
    }

    /// A device joins the list, as `kAudioHardwarePropertyDevices` reports it.
    func add(_ device: AudioObjectID, hasOutput: Bool) {
        state.withLock { $0.outputs[device] = hasOutput }
        notify(nil)
    }

    func remove(_ device: AudioObjectID) {
        state.withLock { _ = $0.outputs.removeValue(forKey: device) }
        notify(nil)
    }

    /// The device publishes its output streams, with or without a stream notice.
    func publishStreams(of device: AudioObjectID, notify sendNotice: Bool) {
        state.withLock { $0.outputs[device] = true }
        if sendNotice { notify(device) }
    }

    private func notify(_ device: AudioObjectID?) {
        let targets = state.withLock { $0.observers.values.filter { $0.device == device } }
        for o in targets { o.queue.async(execute: o.action) }
    }
}

private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock(), end = clock.now + timeout
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let zd3: AudioObjectID = 61, airPodsMax: AudioObjectID = 92, microphone: AudioObjectID = 75

@Suite("Device hot-plug")
struct DeviceHotplugTests {
    /// `window`: how long a new device is re-checked. Long by default, so a test held up on a busy machine (the full
    /// suite runs in parallel) can't outlast it; the re-check interval is the app's.
    private func monitor(_ provider: FakeDeviceProvider, changes: Locked<Int>, window: TimeInterval = 600) -> DeviceMonitor {
        DeviceMonitor(provider: provider, queue: DispatchQueue(label: "test.devices"), recheckWindow: window) { change in
            if case .devices = change { changes.withLock { $0 += 1 } }
        }
    }

    @Test("A device whose output streams arrive after it joins the list is reported once they do")
    func streamsArriveLater() async {
        let hal = FakeDeviceProvider([zd3: true])
        let changes = Locked(0)
        let m = monitor(hal, changes: changes)
        // AirPods Max on USB-C: the device list changes before the device has output streams, so a read of the
        // list at that moment leaves it out.
        hal.add(airPodsMax, hasOutput: false)
        #expect(await waitUntil { changes.withLock { $0 } == 1 })
        hal.publishStreams(of: airPodsMax, notify: true)
        #expect(await waitUntil(.seconds(1)) { changes.withLock { $0 } >= 2 }, "no device change after the streams arrived")
        withExtendedLifetime(m) {}
    }

    @Test("Streams that arrive without a notice are found by re-checking within a second")
    func streamsArriveSilently() async {
        let hal = FakeDeviceProvider([zd3: true])
        let changes = Locked(0)
        let m = monitor(hal, changes: changes)
        hal.add(airPodsMax, hasOutput: false)
        #expect(await waitUntil { changes.withLock { $0 } == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        hal.publishStreams(of: airPodsMax, notify: false)
        #expect(await waitUntil(.seconds(1)) { changes.withLock { $0 } >= 2 }, "the new device was never re-checked")
        withExtendedLifetime(m) {}
    }

    @Test("Re-checking ends after its window; the stream listener still catches a late device")
    func recheckWindowEnds() async {
        let hal = FakeDeviceProvider([zd3: true])
        let changes = Locked(0)
        let m = monitor(hal, changes: changes, window: 0.2)
        hal.add(airPodsMax, hasOutput: false)
        #expect(await waitUntil { changes.withLock { $0 } == 1 })
        try? await Task.sleep(for: .milliseconds(700))
        hal.publishStreams(of: airPodsMax, notify: false)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(changes.withLock { $0 } == 1)
        hal.publishStreams(of: airPodsMax, notify: true)
        #expect(await waitUntil { changes.withLock { $0 } == 2 })
        withExtendedLifetime(m) {}
    }

    @Test("An input-only device causes no extra changes, and its listener goes when it does")
    func inputOnlyDevice() async {
        let hal = FakeDeviceProvider([zd3: true])
        let changes = Locked(0)
        let m = monitor(hal, changes: changes)
        hal.add(microphone, hasOutput: false)
        #expect(await waitUntil { changes.withLock { $0 } == 1 })
        try? await Task.sleep(for: .milliseconds(600))
        #expect(changes.withLock { $0 } == 1)
        hal.remove(microphone)
        #expect(await waitUntil { changes.withLock { $0 } == 2 })
        #expect(await waitUntil { hal.streamObservers(of: microphone) == 0 })
        withExtendedLifetime(m) {}
    }

    @Test("Devices with output are not watched, and a listed device stops being watched once it has output")
    func noWatchOnceListed() async {
        let hal = FakeDeviceProvider([zd3: true])
        let changes = Locked(0)
        let m = monitor(hal, changes: changes)
        hal.add(airPodsMax, hasOutput: false)
        #expect(await waitUntil { changes.withLock { $0 } == 1 })
        hal.publishStreams(of: airPodsMax, notify: true)
        #expect(await waitUntil { changes.withLock { $0 } == 2 })
        #expect(await waitUntil { hal.streamObservers(of: airPodsMax) == 0 })
        #expect(hal.streamObservers(of: zd3) == 0)
        withExtendedLifetime(m) {}
    }

    /// The same on Core Audio: a private aggregate device joins the list with no output streams and gets them when
    /// a sub-device is added, as a device that publishes its streams late does. The aggregate is visible to this
    /// process only and goes away with it. Set VESPERTINE_HOTPLUG_SUBDEVICE to an output's name (e.g. "BlackHole 2ch").
    @Test("Core Audio: an output whose streams arrive late is listed within a second",
          .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HOTPLUG_SUBDEVICE"] != nil))
    func halLateStreams() async throws {
        let name = ProcessInfo.processInfo.environment["VESPERTINE_HOTPLUG_SUBDEVICE"] ?? ""
        let sub = try #require(OutputDevices.list().first { $0.name == name }, "no output named \(name)")
        let uid = "org.szeremeta.vespertine.hotplug-test.\(getpid())"
        let changes = Locked(0)
        let m = DeviceMonitor { if case .devices = $0 { changes.withLock { $0 += 1 } } }
        var aggregate = AudioObjectID(0)
        let description: [String: Any] = [kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceNameKey: "Hot-plug test",
                                          kAudioAggregateDeviceIsPrivateKey: 1]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "create aggregate")
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }
        #expect(await waitUntil { changes.withLock { $0 } >= 1 })
        #expect(DeviceQuery.outputChannelCount(aggregate) == 0)
        #expect(!OutputDevices.list().contains { $0.uid == uid }, "listed before it has output")
        try? await Task.sleep(for: .milliseconds(300))
        let before = changes.withLock { $0 }
        var subDevices = [sub.uid] as CFArray
        var address = AudioObjectPropertyAddress.global(kAudioAggregateDevicePropertyFullSubDeviceList)
        try check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), &subDevices),
                  "set sub-devices")
        #expect(await waitUntil(.seconds(1)) { changes.withLock { $0 } > before }, "no device change after streams arrived")
        #expect(OutputDevices.list().contains { $0.uid == uid })
        withExtendedLifetime(m) {}
    }
}
