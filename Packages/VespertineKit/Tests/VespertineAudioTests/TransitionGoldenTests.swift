//
// Vespertine — golden PCM with transitions on: what reaches the device, through the engine's own pieces (the planner,
// the silence scan, Crossfade, FrameRamp, Decoding) into the real ring and I/O stage, with no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// - Every one of the 23 golden cases plays byte for byte as with transitions off, except the two whose boundaries
//   are a dip (another rate) and a crossfade (unrelated songs): albums, CUE sheets, native DSD, bitstream, integer
//   and 16-bit output are untouched.
// - Crossfades, a trimmed crossfade and a dip are checked sample by sample against a reference computed here from the
//   source samples and the closed-form curves (dither off), so the songs' bodies are shown to be exact and the
//   transition frames to be the mix and nothing else.
// - Stored hashes (Fixtures/golden-pcm-transitions.json) catch any later change, the mixer's dither included.
//   Re-record: VESPERTINE_GOLDEN_RECORD=1 swift test --filter TransitionGolden
//

import Foundation
import Testing
@testable import VespertineAudio

enum TransitionGolden {
    typealias R = GoldenRender
    static let rate = 48_000

    static var on: TransitionSettings {
        var s = TransitionSettings()
        s.enabled = true
        return s
    }

    static func settings(_ seconds: Double = 1, curve: TransitionCurve = .equalPower, trim: Bool = true) -> TransitionSettings {
        var s = on
        s.crossfadeSeconds = seconds
        s.curve = curve
        s.trimSilence = trim
        return s
    }

    /// 24-bit stereo test material (`GoldenFixtures.samples`), as WAV.
    static func song(_ name: String, seconds: Double, seed: UInt64, rate: Int = rate, silentHead: Int = 0, silentTail: Int = 0) throws -> (URL, [[Int32]]) {
        var s = GoldenFixtures.samples(frames: Int(seconds * Double(rate)), channels: 2, bits: 24, seed: seed)
        for c in 0..<2 {
            for n in 0..<silentHead { s[c][n] = 0 }
            for n in (s[c].count - silentTail)..<s[c].count { s[c][n] = 0 }
        }
        return (try GoldenCases.wav("transition-\(name).wav", s, bits: 24, rate: rate), s)
    }

    static func item(_ url: URL, context: TransitionContext? = nil, start: Int64? = nil, length: Int64? = nil) -> PlayableItem {
        PlayableItem(id: UUID(), url: url, regionStartFrame: start, regionFrameLength: length, context: context)
    }

    /// The source as the Float32 pipeline carries it, interleaved.
    static func floats(_ s: [[Int32]], from: Int = 0, to: Int? = nil) -> [Float] {
        let end = to ?? s[0].count
        var out: [Float] = []
        out.reserveCapacity((end - from) * s.count)
        for f in from..<end { for c in s.indices { out.append(Float(s[c][f]) / Float(1 << 23)) } }
        return out
    }

    /// What the silence scan finds: the last frame (+1) and the first frame above −60 dBFS.
    static func musicalEnd(_ s: [[Int32]]) -> Int {
        let x = floats(s), ch = s.count
        for f in stride(from: s[0].count - 1, through: 0, by: -1) where (0..<ch).contains(where: { abs(x[f * ch + $0]) > SilenceScan.threshold }) { return f + 1 }
        return 0
    }

    static func musicalStart(_ s: [[Int32]]) -> Int {
        let x = floats(s), ch = s.count
        for f in 0..<s[0].count where (0..<ch).contains(where: { abs(x[f * ch + $0]) > SilenceScan.threshold }) { return f }
        return s[0].count
    }

