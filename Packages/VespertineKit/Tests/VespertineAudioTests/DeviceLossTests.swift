//
// Vespertine: an output unplugged mid-song and plugged back in, through the engine's device seams (`outputListing`,
// `sessionFactory`): no Core Audio device and no sound. Everything the rig plays through is its own (cache, share gate,
// share), so suites running beside it (stalled shares, the shared cache) can't hold it up. Each scenario runs on a thread
// of its own and records what it saw (see RigThreadSupport.swift): a test task that waits with `Task.sleep` resumes on one
// of Swift's few cooperative threads, late when other suites hold them all. Waits are on conditions, with generous patience.
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
    /// The song, served from memory through a cache and a share gate of the rig's own. A plain local file would be
    /// checked for a network mount on GCD's shared pool, which suites that stall shares on purpose can keep busy for
    /// many seconds.
    let cache: NetworkPlaybackCache
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
        let file = directory.appendingPathComponent("song.wav")
        try PlayPauseRig.writeWAV(file, rate: Self.rate, seconds: 20)
        let share = ControlledShare(data: try Data(contentsOf: file), bytesPerSecond: 1_073_741_824)
        cache = NetworkPlaybackCache(directory: directory.appendingPathComponent("cache"), budget: 256 << 20, chunk: 1 << 16,
                                     gate: ShareIOGate())
        cache.readerFactory = { _ in share }
        engine.cacheOverride = cache
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

    var item: PlayableItem { PlayableItem(url: URL(fileURLWithPath: "/share/song.wav"), cacheKey: "device-loss-song") }

    /// The DAC leaves the list, or comes back; then the notice Core Audio would give.
    func unplug() { listed.withLock { $0.removeAll { $0.uid == dac.uid } }; engine.devicesChanged() }
    func replug() { listed.withLock { $0.insert(dac, at: 0) }; engine.devicesChanged() }
    /// Something else changed in the device list (another device came or went); the DAC is still there.
    func otherDeviceChanged() { engine.devicesChanged() }

    /// Runs `script` on a thread of its own and returns what it returns, without holding a cooperative thread meanwhile.
    func runScript<T: Sendable>(_ script: @escaping @Sendable (DeviceLossRig) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try script(self) }) }
            thread.name = "Device loss script"
            thread.start()
        }
    }

    /// For a script: waits until `condition` holds of the snapshot; false only when it still doesn't after `timeout`.
    func wait(timeout: Double = 60, _ condition: (EngineSnapshot) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(engine.snapshot) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition(engine.snapshot)
    }

    /// For a script: plays the song and waits until it is heard moving.
    func playing() -> Bool {
        engine.play(item)
        return wait { $0.state == .playing && $0.position > 0.2 }
    }

    func sleep(ms: Int) { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
}

/// What a scenario saw, judged by the test afterwards.
private struct Seen: Sendable {
    var playing = false
    var condition = false
    var laterState: PlaybackState?
    var waiting: String?
    var stoppedAt = 0.0
    var resumed = false
    var positionAfter = 0.0
    var opened: [String] = []
}

@Suite("An output unplugged mid-song")
struct DeviceLossTests {
    @Test("A device list change that leaves the output connected doesn't interrupt the song")
    func stillConnected() async throws {
        let rig = try DeviceLossRig(chosen: true)
        let seen = try await rig.runScript { rig -> Seen in
            var seen = Seen()
            seen.playing = rig.playing()
            let before = rig.engine.snapshot.position
            rig.otherDeviceChanged()
            seen.condition = rig.wait { $0.state == .playing && $0.position > before + 0.5 }
            seen.waiting = rig.engine.snapshot.waitingForDevice
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.condition)
        #expect(seen.waiting == nil)
        #expect(seen.opened == ["sim-dac"])
    }

    @Test("The chosen output unplugged mid-song: playback waits for it, says so, and never moves to another output")
    func chosenUnplugged() async throws {
        let rig = try DeviceLossRig(chosen: true)
        let seen = try await rig.runScript { rig -> Seen in
            var seen = Seen()
            seen.playing = rig.playing()
            rig.unplug()
            seen.condition = rig.wait { $0.state == .paused && $0.waitingForDevice == "Downstairs DAC" }
            rig.sleep(ms: 500)
            seen.laterState = rig.engine.snapshot.state
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.condition)
        #expect(seen.laterState == .paused)
        #expect(seen.opened == ["sim-dac"], "nothing opened on the other output while waiting")
    }

    @Test("Plugged back in, the song carries on from where it stopped, on the same output")
    func replugged() async throws {
        let rig = try DeviceLossRig(chosen: true)
        let seen = try await rig.runScript { rig -> Seen in
            var seen = Seen()
            seen.playing = rig.playing()
            rig.sleep(ms: 300)
            rig.unplug()
            seen.condition = rig.wait { $0.state == .paused && $0.waitingForDevice != nil }
            seen.stoppedAt = rig.engine.snapshot.position
            rig.replug()
            let stoppedAt = seen.stoppedAt
            seen.resumed = rig.wait { $0.state == .playing && $0.waitingForDevice == nil && $0.position > stoppedAt + 0.2 }
            seen.positionAfter = rig.engine.snapshot.position
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.condition)
        #expect(seen.resumed)
        #expect(seen.positionAfter >= seen.stoppedAt, "resumed where it stopped, not from the start")
        #expect(seen.opened == ["sim-dac", "sim-dac"])
    }

    @Test("Following the Mac's sound output: the output unplugged mid-song pauses there, never moving to the new default")
    func followingDefaultUnplugged() async throws {
        let rig = try DeviceLossRig(chosen: false)
        let seen = try await rig.runScript { rig -> Seen in
            var seen = Seen()
            seen.playing = rig.playing()
            rig.unplug()
            seen.condition = rig.wait { $0.state == .paused }
            rig.sleep(ms: 500)
            seen.laterState = rig.engine.snapshot.state
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.condition)
        #expect(seen.laterState == .paused)
        #expect(seen.opened == ["sim-dac"], "the song isn't moved to another output by itself")
    }
}
