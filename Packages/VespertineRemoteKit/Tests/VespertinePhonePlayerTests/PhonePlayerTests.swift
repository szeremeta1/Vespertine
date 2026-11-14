//
// Vespertine: the phone's first player (stereo): plays a downloaded stream's file through AVAudioEngine with nothing in the
// path but a mixer at unity, checked by rendering the engine offline and comparing every sample with the file.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func stereo(rate: Double = 44_100) -> StreamFormat {
    StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true)
}

/// A file of `seconds` of two different tones, written and closed.
private func makeFile(seconds: Double, rate: Double = 44_100, channels: Int = 2) throws -> (url: URL, planes: [[Float]]) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).wav")
    let frames = Int(seconds * rate)
    let planes: [[Float]] = (0..<channels).map { c in (0..<frames).map { Float(0.4 * sin(2 * Double.pi * (330 + 110 * Double(c)) * Double($0) / rate)) } }
    do {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { buffer.floatChannelData![c][i] = planes[c][i] } }
        try file.write(from: buffer)
    }
    return (url, planes)
}

@MainActor private func offlineEngine(rate: Double) throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    return engine
}

/// Renders `frames` frames from the engine, as the device would pull them.
@MainActor private func render(_ engine: AVAudioEngine, frames: Int) throws -> [[Float]] {
    let format = engine.manualRenderingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var out: [[Float]] = [[], []]
    var left = frames
    while left > 0 {
        let n = AVAudioFrameCount(min(left, 4096))
        let status = try engine.renderOffline(n, to: buffer)
        guard status == .success else { break }
        for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
        left -= Int(buffer.frameLength)
    }
    return out
}

