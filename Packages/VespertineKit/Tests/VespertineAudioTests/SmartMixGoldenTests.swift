//
// Vespertine — golden PCM for Smart Mix and gaps: songs made to order (a fade-out, a cold end, silence, a segue), played
// through the engine's own pieces (the planner, the just-in-time measurements, Crossfade with Smart Mix's shape and the
// limiter) into the real ring and I/O stage, and checked sample by sample against a reference computed here from the
// source samples and the decision (dither off). The decisions themselves are checked against how the songs were made.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stored hashes: Fixtures/golden-pcm-smartmix.json (phase 2's golden-pcm-transitions.json is left as it was).
// Re-record: VESPERTINE_GOLDEN_RECORD=1 swift test --filter SmartMixGolden
//

import Foundation
import Testing
@testable import VespertineAudio

enum SmartGolden {
    typealias T = TransitionGolden
    static let rate = 48_000.0

    static var smart: TransitionSettings {
        var s = T.on
        s.style = .smartMix
        return s
    }

    /// Stereo 24-bit noise at `rms` dBFS, with silence at either end and an exponential fade-out (straight in dB, from
    /// the body's level down by `fadeDB`) over its last `fadeOut` seconds of sound.
    static func song(_ name: String, seconds: Double, seed: UInt64, rms: Double = -14, silentHead: Double = 0, silentTail: Double = 0,
                     fadeOut: Double = 0, fadeDB: Double = -60) throws -> (URL, [[Int32]]) {
        let frames = Int(seconds * rate), head = Int(silentHead * rate), tail = Int(silentTail * rate), fade = Int(fadeOut * rate)
        let amplitude = pow(10, rms / 20) * 3.0.squareRoot()
        var state = seed
        var s = [[Int32]](repeating: [Int32](repeating: 0, count: frames), count: 2)
        let soundEnd = frames - tail
        for f in head..<soundEnd {
            var g = 1.0
            if fade > 0, f >= soundEnd - fade { g = pow(10, fadeDB * Double(f - (soundEnd - fade)) / Double(fade) / 20) }
            for c in 0..<2 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let x = amplitude * g * (Double(state >> 11) / Double(1 << 53) * 2 - 1)
                s[c][f] = Int32((x * Double(1 << 23)).rounded())
            }
        }
        return (try GoldenCases.wav("smart-\(name).wav", s, bits: 24, rate: Int(rate)), s)
    }

    /// The mix of `a` into `b` as Crossfade computes it with Smart Mix's `shape` (the limiter idle).
    static func mix(_ a: [[Int32]], _ b: [[Int32]], start: Int, length: Int, bStart: Int, shape: SmartMix) -> [Float] {
        let fa = T.floats(a, to: start + length), fb = T.floats(b, from: bStart)
        let inFraction = min(1, shape.inSeconds * rate / Double(max(1, length)))
        var out = Array(fa[0..<(start * 2)])
        for k in 0..<length {
            let g = shape.gains(at: Double(k) / Double(length), inFraction: inFraction)
            let ga = Float(g.out), gb = Float(g.in)
            for c in 0..<2 { out.append(fa[(start + k) * 2 + c] * ga + fb[k * 2 + c] * gb) }
        }
        out += fb[(length * 2)...]
        return out
    }

    /// The overlap the engine places for `seconds`: ending at `a`'s last sound, at most half of `b`'s music.
    static func overlap(_ a: [[Int32]], _ b: [[Int32]], seconds: Double) -> (start: Int, length: Int, bStart: Int) {
        let end = T.musicalEnd(a), bStart = T.musicalStart(b)
        let length = min(Int(seconds * rate), (b[0].count - bStart) / 2)
        return (end - length, length, bStart)
    }

    static func peak(_ words: ArraySlice<UInt32>) -> Float { words.reduce(0) { max($0, abs(Float(bitPattern: $1))) } }
}