    /// The crossfade of `a` into `b` as the mixer computes it: `a` up to `start`, `length` frames of the mix, then `b` from
    /// `bStart + length`. Float arithmetic in the mixer's order.
    static func crossfade(_ a: [[Int32]], _ b: [[Int32]], start: Int, length: Int, bStart: Int, curve: TransitionCurve) -> [Float] {
        let fa = floats(a, to: start + length), fb = floats(b, from: bStart)
        var out = Array(fa[0..<(start * 2)])
        for k in 0..<length {
            let g = curve.gains(at: Double(k) / Double(length))
            let ga = Float(g.out), gb = Float(g.in)
            for c in 0..<2 { out.append(fa[(start + k) * 2 + c] * ga + fb[k * 2 + c] * gb) }
        }
        out += fb[(length * 2)...]
        return out
    }

    static func words(_ session: R.SessionOutput) -> [UInt32] { session.words }
    static func bits(_ x: [Float]) -> [UInt32] { x.map(\.bitPattern) }

    /// The first frame where `got` and `want` differ, for a readable failure.
    static func firstDifference(_ got: [UInt32], _ want: [UInt32], channels: Int = 2) -> Int? {
        if let i = zip(got, want).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset { return i / channels }
        return got.count == want.count ? nil : min(got.count, want.count) / channels
    }
}

struct TransitionGoldenRecord: Codable {
    var recordedOn: String
    var cases: [String: String]

    static let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden-pcm-transitions.json")
    static func load() throws -> TransitionGoldenRecord {
        try JSONDecoder().decode(TransitionGoldenRecord.self,
                                 from: Data(contentsOf: Bundle.module.url(forResource: "golden-pcm-transitions", withExtension: "json", subdirectory: "Fixtures")!))
    }
    static let recorded = Locked([String: String]())
}

@Suite("Transition golden PCM", .serialized)
struct TransitionGoldenTests {
    typealias T = TransitionGolden
    typealias R = GoldenRender

    @Test("Transitions on: every golden case plays byte for byte as with them off, but the dip and the crossfade",
          arguments: GoldenCase.all)
    func onIsOffWhereNothingMixes(_ c: GoldenCase) throws {
        let off = try GoldenCases.run(c).output
        let on = try GoldenCases.$transitions.withValue(T.on) { try GoldenCases.run(c).output }
        // The same device formats (a crossfade only shortens the session: its header counts frames).
        let format = { (o: GoldenRender.Output) in o.sessions.map { $0.header.components(separatedBy: " frames=")[0] } }
        #expect(format(on) == format(off), "\(c.name): device formats changed")
        if ["rate-change-queue", "silence-tail-pair"].contains(c.name) {
            #expect(on.sha256 != off.sha256, "\(c.name): expected a transition")
        } else {
            #expect(on.sha256 == off.sha256, "\(c.name): transitions on changed the output")
        }
        // And the recorded hash still holds with transitions off (the "off is off" gate).
        let stored = try #require(try GoldenRecord.load().cases[c.name])
        let recordedOn = try GoldenRecord.load().recordedOn
        if c.portable || recordedOn == GoldenRecord.environment { #expect(stored.sha256 == off.sha256, "\(c.name)") }
    }

    @Test("A crossfade, sample by sample: the outgoing song exact, the overlap the curve's mix, the incoming song exact",
          arguments: TransitionCurve.allCases)
    func crossfade(_ curve: TransitionCurve) throws {
        let (ua, a) = try T.song("a-\(curve.rawValue)", seconds: 3, seed: 101)
        let (ub, b) = try T.song("b-\(curve.rawValue)", seconds: 4, seed: 202)
        let run = try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.settings(1.5, curve: curve), dither: false)
        #expect(run.decisions == [.overlap(seconds: 1.5, curve: curve)])
        let end = T.musicalEnd(a), bStart = T.musicalStart(b)
        let length = 72_000, start = end - length
        #expect(run.mixes == [GoldenRender.Mixed(session: 0, ringFrame: UInt64(start), length: length, kind: .overlap)])
        let want = T.bits(T.crossfade(a, b, start: start, length: length, bStart: bStart, curve: curve))
        let session = try #require(run.output.sessions.first)
        #expect(run.output.sessions.count == 1)
        #expect(session.words.count == want.count, "frames: \(session.frames), expected \(want.count / 2)")
        #expect(T.firstDifference(session.words, want) == nil, "first difference at frame \(T.firstDifference(session.words, want) ?? -1)")
        // The incoming song's body plays as itself: its samples, not merely close.
        let tail = T.bits(T.floats(b, from: bStart + length))
        #expect(Array(session.words.suffix(tail.count)) == tail)
    }