/// Waits (on the main actor, letting its tasks run) until `condition` holds.
@MainActor private func wait(_ seconds: Double = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { Issue.record("the condition never held"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A Mac in memory that answers slowly, a range at a time, and can stop answering.
private final class SlowMac: @unchecked Sendable {
    let data: Data
    let delay: Duration
    private let lock = NSLock()
    private var _offsets: [Int64] = []
    var failAfter = Int.max

    init(data: Data, delay: Duration) { self.data = data; self.delay = delay }

    var offsets: [Int64] { lock.withLock { _offsets } }
    var descriptor: StreamDescriptor {
        StreamDescriptor(stream: 1, kind: .original, byteSize: Int64(data.count), format: stereo(), frames: nil, tag: "t", chunkSize: 8_192)
    }

    func read(_ offset: Int64, _ length: Int) async throws -> StreamFrame {
        let count = lock.withLock { () -> Int in _offsets.append(offset); return _offsets.count }
        try await Task.sleep(for: delay)
        if count > failAfter { throw CocoaError(.fileReadUnknown) }
        let end = min(Int(offset) + length, data.count)
        return StreamFrame(request: 1, stream: 1, offset: offset, endOfStream: end >= data.count, payload: Data(data[Int(offset)..<end]))
    }
}

@Suite(.serialized) @MainActor struct Player {
    @Test func theSamplesOutAreTheSamplesInUntouched() async throws {
        let (url, planes) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        #expect(player.state == .ready && abs(player.duration - 1) < 0.001)
        try player.play()
        #expect(player.state == .playing)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let expected = (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        #expect(expected[0].count == planes[0].count)
        let out = try render(engine, frames: expected[0].count)
        #expect(out[0].count == expected[0].count)
        #expect(out == expected, "bit-exact through the player node and a unity mixer")
    }

    @Test func thePathHasNoGainAndNoEffects() throws {
        let (url, _) = try makeFile(seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        #expect(engine.mainMixerNode.outputVolume == 1 && engine.mainMixerNode.volume == 1)
        #expect(player.isUntouchedPath)
    }

    @Test func seekingPlaysFromThere() async throws {
        let (url, planes) = try makeFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        try player.play()
        try player.seek(to: 1.0)
        let out = try render(engine, frames: 2_000)
        let start = 44_100
        let maxDiff = (0..<2_000).map { abs(out[0][$0] - planes[0][start + $0]) }.max() ?? 1
        #expect(maxDiff < 1e-6, "the first frame out is frame 44100 of the file")
        #expect(abs(player.position - 1.0) < 0.2)
    }

    @Test func pausingKeepsThePlaceAndPlayingResumes() throws {
        let (url, _) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        try player.play()
        _ = try render(engine, frames: 8_192)
        player.pause()
        #expect(player.state == .paused)
        let held = player.position
        #expect(held > 0.1 && held < 0.3)
        try player.play()
        #expect(player.state == .playing && abs(player.position - held) < 0.05)
    }

    @Test func stoppingGoesBackToTheStart() throws {
        let (url, _) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        try player.load(url, format: stereo())
        try player.play()
        player.stop()
        #expect(player.state == .ready && player.position == 0)
    }

    @Test func theNextSongFollowsWithoutAGapSampleForSample() async throws {
        let (first, a) = try makeFile(seconds: 0.5)
        let (second, b) = try makeFile(seconds: 0.25)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = 30
        var scheduled: [String] = [], advanced: [String] = []
        player.onScheduledNext = { scheduled.append($0) }
        player.onAdvance = { advanced.append($0) }
        player.start(.init(id: "a", source: try FileByteSource(url: first), format: stereo()), playing: true)
        player.setFollowing(.init(id: "b", source: try FileByteSource(url: second), format: stereo()))
        try await wait { scheduled == ["b"] }
        #expect(player.currentID == "a")
        let out = try render(engine, frames: a[0].count + b[0].count)
        #expect(out[0] == a[0] + b[0], "the second song's first sample comes right after the first song's last")
        #expect(out[1] == a[1] + b[1])
        player.tick()
        #expect(advanced == ["b"] && player.currentID == "b")
        #expect(abs(player.duration - 0.25) < 0.001)
    }

    @Test func aSongAtAnotherRateFinishesInsteadOfJoining() async throws {
        let (first, a) = try makeFile(seconds: 0.2)
        let (second, _) = try makeFile(seconds: 0.2, rate: 48_000)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        var scheduled: [String] = [], finished = 0
        player.onScheduledNext = { scheduled.append($0) }
        player.onFinished = { finished += 1 }
        player.start(.init(id: "a", source: try FileByteSource(url: first), format: stereo()), playing: true)
        player.setFollowing(.init(id: "b", source: try FileByteSource(url: second), format: stereo(rate: 48_000)))
        try await Task.sleep(for: .milliseconds(150))
        _ = try render(engine, frames: a[0].count + 4_096)
        try await wait { finished == 1 }
        #expect(scheduled.isEmpty)
        #expect(player.state == .ready)
    }

    @Test func aSongPlayedToItsEndStartsOverOnPlay() async throws {
        let (url, planes) = try makeFile(seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        var finished = 0
        player.onFinished = { finished += 1 }
        try player.load(url, format: stereo())
        try player.play()
        _ = try render(engine, frames: planes[0].count + 4_096)
        try await wait { finished == 1 }
        #expect(player.state == .ready)
        try player.play()
        #expect(player.state == .playing)
        let again = try render(engine, frames: 1_000)
        #expect(again[0] == Array(planes[0].prefix(1_000)))
    }

    @Test func aStreamStartsPlayingBeforeItHasAllArrived() async throws {
        let (url, _) = try makeFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let mac = SlowMac(data: try Data(contentsOf: url), delay: .milliseconds(25))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).wav")
        let source = try StreamSource(descriptor: mac.descriptor, file: cache, read: mac.read, window: 2)
        defer { source.close(); try? FileManager.default.removeItem(at: cache) }
        source.start()
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        player.start(.init(id: "s", source: source, format: stereo()), playing: true)
        #expect(player.state == .loading)
        try await wait { player.state == .playing }
        #expect(!source.isComplete, "playing while most of the song is still on the Mac")
        #expect(abs(player.duration - 2) < 0.001)
    }

    @Test func seekingIntoWhatHasNotArrivedFetchesThatPartFirst() async throws {
        let (url, _) = try makeFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let mac = SlowMac(data: data, delay: .milliseconds(25))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).wav")
        let source = try StreamSource(descriptor: mac.descriptor, file: cache, read: mac.read, window: 1)
        defer { source.close(); try? FileManager.default.removeItem(at: cache) }
        source.start()
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        player.scheduleAhead = 0.25
        player.start(.init(id: "s", source: source, format: stereo()), playing: false)
        try await wait { player.state == .ready }
        try player.seek(to: 1.8)
        #expect(abs(player.position - 1.8) < 0.01)
        let far = Int64(Double(data.count) * 0.85)
        try await wait { mac.offsets.contains { $0 >= far } }
        #expect(!source.isComplete, "the part asked for came before the gap behind it")
    }

    @Test func aStreamThatStopsArrivingIsReportedNotSilentlyStuck() async throws {
        let (url, _) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let mac = SlowMac(data: try Data(contentsOf: url), delay: .zero)
        mac.failAfter = 3
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).wav")
        let source = try StreamSource(descriptor: mac.descriptor, file: cache, read: mac.read, window: 1, attempts: 1)
        defer { source.close() }
        source.start()
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        var failures: [Error] = []
        player.onFailure = { failures.append($0) }
        player.start(.init(id: "s", source: source, format: stereo()), playing: true)
        try await wait { !failures.isEmpty }
        #expect(failures.first is StreamSource.Failure)
        #expect(player.state == .idle)
    }

    @Test func multichannelWaitsForTheSpatialPath() throws {
        // Stereo first: a six-channel stream is refused with a clear reason until the 5.1 path (see the plan addendum) is built.
        let (url, _) = try makeFile(seconds: 0.2, channels: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        let sixChannels = StreamFormat(codec: "WAV", container: "wav", sampleRate: 44_100, bitDepth: 24, channels: 6, channelLabels: [1, 2, 3, 4, 5, 6], lossless: true)
        #expect(throws: PhonePlayer.Failure.multichannelNotYet(6)) { try player.load(url, format: sixChannels) }
        #expect(player.state == .idle)
    }

    @Test func aFileThatIsNotAudioFailsWithWords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).flac")
        try Data(repeating: 1, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        #expect(throws: PhonePlayer.Failure.self) { try player.load(url, format: stereo()) }
        #expect(player.state == .idle)
    }
}

@Suite struct Flag {
    @Test func offUnlessTurnedOn() {
        let defaults = UserDefaults(suiteName: "phoneplayer-flag-\(UUID())")!
        #expect(!PhonePlayerFlag.isEnabled(defaults: defaults, arguments: []))
        defaults.set(true, forKey: PhonePlayerFlag.defaultsKey)
        #expect(PhonePlayerFlag.isEnabled(defaults: defaults, arguments: []))
    }

    @Test func theLaunchArgumentWinsEitherWay() {
        let defaults = UserDefaults(suiteName: "phoneplayer-flag-\(UUID())")!
        #expect(PhonePlayerFlag.isEnabled(defaults: defaults, arguments: ["app", "-VespertinePhonePlayer", "YES"]))
        defaults.set(true, forKey: PhonePlayerFlag.defaultsKey)
        #expect(!PhonePlayerFlag.isEnabled(defaults: defaults, arguments: ["app", "-VespertinePhonePlayer", "NO"]))
    }
}
#endif
