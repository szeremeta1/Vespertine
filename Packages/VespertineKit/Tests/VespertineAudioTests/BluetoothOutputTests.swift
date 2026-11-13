//
// Vespertine: Bluetooth outputs are not ours to configure. macOS and the headset own the link's rate (A2DP at 44.1 or 48 kHz,
// or a 24 kHz mono call mode while any app has the headset's microphone open), and asking for another one is refused
// ('!dat') for as long as the microphone stays open, so a song that insisted on 48 kHz never started. These tests use a
// simulated headset: two rates (plus the call mode's), no exclusive access, and a link that drops and comes back.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// AirPods Max as macOS lists them: nominal rates 24, 44.1 and 48 kHz, one rate current.
private func headset(rate: Double, channels: Int = 2, transport: Transport = .bluetooth, id: UInt32 = 7001) -> OutputDevice {
    OutputDevice(id: id, uid: "sim-airpods", name: "Alex’s AirPods Max", manufacturer: "Apple Inc.", modelUID: nil, transport: transport,
                 nominalSampleRate: rate,
                 capabilities: DeviceCapabilities(sampleRates: [24_000, 44_100, 48_000], physicalFormats: [], outputChannels: channels, supportsDoP: false),
                 hasHardwareVolume: true, isDefault: false)
}

private func source(rate: Double) -> SourceFormat {
    SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: rate, bitDepth: 24, channels: 2)
}

@Suite("Bluetooth outputs")
struct BluetoothOutputTests {
    // MARK: Never held

    @Test("A Bluetooth output is never held, whatever the plan or the exclusive setting", arguments: [Transport.bluetooth, .bluetoothLE],
          [OutputPlan.Mode.pcm, .dop, .bitstream])
    func neverHeld(transport: Transport, mode: OutputPlan.Mode) {
        var plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 24, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        plan.mode = mode
        let device = headset(rate: 48_000, transport: transport)
        #expect(device.alwaysShared)
        #expect(!PlaybackEngine.takesDevice(device, plan: plan, exclusiveSetting: true))
        #expect(!PlaybackEngine.takesDevice(device, plan: plan, exclusiveSetting: false))
    }

    // MARK: Never switched

    @Test("The plan only uses the rate the Bluetooth link is at: the headset's other rates are not offered")
    func planningPinsTheRate() {
        #expect(headset(rate: 48_000).planningCapabilities.sampleRates == [48_000])
        #expect(headset(rate: 24_000, channels: 1).planningCapabilities.sampleRates == [24_000])
        #expect(headset(rate: 44_100, transport: .bluetoothLE).planningCapabilities.sampleRates == [44_100])
        // What the picker shows is still what the device lists.
        #expect(headset(rate: 48_000).capabilities.sampleRates == [24_000, 44_100, 48_000])
    }

    @Test("Other outputs keep every rate they list")
    func othersKeepTheirRates() {
        let dac = headset(rate: 48_000, transport: .usb)
        #expect(dac.planningCapabilities == dac.capabilities)
    }

    @Test("Hi-res music on a headset in A2DP is converted to the rate the link is at, not switched to another", arguments: [44_100.0, 48_000])
    func hiResResampledToTheLink(linkRate: Double) {
        for sourceRate in [44_100.0, 48_000, 88_200, 96_000, 192_000] {
            let plan = FormatPlanner.plan(source: source(rate: sourceRate), device: headset(rate: linkRate).planningCapabilities)
            #expect(plan.deviceSampleRate == linkRate, "\(sourceRate) Hz source on a link at \(linkRate) Hz planned \(plan.deviceSampleRate) Hz")
            #expect(plan.channels == 2)
        }
    }

    @Test("A headset in call mode (24 kHz, mono) is played at that, not asked for 48 kHz")
    func callMode() {
        let plan = FormatPlanner.plan(source: source(rate: 96_000), device: headset(rate: 24_000, channels: 1).planningCapabilities)
        #expect(plan.deviceSampleRate == 24_000)
        #expect(plan.channels == 1)
        #expect(plan.resamples)
    }

    // MARK: The signal path says so

    private func path(linkRate: Double, channels: Int = 2) -> SignalPath {
        let device = headset(rate: linkRate, channels: channels)
        let plan = FormatPlanner.plan(source: source(rate: 96_000), device: device.planningCapabilities)
        return SignalPath(source: source(rate: 96_000), decoderName: "test", plan: plan,
                          applied: AppliedFormat(sampleRate: linkRate, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: channels,
                                                 exclusive: false, bufferFrames: 512),
                          deviceName: device.name, deviceUID: device.uid, deviceProfile: device.profile, volume: .hardware)
    }

    @Test("Over a normal link the signal path says the link's rate was kept and the music converted to it")
    func notesTheLink() throws {
        let path = path(linkRate: 48_000)
        #expect(!path.isBluetoothCallMode)
        let note = try #require(path.bluetoothNote)
        #expect(note.contains("48"), "\(note)")
        #expect(note.localizedCaseInsensitiveContains("converted"), "\(note)")
        #expect(!path.isBitPerfect)
    }

    @Test("In call mode the signal path says plainly that the headset is in call mode and why")
    func notesCallMode() throws {
        let path = path(linkRate: 24_000, channels: 1)
        #expect(path.isBluetoothCallMode)
        #expect(path.statusLine == "BLUETOOTH · CALL MODE")
        let note = try #require(path.bluetoothNote)
        #expect(note.localizedCaseInsensitiveContains("microphone"), "\(note)")
        #expect(note.contains("24"), "\(note)")
        #expect(!path.isBitPerfect)
    }

