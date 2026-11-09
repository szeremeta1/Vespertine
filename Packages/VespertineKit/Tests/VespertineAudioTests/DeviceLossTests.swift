//
// Vespertine — an output unplugged mid-song and plugged back in, through the engine's device seams (`outputListing`,
// `sessionFactory`): no Core Audio device and no sound.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// The real engine thread on simulated outputs, with a device list the test changes.
private final class DeviceLossRig: @unchecked Sendable {
    static let rate = 48_000.0
    let directory: URL
    let engine = PlaybackEngine()
    let listed: Locked<[OutputDevice]>
    /// The output each session was opened on, in order.
    let opened = Locked<[String]>([])
    let dac: OutputDevice
    let speakers: OutputDevice

    static func device(id: UInt32, uid: String, name: String, isDefault: Bool) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: rate,
                     capabilities: DeviceCapabilities(sampleRates: [44_100, 48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                     hasHardwareVolume: false, isDefault: isDefault)
    }

    /// `chosen`: the DAC is the chosen output; otherwise playback follows the Mac's sound output, which is the DAC at first.
    init(chosen: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("device-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PlayPauseRig.writeWAV(directory.appendingPathComponent("song.wav"), rate: Self.rate, seconds: 20)
        dac = Self.device(id: 4243, uid: "sim-dac", name: "Downstairs DAC", isDefault: true)
        speakers = Self.device(id: 4244, uid: "sim-speakers", name: "Desk speakers", isDefault: false)
        listed = Locked([dac, speakers])
        let listed = listed, opened = opened
        engine.outputListing = { listed.withLock { $0 } }
        engine.sessionFactory = { device, plan in
            opened.withLock { $0.append(device.uid) }
            return try OutputSession(simulating: plan, rate: plan.deviceSampleRate)
        }
        var settings = EngineSettings()
        settings.deviceUID = chosen ? dac.uid : nil
        settings.exclusive = true
        engine.update(settings: settings)
    }

    deinit {
        engine.stopAndWait()
        try? FileManager.default.removeItem(at: directory)
    }

    var item: PlayableItem { PlayableItem(url: directory.appendingPathComponent("song.wav")) }

    /// The DAC leaves the list, or comes back; then the notice Core Audio would give.
    func unplug() { listed.withLock { $0.removeAll { $0.uid == dac.uid } }; engine.devicesChanged() }
    func replug() { listed.withLock { $0.insert(dac, at: 0) }; engine.devicesChanged() }
    /// Something else changed in the device list (another device came or went); the DAC is still there.
    func otherDeviceChanged() { engine.devicesChanged() }

    /// Waits until `condition` holds of the snapshot (false on timeout).
    func wait(timeout: Double = 10, _ condition: (EngineSnapshot) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(engine.snapshot) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func playing() async -> Bool {
        engine.play(item)
        return await wait { $0.state == .playing && $0.position > 0.2 }
    }
}

@Suite("An output unplugged mid-song")
struct DeviceLossTests {
    @Test("A device list change that leaves the output connected doesn't interrupt the song")
    func stillConnected() async throws {
        let rig = try DeviceLossRig(chosen: true)
        #expect(await rig.playing())
        let before = rig.engine.snapshot.position
        rig.otherDeviceChanged()
        #expect(await rig.wait { $0.state == .playing && $0.position > before + 0.5 })
        #expect(rig.engine.snapshot.waitingForDevice == nil)
        #expect(rig.opened.withLock { $0 } == ["sim-dac"])
    }

    @Test("The chosen output unplugged mid-song: playback waits for it, says so, and never moves to another output")
    func chosenUnplugged() async throws {
        let rig = try DeviceLossRig(chosen: true)
        #expect(await rig.playing())
        rig.unplug()
        #expect(await rig.wait { $0.state == .paused && $0.waitingForDevice == "Downstairs DAC" })
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.engine.snapshot.state == .paused)
        #expect(rig.opened.withLock { $0 } == ["sim-dac"], "nothing opened on the other output while waiting")
    }

    @Test("Plugged back in, the song carries on from where it stopped, on the same output")
    func replugged() async throws {
        let rig = try DeviceLossRig(chosen: true)
        #expect(await rig.playing())
        try await Task.sleep(for: .milliseconds(300))
        rig.unplug()
        #expect(await rig.wait { $0.state == .paused && $0.waitingForDevice != nil })
        let stoppedAt = rig.engine.snapshot.position
        rig.replug()
        #expect(await rig.wait { $0.state == .playing && $0.waitingForDevice == nil && $0.position > stoppedAt + 0.2 })
        #expect(rig.engine.snapshot.position >= stoppedAt, "resumed where it stopped, not from the start")
        #expect(rig.opened.withLock { $0 } == ["sim-dac", "sim-dac"])
    }

    @Test("Following the Mac's sound output: the output unplugged mid-song pauses there, never moving to the new default")
    func followingDefaultUnplugged() async throws {
        let rig = try DeviceLossRig(chosen: false)
        #expect(await rig.playing())
        rig.unplug()
        #expect(await rig.wait { $0.state == .paused })
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.engine.snapshot.state == .paused)
        #expect(rig.opened.withLock { $0 } == ["sim-dac"], "the song isn't moved to another output by itself")
    }
}
