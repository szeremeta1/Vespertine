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
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), "Engine did not reach expected state before deadline")
    }
}