    @Test("A USB DAC's signal path has no Bluetooth note")
    func noNoteElsewhere() {
        let dac = headset(rate: 96_000, transport: .usb)
        let plan = FormatPlanner.plan(source: source(rate: 96_000), device: dac.planningCapabilities)
        let path = SignalPath(source: source(rate: 96_000), decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: 96_000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2,
                                                     exclusive: true, bufferFrames: 512),
                              deviceName: "DAC", deviceUID: "dac", deviceProfile: dac.profile, volume: .hardware)
        #expect(path.bluetoothNote == nil)
        #expect(!path.isBluetoothCallMode)
    }
}

// MARK: The engine, on a simulated headset whose link drops and comes back

private final class HeadsetRig: @unchecked Sendable {
    let directory: URL
    let engine = PlaybackEngine()
    let cache: NetworkPlaybackCache
    let listed: Locked<[OutputDevice]>
    /// What each session was opened with: the rate the plan asked the device for, in order.
    let opened = Locked<[Double]>([])

    init(linkRate: Double) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("song.wav")
        try PlayPauseRig.writeWAV(file, rate: 96_000, seconds: 20)
        let share = ControlledShare(data: try Data(contentsOf: file), bytesPerSecond: 1_073_741_824)
        cache = NetworkPlaybackCache(directory: directory.appendingPathComponent("cache"), budget: 256 << 20, chunk: 1 << 16, gate: ShareIOGate())
        cache.readerFactory = { _ in share }
        engine.cacheOverride = cache
        listed = Locked([headset(rate: linkRate, channels: linkRate < 32_000 ? 1 : 2)])
        let listed = listed, opened = opened
        engine.outputListing = { listed.withLock { $0 } }
        engine.sessionFactory = { _, plan in
            opened.withLock { $0.append(plan.deviceSampleRate) }
            return try OutputSession(simulating: plan, rate: plan.deviceSampleRate)
        }
        var settings = EngineSettings()
        settings.deviceUID = "sim-airpods"
        settings.exclusive = true
        engine.update(settings: settings)
    }

    deinit {
        engine.stopAndWait()
        try? FileManager.default.removeItem(at: directory)
    }

    var item: PlayableItem { PlayableItem(url: URL(fileURLWithPath: "/share/song.wav"), cacheKey: "bluetooth-song") }

    /// The headset drops off the Mac, or comes back with the link at `rate` (a reconnect can land in either mode).
    func disconnect() { listed.withLock { $0.removeAll() }; engine.devicesChanged() }
    func reconnect(linkRate: Double) {
        listed.withLock { $0 = [headset(rate: linkRate, channels: linkRate < 32_000 ? 1 : 2, id: 7002)] }
        engine.devicesChanged()
    }

    func runScript<T: Sendable>(_ script: @escaping @Sendable (HeadsetRig) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try script(self) }) }
            thread.name = "Bluetooth script"
            thread.start()
        }
    }

    func wait(timeout: Double = 60, _ condition: (EngineSnapshot) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(engine.snapshot) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition(engine.snapshot)
    }
}

private struct HeadsetSeen: Sendable {
    var playing = false
    var dropped = false
    var resumed = false
    var opened: [Double] = []
    var stoppedAt = 0.0
    var positionAfter = 0.0
}

@Suite("A Bluetooth headset through the engine")
struct BluetoothEngineTests {
    @Test("In call mode the song plays at the call mode's 24 kHz instead of waiting for a 48 kHz switch the headset refuses")
    func playsInCallMode() async throws {
        let rig = try HeadsetRig(linkRate: 24_000)
        let seen = try await rig.runScript { rig -> HeadsetSeen in
            var seen = HeadsetSeen()
            rig.engine.play(rig.item)
            seen.playing = rig.wait { $0.state == .playing && $0.position > 0.2 }
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.opened == [24_000])
    }

    @Test("The link drops mid-song and comes back in A2DP at another rate: the song carries on at the rate it came back at")
    func survivesAReconnect() async throws {
        let rig = try HeadsetRig(linkRate: 48_000)
        let seen = try await rig.runScript { rig -> HeadsetSeen in
            var seen = HeadsetSeen()
            rig.engine.play(rig.item)
            seen.playing = rig.wait { $0.state == .playing && $0.position > 0.2 }
            Thread.sleep(forTimeInterval: 0.3)
            rig.disconnect()
            seen.dropped = rig.wait { $0.state == .paused && $0.waitingForDevice != nil }
            seen.stoppedAt = rig.engine.snapshot.position
            rig.reconnect(linkRate: 44_100)
            let stoppedAt = seen.stoppedAt
            seen.resumed = rig.wait { $0.state == .playing && $0.waitingForDevice == nil && $0.position > stoppedAt + 0.2 }
            seen.positionAfter = rig.engine.snapshot.position
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.dropped)
        #expect(seen.resumed)
        #expect(seen.positionAfter >= seen.stoppedAt)
        #expect(seen.opened == [48_000, 44_100], "each open used the rate the link was at, never another")
    }

    @Test("It comes back in call mode: the song carries on there too")
    func reconnectsIntoCallMode() async throws {
        let rig = try HeadsetRig(linkRate: 48_000)
        let seen = try await rig.runScript { rig -> HeadsetSeen in
            var seen = HeadsetSeen()
            rig.engine.play(rig.item)
            seen.playing = rig.wait { $0.state == .playing && $0.position > 0.2 }
            rig.disconnect()
            seen.dropped = rig.wait { $0.state == .paused && $0.waitingForDevice != nil }
            rig.reconnect(linkRate: 24_000)
            seen.resumed = rig.wait { $0.state == .playing && $0.waitingForDevice == nil }
            seen.opened = rig.opened.withLock { $0 }
            return seen
        }
        #expect(seen.playing)
        #expect(seen.dropped)
        #expect(seen.resumed)
        #expect(seen.opened == [48_000, 24_000])
    }
}
