//
// Vespertine — the spectrum and visualizer taps on a multichannel bed (Spatial Audio, upmixed stereo, 5.1 outputs): they
// must carry every speaker, not the first two channels of the bed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Taps on a multichannel bed")
struct BedTapTests {
    static let rate = 48_000.0

    /// `frames` interleaved frames of `channels`, a 1 kHz tone of `amplitude` on each channel in `on`.
    static func bed(channels: Int, on: [Int], frames: Int, amplitude: Float = 0.2) -> [Float] {
        var x = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let s = amplitude * Float(sin(2 * .pi * 1_000 * Double(f) / rate))
            for c in on { x[f * channels + c] = s }
        }
        return x
    }

    /// Writes `bed` through a context of `channels` (the mix `labels` when given), renders it, and reads what the taps saw:
    /// the spectrum tap's mono samples and the visualizer's left and right.
    static func taps(_ bed: [Float], channels: Int, labels: [AudioChannelLabel]? = nil) -> (mono: [Float], left: [Float], right: [Float]) {
        let frames = bed.count / channels
        let ring = nrt_ring_create(UInt32(frames + 1024), UInt32(channels))!
        let ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        if let labels { applyTapMix(ctx, labels: labels) }
        nrt_context_set_viz(ctx, true)
        _ = nrt_ring_write(ring, bed, UInt32(frames))
        var out = [Float](repeating: 0, count: frames * channels)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(frames), UInt32(channels)) }
        let n = 8192
        var mono = [Float](repeating: 0, count: n), l = mono, r = mono
        _ = nrt_context_copy_tap(ctx, &mono, UInt32(n))
        _ = nrt_context_copy_viz(ctx, &l, &r, UInt32(n), nil)
        return (mono, l, r)
    }

    static func level(_ x: [Float]) -> Double { SpatialProbe.level(x, stride: 1, offset: 0, frequency: 1_000, rate: rate, from: 1_000, count: 4_800) }

    @Test("A 5.1 bed's spectrum tap carries the centre, the surrounds and the LFE, not only L and R")
    func fiveOne() {
        let names = ["L", "R", "C", "LFE", "Ls", "Rs"]
        for (c, name) in names.enumerated() {
            let t = Self.taps(Self.bed(channels: 6, on: [c], frames: 12_000), channels: 6)
            #expect(Self.level(t.mono) > 0.02, "\(name) alone: the spectrum tap saw \(Self.level(t.mono))")
            #expect(Self.level(t.left) + Self.level(t.right) > 0.02, "\(name) alone: the visualizer saw nothing")
        }
    }

    @Test("The tap keeps the sides apart: L only on the left, R only on the right, the centre on both")
    func sides() {
        let left = Self.taps(Self.bed(channels: 6, on: [0], frames: 12_000), channels: 6)
        #expect(Self.level(left.left) > 0.15 && Self.level(left.right) < 0.001)
        let right = Self.taps(Self.bed(channels: 6, on: [1], frames: 12_000), channels: 6)
        #expect(Self.level(right.right) > 0.15 && Self.level(right.left) < 0.001)
        let centre = Self.taps(Self.bed(channels: 6, on: [2], frames: 12_000), channels: 6)
        #expect(abs(Self.level(centre.left) - Self.level(centre.right)) < 0.001 && Self.level(centre.left) > 0.1)
    }

    @Test("Two channels, as before: the tap is the mean of L and R")
    func stereoUnchanged() {
        let t = Self.taps(Self.bed(channels: 2, on: [0], frames: 12_000, amplitude: 0.4), channels: 2)
        #expect(abs(Self.level(t.mono) - 0.2) < 0.005)
        #expect(abs(Self.level(t.left) - 0.4) < 0.005 && Self.level(t.right) < 0.001)
    }

    @Test("A bed in another order (HDMI: L R LFE C Ls Rs) is folded by its labels")
    func labelled() {
        let hdmi: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LFEScreen,
                                         kAudioChannelLabel_Center, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let left = Self.taps(Self.bed(channels: 6, on: [4], frames: 12_000), channels: 6, labels: hdmi)
        #expect(Self.level(left.left) > 0.1 && Self.level(left.right) < 0.001, "Ls is on the left side")
        let centre = Self.taps(Self.bed(channels: 6, on: [3], frames: 12_000), channels: 6, labels: hdmi)
        #expect(Self.level(centre.left) > 0.1 && abs(Self.level(centre.left) - Self.level(centre.right)) < 0.001, "C (4th) is on both")
    }

    @Test("A dual-mono song, upmixed (all in the centre), still shows a spectrum: the original's, at the original's level")
    func dualMonoUpmixed() throws {
        let frames = 24_000
        var stereo = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { let s = 0.3 * Float(sin(2 * .pi * 1_000 * Double(f) / Self.rate)); stereo[2 * f] = s; stereo[2 * f + 1] = s }
        let bed = try StereoUpmixTests.upmix(stereo)
        let t = Self.taps(bed, channels: 6, labels: StereoUpmixer.outputLabels)
        #expect(Self.level(bed.enumerated().filter { $0.offset % 6 == 2 }.map(\.element)) > 0.3, "the upmix put it in the centre")
        #expect(abs(Self.level(t.left) - 0.3) < 0.01 && abs(Self.level(t.right) - 0.3) < 0.01, "visualizer \(Self.level(t.left)) \(Self.level(t.right))")
        #expect(abs(Self.level(t.mono) - 0.3) < 0.01, "spectrum \(Self.level(t.mono))")
    }
}