struct SmartGoldenRecord: Codable {
    var recordedOn: String
    var cases: [String: String]
    static let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden-pcm-smartmix.json")
    static func load() throws -> SmartGoldenRecord {
        try JSONDecoder().decode(SmartGoldenRecord.self,
                                 from: Data(contentsOf: Bundle.module.url(forResource: "golden-pcm-smartmix", withExtension: "json", subdirectory: "Fixtures")!))
    }
    static let recorded = Locked([String: String]())
}

@Suite("Smart Mix golden PCM", .serialized)
struct SmartMixGoldenTests {
    typealias S = SmartGolden
    typealias T = TransitionGolden
    typealias R = GoldenRender

    /// Plays `a` into `b` with Smart Mix; checks the decision is a mix of `kind`, then every sample against the reference.
    @discardableResult
    func checkMix(_ a: (URL, [[Int32]]), _ b: (URL, [[Int32]]), kind: SmartMix.Kind, settings: TransitionSettings = SmartGolden.smart,
                  profiles: ((PlayableItem) -> TransitionProfile?)? = nil) throws -> (SmartMix, R.TransitionOutput) {
        let run = try R.render([T.item(a.0), T.item(b.0)], device: GoldenDevices.dac, transitions: settings, dither: false, profiles: profiles)
        guard case .mix(let shape) = try #require(run.decisions.first) else {
            Issue.record("expected a mix, got \(run.decisions)")
            throw CancellationError()
        }
        #expect(shape.kind == kind)
        let o = S.overlap(a.1, b.1, seconds: shape.seconds)
        #expect(run.mixes == [R.Mixed(session: 0, ringFrame: UInt64(o.start), length: o.length, kind: .overlap)])
        let want = T.bits(S.mix(a.1, b.1, start: o.start, length: o.length, bStart: o.bStart, shape: shape))
        let words = try #require(run.output.sessions.first).words
        #expect(run.output.sessions.count == 1)
        #expect(words.count == want.count, "frames \(words.count / 2), expected \(want.count / 2)")
        #expect(T.firstDifference(words, want) == nil, "first difference at frame \(T.firstDifference(words, want) ?? -1)")
        // Both songs' bodies are exactly the files.
        #expect(Array(words.prefix(o.start * 2)) == T.bits(T.floats(a.1, to: o.start)))
        #expect(Array(words.suffix(want.count - (o.start + o.length) * 2)) == T.bits(T.floats(b.1, from: o.bStart + o.length)))
        return (shape, run)
    }

    @Test("A fade-out: the next song starts inside it, over the fade's length; loudness matched (A 4 dB louder)")
    func insideFade() throws {
        let a = try S.song("fade-a", seconds: 24, seed: 11, rms: -14, fadeOut: 8)
        let b = try S.song("fade-b", seconds: 30, seed: 12, rms: -18)
        let (shape, _) = try checkMix(a, b, kind: .insideFade)
        // The fade reaches −60 dBFS before the file ends: the measured fade is its audible part, 2…12 s.
        #expect(shape.seconds >= 5 && shape.seconds <= 8.6, "\(shape.seconds)")
        #expect(shape.outCurve == nil, "A fades out by itself")
        #expect(shape.inSeconds == max(1, shape.seconds / 2))
        #expect(abs(shape.matchDB - 4) <= 0.3, "\(shape.matchDB)")
    }

    @Test("Both cold: a quick cut, half a second, B rising over 0.1 s")
    func coldCut() throws {
        let a = try S.song("cold-a", seconds: 12, seed: 21, silentTail: 0.3)
        let b = try S.song("cold-b", seconds: 12, seed: 22, silentHead: 0.2)
        let (shape, _) = try checkMix(a, b, kind: .coldCut)
        #expect(shape.seconds == 0.5 && shape.inSeconds == 0.1 && shape.outCurve == .equalPower)
        #expect(abs(shape.matchDB) <= 0.2)
    }

    @Test("Silence at the end: trimmed, then a one-second blend; the silence never reaches the output")
    func trimmed() throws {
        let a = try S.song("silence-a", seconds: 14, seed: 31, silentTail: 2.5)
        let b = try S.song("silence-b", seconds: 12, seed: 32, silentHead: 0.2)
        let (shape, run) = try checkMix(a, b, kind: .trimmed)
        #expect(shape.seconds == 1 && shape.inSeconds == 1)
        // 2.5 s of A's silence and 0.2 s of B's are gone.
        let frames = try #require(run.output.sessions.first).frames
        #expect(frames == T.musicalEnd(a.1) + (b.1[0].count - T.musicalStart(b.1)) - 48_000)
    }

    @Test("A segue (loud to the last sample, loud from the first): joined untouched, the off bytes")
    func segue() throws {
        let a = try S.song("segue-a", seconds: 12, seed: 41)
        let b = try S.song("segue-b", seconds: 12, seed: 42)
        let items = [T.item(a.0), T.item(b.0)]
        let on = try R.render(items, device: GoldenDevices.dac, transitions: S.smart, dither: true)
        #expect(on.decisions == [.gapless(.segue)])
        #expect(on.mixes.isEmpty)
        #expect(on.output.sha256 == (try R.render(items, device: GoldenDevices.dac)).sha256)
    }

    @Test("The library's stored profiles decide when there are some (here: a 4 s fade the audio doesn't have)")
    func storedProfiles() throws {
        let a = try S.song("stored-a", seconds: 12, seed: 51, silentTail: 0.3)
        let b = try S.song("stored-b", seconds: 12, seed: 52, silentHead: 0.2)
        let fake = TransitionProfile(seconds: 12, head: .init(silence: 0.2, loudness: -20, edgeLoudness: -20, type: .cold),
                                     tail: .init(silence: 0.3, fade: 4, fadeConfidence: 1, loudness: -17, edgeLoudness: -50, type: .fade))
        let (shape, _) = try checkMix(a, b, kind: .insideFade, profiles: { _ in fake })
        #expect(shape.seconds == 4 && shape.matchDB == 3)
    }

    @Test("Peaks over full scale in an overlap are limited; the songs either side are untouched")
    func limiter() throws {
        // Two loud songs (−5 dBFS RMS noise, peaks near full scale): an equal-power blend sums past 1.
        let a = try S.song("loud-a", seconds: 12, seed: 61, rms: -5, silentTail: 0.3)
        let b = try S.song("loud-b", seconds: 12, seed: 62, rms: -5, silentHead: 0.2)
        var settings = S.smart
        settings.crossfadeSeconds = 3
        // Stored profiles that say nothing sure: Smart Mix's plain crossfade, at the chosen 3 s.
        let unsure = TransitionProfile(seconds: 12, head: .init(silence: 0.2, fadeConfidence: 0.4, loudness: -3, type: .cold),
                                       tail: .init(silence: 0.3, fadeConfidence: 0.4, loudness: -3, type: .cold))
        let items = [T.item(a.0), T.item(b.0)]
        let run = try R.render(items, device: GoldenDevices.dac, transitions: settings, dither: false, profiles: { _ in unsure })
        guard case .mix(let shape) = try #require(run.decisions.first) else { Issue.record("\(run.decisions)"); return }
        #expect(shape.kind == .crossfade && shape.seconds == 3 && shape.matchDB == 0)
        let o = S.overlap(a.1, b.1, seconds: 3)
        let words = try #require(run.output.sessions.first).words
        let unlimited = S.mix(a.1, b.1, start: o.start, length: o.length, bStart: o.bStart, shape: shape)
        #expect(unlimited.map(abs).max()! > 1, "the test's blend must go over full scale")
        let overlapWords = words[(o.start * 2)..<((o.start + o.length) * 2)]
        let worst = overlapWords.indices.max { abs(Float(bitPattern: words[$0])) < abs(Float(bitPattern: words[$1])) }!
        #expect(S.peak(overlapWords) <= OverlapLimiter.ceiling, "peak \(Float(bitPattern: words[worst])) at frame \(worst / 2 - o.start) of \(o.length); mixes \(run.mixes), expected start \(o.start)")
        #expect(Array(words.prefix(o.start * 2)) == T.bits(T.floats(a.1, to: o.start)))
        #expect(Array(words.suffix(words.count - (o.start + o.length) * 2)) == T.bits(T.floats(b.1, from: o.bStart + o.length)))
        // Only frames near a peak change: within the lookahead before it, and the release after it.
        let reach = OverlapLimiter(channels: 2, sampleRate: S.rate).lookahead * 2 + Int(OverlapLimiter.releaseSeconds * S.rate) + 1
        let over = (o.start..<(o.start + o.length)).filter { f in (0..<2).contains { abs(unlimited[f * 2 + $0]) > OverlapLimiter.ceiling } }
        var near = [Bool](repeating: false, count: words.count / 2)
        for f in over { for g in max(0, f - reach)...min(near.count - 1, f + reach) { near[g] = true } }
        let changed = (o.start..<(o.start + o.length)).filter { f in (0..<2).contains { words[f * 2 + $0] != unlimited[f * 2 + $0].bitPattern } }
        #expect(!changed.isEmpty && changed.allSatisfy { near[$0] }, "\(changed.count) frames changed, \(over.count) over")
    }

    @Test("A gap: the first song whole, then silence, then the next whole (bit for bit)")
    func gap() throws {
        let (ua, a) = try T.song("gap-a", seconds: 2, seed: 71)
        let (ub, b) = try T.song("gap-b", seconds: 2, seed: 72)
        for style in TransitionStyle.allCases {
            var settings = T.on
            settings.style = style
            settings.gapSeconds = 1.5
            let run = try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: settings, dither: true)
            #expect(run.decisions == [.gap(seconds: 1.5)], "\(style)")
            #expect(run.mixes.isEmpty)
            let want = T.bits(T.floats(a) + [Float](repeating: 0, count: 72_000 * 2) + T.floats(b))
            #expect(try #require(run.output.sessions.first).words == want, "\(style)")
        }
        // Never inside an album.
        var settings = T.on
        settings.gapSeconds = 3
        let album = [T.item(ua, context: GoldenCases.track(1)), T.item(ub, context: GoldenCases.track(2))]
        let run = try R.render(album, device: GoldenDevices.dac, transitions: settings, dither: true)
        #expect(run.decisions == [.gapless(.sameAlbum)])
        #expect(run.output.sha256 == (try R.render(album, device: GoldenDevices.dac)).sha256)
    }

    @Test("A playlist's own setting: off plays the off bytes; a crossfade length wins over the app's Smart Mix")
    func playlistOverride() throws {
        let (ua, _) = try T.song("override-a", seconds: 3, seed: 81)
        let (ub, _) = try T.song("override-b", seconds: 3, seed: 82)
        let off = [T.item(ua, context: TransitionContext(override: .off)), T.item(ub, context: TransitionContext(override: .off))]
        let run = try R.render(off, device: GoldenDevices.dac, transitions: SmartGolden.smart, dither: true)
        #expect(run.decisions == [.gapless(.playlist)])
        #expect(run.output.sha256 == (try R.render(off, device: GoldenDevices.dac)).sha256)
        let two = [T.item(ua), T.item(ub, context: TransitionContext(override: .crossfade(seconds: 2)))]
        #expect(try R.render(two, device: GoldenDevices.dac, transitions: SmartGolden.smart, dither: false).decisions == [.overlap(seconds: 2, curve: .equalPower)])
        // The master switch rules: off, a playlist's crossfade does nothing.
        #expect(try R.render(two, device: GoldenDevices.dac, transitions: TransitionSettings(), dither: false).decisions == [.gapless(.off)])
    }

    @Test("Smart Mix on: every golden case but the dip and the silence pair plays byte for byte as with transitions off",
          arguments: GoldenCase.all)
    func smartIsOffWhereNothingMixes(_ c: GoldenCase) throws {
        let off = try GoldenCases.run(c).output
        let on = try GoldenCases.$transitions.withValue(SmartGolden.smart) { try GoldenCases.run(c).output }
        let format = { (o: GoldenRender.Output) in o.sessions.map { $0.header.components(separatedBy: " frames=")[0] } }
        #expect(format(on) == format(off), "\(c.name): device formats changed")
        if !["rate-change-queue", "silence-tail-pair"].contains(c.name) {
            #expect(on.sha256 == off.sha256, "\(c.name): Smart Mix changed the output")
        }
    }

    static let recordedCases = ["inside-fade", "cold-cut", "trimmed", "limited", "gap"]

    static func recordedRun(_ name: String) throws -> GoldenRender.Output {
        switch name {
        case "inside-fade":
            let a = try S.song("rec-fade-a", seconds: 24, seed: 11, rms: -14, fadeOut: 8), b = try S.song("rec-fade-b", seconds: 30, seed: 12, rms: -18)
            return try R.render([T.item(a.0), T.item(b.0)], device: GoldenDevices.dac, transitions: S.smart, dither: true).output
        case "cold-cut":
            let a = try S.song("rec-cold-a", seconds: 12, seed: 21, silentTail: 0.3), b = try S.song("rec-cold-b", seconds: 12, seed: 22, silentHead: 0.2)
            return try R.render([T.item(a.0), T.item(b.0)], device: GoldenDevices.dac, transitions: S.smart, dither: false).output
        case "trimmed":
            let a = try S.song("rec-silence-a", seconds: 14, seed: 31, silentTail: 2.5), b = try S.song("rec-silence-b", seconds: 12, seed: 32, silentHead: 0.2)
            return try R.render([T.item(a.0), T.item(b.0)], device: GoldenDevices.dac, transitions: S.smart, dither: false).output
        case "limited":
            let a = try S.song("rec-loud-a", seconds: 12, seed: 61, rms: -5, silentTail: 0.3), b = try S.song("rec-loud-b", seconds: 12, seed: 62, rms: -5, silentHead: 0.2)
            var settings = S.smart
            settings.crossfadeSeconds = 3
            return try R.render([T.item(a.0), T.item(b.0)], device: GoldenDevices.dac, transitions: settings, dither: false).output
        default:
            let (ua, _) = try T.song("rec-gap-a", seconds: 2, seed: 71), (ub, _) = try T.song("rec-gap-b", seconds: 2, seed: 72)
            var settings = T.on
            settings.gapSeconds = 1.5
            return try R.render([T.item(ua), T.item(ub)], device: GoldenDevices.dac, transitions: settings, dither: true).output
        }
    }

    @Test("Stored hashes of Smart Mix's mixes", arguments: SmartMixGoldenTests.recordedCases)
    func stored(_ name: String) throws {
        let hash = try Self.recordedRun(name).sha256
        #expect(try Self.recordedRun(name).sha256 == hash, "\(name): not the same twice")
        if GoldenRecord.recording {
            SmartGoldenRecord.recorded.withLock { $0[name] = hash }
            return
        }
        let record = try SmartGoldenRecord.load()
        // libm's pow/sin/cos and log10 (the measurements) are compared only where recorded; the closed-form checks run everywhere.
        guard record.recordedOn == GoldenRecord.environment else {
            print("Smart Mix golden: \(name) recorded on \(record.recordedOn); not compared on \(GoldenRecord.environment)")
            return
        }
        #expect(record.cases[name] == hash, "\(name): output changed (\(hash))")
    }

    @Test("Record", .enabled(if: GoldenRecord.recording))
    func writeRecord() throws {
        for name in Self.recordedCases where SmartGoldenRecord.recorded.withLock({ $0[name] == nil }) { try stored(name) }
        let record = SmartGoldenRecord(recordedOn: GoldenRecord.environment, cases: SmartGoldenRecord.recorded.withLock { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: SmartGoldenRecord.sourceURL)
        print("Smart Mix golden: recorded \(record.cases.count) cases to \(SmartGoldenRecord.sourceURL.path)")
    }
}
