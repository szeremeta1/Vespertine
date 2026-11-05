//
// Vespertine — the stereo-to-5.1 upmixer on its own: where each kind of sound goes, that nothing is phase-inverted or
// invented, that folding the result back (ITU-R BS.775) gives the original, and that it's sample-aligned and length-exact.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Spatialize stereo: the upmixer")
struct StereoUpmixTests {
    /// Runs interleaved `input` (`channels` 1 or 2) through a fresh upmixer, in uneven blocks as decoding hands them over.
    static func upmix(_ input: [Float], channels: Int = 2, rate: Double = 48_000, settings: UpmixSettings = UpmixSettings()) throws -> [Float] {
        let upmixer = try #require(StereoUpmixer(inputChannels: channels, sampleRate: rate, settings: settings))
        var out: [Float] = []
        let frames = input.count / channels
        var f = 0, block = 997
        while f < frames {
            let n = min(block, frames - f)
            input.withUnsafeBufferPointer { upmixer.process($0.baseAddress! + f * channels, frames: n, into: &out) }
            f += n
            block = block == 997 ? 4096 : 997
        }
        upmixer.finish(into: &out)
        return out
    }

    static func rms(_ x: [Float], channel: Int, of n: Int = 6, from: Int, count: Int) -> Double {
        var s = 0.0
        for f in from..<(from + count) { let v = Double(x[f * n + channel]); s += v * v }
        return (s / Double(count)).squareRoot()
    }

