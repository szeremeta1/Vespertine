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
