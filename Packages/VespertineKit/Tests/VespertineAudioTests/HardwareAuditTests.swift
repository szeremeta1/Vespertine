import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Silent hardware integration", .serialized)
struct HardwareAuditTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"))
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"))
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"))
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
        settings.deviceUID = "vespertine-test:absent-output"
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
        settings.deviceUID = "vespertine-test:absent-output"
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

    /// A track streaming from a share moves to its local copy once the copy is complete, mid-track,
    /// without restarting it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"))
    func streamingTrackMovesToLocalCopy() async throws {
        let device = try #require(OutputDevices.list().first { $0.transport == .builtIn })
        let rate = device.nominalSampleRate
        // Longer than the output buffer, so decoding is still under way when the copy completes.
        let share = try writeWAV("hardware-share", rate: rate, bits: 16, seconds: 60) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: share) }
        let copy = share.deletingLastPathComponent().appendingPathComponent("copy-\(UUID()).wav")
        try FileManager.default.copyItem(at: share, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let engine = PlaybackEngine()
        defer { engine.stop() }
        var settings = EngineSettings(); settings.deviceUID = device.uid; settings.exclusive = false
        settings.ratePolicies[device.uid] = .fixed(rate)
        engine.update(settings: settings)
        let copied = Locked(false)
        engine.urlResolver = { item in copied.value ? copy : item.url }
        let started = Locked(0)
        engine.eventHandler = { event in if case .trackStarted = event { started.value += 1 } }

        let item = PlayableItem(url: share, cacheKey: "test")
        engine.play(item)
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 0.3 }
        #expect(engine.snapshot.readingFromShare)
        let before = engine.snapshot.position
        copied.value = true                                  // the cache finished copying it
        try await wait { !engine.snapshot.readingFromShare }
        #expect(engine.snapshot.state == .playing)
        #expect(engine.snapshot.position >= before)          // carried on, not restarted
        #expect(started.value == 1)
        engine.stop()
    }

    /// Dolby Atmos goes to macOS's renderer (objects rendered by the system) and back to Vespertine's own
    /// path for the next track. Set VESPERTINE_ATMOS_FILE to a Dolby Digital Plus + Atmos (JOC) file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"
                   && ProcessInfo.processInfo.environment["VESPERTINE_ATMOS_FILE"] != nil))
    func atmosRenderedBySystem() async throws {
        let atmos = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VESPERTINE_ATMOS_FILE"]!)
        #expect(try SourceOpener.probe(atmos).format.codec == DolbyAtmos.codecName)
        let device = try #require(OutputDevices.list().first { $0.transport == .builtIn })
        let rate = device.nominalSampleRate
        let after = try writeWAV("hardware-after-atmos", rate: rate, bits: 16, seconds: 1) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: after) }
        let engine = PlaybackEngine()
        defer { engine.stop() }
        var settings = EngineSettings(); settings.deviceUID = device.uid; settings.exclusive = false
        settings.ratePolicies[device.uid] = .fixed(rate)
        settings.digitalVolumeDB = -200                       // silent
        engine.update(settings: settings)
        let first = PlayableItem(url: atmos), second = PlayableItem(url: after)
        engine.nextItemProvider = { $0.id == first.id ? second : nil }
        let started = Locked<[UUID]>([])
        engine.eventHandler = { event in if case .trackStarted(let item) = event { started.value.append(item.id) } }

        engine.play(first)
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 0.5 }
        #expect(engine.snapshot.systemRendering?.format == DolbyAtmos.codecName)
        #expect(engine.snapshot.duration > 10)
        engine.pause()
        try await wait { engine.snapshot.state == .paused }
        let paused = engine.snapshot.position
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(engine.snapshot.position - paused) < 0.05)
        engine.seek(to: engine.snapshot.duration - 1.5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.snapshot.position > engine.snapshot.duration - 2)
        engine.resume()
        // Plays out, then the next (ordinary) track goes through Vespertine's own path.
        try await wait { started.value.contains(second.id) && engine.snapshot.signalPath != nil }
        // A seek announces the track again (as on Vespertine's own path); the order is what matters.
        let order = started.value.reduce(into: [UUID]()) { if $0.last != $1 { $0.append($1) } }
        #expect(order == [first.id, second.id])
        #expect(engine.snapshot.systemRendering == nil)
        engine.stop()
    }

    /// Integer mode on a DAC that offers it (VESPERTINE_INTEGER_DEVICE = part of its name): a 32-bit source
    /// plays bit-perfect as 32-bit integers, and the device is left on its ordinary format afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"
                   && ProcessInfo.processInfo.environment["VESPERTINE_INTEGER_DEVICE"] != nil))
    func integerModeOnDAC() async throws {
        let name = ProcessInfo.processInfo.environment["VESPERTINE_INTEGER_DEVICE"]!
        let device = try #require(OutputDevices.list().first { $0.name.localizedCaseInsensitiveContains(name) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("int32-silence-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {   // closed (header written) before it's played
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96_000,
                                                                    AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false],
                                       commonFormat: .pcmFormatInt32, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480_000)!
            buffer.frameLength = 480_000                              // 5 s of silence
            try file.write(from: buffer)
        }
        let engine = PlaybackEngine()
        defer { engine.stop() }
        var settings = EngineSettings(); settings.deviceUID = device.uid; settings.exclusive = true; settings.integerMode = true
        engine.update(settings: settings)
        let failures = Locked<[String]>([])
        engine.eventHandler = { event in if case .failed(_, let m) = event { failures.value.append(m) } }
        engine.play(PlayableItem(url: url))
        try await Task.sleep(for: .milliseconds(800))
        let snap = engine.snapshot
        print("integer test: state \(snap.state) position \(snap.position) duration \(snap.duration) integer \(snap.signalPath?.applied.integerMode as Any) rate \(snap.signalPath?.applied.sampleRate as Any) underruns \(snap.underruns) waiting \(snap.waitingForDevice as Any)")
        #expect(failures.value.isEmpty, "\(failures.value) state \(engine.snapshot.state) error \(engine.snapshot.lastError ?? "-")")
        try await wait { engine.snapshot.state == .playing && engine.snapshot.position > 0.2 }
        let path = try #require(engine.snapshot.signalPath)
        #expect(path.applied.integerMode)
        #expect(path.isBitPerfect)
        engine.stopAndWait()
        try await Task.sleep(for: .milliseconds(300))
        // Released and back on a mixable Float32 format.
        let stream = try #require(DeviceQuery.outputStreams(device.id).first)
        let virtual = try HAL.get(stream, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription())
        #expect(virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0 && virtual.mFormatFlags & kAudioFormatFlagIsNonMixable == 0)
        #expect(DeviceControl.hogOwner(device.id) == -1)
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