    static func tone(_ frames: Int, _ hz: Double, rate: Double = 48_000, gains: (Float, Float)) -> [Float] {
        var x = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let s = Float(sin(2 * .pi * hz * Double(f) / rate))
            x[f * 2] = gains.0 * s
            x[f * 2 + 1] = gains.1 * s
        }
        return x
    }

    /// Deterministic white noise in [-1, 1].
    static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: (state >> 11) << 11)) / Float(Int64.max)
        }
    }

    static let names = ["L", "R", "C", "LFE", "Ls", "Rs"]

    @Test("A centre-panned sound moves to the centre at the same power; nothing else carries it", arguments: [44_100.0, 48_000, 96_000, 192_000])
    func centre(rate: Double) throws {
        let frames = Int(rate * 2)
        let out = try Self.upmix(Self.tone(frames, 997, rate: rate, gains: (0.25, 0.25)), rate: rate)
        #expect(out.count == frames * 6)
        let from = Int(rate * 0.5), count = Int(rate)
        let levels = (0..<6).map { Self.rms(out, channel: $0, from: from, count: count) }
        let source = 0.25 / 2.0.squareRoot()
        #expect(abs(levels[2] / (source * 2.0.squareRoot()) - 1) < 0.01, "C \(levels[2]), want \(source * 2.0.squareRoot())")
        for c in [0, 1, 3, 4, 5] { #expect(levels[c] < source * 0.01, "\(Self.names[c]) \(levels[c]) (−40 dB is \(source * 0.01))") }
    }

    @Test("A hard-left sound stays on the left: no centre, no surround")
    func hardLeft() throws {
        let out = try Self.upmix(Self.tone(96_000, 440, gains: (0.3, 0)))
        let levels = (0..<6).map { Self.rms(out, channel: $0, from: 24_000, count: 48_000) }
        let source = 0.3 / 2.0.squareRoot()
        #expect(abs(levels[0] / source - 1) < 0.01, "L \(levels[0])")
        for c in 1..<6 { #expect(levels[c] < source * 0.01, "\(Self.names[c]) \(levels[c])") }
    }

    @Test("Out-of-phase L and R make no centre and no ambience: the fronts keep it as it is")
    func antiPhase() throws {
        let out = try Self.upmix(Self.tone(96_000, 440, gains: (0.3, -0.3)))
        let levels = (0..<6).map { Self.rms(out, channel: $0, from: 24_000, count: 48_000) }
        let source = 0.3 / 2.0.squareRoot()
        #expect(abs(levels[0] / source - 1) < 0.01 && abs(levels[1] / source - 1) < 0.01, "\(levels)")
        for c in 2..<6 { #expect(levels[c] < source * 0.01, "\(Self.names[c]) \(levels[c])") }
    }

    @Test("Diffuse sound (uncorrelated L and R) feeds the surrounds at the ambience level; little reaches the centre")
    func diffuse() throws {
        let frames = 192_000
        let l = Self.noise(frames, seed: 1), r = Self.noise(frames, seed: 2)
        var input = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { input[f * 2] = 0.2 * l[f]; input[f * 2 + 1] = 0.2 * r[f] }
        let out = try Self.upmix(input)
        let from = 24_000, count = 144_000
        let levels = (0..<6).map { Self.rms(out, channel: $0, from: from, count: count) }
        let source = 0.2 / 3.0.squareRoot()
        print("diffuse: " + zip(Self.names, levels).map { "\($0) \(String(format: "%.1f", 20 * log10($1 / source))) dB" }.joined(separator: " · "))
        // Coherence measured over ~40 ms is never exactly 0 for independent noise, so some ambience is read as shared.
        #expect(levels[4] > source * 0.5 * 0.6 && levels[4] < source * 0.5 * 1.05, "Ls \(levels[4])")
        #expect(levels[5] > source * 0.5 * 0.6 && levels[5] < source * 0.5 * 1.05, "Rs \(levels[5])")
        #expect(levels[2] < source * 0.5, "C \(levels[2])")
        #expect(levels[3] == 0, "LFE must stay silent by default")
    }

    @Test("Folded back to stereo (L′ + 0.707·C, R′ + 0.707·C) a panned sound is the original", arguments: [(Float(0.8), Float(0.4)), (0.2, 0.9), (0.5, 0.5)])
    func foldsBack(gains: (Float, Float)) throws {
        let frames = 96_000
        let s = Self.noise(frames, seed: 7)
        var input = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { input[f * 2] = gains.0 * 0.3 * s[f]; input[f * 2 + 1] = gains.1 * 0.3 * s[f] }
        let out = try Self.upmix(input)
        var error = 0.0, signal = 0.0
        for f in 24_000..<72_000 {
            let l = Double(out[f * 6] + 0.70710677 * out[f * 6 + 2]), r = Double(out[f * 6 + 1] + 0.70710677 * out[f * 6 + 2])
            error += pow(l - Double(input[f * 2]), 2) + pow(r - Double(input[f * 2 + 1]), 2)
            signal += pow(Double(input[f * 2]), 2) + pow(Double(input[f * 2 + 1]), 2)
        }
        let db = 10 * log10(error / signal)
        #expect(db < -60, "fold-back error \(db) dB")
    }

    @Test("Sample-aligned and length-exact: an impulse comes out at its own frame, a song exactly as long as it went in",
          arguments: [1, 517, 48_000, 48_001, 123_457])
    func alignment(frames: Int) throws {
        var input = [Float](repeating: 0, count: frames * 2)
        let at = frames / 2
        input[at * 2] = 0.5; input[at * 2 + 1] = 0.5
        let out = try Self.upmix(input)
        #expect(out.count == frames * 6)
        if frames > 1 {
            let c = (0..<frames).map { abs(out[$0 * 6 + 2]) }
            #expect(c.indices.max { c[$0] < c[$1] } == at, "centre peak at \(c.indices.max { c[$0] < c[$1] } ?? -1), impulse at \(at)")
        }
    }

    @Test("Mono plays from the centre, at the power of the same mono on two speakers")
    func mono() throws {
        let frames = 96_000
        let m = (0..<frames).map { Float(0.3 * sin(2 * .pi * 300 * Double($0) / 48_000)) }
        let out = try Self.upmix(m, channels: 1)
        let levels = (0..<6).map { Self.rms(out, channel: $0, from: 24_000, count: 48_000) }
        let source = 0.3 / 2.0.squareRoot()
        #expect(abs(levels[2] / (source * 2.0.squareRoot()) - 1) < 0.01, "C \(levels[2])")
        for c in [0, 1, 3, 4, 5] { #expect(levels[c] < source * 0.01, "\(Self.names[c]) \(levels[c])") }
    }

    @Test("With an LFE level set, the LFE carries the bass and none of the treble")
    func lfe() throws {
        var settings = UpmixSettings()
        settings.lfeGain = 1
        let low = try Self.upmix(Self.tone(96_000, 50, gains: (0.3, 0.3)), settings: settings)
        let high = try Self.upmix(Self.tone(96_000, 2_000, gains: (0.3, 0.3)), settings: settings)
        let source = 0.3 / 2.0.squareRoot()
        #expect(abs(Self.rms(low, channel: 3, from: 24_000, count: 48_000) / source - 1) < 0.05)
        #expect(Self.rms(high, channel: 3, from: 24_000, count: 48_000) < source * 0.001)
    }
}