    @Test("Silence is trimmed: the overlap ends at the outgoing song's last sound and the incoming one starts at its first")
    func trimmed() throws {
        let (ua, a) = try T.song("trim-a", seconds: 3, seed: 7, silentTail: 24_000)      // half a second of silence at the end
        let (ub, b) = try T.song("trim-b", seconds: 3, seed: 8, silentHead: 12_000)      // a quarter of a second at the start
        let run = try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.settings(1), dither: false)
        let end = T.musicalEnd(a), bStart = T.musicalStart(b)
        #expect(end <= 144_000 - 24_000 && end > 144_000 - 24_100)
        #expect(bStart >= 12_000 && bStart < 12_100)
        let want = T.bits(T.crossfade(a, b, start: end - 48_000, length: 48_000, bStart: bStart, curve: .equalPower))
        let words = try #require(run.output.sessions.first).words
        #expect(T.firstDifference(words, want) == nil, "first difference at frame \(T.firstDifference(words, want) ?? -1)")
        // Untrimmed, the overlap runs to the files' ends, silence and all.
        let raw = try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.settings(1, trim: false), dither: false)
        let rawWant = T.bits(T.crossfade(a, b, start: 144_000 - 48_000, length: 48_000, bStart: 0, curve: .equalPower))
        #expect(T.firstDifference(try #require(raw.output.sessions.first).words, rawWant) == nil)
    }

    @Test("Consecutive tracks of one album never fade, even in a playlist: the bytes are the off bytes")
    func albumGapless() throws {
        let (ua, a) = try T.song("album-1", seconds: 2, seed: 31)
        let (ub, b) = try T.song("album-2", seconds: 2, seed: 32)
        let items = [T.item(ua, context: GoldenCases.track(1)), T.item(ub, context: GoldenCases.track(2))]
        let off = try R.render(items, device: GoldenDevices.dac)
        let on = try R.render(items, device: GoldenDevices.dac, transitions: T.on, dither: true)
        #expect(on.decisions == [.gapless(.sameAlbum)])
        #expect(on.mixes.isEmpty)
        #expect(on.output.sha256 == off.sha256)
        #expect(try #require(on.output.sessions.first).words == T.bits(T.floats(a) + T.floats(b)))
        // The same two out of order (track 2, then 1) aren't consecutive: they crossfade.
        let swapped = try R.render(items.reversed(), device: GoldenDevices.dac, transitions: T.on, dither: true)
        #expect(swapped.decisions.first?.changesSamples == true)
    }

    @Test("CUE tracks in order play gaplessly; the same file's tracks out of order crossfade")
    func cueSheet() throws {
        let (url, s) = try T.song("cue", seconds: 4, seed: 41)
        let cut: Int64 = 96_000
        let one = T.item(url, start: 0, length: cut), two = T.item(url, start: cut, length: 192_000 - cut)
        let on = try R.render([one, two], device: GoldenDevices.dac, transitions: T.on, dither: true)
        #expect(on.decisions == [.gapless(.cueSheet)])
        #expect(try #require(on.output.sessions.first).words == T.bits(T.floats(s)))
        let reversed = try R.render([two, one], device: GoldenDevices.dac, transitions: T.settings(1), dither: false)
        #expect(reversed.decisions == [.overlap(seconds: 1, curve: .equalPower)])
        #expect(reversed.mixes.count == 1)
    }

    @Test("Excluded genres play without transitions, on either side; with the list emptied, they crossfade",
          arguments: [("Classical", "Rock"), ("Pop", "Spoken Word"), ("Rock; Opera", "Jazz"), ("soundtrack", "Pop")])
    func excludedGenres(_ genres: (String, String)) throws {
        let (ua, _) = try T.song("genre-a", seconds: 2, seed: 51)
        let (ub, _) = try T.song("genre-b", seconds: 2, seed: 52)
        let items = [T.item(ua, context: TransitionContext(genre: genres.0)), T.item(ub, context: TransitionContext(genre: genres.1))]
        let off = try R.render(items, device: GoldenDevices.dac)
        let on = try R.render(items, device: GoldenDevices.dac, transitions: T.on, dither: true)
        #expect(on.decisions == [.gapless(.excludedGenre)])
        #expect(on.output.sha256 == off.sha256)
        var none = T.on
        none.excludedGenres = []
        let mixed = try R.render(items, device: GoldenDevices.dac, transitions: none, dither: true)
        #expect(mixed.decisions.first?.changesSamples == true)
        #expect(mixed.output.sha256 != off.sha256)
    }

    @Test("Native DSD, bitstream, integer mode and 16-bit output stay cuts: the bytes are the off bytes")
    func cuts() throws {
        let cases = ["dop-dsd64-gapless-pair", "int32-96k-integer-mode", "int16-44k1-matched", "bitstream-ac3"]
        for c in GoldenCase.all where cases.contains(c.name) {
            #expect(try GoldenCases.$transitions.withValue(T.on) { try GoldenCases.run(c).output.sha256 } == GoldenCases.run(c).output.sha256, "\(c.name)")
        }
        // Pairs (a boundary each): 32-bit integer mode, and 16-bit sent as 16-bit.
        for (bits, device, integer, sixteen) in [(32, GoldenDevices.integerDAC, true, false), (16, GoldenDevices.integerDAC, false, true)] {
            var settings = GoldenRender.Settings()
            settings.integerMode = integer
            settings.matchSixteenBit = sixteen
            let a = GoldenFixtures.samples(frames: 48_000, channels: 2, bits: bits, seed: 61)
            let b = GoldenFixtures.samples(frames: 48_000, channels: 2, bits: bits, seed: 62)
            let items = [T.item(try GoldenCases.wav("cut-\(bits)-a.wav", a, bits: bits, rate: 48_000)),
                         T.item(try GoldenCases.wav("cut-\(bits)-b.wav", b, bits: bits, rate: 48_000))]
            let on = try R.render(items, device: device, settings: settings, transitions: T.on, dither: true)
            #expect(on.decisions == [.cut(integer ? .integerMode : .sixteenBit)])
            #expect(on.output.sha256 == (try R.render(items, device: device, settings: settings)).sha256)
        }
    }

    @Test("A change of rate is a dip: the outgoing song fades out over its last second, the next fades in over its first",
          arguments: TransitionCurve.allCases)
    func dip(_ curve: TransitionCurve) throws {
        let (ua, a) = try T.song("dip-a-\(curve.rawValue)", seconds: 2, seed: 71, rate: 44_100)
        let (ub, b) = try T.song("dip-b-\(curve.rawValue)", seconds: 2, seed: 72, rate: 48_000)
        let run = try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.settings(6, curve: curve), dither: false)
        #expect(run.decisions == [.dip(seconds: 1, curve: curve)])
        #expect(run.mixes == [GoldenRender.Mixed(session: 0, ringFrame: 44_100, length: 44_100, kind: .dipOut),
                              GoldenRender.Mixed(session: 1, ringFrame: 0, length: 48_000, kind: .dipIn)])
        #expect(run.output.sessions.count == 2)
        var wantA = T.floats(a)
        for f in 44_100..<88_200 {
            let g = Float(curve.gains(at: Double(f - 44_100) / 44_100).out)
            for c in 0..<2 { wantA[f * 2 + c] *= g }
        }
        var wantB = T.floats(b)
        for f in 0..<48_000 {
            let g = Float(curve.gains(at: Double(f) / 48_000).in)
            for c in 0..<2 { wantB[f * 2 + c] *= g }
        }
        #expect(T.firstDifference(run.output.sessions[0].words, T.bits(wantA)) == nil)
        #expect(T.firstDifference(run.output.sessions[1].words, T.bits(wantB)) == nil)
        // The first second of A and the last of B are exactly the files.
        #expect(Array(run.output.sessions[0].words.prefix(88_200)) == T.bits(T.floats(a, to: 44_100)))
        #expect(Array(run.output.sessions[1].words.suffix(96_000)) == T.bits(T.floats(b, from: 48_000)))
    }

    @Test("The outgoing song decoded again from its overlap (a queue change taking a crossfade back) gives the same samples")
    func decodedAgain() throws {
        let (url, s) = try T.song("again", seconds: 2, seed: 81)
        let item = T.item(url)
        let session = try GoldenRender.Session(plan: GoldenRender.plan(try SourceOpener.probe(url), item: item, device: GoldenDevices.dac, settings: .init()),
                                               device: GoldenDevices.dac, settings: .init())
        let probed = try SourceOpener.probe(url)
        let d = try GoldenRender.decoding(item, probed: probed, decoder: try SourceOpener.decoder(for: probed, plan: session.plan, item: item),
                                          session: session, settings: .init())
        while !d.finished { let c = d.convertChunk(); if c.ended { d.finished = true } }
        let from: UInt64 = 50_000
        let again = try #require(PlaybackEngine.decodeAgain(d, from: from, chunk: GoldenRender.chunkFrames, layout: session.layout))
        #expect(again.framesProduced == from)
        var out: [Float] = []
        while true {
            let c = again.convertChunk()
            if let data = c.data { out += UnsafeBufferPointer(start: data, count: Int(c.frames) * 2) }
            if c.ended { break }
        }
        #expect(again.framesProduced == 96_000)
        #expect(T.bits(out) == T.bits(T.floats(s, from: Int(from))))
    }

    @Test("The outgoing song ending early inside the overlap: the incoming one fades in over silence")
    func outgoingEndsEarly() throws {
        let (ua, a) = try T.song("early-a", seconds: 2, seed: 91)
        let (ub, b) = try T.song("early-b", seconds: 2, seed: 92)
        let probedA = try SourceOpener.probe(ua), probedB = try SourceOpener.probe(ub)
        let plan = GoldenRender.plan(probedA, item: T.item(ua), device: GoldenDevices.dac, settings: .init())
        let session = try GoldenRender.Session(plan: plan, device: GoldenDevices.dac, settings: .init())
        let deckA = try GoldenRender.decoding(T.item(ua), probed: probedA, decoder: try SourceOpener.decoder(for: probedA, plan: plan, item: T.item(ua)),
                                              session: session, settings: .init())
        let deckB = try GoldenRender.decoding(T.item(ub), probed: probedB, decoder: try SourceOpener.decoder(for: probedB, plan: plan, item: T.item(ub)),
                                              session: session, settings: .init())
        // An overlap of 20 000 frames from frame 40 000, but A's samples stop at 50 000 (as if its length were wrong).
        let cf = Crossfade(incoming: deckB, start: 40_000, length: 20_000, curve: .linear)
        var out: [Float] = []
        let write: (UnsafePointer<Float>, Int) -> Void = { out += UnsafeBufferPointer(start: $0, count: $1 * 2) }
        var fa = T.floats(a, to: 50_000)
        fa.withUnsafeMutableBufferPointer { p in
            _ = cf.feed(p.baseAddress!, frames: 30_000, first: 0, write: write)
            _ = cf.feed(p.baseAddress! + 60_000, frames: 20_000, first: 30_000, write: write)
        }
        #expect(cf.started && !cf.done)
        while !cf.done { cf.finishAlone(maxFrames: 4096, write: write) }
        cf.flushIncoming(write: write)
        _ = deckA
        let fb = T.floats(b)
        var want = T.floats(a, to: 40_000)
        for k in 0..<20_000 {
            let g = TransitionCurve.linear.gains(at: Double(k) / 20_000)
            for c in 0..<2 { want.append(k < 10_000 ? T.floats(a, from: 40_000 + k, to: 40_001 + k)[c] * Float(g.out) + fb[k * 2 + c] * Float(g.in) : 0 * Float(g.out) + fb[k * 2 + c] * Float(g.in)) }
        }
        #expect(T.bits(Array(out.prefix(want.count))) == T.bits(want))
        // After the overlap: B as itself, as far as it was converted (the rest follows from B's own deck).
        let rest = out.count - want.count
        #expect(T.bits(Array(out.suffix(rest))) == T.bits(Array(fb[40_000..<(40_000 + rest)])))
    }

    /// The stored cases: the three curves, a trimmed crossfade, a dip, and the engine's dithered mix.
    static let recordedCases = ["crossfade-equalPower", "crossfade-linear", "crossfade-sCurve", "trimmed", "dip-44k1-48k", "dithered-24"]

    static func recordedRun(_ name: String) throws -> GoldenRender.Output {
        let curve = TransitionCurve(rawValue: name.replacingOccurrences(of: "crossfade-", with: "")) ?? .equalPower
        switch name {
        case "trimmed":
            let (ua, _) = try T.song("rec-trim-a", seconds: 3, seed: 7, silentTail: 24_000)
            let (ub, _) = try T.song("rec-trim-b", seconds: 3, seed: 8, silentHead: 12_000)
            return try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.settings(1), dither: false).output
        case "dip-44k1-48k":
            let (ua, _) = try T.song("rec-dip-a", seconds: 2, seed: 71, rate: 44_100)
            let (ub, _) = try T.song("rec-dip-b", seconds: 2, seed: 72)
            return try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.on, dither: false).output
        default:
            let (ua, _) = try T.song("rec-\(name)-a", seconds: 3, seed: 101)
            let (ub, _) = try T.song("rec-\(name)-b", seconds: 4, seed: 202)
            return try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: T.settings(1.5, curve: curve),
                                dither: name == "dithered-24").output
        }
    }

    @Test("Stored hashes of the mixes", arguments: TransitionGoldenTests.recordedCases)
    func stored(_ name: String) throws {
        let hash = try Self.recordedRun(name).sha256
        #expect(try Self.recordedRun(name).sha256 == hash, "\(name): not the same twice")
        if GoldenRecord.recording {
            TransitionGoldenRecord.recorded.withLock { $0[name] = hash }
            return
        }
        let record = try TransitionGoldenRecord.load()
        // Only exact float arithmetic (multiplies and adds of the same values) and libm's sin/cos: compared where recorded.
        guard record.recordedOn == GoldenRecord.environment else {
            print("Transition golden: \(name) recorded on \(record.recordedOn); not compared on \(GoldenRecord.environment)")
            return
        }
        #expect(record.cases[name] == hash, "\(name): output changed (\(hash))")
    }

    @Test("Record", .enabled(if: GoldenRecord.recording))
    func writeRecord() throws {
        for name in Self.recordedCases where TransitionGoldenRecord.recorded.withLock({ $0[name] == nil }) { try stored(name) }
        let record = TransitionGoldenRecord(recordedOn: GoldenRecord.environment, cases: TransitionGoldenRecord.recorded.withLock { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: TransitionGoldenRecord.sourceURL)
        print("Transition golden: recorded \(record.cases.count) cases to \(TransitionGoldenRecord.sourceURL.path)")
    }
}
