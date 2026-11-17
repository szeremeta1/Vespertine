//
// Vespertine: the phone bench, run whole. Test songs are written to a folder, the bench plays them through the phone's
// player on an engine rendered here (no sound device), and its report has to say what the songs are: one tone cut in
// two is gapless, a tone with 30 ms of silence put in has a 30 ms gap, and a song tagged −6.2 dB comes out 6.2 dB down.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertinePhoneBench
import VespertinePhonePlayer

private let rate = 44_100.0

/// Frames `from` to `to` of one 1 kHz tone.
private func tone(_ from: Int, _ to: Int, scale: Double = 0.5) -> [Double] {
    var out: [Double] = []
    var frame = from
    while frame < to {
        out.append(scale * sin(2 * Double.pi * 1_000 * Double(frame) / rate))
        frame += 1
    }
    return out
}

private func le(_ value: Int, bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((value >> (8 * $0)) & 0xff) } }
private func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) } }

/// A user-named text frame of an ID3v2.3 tag.
private func named(_ name: String, _ value: String) -> [UInt8] {
    let body: [UInt8] = [0] + Array(name.utf8) + [0] + Array(value.utf8)
    return Array("TXXX".utf8) + be32(body.count) + [0, 0] + body
}

/// A 16-bit stereo WAV file of `samples` (the same in both channels), with ReplayGain values in an ID3 tag when given.
private func wave(_ samples: [Double], gains: [(String, String)] = []) -> Data {
    var pcm: [UInt8] = []
    pcm.reserveCapacity(samples.count * 4)
    for sample in samples {
        let value = Int((sample * 32_767).rounded()) & 0xffff
        pcm += [UInt8(value & 0xff), UInt8(value >> 8), UInt8(value & 0xff), UInt8(value >> 8)]
    }
    var tag: [UInt8] = []
    if !gains.isEmpty {
        let frames = gains.flatMap { named($0.0, $0.1) }
        let size = frames.count
        tag = Array("ID3".utf8) + [3, 0, 0] + [UInt8((size >> 21) & 0x7f), UInt8((size >> 14) & 0x7f), UInt8((size >> 7) & 0x7f), UInt8(size & 0x7f)] + frames
        if tag.count % 2 == 1 { tag.append(0) }
    }
    var file: [UInt8] = Array("WAVEfmt ".utf8) + le(16, bytes: 4) + le(1, bytes: 2) + le(2, bytes: 2) + le(Int(rate), bytes: 4)
    file += le(Int(rate) * 4, bytes: 4) + le(4, bytes: 2) + le(16, bytes: 2)
    file += Array("data".utf8) + le(pcm.count, bytes: 4) + pcm
    if !tag.isEmpty { file += Array("id3 ".utf8) + le(tag.count, bytes: 4) + tag }
    return Data(Array("RIFF".utf8) + le(file.count, bytes: 4) + file)
}

@Suite(.serialized) @MainActor struct PhoneBenchRuns {
    private func seconds(_ value: Double) -> Int { Int(value * rate) }

