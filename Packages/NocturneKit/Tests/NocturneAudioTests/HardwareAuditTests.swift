import Foundation
import Testing
@testable import NocturneAudio

@Suite("Silent hardware integration", .serialized)
struct HardwareAuditTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCTURNE_HARDWARE_TESTS"] == "1"))
    func transportAndQueueInvalidation() async throws {
        let device = try #require(OutputDevices.list().first { $0.transport == .builtIn })
        let rate = device.nominalSampleRate
        let url = try writeWAV("hardware-silence", rate: rate, bits: 16, seconds: 4) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = PlaybackEngine()
        defer { engine.stop() }
        var settings = EngineSettings(); settings.deviceUID = device.uid; settings.exclusive = false
        settings.ratePolicies[device.uid] = .fixed(rate)
        engine.update(settings: settings)
        let item = PlayableItem(url: url)
        engine.play(item)
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 0.05 }
        #expect(engine.snapshot.signalPath?.applied.sampleRate == rate)
        engine.pause()
        try await wait { engine.snapshot.state == .paused }
        let paused = engine.snapshot.position
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(engine.snapshot.position - paused) < 0.04)
        engine.seek(to: 2)
        try await wait { engine.snapshot.position >= 1.99 }
        #expect(engine.snapshot.state == .paused)
        engine.resume()
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 2.05 }
        settings.digitalVolumeDB = -12
        engine.update(settings: settings)
        try await wait { engine.snapshot.signalPath?.modifiesSamples == true }
        engine.queueChanged()
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 2.15 }
        engine.seek(to: 1e200)
        try await wait { engine.snapshot.state == .stopped }
        engine.play(item)
        try await wait { engine.snapshot.state == .playing }
        for _ in 0..<20 { engine.pause(); engine.seek(to: 0.5); engine.resume() }
        engine.stop()
        try await wait { engine.snapshot.state == .stopped && engine.snapshot.outputDevice == nil }
    }
    /// Shuffle/repeat/queue edits must not interrupt the song that's playing: it isn't reopened
    /// (no second `trackStarted`), and what follows it comes from the new queue.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCTURNE_HARDWARE_TESTS"] == "1"))
    func queueChangeKeepsCurrentSongPlaying() async throws {
        let device = try #require(OutputDevices.list().first { $0.transport == .builtIn })
        let rate = device.nominalSampleRate
        let url = try writeWAV("hardware-queue", rate: rate, bits: 16, seconds: 2) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = PlaybackEngine()
        defer { engine.stop() }
        var settings = EngineSettings(); settings.deviceUID = device.uid; settings.exclusive = false
        settings.ratePolicies[device.uid] = .fixed(rate)
        engine.update(settings: settings)

        let a = PlayableItem(url: url), b = PlayableItem(url: url), c = PlayableItem(url: url), d = PlayableItem(url: url)
        let next = Locked<[UUID: PlayableItem]>([a.id: b])
        let started = Locked<[UUID]>([])
        engine.nextItemProvider = { finished in next.value[finished.id] }
        engine.eventHandler = { event in if case .trackStarted(let item) = event { started.value.append(item.id) } }

        // A 2 s song is decoded long before it ends, so B is already lined up in the ring.
        engine.play(a)
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 0.4 }
        let before = engine.snapshot.position
        next.value = [a.id: c]                          // e.g. shuffle picked a different next song
        engine.queueChanged()
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.snapshot.position > before)       // kept going; a restart would have re-buffered
        try await wait { started.value.count >= 2 }
        #expect(started.value == [a.id, c.id])           // A never restarted; C replaced B

        // End of the queue (repeat off), then repeat switched on while the last song plays.
        next.value = [:]
        engine.queueChanged()
        try await Task.sleep(for: .milliseconds(300))
        next.value = [c.id: d]
        engine.queueChanged()
        try await wait { started.value.count >= 3 }
        #expect(started.value == [a.id, c.id, d.id])
        engine.stop()
    }

    /// A chosen output that's missing (AirPods put back on but not reconnected yet) is waited for,
    /// never swapped for another device; playback starts on it as soon as it's there.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCTURNE_HARDWARE_TESTS"] == "1"))
    func missingChosenOutputIsWaitedFor() async throws {
        let device = try #require(OutputDevices.list().first { $0.transport == .builtIn })
        let rate = device.nominalSampleRate
        let url = try writeWAV("hardware-wait", rate: rate, bits: 16, seconds: 3) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = PlaybackEngine(deviceWait: 1.5)
        defer { engine.stop() }
        let events = Locked<[String]>([])
        engine.eventHandler = { event in
            switch event {
            case .waitingForDevice: events.value.append("waiting")
            case .deviceUnavailable: events.value.append("unavailable")
            case .failed: events.value.append("failed")
            default: break
            }
        }
        var settings = EngineSettings(); settings.exclusive = false
        settings.ratePolicies[device.uid] = .fixed(rate)
        settings.deviceUID = "nocturne-test:absent-output"
        engine.update(settings: settings)
        let item = PlayableItem(url: url)

        // Missing: nothing plays anywhere, the song waits.
        engine.play(item)
        try await wait { engine.snapshot.waitingForDevice != nil }
        #expect(engine.snapshot.state == .paused && engine.snapshot.outputDevice == nil)
        #expect(engine.snapshot.item?.id == item.id)

        // The output "comes back" (here: the chosen output becomes one that exists): playback starts on it.
        settings.deviceUID = device.uid
        engine.update(settings: settings)
        try await wait { engine.snapshot.state == .playing && engine.snapshot.outputDevice?.uid == device.uid }
        #expect(engine.snapshot.waitingForDevice == nil)

        // Gone for good: gives up after the wait, stays paused, and says so.
        settings.deviceUID = "nocturne-test:absent-output"
        engine.update(settings: settings)
        try await wait { engine.snapshot.waitingForDevice != nil }
        try await wait { engine.snapshot.waitingForDevice == nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.snapshot.state == .paused)
        #expect(events.value == ["waiting", "waiting", "unavailable"])

        // Pause cancels a wait.
        engine.resume()
        try await wait { engine.snapshot.waitingForDevice != nil }
        engine.pause()
        try await wait { engine.snapshot.waitingForDevice == nil }
        #expect(engine.snapshot.state == .paused)
        #expect(!events.value.contains("failed"))
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), "Engine did not reach expected state before deadline")
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
