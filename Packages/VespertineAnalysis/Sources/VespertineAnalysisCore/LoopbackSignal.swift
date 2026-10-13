//
// Vespertine — the loopback test signal: what is played out to a loopback device and compared, sample for sample,
// with what comes back.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per channel: lead silence, a start-sync MLS at ±0.5 FS (a different polynomial on each channel, so swapped,
// inverted or duplicated channels are told apart), an edge block (full-scale extremes, ±1 LSB, walking ones,
// 0x55/0xAA patterns), a seeded random full-range payload, an end sync (the start sync reversed, so the two never
// mistake each other for the other), then tail silence. Samples are signed integers at the test's bit depth; played
// as files, so the real decoder runs.
//

import Foundation

public struct LoopbackSignal: Sendable {
    public struct Spec: Sendable, Hashable, Codable {
        public var sampleRate: Double
        /// 16, 24 or 32.
        public var bits: Int
        public var channels: Int
        public var payloadSeconds: Double
        public var seed: UInt64
        /// Which set of sync polynomials: two signals played one after the other (a 16-bit file, then a 24-bit one)
        /// use different sets, so each is found on its own.
        public var syncSet: Int

        public init(sampleRate: Double, bits: Int, channels: Int = 2, payloadSeconds: Double = 2, seed: UInt64 = 0x5645_5350, syncSet: Int = 0) {
            self.sampleRate = sampleRate
            self.bits = bits
            self.channels = channels
            self.payloadSeconds = payloadSeconds
            self.seed = seed
            self.syncSet = syncSet
        }
    }

    /// MLS length 2^14 − 1: 0.37 s at 44.1 kHz, 43 ms at 384 kHz.
    public static let mlsDegree = 14
    /// Galois feedback masks of maximal-length 14-bit LFSRs (each one checked in the tests).
    public static let mlsTaps: [UInt32] = [0x2015, 0x2029, 0x202F, 0x203D, 0x2057, 0x205D, 0x2067, 0x2075]
    /// Channels × sync sets the polynomials cover.
    public static let maxChannels = 4

    public let spec: Spec
    /// Per channel, signed integers at `spec.bits`.
    public let samples: [[Int32]]
    public let startSync: Range<Int>
    public let edge: Range<Int>
    public let payload: Range<Int>
    public let endSync: Range<Int>
    public var frames: Int { samples.first?.count ?? 0 }
    /// What's compared: start sync through end sync.
    public var compared: Range<Int> { startSync.lowerBound..<endSync.upperBound }
    /// Where the gapless case splits the signal into two files: the middle of the payload.
    public var splitFrame: Int { payload.lowerBound + payload.count / 2 }
    public var fullScale: Double { Double(Int64(1) << (spec.bits - 1)) }

    public init(_ spec: Spec) {
        precondition([16, 24, 32].contains(spec.bits) && spec.channels >= 1 && spec.channels <= Self.maxChannels
                     && spec.syncSet >= 0 && spec.syncSet * spec.channels + spec.channels <= Self.mlsTaps.count)
        self.spec = spec
        let quiet = max(4096, Int(spec.sampleRate * 0.05))
        let mlsLength = (1 << Self.mlsDegree) - 1
        let edgeBlock = (0..<spec.channels).map { Self.edgeBlock(bits: spec.bits, channel: $0) }
        let payloadFrames = max(1024, Int(spec.sampleRate * spec.payloadSeconds))
        startSync = quiet..<(quiet + mlsLength)
        edge = startSync.upperBound..<(startSync.upperBound + edgeBlock[0].count)
        payload = edge.upperBound..<(edge.upperBound + payloadFrames)
        endSync = payload.upperBound..<(payload.upperBound + mlsLength)
        let total = endSync.upperBound + quiet
        let half = Int32(truncatingIfNeeded: Int64(1) << (spec.bits - 2))
        var out: [[Int32]] = []
        for c in 0..<spec.channels {
            var x = [Int32](repeating: 0, count: total)
            let mls = Self.mls(channel: c, syncSet: spec.syncSet, channels: spec.channels)
            for (i, v) in mls.enumerated() {
                x[startSync.lowerBound + i] = v > 0 ? half : -half
                x[endSync.lowerBound + i] = mls[mlsLength - 1 - i] > 0 ? half : -half
            }
            for (i, v) in edgeBlock[c].enumerated() { x[edge.lowerBound + i] = v }
            var rng = SplitMix64(seed: spec.seed &+ UInt64(c) &* 0x9E37_79B9_7F4A_7C15)
            for i in payload { x[i] = Int32(truncatingIfNeeded: Int64(bitPattern: rng.next()) >> (64 - spec.bits)) }
            out.append(x)
        }
        samples = out
    }

    /// ±1 per chip of the start sync on `channel`.
    public static func mls(channel: Int, syncSet: Int, channels: Int) -> [Int8] {
        mls(taps: mlsTaps[syncSet * channels + channel])
    }

    /// A Galois LFSR's output bits as ±1, one period.
    public static func mls(taps: UInt32, degree: Int = mlsDegree) -> [Int8] {
        let n = (1 << degree) - 1
        var state: UInt32 = 1
        var out = [Int8](repeating: 0, count: n)
        for i in 0..<n {
            let bit = state & 1
            out[i] = bit == 1 ? 1 : -1
            state >>= 1
            if bit == 1 { state ^= taps }
        }
        return out
    }

    /// Full-scale extremes, ±1 LSB, walking ones and zeros and 0x55/0xAA words, in both polarities.
    static func edgeBlock(bits: Int, channel: Int) -> [Int32] {
        let maxV = Int64(1) << (bits - 1) - 1
        let minV = -(Int64(1) << (bits - 1))
        let mask = (Int64(1) << bits) - 1
        func signed(_ word: Int64) -> Int64 { let w = word & mask; return w > maxV ? w - (mask + 1) : w }
        var v: [Int64] = []
        for _ in 0..<8 { v += [maxV, minV] }
        for _ in 0..<4 { v += [maxV, maxV, minV, minV] }
        v += [0, 1, -1, 0, 1, 1, -1, -1, 0, minV + 1, maxV - 1, 0]
        for k in 0..<bits { v += [signed(Int64(1) << k), signed(~(Int64(1) << k))] }
        var five: Int64 = 0
        for k in stride(from: 0, to: bits, by: 2) { five |= Int64(1) << k }
        for _ in 0..<8 { v += [signed(five), signed(~five)] }
        v += [signed(five), signed(five), signed(~five), signed(~five), 0]
        // A channel's block is its own (rotated), so a channel copied onto another shows as different samples too.
        let r = channel % max(1, v.count)
        return (v[r...] + v[..<r]).map { Int32(truncatingIfNeeded: $0) }
    }

    /// Float32 sample values (what goes into a Float32 file or comes back from a float input).
    public func floatSamples(channel: Int, range: Range<Int>? = nil) -> [Float] {
        let scale = 1 / fullScale
        return samples[channel][range ?? 0..<frames].map { Float(Double($0) * scale) }
    }
}

/// Small, seedable, the same on every platform.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
