//
// Vespertine: the silence at the ends of songs, through the same render the golden tests use: what the output holds
// between one song's last sound and the next one's first, for each style, with realistic ends (a fade-out into
// near-silence, dither-level noise) as well as exact zeros.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transition trim", .serialized)
struct TransitionTrimTests {
    typealias T = TransitionGolden
    static let rate = 48_000

    enum Ends: String, CaseIterable {
        /// Exact zeros: a song cut to length, a padded file.
        case zeros
        /// Noise at about −80 dBFS: dither, or the floor a fade-out settles into.
        case floor
    }

    /// A song of `seconds` with `silentTail` frames at its end and `silentHead` at its start, filled as `ends` says.
    static func song(_ name: String, seconds: Double, seed: UInt64, head: Int = 0, tail: Int = 0, ends: Ends) throws -> URL {
        var s = GoldenFixtures.samples(frames: Int(seconds * Double(rate)), channels: 2, bits: 24, seed: seed)
        var noise = SplitMix(seed: seed &+ 99)
        let floor = Double(1 << 23) * 0.0001                       // −80 dBFS
        for c in 0..<2 {
            for n in 0..<head { s[c][n] = ends == .zeros ? 0 : Int32((noise.unit() * 2 - 1) * floor) }
            for n in (s[c].count - tail)..<s[c].count { s[c][n] = ends == .zeros ? 0 : Int32((noise.unit() * 2 - 1) * floor) }
        }
        return try GoldenCases.wav("transition-trim-\(name).wav", s, bits: 24, rate: rate)
    }

    /// The longest run of frames under −60 dBFS in both channels, in seconds.
    static func longestQuiet(_ words: [UInt32], channels: Int = 2) -> Double {
        var best = 0, run = 0
        for f in 0..<(words.count / channels) {
            var loud = false
            for c in 0..<channels where abs(Float(bitPattern: words[f * channels + c])) > SilenceScan.threshold { loud = true }
            if loud { run = 0 } else { run += 1; best = max(best, run) }
        }
        return Double(best) / Double(rate)
    }

    static func render(_ a: URL, _ b: URL, style: TransitionStyle, trim: Bool) throws -> (quiet: Double, seconds: Double) {
        var s = T.on
        s.style = style
        s.trimSilence = trim
        let run = try GoldenRender.render([T.item(a), T.item(b)], device: GoldenDevices.dac, transitions: s, dither: false)
        let words = run.output.sessions.flatMap(\.words)
        return (longestQuiet(words), Double(words.count / 2) / Double(rate))
    }

    @Test("Four seconds of silence at the end of one song and three at the start of the next leave no gap, in every style",
          arguments: TransitionStyle.allCases, Ends.allCases)
    func trimmed(style: TransitionStyle, ends: Ends) throws {
        let a = try Self.song("a-\(ends)", seconds: 20, seed: 11, tail: 4 * Self.rate, ends: ends)
        let b = try Self.song("b-\(ends)", seconds: 20, seed: 12, head: 3 * Self.rate, ends: ends)
        let r = try Self.render(a, b, style: style, trim: true)
        #expect(r.quiet < 0.05, "\(style) with \(ends): \(r.quiet) s of quiet between the songs")
    }

    @Test("With trimming off a crossfade keeps the silence: the same songs leave the full second of it",
          arguments: Ends.allCases)
    func untrimmed(ends: Ends) throws {
        let a = try Self.song("ua-\(ends)", seconds: 20, seed: 11, tail: 4 * Self.rate, ends: ends)
        let b = try Self.song("ub-\(ends)", seconds: 20, seed: 12, head: 3 * Self.rate, ends: ends)
        let on = try Self.render(a, b, style: .crossfade, trim: true)
        let off = try Self.render(a, b, style: .crossfade, trim: false)
        #expect(off.quiet > 0.9)
        #expect(off.seconds - on.seconds > 6.9, "trimming should take out the 4 s + 3 s of silence")
    }
}

/// A small deterministic generator for the noise floor.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
