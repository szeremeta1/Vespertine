//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CNocturneRT
import Testing

@Suite("Real-time ring and render context")
struct RingBufferTests {
    @Test("Writes and reads wrap around without loss")
    func wrap() {
        let ring = nrt_ring_create(8, 2)!
        defer { nrt_ring_destroy(ring) }
        #expect(nrt_ring_capacity(ring) == 8)
        var out = [Float](repeating: 0, count: 16)
        var counter: Float = 0
        for _ in 0..<50 {
            let input = (0..<10).map { _ -> Float in counter += 1; return counter } // 5 frames
            #expect(nrt_ring_write(ring, input, 5) == 5)
            #expect(nrt_ring_read(ring, &out, 5) == 5)
            #expect(Array(out[0..<10]) == input)
        }
        #expect(nrt_ring_total_read(ring) == 250)
    }

    @Test("Writes never exceed free space")
    func overflow() {
        let ring = nrt_ring_create(4, 1)!
        defer { nrt_ring_destroy(ring) }
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(nrt_ring_write(ring, input, 6) == 4)
        #expect(nrt_ring_writable(ring) == 0)
    }

    @Test("Rewinding takes back look-ahead exactly, and never frames the reader is close to")
    func rewind() {
        let ring = nrt_ring_create(64, 1)!
        defer { nrt_ring_destroy(ring) }
        let current = (1...20).map(Float.init)                    // the song that's playing
        let lookAhead = [Float](repeating: -1, count: 30)          // the next one, decoded early
        #expect(nrt_ring_write(ring, current, 20) == 20)
        #expect(nrt_ring_write(ring, lookAhead, 30) == 30)
        var out = [Float](repeating: 0, count: 64)
        #expect(nrt_ring_read(ring, &out, 5) == 5)

        // Too close to the reader, or beyond what was written: refused, nothing changes.
        #expect(!nrt_ring_rewind(ring, 20, 16))
        #expect(!nrt_ring_rewind(ring, 51, 1))
        #expect(nrt_ring_total_written(ring) == 50)

        #expect(nrt_ring_rewind(ring, 20, 8))
        #expect(nrt_ring_total_written(ring) == 20 && nrt_ring_readable(ring) == 15)
        let replacement = [Float](repeating: 7, count: 10)
        #expect(nrt_ring_write(ring, replacement, 10) == 10)
        #expect(nrt_ring_read(ring, &out, 64) == 25)
        #expect(Array(out[0..<25]) == Array(current[5...]) + replacement)
    }

