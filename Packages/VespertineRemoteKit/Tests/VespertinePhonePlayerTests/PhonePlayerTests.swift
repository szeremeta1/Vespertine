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

/// The largest difference between two signals (1 when their lengths differ).
private func worst(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 1 }
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
}

/// Waits (on the main actor, letting its tasks run) until `condition` holds.
/// The 500 looks end a run where it never does; they decide nothing. They are counted, not timed: a busy machine that holds every test still for seconds uses up a clock but not a count.
@MainActor private func wait(until condition: () -> Bool) async throws {
    var looks = 0
    while !condition() {
        if looks == 500 { Issue.record("the condition never held"); return }
        looks += 1
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
        try await wait { scheduled == ["b"] && player.decodedAhead > 0.749 }
        #expect(player.currentID == "a")
        let out = try render(engine, frames: a[0].count + b[0].count)
        // The files are 24-bit, so what comes out is the tones to within a 24-bit step; a sample too many or too few at the
        // join would put the second tone out of place by far more than that.
        #expect(out[0].count == a[0].count + b[0].count)
        #expect(worst(out[0], a[0] + b[0]) < 1e-6, "the second song's first sample comes right after the first song's last")
        #expect(worst(out[1], a[1] + b[1]) < 1e-6)
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
        #expect(worst(again[0], Array(planes[0].prefix(1_000))) < 1e-6)
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

    // TestFlight AGWqTwVAvOJJl42tjue-P-M: "scrubbing to a point mid-song appears to be utterly nonfunctional", on an ALAC
    // 24/96 file sent as it is from the Mac. The same case here: an ALAC file in an .m4a, still arriving, sought to its
    // middle while it plays.
    @Test func seekingMidSongInAnALACFileThatIsStillArrivingPlaysFromThere() async throws {
        let rate = 96_000.0, seconds = 20.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = Int(seconds * rate)
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            // A tone that rises in pitch, so every place in the song sounds different from every other.
            for c in 0..<2 {
                for i in 0..<frames {
                    let t = Double(i) / rate
                    buffer.floatChannelData![c][i] = Float(0.4 * sin(2 * Double.pi * (220 + 20 * t + 55 * Double(c)) * t))
                }
            }
            try file.write(from: buffer)
        }
        // What the file decodes to, to compare with.
        let decoded = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let whole = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length))!
        try decoded.read(into: whole)
        let expected = Array(UnsafeBufferPointer(start: whole.floatChannelData![0], count: Int(whole.frameLength)))
        #expect(expected.count == frames)

        let format = StreamFormat(codec: "ALAC", container: "m4a", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true)
        let mac = SlowMac(data: try Data(contentsOf: url), delay: .milliseconds(5))
        let descriptor = StreamDescriptor(stream: 1, kind: .original, byteSize: Int64(mac.data.count), format: format, frames: nil, tag: "t", chunkSize: 8_192)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).m4a")
        let source = try StreamSource(descriptor: descriptor, file: cache, read: mac.read, window: 2)
        defer { source.close(); try? FileManager.default.removeItem(at: cache) }
        source.start()
        let engine = try offlineEngine(rate: rate)
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = 0.5
        var failures: [Error] = []
        player.onFailure = { failures.append($0) }
        player.start(.init(id: "s", source: source, format: format), playing: true)
        try await wait { player.state == .playing }
        #expect(abs(player.duration - seconds) < 0.01)
        _ = try render(engine, frames: 9_600)
        #expect(!source.isComplete, "the middle of the song is still on the Mac")

        try player.seek(to: 11.0)
        #expect(abs(player.position - 11.0) < 0.05, "the playhead is where it was put, at \(player.position)")
        #expect(player.state == .playing)
        // The part asked for is fetched and decoded; until it is, the output is silent. Then it is the song from 11 s.
        var out: [Float] = []
        var looks = 0
        while out.filter({ abs($0) > 1e-4 }).count < 4_000, looks < 500 {
            looks += 1
            out += try render(engine, frames: 4_096)[0]
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failures.isEmpty, "\(failures)")
        let first = try #require(out.firstIndex { abs($0) > 1e-4 }, "sound came after the seek")
        let start = Int(11.0 * rate)
        let from = try #require(expected[start...].firstIndex { abs($0) > 1e-4 })
        let heard = Array(out[first..<min(first + 2_000, out.count)])
        let wanted = Array(expected[from..<from + heard.count])
        #expect(worst(heard, wanted) < 1e-4, "what plays after the seek is the song from 11 s on")
        #expect(player.position > 11.0 && player.position < 13.0, "and the playhead moves on from there, at \(player.position)")
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
