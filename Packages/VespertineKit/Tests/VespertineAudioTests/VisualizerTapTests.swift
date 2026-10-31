//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing

@Suite("Visualizer tap")
struct VisualizerTapTests {
    /// Stereo frames whose left sample is the frame number and right its negative, exact in Float32 up to 2^24.
    private static func ramp(from start: Int, count: Int) -> [Float] {
        (0..<count).flatMap { [Float(start + $0), -Float(start + $0)] }
    }

    private static func render(_ ctx: OpaquePointer, frames: Int, channels: Int = 2) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(frames), UInt32(channels)) }
        return out
    }

    @Test("Off by default: nothing is tapped")
    func offByDefault() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        #expect(!nrt_context_viz(ctx))
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 512), 512)
        _ = Self.render(ctx, frames: 512)
        var l = [Float](repeating: 0, count: 64), r = l
        var position: UInt64 = 99
        _ = nrt_context_copy_viz(ctx, &l, &r, 64, &position)
        #expect(position == 0)
        #expect(l.allSatisfy { $0 == 0 })
    }

    @Test("The output is bit-identical with the tap on or off, at unity gain and with gain", arguments: [1.0, 0.5])
    func outputUntouched(gain: Double) {
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 { input[i] = Float(Int32(truncatingIfNeeded: i &* 2_654_435_761) >> 8) / 8_388_608 }
        var outputs: [[UInt32]] = []
        for on in [false, true] {
            let ring = nrt_ring_create(4096, 2)!
            let ctx = nrt_context_create(ring, 4096)!
            defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
            nrt_context_set_gain(ctx, gain, 24)
            nrt_context_set_viz(ctx, on)
            _ = nrt_ring_write(ring, input, 2048)
            outputs.append(Self.render(ctx, frames: 2048).map(\.bitPattern))
        }
        #expect(outputs[0] == outputs[1])
        if gain == 1 { #expect(outputs[1] == input.map(\.bitPattern)) }
    }

    @Test("Copies the newest frames oldest first, left and right apart, at the music's size whatever the gain")
    func newestFramesUnscaled() {
        let ring = nrt_ring_create(8192, 2)!
        let ctx = nrt_context_create(ring, 1024)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        nrt_context_set_gain(ctx, 0.25, 0)    // no dither, so the output is exactly a quarter
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 3000), 3000)
        let out = Self.render(ctx, frames: 3000)
        #expect(out[2 * 2999] == 750)
        var l = [Float](repeating: 0, count: 100), r = l
        var position: UInt64 = 0
        #expect(nrt_context_copy_viz(ctx, &l, &r, 100, &position) == 100)
        #expect(position == 3000)
        #expect(l == (2901...3000).map(Float.init))
        #expect(r == (2901...3000).map { -Float($0) })
    }

    @Test("A mono source reaches both sides")
    func mono() {
        let ring = nrt_ring_create(4096, 1)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        let input = (0..<256).map { Float($0) / 256 }
        _ = nrt_ring_write(ring, input, 256)
        _ = Self.render(ctx, frames: 256)
        var l = [Float](repeating: 0, count: 256), r = l
        #expect(nrt_context_copy_viz(ctx, &l, &r, 256, nil) == 256)
        #expect(l == input && r == input)
    }

    @Test("The position stands still while muted, and nothing is tapped from silence held for a pause")
    func standsStillWhenMuted() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 1024), 1024)
        _ = Self.render(ctx, frames: 256)
        var l = [Float](repeating: 0, count: 16), r = l
        var position: UInt64 = 0
        _ = nrt_context_copy_viz(ctx, &l, &r, 16, &position)
        #expect(position == 256)
        nrt_context_set_muted(ctx, true)
        _ = Self.render(ctx, frames: 256)
        _ = nrt_context_copy_viz(ctx, &l, &r, 16, &position)
        #expect(position == 256)
        #expect(l.last == 256)
    }

    @Test("DoP: the tap reads the levels of the DSD bits, and the frames still go out untouched")
    func dop() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_passthrough(ctx, true)
        nrt_context_set_dop(ctx, true)
        nrt_context_set_viz(ctx, true)
        var frames: [Float] = []
        for i in 0..<256 {
            let marker: UInt32 = i % 2 == 0 ? 0x05 : 0xFA
            for bits: UInt32 in [0xFFFF, 0x5555] {
                frames.append(Float(Int32(bitPattern: (marker << 16 | bits) << 8) >> 8) / 8_388_608)
            }
        }
        _ = nrt_ring_write(ring, frames, 256)
        #expect(Self.render(ctx, frames: 256).map(\.bitPattern) == frames.map(\.bitPattern))
        var l = [Float](repeating: 0, count: 128), r = l
        #expect(nrt_context_copy_viz(ctx, &l, &r, 128, nil) == 128)
        #expect(l.allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(r.allSatisfy { abs($0) < 1e-6 })
    }

    /// The render context and ring, shared with the threads below.
    private struct Shared: @unchecked Sendable {
        let ring: OpaquePointer
        let ctx: OpaquePointer
    }

    @Test("The I/O side never waits for the reader, and every copy the reader keeps is one moment, never torn")
    func neverBlocksNeverTears() async {
        let ring = nrt_ring_create(65536, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        let shared = Shared(ring: ring, ctx: ctx)
        let slices = 8000, slice = 512
        let stop = Locked(false)

        // The reader copies as fast as it can, the largest windows the tap allows, checking every copy it keeps.
        let reader = Task.detached { () -> (kept: Int, dropped: Int, torn: Int) in
            var l = [Float](repeating: 0, count: Int(NRT_VIZ_TAP_SIZE / 2)), r = l
            var kept = 0, dropped = 0, torn = 0
            while !stop.value {
                let got = nrt_context_copy_viz(shared.ctx, &l, &r, UInt32(l.count), nil)
                if got == 0 { dropped += 1; continue }
                guard let first = l.first, first > 0 else { continue }   // before the first full window
                kept += 1
                for i in 1..<l.count where l[i] != l[i - 1] + 1 || r[i] != -l[i] { torn += 1; break }
            }
            return (kept, dropped, torn)
        }

        // The I/O side: decode-and-render loops, as fast as they go. Its time per slice shouldn't depend on the reader.
        let writer = Task.detached { () -> Double in
            var out = [Float](repeating: 0, count: slice * 2)
            var next = 1
            let start = Date()
            for _ in 0..<slices {
                let input = (0..<slice).flatMap { [Float(next + $0), -Float(next + $0)] }
                next += slice
                if next > 1 << 23 { next = 1 }   // stay exact in Float32
                _ = nrt_ring_write(shared.ring, input, UInt32(slice))
                out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(shared.ctx, $0.baseAddress!, UInt32(slice), 2) }
            }
            return Date().timeIntervalSince(start)
        }
        let elapsed = await writer.value
        stop.value = true
        let result = await reader.value
        #expect(result.torn == 0)
        #expect(result.kept > 0)
        // 8000 slices of 512 frames is 93 s of 44.1 kHz audio; rendering it with the reader racing must stay far
        // faster than real time (a reader that could hold the I/O thread up would show here).
        #expect(elapsed < 20)
    }
}

/// A value shared between test threads.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
