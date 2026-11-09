//
// Vespertine: golden PCM for Live Set: beat-matched blends placed from the library's stored beat grids, the bass swap,
// and the session's fixed output rate, through the engine's own pieces into the real ring and I/O stage. Placements and
// mixes are checked sample by sample against references computed here from the source samples and the grids (dither
// off; the sources are quiet enough that the limiter never acts).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stored hashes: Fixtures/golden-pcm-liveset.json. Re-record: VESPERTINE_GOLDEN_RECORD=1 swift test --filter LiveSetGolden
//

import Foundation
import Testing
@testable import VespertineAudio

enum LiveSetGolden {
    typealias S = SmartGolden
    typealias T = TransitionGolden
    static let rate = 48_000.0

    static var liveSet: TransitionSettings {
        var s = T.on
        s.style = .liveSet
        return s
    }

    static func tempo(_ bpm: Double, beat: Double, downbeat: Double) -> TransitionProfile.Tempo {
        .init(bpm: bpm, confidence: 0.8, beat: beat, downbeat: downbeat, downbeatConfidence: 0.7)
    }

    /// A stored profile: cold at both ends (so Smart Mix alone would make a quick cut), steady at `bpm` with its grid.
    static func profile(seconds: Double, bpm: Double, beat: Double, downbeat: Double, loudness: Double) -> TransitionProfile {
        let t = tempo(bpm, beat: beat, downbeat: downbeat)
        return TransitionProfile(seconds: seconds,
                                 head: .init(silence: 0.2, loudness: loudness, edgeLoudness: loudness, type: .cold, tempo: t),
                                 tail: .init(silence: 0.5, loudness: loudness, edgeLoudness: loudness - 20, type: .cold, tempo: t))
    }

    /// Two songs and their stored profiles: A 30 s with half a second of silence at its end, B 24 s with 0.2 s at its start.
    static func pair(_ name: String, bpmA: Double, bpmB: Double, downbeatA: Double = 0.1, downbeatB: Double = 0.3)
        throws -> (a: (URL, [[Int32]]), b: (URL, [[Int32]]), profiles: (PlayableItem) -> TransitionProfile?) {
        let a = try S.song("ls-\(name)-a", seconds: 30, seed: 501, rms: -20, silentTail: 0.5)
        let b = try S.song("ls-\(name)-b", seconds: 24, seed: 502, rms: -23, silentHead: 0.2)
        let pa = profile(seconds: 30, bpm: bpmA, beat: downbeatA, downbeat: downbeatA, loudness: -20)
        let pb = profile(seconds: 24, bpm: bpmB, beat: downbeatB, downbeat: downbeatB, loudness: -23)
        let urlA = a.0
        return (a, b, { $0.url == urlA ? pa : pb })
    }
}

struct LiveSetGoldenRecord: Codable {
    var recordedOn: String
    var cases: [String: String]
    static let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden-pcm-liveset.json")
    static func load() throws -> LiveSetGoldenRecord {
        try JSONDecoder().decode(LiveSetGoldenRecord.self,
                                 from: Data(contentsOf: Bundle.module.url(forResource: "golden-pcm-liveset", withExtension: "json", subdirectory: "Fixtures")!))
    }
    static let recorded = Locked([String: String]())
}

@Suite("Live Set golden PCM", .serialized)
struct LiveSetGoldenTests {
    typealias L = LiveSetGolden
    typealias S = SmartGolden
    typealias T = TransitionGolden
    typealias R = GoldenRender