    /// The bench on an engine rendered here: a hundredth of a second going by is that much audio rendered and kept, once
    /// the player has it ready. Time is audio, so nothing waits on a clock.
    /// `taps`: the bench taps the engine's mixer itself, as it does on a phone, instead of being handed what was rendered.
    private func offline(folder: URL, results: URL, taps: Bool = false) throws -> PhoneBench {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let bench = PhoneBench(folder: folder, results: results, engine: engine, taps: taps)
        let out = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        bench.pause = { [weak bench] _ in
            guard let bench else { return }
            var looks = 0
            while bench.player.state == .playing, bench.player.decodedAhead < 0.05, looks < 40 {
                try? await Task.sleep(for: .milliseconds(2))
                looks += 1
            }
            if engine.isRunning, (try? engine.renderOffline(441, to: out)) == .success, !taps { bench.capture.append(out, sampleTime: nil) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return bench
    }

    @Test func itMeasuresJoinsAndReplayGain() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let music = root.appendingPathComponent("music", isDirectory: true), results = root.appendingPathComponent("results", isDirectory: true)
        func put(_ data: Data, _ path: String) throws {
            let url = music.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        // One tone cut in two: a long first song (the bench enters it near its end) and a short one (played whole).
        try put(wave(tone(0, seconds(6))), "1 whole/01.wav")
        try put(wave(tone(seconds(6), seconds(9))), "1 whole/02.wav")
        try put(wave(tone(0, seconds(2))), "2 short/01.wav")
        try put(wave(tone(seconds(2), seconds(5))), "2 short/02.wav")
        // The same with 30 ms of silence in front of the second song.
        try put(wave(tone(0, seconds(6))), "3 gap/01.wav")
        try put(wave([Double](repeating: 0, count: seconds(0.03)) + tone(seconds(6), seconds(9))), "3 gap/02.wav")
        // A song that says how it is to be levelled.
        try put(wave(tone(0, seconds(9), scale: 0.25), gains: [("REPLAYGAIN_TRACK_GAIN", "-6.20 dB"), ("REPLAYGAIN_TRACK_PEAK", "0.250000"),
                                                                 ("REPLAYGAIN_ALBUM_GAIN", "+3.50 dB"), ("REPLAYGAIN_ALBUM_PEAK", "0.250000")]), "4 gain/tone.wav")

        let bench = try offline(folder: music, results: results)

        let report = await bench.run()
        #expect(report.notes.isEmpty, "\(report.notes)")
        #expect(report.songs == 7 && report.captureRate == rate)
        try #require(report.joins.count == 3, "\(report.text)")

        for whole in report.joins.prefix(2) {
            #expect(whole.verdict == .gapless, "\(report.text)")
            #expect(whole.gapMilliseconds == 0 && whole.gapsElsewhere.isEmpty)
            #expect((whole.joinResidual ?? 0) < -60)
            #expect(abs((whole.toneHz ?? 0) - 1_000) < 1)
            #expect(abs((whole.joinSlip ?? 99)) < 0.01 && abs((whole.levelStep ?? 99)) < 0.01 && !whole.lossy)
        }
        #expect(report.joins[0].folder == "1 whole" && report.joins[0].first == "01.wav" && report.joins[0].second == "02.wav")
        // The long song was entered three seconds from its end: about five seconds were kept, not eight.
        #expect(report.joins[0].captureSeconds < 6.5 && report.joins[1].captureSeconds > 3.5)

        let gap = report.joins[2]
        #expect(gap.verdict == .gap, "\(report.text)")
        #expect(abs(gap.gapMilliseconds - 30) < 0.2, "\(report.text)")

        try #require(report.gains.count == 1, "\(report.text)")
        let gain = report.gains[0]
        #expect(gain.file == "4 gain/tone.wav" && gain.verdict == .matches, "\(report.text)")
        #expect(gain.trackGain == -6.2 && gain.albumGain == 3.5 && gain.trackPeak == 0.25)
        let track = try #require(gain.track), album = try #require(gain.album)
        #expect(track.expected == -6.2 && abs(track.measured + 6.2) < 0.02 && !track.heldByPeak)
        #expect(album.expected == 3.5 && abs(album.measured - 3.5) < 0.02)
        #expect(abs((gain.offLevel ?? 0) - 20 * log10(0.25 / 2.0.squareRoot())) < 0.02)

        // The report and the captures are beside each other for whoever reads them.
        let saved = try JSONDecoder.iso.decode(BenchReport.self, from: Data(contentsOf: results.appendingPathComponent("report.json")))
        #expect(saved.joins == report.joins && saved.gains == report.gains)
        #expect(try String(contentsOf: results.appendingPathComponent("report.txt"), encoding: .utf8) == report.text)
        #expect(report.text.contains("VTBENCH JOIN 3 gap: 01.wav > 02.wav: GAP, gap "))
        #expect(report.text.hasSuffix("VTBENCH DONE joins 3, gains 1"))
        let capture = try #require(report.joins[0].capture)
        #expect(manager.fileExists(atPath: results.appendingPathComponent(capture).path))
    }

    /// The way it runs on a phone: the audio is taken by a tap on the engine's mixer, with the tap's own clock checked
    /// for skips.
    @Test func theTapOnTheMixerKeepsTheSameAudio() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let album = root.appendingPathComponent("music/tone", isDirectory: true)
        try manager.createDirectory(at: album, withIntermediateDirectories: true)
        try wave(tone(0, seconds(6))).write(to: album.appendingPathComponent("01.wav"))
        try wave([Double](repeating: 0, count: seconds(0.08)) + tone(seconds(6), seconds(9))).write(to: album.appendingPathComponent("02.wav"))
        try wave(tone(seconds(9), seconds(12))).write(to: album.appendingPathComponent("03.wav"))

        let report = try await offline(folder: root.appendingPathComponent("music"), results: root.appendingPathComponent("results"), taps: true).run()
        try #require(report.joins.count == 2, "\(report.text)")
        #expect(report.joins[0].verdict == .gap && abs(report.joins[0].gapMilliseconds - 80) < 0.2, "\(report.text)")
        #expect(report.joins[1].verdict == .gapless && report.joins[1].gapMilliseconds == 0, "\(report.text)")
        #expect(report.joins.allSatisfy { $0.captureBreaks == 0 } && report.captureRate == rate)
    }

    @Test func anEmptyFolderIsSaidSo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bench = try offline(folder: root.appendingPathComponent("music"), results: root.appendingPathComponent("results"))
        let report = await bench.run()
        #expect(report.songs == 0 && report.joins.isEmpty && report.gains.isEmpty)
        #expect(report.notes.count == 1 && report.text.contains("VTBENCH NOTE No songs in"))
    }

    /// For trying real files on a Mac without a sound: `VTBENCH_FOLDER=<folder of albums> swift test --filter aFolderNamedFromOutside`
    /// runs the bench over that folder with Apple's decoders (the phone's) and prints its report. The report and the
    /// captures go to `VTBENCH_RESULTS` when that is set. It isn't run otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VTBENCH_FOLDER"] != nil)) func aFolderNamedFromOutside() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(environment["VTBENCH_FOLDER"]), isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let results = environment["VTBENCH_RESULTS"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? scratch
        let report = try await offline(folder: folder, results: results).run()
        print(report.text)
        #expect(!report.joins.isEmpty || !report.gains.isEmpty, "nothing in \(folder.path) could be measured")
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
