//
// Vespertine — the real-time fader (transitions' fades on play, pause, stop, skip and seek): idle it changes nothing,
// a ramp has the right shape, a fade out mutes at its end and leaves the fader at full level, and native DSD,
// passthrough and integer words are never scaled.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing

@Suite("Real-time fader")
struct FaderTests {
    /// 24-bit-like values over the whole range, interleaved stereo.
    private func signal(_ frames: Int) -> [Float] {
        (0..<frames * 2).map { Float(Int32(truncatingIfNeeded: $0 &* 2_654_435_761) >> 8) / 8_388_608 }
    }

    private func render(_ ctx: OpaquePointer, _ frames: Int, channels: Int = 2) -> [Float] {
        var out = [Float](repeating: 7, count: frames * channels)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(frames), UInt32(channels)) }
        return out
    }

    @Test("Idle, and after a fade has come back up, the output is a copy, bit for bit")
    func idleIsTransparent() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        let input = signal(6000)
        #expect(nrt_ring_write(ring, input, 6000) == 6000)
        #expect(render(ctx, 2000).map(\.bitPattern) == input[0..<4000].map(\.bitPattern))
        #expect(!nrt_context_fading(ctx))
        // A fade in from silence over 1000 frames, then a copy again (dither is on at 24 bits: only during the ramp).
        nrt_context_fade(ctx, true, 1000, true, false)
        #expect(nrt_context_fading(ctx))
        _ = render(ctx, 1000)
        #expect(!nrt_context_fading(ctx))
        #expect(render(ctx, 3000).map(\.bitPattern) == input[6000..<12000].map(\.bitPattern))
    }

    @Test("A fade out follows its ramp, mutes at its end, takes nothing more from the ring, and resets to full level")
    func fadeOutThenMute() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 0)            // no dither, so the ramp can be checked exactly
        let input = signal(4000)
        #expect(nrt_ring_write(ring, input, 4000) == 4000)
        nrt_context_fade(ctx, false, 800, false, true)
        let out = render(ctx, 1024)
        var level = 1.0
        for f in 0..<1024 {
            for c in 0..<2 {
                let expected = f < 800 ? Float(Double(input[2 * f + c]) * level) : 0
                #expect(abs(out[2 * f + c] - expected) <= 1e-7, "frame \(f)")
            }
            if f < 800 { level += -1.0 / 800 }
        }
        #expect(abs(out[2] - input[2] * (1 - 1 / 800)) < 1e-7)
        #expect(nrt_context_is_muted(ctx))
        #expect(!nrt_context_fading(ctx))
        // Muted: nothing more is read (the slice that finished the fade was read whole).
        let readable = nrt_ring_readable(ring)
        #expect(render(ctx, 256).allSatisfy { $0 == 0 })
        #expect(nrt_ring_readable(ring) == readable)
        // Unmuted without a fade: full level straight away, a copy.
        nrt_context_set_muted(ctx, false)
        #expect(render(ctx, 256).map(\.bitPattern) == input[2048..<2560].map(\.bitPattern))
    }

    @Test("A fade in from silence rises along its ramp; held muted, it waits")
    func fadeIn() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 0)
        let input = [Float](repeating: 0.5, count: 2 * 3000)
        #expect(nrt_ring_write(ring, input, 3000) == 3000)
        nrt_context_set_muted(ctx, true)
        nrt_context_fade(ctx, true, 1000, true, false)
        #expect(render(ctx, 300).allSatisfy { $0 == 0 })
        #expect(nrt_context_fading(ctx))
        nrt_context_set_muted(ctx, false)
        let out = render(ctx, 1200)
        #expect(out[0] == 0 && out[1] == 0)
        for f in 1..<1000 { #expect(abs(out[2 * f] - Float(0.5 * Double(f) / 1000)) < 1e-6, "frame \(f)") }
        #expect(out[2000...].allSatisfy { $0 == 0.5 })
        #expect(!nrt_context_fading(ctx))
    }

    @Test("A new command takes over from where the level is (a skip during a fade in)")
    func reverses() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 0)
        #expect(nrt_ring_write(ring, [Float](repeating: 1, count: 8000), 4000) == 4000)
        nrt_context_fade(ctx, true, 1000, true, false)
        let up = render(ctx, 500)
        #expect(abs(up[998] - 0.499) < 1e-6)
        nrt_context_fade(ctx, false, 500, false, true)
        let down = render(ctx, 600)
        #expect(abs(down[0] - 0.5) < 1e-6)
        #expect(down[1000...].allSatisfy { $0 == 0 })
        #expect(nrt_context_is_muted(ctx))
    }

    @Test("The fade multiplies with the digital volume, and dithers like it")
    func withDigitalVolume() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 0.5, 0)
        #expect(nrt_ring_write(ring, [Float](repeating: 0.8, count: 4000), 2000) == 2000)
        nrt_context_fade(ctx, false, 400, false, false)
        let out = render(ctx, 600)
        #expect(abs(out[0] - 0.4) < 1e-7)
        #expect(abs(out[400] - 0.2) < 1e-6)
        // Down to silence without `thenMute`: it stays silent, unmuted, until faded up again.
        #expect(out[800...].allSatisfy { $0 == 0 })
        #expect(!nrt_context_is_muted(ctx))
        nrt_context_fade(ctx, true, 0, false, false)
        #expect(render(ctx, 100).allSatisfy { abs($0 - 0.4) < 1e-7 })
    }

    @Test("Native DSD, passthrough and integer words are never scaled: a command applies at once", arguments: ["dop", "passthrough", "integer"])
    func bypass(_ kind: String) {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        switch kind {
        case "dop": nrt_context_set_dop(ctx, true)
        case "passthrough": nrt_context_set_passthrough(ctx, true)
        default: nrt_context_set_integer(ctx, true)
        }
        // Words that are DoP frames with alternating markers (valid for every kind).
        var words = [UInt32]()
        for f in 0..<2000 { let m: UInt32 = f % 2 == 0 ? 0x05 : 0xFA; words += [(m << 16 | UInt32(f & 0xFFFF)) << 8, (m << 16 | UInt32((f + 7) & 0xFFFF)) << 8] }
        let input: [Float] = kind == "integer" ? words.map { Float(bitPattern: $0) } : words.map { Float(Int32(bitPattern: $0)) / 2_147_483_648 }
        #expect(nrt_ring_write(ring, input, 2000) == 2000)
        nrt_context_fade(ctx, true, 1000, true, false)
        let out = render(ctx, 1000)
        #expect(out.map(\.bitPattern) == input[0..<2000].map(\.bitPattern))
        #expect(!nrt_context_fading(ctx))
        // A fade out that mutes: muted at once (DoP then sends idle frames).
        nrt_context_fade(ctx, false, 1000, false, true)
        _ = render(ctx, 10)
        #expect(nrt_context_is_muted(ctx))
        nrt_context_set_muted(ctx, false)
        let after = render(ctx, 500)
        if kind != "dop" { #expect(after.map(\.bitPattern) == input[2000..<3000].map(\.bitPattern)) }
    }
}