    /// Plays the pair with Live Set; checks a beat-matched blend placed at `start` in A for `beats` of A's beats, B from
    /// `bStart`, every sample against the reference.
    @discardableResult
    func checkBeatBlend(_ p: (a: (URL, [[Int32]]), b: (URL, [[Int32]]), profiles: (PlayableItem) -> TransitionProfile?),
                        settings: TransitionSettings = LiveSetGolden.liveSet, bpm: Double, beats: Int, outgoingStart: Double,
                        incomingStart: Double) throws -> (SmartMix, R.TransitionOutput) {
        let run = try R.render([T.item(p.a.0), T.item(p.b.0)], device: GoldenDevices.dac, transitions: settings, dither: false, profiles: p.profiles)
        guard case .mix(let shape) = try #require(run.decisions.first), let beat = shape.beat else {
            Issue.record("expected a beat-matched blend, got \(run.decisions)")
            throw CancellationError()
        }
        #expect(shape.kind == .beatMatched && beat.beats == beats)
        #expect(abs(beat.outgoingStart - outgoingStart) < 1e-9, "outgoing start \(beat.outgoingStart)")
        #expect(abs(beat.incomingStart - incomingStart) < 1e-9, "incoming start \(beat.incomingStart)")
        #expect(abs(shape.matchDB - 3) < 1e-9, "A's −20 LUFS against B's −23: \(shape.matchDB)")
        // The overlap starts on A's downbeat, to the frame, and lasts `beats` of A's beats.
        let start = Int((outgoingStart * L.rate).rounded()), length = Int((Double(beats) * 60 / bpm * L.rate).rounded())
        let bStart = Int((incomingStart * L.rate).rounded())
        #expect(run.mixes == [R.Mixed(session: 0, ringFrame: UInt64(start), length: length, kind: .overlap)])
        let words = try #require(run.output.sessions.first).words
        #expect(run.output.sessions.count == 1)
        // A exact up to the downbeat; B exact from the blend's end.
        #expect(Array(words.prefix(start * 2)) == T.bits(T.floats(p.a.1, to: start)))
        let after = T.bits(T.floats(p.b.1, from: bStart + length))
        #expect(words.count == (start + length) * 2 + after.count, "frames \(words.count / 2)")
        #expect(Array(words.suffix(after.count)) == after)
        if !beat.bassSwap {
            let want = T.bits(S.mix(p.a.1, p.b.1, start: start, length: length, bStart: bStart, shape: shape))
            #expect(T.firstDifference(words, want) == nil, "first difference at frame \(T.firstDifference(words, want) ?? -1)")
        }
        return (shape, run)
    }

    @Test("Same tempo: 16 beats from A's last downbeat that fits before its music ends; B from its first downbeat")
    func sameTempo() throws {
        let p = try L.pair("same", bpmA: 120, bpmB: 120)
        // A's music ends at 29.5 s; 16 beats at 120 BPM are 8 s; A's bars of 2 s from 0.1: the last start ≤ 21.5 is 20.1.
        // B's music starts at 0.2 s, its downbeat is 0.3 s.
        try checkBeatBlend(p, bpm: 120, beats: 16, outgoingStart: 20.1, incomingStart: 0.3)
    }

    @Test("Half time (A 140, B 70): beat on every other beat, no drift")
    func halfTime() throws {
        let p = try L.pair("half", bpmA: 140, bpmB: 70)
        // 16 beats at 140: 6.857 s; bars of 1.714 s from 0.1; last start ≤ 29.5 − 6.857.
        let bar = 4 * 60 / 140.0, length = 16 * 60 / 140.0
        let start = 0.1 + ((29.5 - length - 0.1) / bar).rounded(.down) * bar
        try checkBeatBlend(p, bpm: 140, beats: 16, outgoingStart: start, incomingStart: 0.3)
    }

    @Test("A little apart (120 and 120.5 BPM): B starts earlier so the beats meet in the middle")
    func slightlyApart() throws {
        let p = try L.pair("apart", bpmA: 120, bpmB: 120.5)
        try checkBeatBlend(p, bpm: 120, beats: 16, outgoingStart: 20.1, incomingStart: 0.3 + 8 * (60 / 120.5 - 0.5))
    }

    @Test("Too far apart, beat blends off, or Smart Mix: no beat-matched blend (Smart Mix's quick cut instead)")
    func fallsBack() throws {
        let apart = try L.pair("far", bpmA: 120, bpmB: 124)
        var run = try R.render([T.item(apart.a.0), T.item(apart.b.0)], device: GoldenDevices.dac, transitions: L.liveSet, dither: false, profiles: apart.profiles)
        guard case .mix(let far) = try #require(run.decisions.first) else { Issue.record("\(run.decisions)"); return }
        #expect(far.kind == .coldCut && far.beat == nil)
        let same = try L.pair("off", bpmA: 120, bpmB: 120)
        var settings = L.liveSet
        settings.beatBlends = false
        run = try R.render([T.item(same.a.0), T.item(same.b.0)], device: GoldenDevices.dac, transitions: settings, dither: false, profiles: same.profiles)
        guard case .mix(let off) = try #require(run.decisions.first) else { Issue.record("\(run.decisions)"); return }
        #expect(off.kind == .coldCut)
        run = try R.render([T.item(same.a.0), T.item(same.b.0)], device: GoldenDevices.dac, transitions: S.smart, dither: false, profiles: same.profiles)
        guard case .mix(let smart) = try #require(run.decisions.first) else { Issue.record("\(run.decisions)"); return }
        #expect(smart.kind == .coldCut)
        // Without stored profiles (measured just in time: no beat grid for the whole song) there's none either.
        run = try R.render([T.item(same.a.0), T.item(same.b.0)], device: GoldenDevices.dac, transitions: L.liveSet, dither: false)
        guard case .mix(let measured) = try #require(run.decisions.first) else { Issue.record("\(run.decisions)"); return }
        #expect(measured.kind != .beatMatched)
    }

    @Test("Albums, a segue and a playlist set to off still win over Live Set: the off bytes")
    func rulesFirst() throws {
        let p = try L.pair("rules", bpmA: 120, bpmB: 120)
        let album = [T.item(p.a.0, context: GoldenCases.track(1)), T.item(p.b.0, context: GoldenCases.track(2))]
        var settings = L.liveSet
        settings.liveSetRate = 48_000
        let on = try R.render(album, device: GoldenDevices.dac, transitions: settings, dither: true, profiles: p.profiles)
        #expect(on.decisions == [.gapless(.sameAlbum)])
        #expect(on.output.sha256 == (try R.render(album, device: GoldenDevices.dac)).sha256)
        let off = [T.item(p.a.0, context: TransitionContext(override: .off)), T.item(p.b.0, context: TransitionContext(override: .off))]
        let quiet = try R.render(off, device: GoldenDevices.dac, transitions: settings, dither: true, profiles: p.profiles)
        #expect(quiet.decisions == [.gapless(.playlist)])
        #expect(quiet.output.sha256 == (try R.render(off, device: GoldenDevices.dac)).sha256)
    }

    @Test("The bass swap: both songs' bodies exact; in the blend, A's lows are gone after the middle and B's before it")
    func bassSwap() throws {
        let p = try L.pair("swap", bpmA: 120, bpmB: 120)
        var settings = L.liveSet
        settings.bassSwap = true
        let (shape, run) = try checkBeatBlend(p, settings: settings, bpm: 120, beats: 16, outgoingStart: 20.1, incomingStart: 0.3)
        #expect(shape.beat?.bassSwap == true)
        // Against the same blend without the swap: the frames differ only by what's below the crossover; the first frame
        // of the blend (A at full gain, B silent, all of A's lows) is A's own.
        let start = Int((20.1 * L.rate).rounded()), length = 384_000
        let words = try #require(run.output.sessions.first).words
        let plain = S.mix(p.a.1, p.b.1, start: start, length: length, bStart: 14_400, shape: { var s = shape; s.beat?.bassSwap = false; return s }())
        #expect(words[start * 2] == plain[start * 2].bitPattern && words[start * 2 + 1] == plain[start * 2 + 1].bitPattern)
        var differ = 0
        for f in start..<(start + length) where words[f * 2] != plain[f * 2].bitPattern { differ += 1 }
        #expect(differ > length / 4, "the swap changed only \(differ) frames")
    }

    @Test("The fixed rate: 44.1 kHz then 48 kHz blend on one 48 kHz session in Live Set; Smart Mix dips between two")
    func fixedRate() throws {
        let (ua, _) = try T.song("ls-rate-a", seconds: 4, seed: 511, rate: 44_100)
        let (ub, _) = try T.song("ls-rate-b", seconds: 4, seed: 512)
        let items = [T.item(ua), T.item(ub)]
        let live = try R.render(items, device: GoldenDevices.dac, transitions: L.liveSet, dither: false)
        #expect(live.output.sessions.count == 1)
        #expect(live.output.sessions.first?.plan.deviceSampleRate == 48_000)
        // Loud to the last sample and from the first: a segue, joined gaplessly at the one rate (no dip, no gap).
        #expect(live.decisions == [.gapless(.segue)])
        var at96 = L.liveSet
        at96.liveSetRate = 96_000
        let high = try R.render(items, device: GoldenDevices.dac, transitions: at96, dither: false)
        #expect(high.output.sessions.count == 1 && high.output.sessions.first?.plan.deviceSampleRate == 96_000)
        let smart = try R.render(items, device: GoldenDevices.dac, transitions: S.smart, dither: false)
        #expect(smart.output.sessions.map(\.plan.deviceSampleRate) == [44_100, 48_000])
        // Off, Live Set changes nothing.
        var offSettings = L.liveSet
        offSettings.enabled = false
        #expect(try R.render(items, device: GoldenDevices.dac, transitions: offSettings, dither: true).output.sha256
            == (try R.render(items, device: GoldenDevices.dac)).sha256)
    }

    static let recordedCases = ["beat-matched", "half-time", "bass-swap", "fixed-rate"]

    static func recordedRun(_ name: String) throws -> GoldenRender.Output {
        switch name {
        case "beat-matched", "half-time", "bass-swap":
            let p = try L.pair("rec-\(name)", bpmA: name == "half-time" ? 140 : 120, bpmB: name == "half-time" ? 70 : 120.5)
            var settings = L.liveSet
            settings.bassSwap = name == "bass-swap"
            return try R.render([T.item(p.a.0), T.item(p.b.0)], device: GoldenDevices.dac, transitions: settings, dither: true, profiles: p.profiles).output
        default:
            let (ua, _) = try T.song("rec-ls-rate-a", seconds: 4, seed: 511, rate: 44_100), (ub, _) = try T.song("rec-ls-rate-b", seconds: 4, seed: 512)
            return try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: L.liveSet, dither: true).output
        }
    }

    @Test("Stored hashes of Live Set's output", arguments: LiveSetGoldenTests.recordedCases)
    func stored(_ name: String) throws {
        let hash = try Self.recordedRun(name).sha256
        #expect(try Self.recordedRun(name).sha256 == hash, "\(name): not the same twice")
        if GoldenRecord.recording {
            LiveSetGoldenRecord.recorded.withLock { $0[name] = hash }
            return
        }
        let record = try LiveSetGoldenRecord.load()
        guard record.recordedOn == GoldenRecord.environment else {
            print("Live Set golden: \(name) recorded on \(record.recordedOn); not compared on \(GoldenRecord.environment)")
            return
        }
        #expect(record.cases[name] == hash, "\(name): output changed (\(hash))")
    }

    @Test("Record", .enabled(if: GoldenRecord.recording))
    func writeRecord() throws {
        for name in Self.recordedCases where LiveSetGoldenRecord.recorded.withLock({ $0[name] == nil }) { try stored(name) }
        let record = LiveSetGoldenRecord(recordedOn: GoldenRecord.environment, cases: LiveSetGoldenRecord.recorded.withLock { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: LiveSetGoldenRecord.sourceURL)
        print("Live Set golden: recorded \(record.cases.count) cases to \(LiveSetGoldenRecord.sourceURL.path)")
    }
}