    @Test("Integer mode copies every 32-bit word untouched (including ones that look like NaNs as floats) and meters them")
    func integerModeIsBitExact() {
        let ring = nrt_ring_create(4096, 2)!
        defer { nrt_ring_destroy(ring) }
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx) }
        nrt_context_set_integer(ctx, true)
        nrt_context_set_gain(ctx, 0.5, 24)                     // ignored in integer mode
        var words: [UInt32] = [0x7FFF_FFFF, 0x8000_0000, 0x7FA0_0001 /* signalling NaN as float */, 0xFFC0_0000, 0x0000_0001, 0x4000_0000]
        words += (0..<506).map { UInt32(truncatingIfNeeded: $0 &* 2_654_435_761) }
        let floats = words.map { Float(bitPattern: $0) }
        #expect(nrt_ring_write(ring, floats, UInt32(words.count / 2)) == UInt32(words.count / 2))
        var out = [Float](repeating: 0, count: words.count)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(words.count / 2), 2) }
        #expect(out.map(\.bitPattern) == words)
        #expect(abs(nrt_context_take_peak(ctx, 0) - 1) < 1e-6)   // full scale, read as an integer
    }

    @Test("DoP frames go out untouched, and meters and the spectrum tap read their DSD bits", arguments: [false, true])
    func dopIsMeteredButUntouched(integer: Bool) {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_passthrough(ctx, true)
        nrt_context_set_integer(ctx, integer)
        nrt_context_set_dop(ctx, true)
        // Left: all ones (full positive); right: half ones (silence). Alternating 0x05/0xFA markers.
        var frames: [Float] = []
        for i in 0..<256 {
            let marker: UInt32 = i % 2 == 0 ? 0x05 : 0xFA
            for bits: UInt32 in [0xFFFF, 0x5555] {
                let word = marker << 16 | bits
                frames.append(integer ? Float(bitPattern: word << 8) : Float(Int32(bitPattern: word << 8) >> 8) / 8_388_608)
            }
        }
        #expect(nrt_ring_write(ring, frames, 256) == 256)
        var out = [Float](repeating: 0, count: frames.count)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, 256, 2) }
        #expect(out.map(\.bitPattern) == frames.map(\.bitPattern))
        #expect(abs(nrt_context_take_peak(ctx, 0) - 1) < 1e-6)
        #expect(nrt_context_take_peak(ctx, 1) < 1e-6)
        var tap = [Float](repeating: 9, count: 256)
        _ = nrt_context_copy_tap(ctx, &tap, 256)
        #expect(tap.allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    @Test("Muted, the output is silent at once and nothing is taken from the ring; unmuted, it carries on")
    func muteHoldsTheRing() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        let input = (0..<1024).map { Float($0 + 1) / 2048 }
        #expect(nrt_ring_write(ring, input, 512) == 512)
        nrt_context_set_muted(ctx, true)
        var out = [Float](repeating: 1, count: 256)
        nrt_context_render_interleaved(ctx, &out, 128, 2)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(nrt_ring_readable(ring) == 512)
        #expect(nrt_context_take_underruns(ctx) == 0)
        nrt_context_set_muted(ctx, false)
        nrt_context_render_interleaved(ctx, &out, 128, 2)
        #expect(out == Array(input[0..<256]))
    }

    @Test("Unity gain is bit-transparent for every 24-bit value pattern")
    func unityIsTransparent() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 { input[i] = Float(Int32(truncatingIfNeeded: i &* 2_654_435_761) >> 8) / 8_388_608 }
        #expect(nrt_ring_write(ring, input, 2048) == 2048)
        var out = [Float](repeating: 1, count: 4096)
        nrt_context_render_interleaved(ctx, &out, 2048, 2)
        #expect(out == input)
        #expect(nrt_context_take_underruns(ctx) == 0)
    }

    @Test("Running dry fills silence and counts an underrun unless draining")
    func underrun() {
        let ring = nrt_ring_create(64, 2)!
        let ctx = nrt_context_create(ring, 64)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        var out = [Float](repeating: 1, count: 32)
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(nrt_context_take_underruns(ctx) == 1)
        nrt_context_set_draining(ctx, true)
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(nrt_context_take_underruns(ctx) == 0)
    }

    @Test("Rebuffering holds in silence without consuming, then resumes exactly where it stopped")
    func rebuffer() {
        let ring = nrt_ring_create(256, 2)!
        let ctx = nrt_context_create(ring, 64)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_rebuffer(ctx, 100)
        let data = (0..<400).map { Float($0 + 1) / 1000 }     // 200 stereo frames, never zero
        var written = 0
        func write(_ frames: Int) {
            data[written * 2 ..< (written + frames) * 2].withUnsafeBufferPointer { _ = nrt_ring_write(ring, $0.baseAddress!, UInt32(frames)) }
            written += frames
        }
        var out = [Float](repeating: 1, count: 32)

        write(10)                                              // a stall: less than one slice left
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(nrt_context_is_starved(ctx))
        #expect(nrt_ring_readable(ring) == 10)                 // nothing consumed
        #expect(nrt_context_take_stalls(ctx) == 1 && nrt_context_take_underruns(ctx) == 0)

        write(50)                                              // 60 < 100: still holding
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(out.allSatisfy { $0 == 0 } && nrt_context_is_starved(ctx))

        write(50)                                              // 110 ≥ 100: resume from the first held frame
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(!nrt_context_is_starved(ctx))
        #expect(out == Array(data[0..<32]))
        #expect(nrt_context_take_stalls(ctx) == 0)

        nrt_context_set_rebuffer(ctx, 0)                       // off: back to plain underruns
        _ = nrt_ring_read(ring, &out, 16)
        var rest = [Float](repeating: 0, count: 400)
        _ = nrt_ring_read(ring, &rest, 200)
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(!nrt_context_is_starved(ctx) && nrt_context_take_underruns(ctx) == 1)
    }

    @Test("Digital gain attenuates and meters report the post-gain peak")
    func gain() {
        let ring = nrt_ring_create(64, 2)!
        let ctx = nrt_context_create(ring, 64)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 0.5, 24)
        let input = [Float](repeating: 0.8, count: 32)
        _ = nrt_ring_write(ring, input, 16)
        var out = [Float](repeating: 0, count: 32)
        nrt_context_render_interleaved(ctx, &out, 16, 2)
        #expect(out.allSatisfy { abs($0 - 0.4) < 1e-5 })
        #expect(abs(nrt_context_take_peak(ctx, 0) - 0.4) < 1e-5)
        #expect(nrt_context_take_peak(ctx, 0) == 0)
    }

    @Test("Stereo source maps onto a 4-channel device with silent extra channels")
    func channelMapping() {
        let ring = nrt_ring_create(16, 2)!
        let ctx = nrt_context_create(ring, 16)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        _ = nrt_ring_write(ring, [0.1, 0.2, 0.3, 0.4], 2)
        var out = [Float](repeating: 9, count: 8)
        nrt_context_render_interleaved(ctx, &out, 2, 4)
        #expect(out == [0.1, 0.2, 0, 0, 0.3, 0.4, 0, 0])
    }
}
