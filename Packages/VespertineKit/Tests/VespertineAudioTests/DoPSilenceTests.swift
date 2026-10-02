//
// Vespertine — DSD over PCM keeps the DAC locked in DSD: what isn't music is DoP idle frames (DSD silence behind
// markers that never repeat), not zeros, and the output keeps running through pauses, seeks and skips.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("DoP silence")
struct DoPSilenceTests {
    /// A DoP sample as RawDoPDecoder writes it (integer mode: the 32-bit word's bit pattern).
    static func sample(marker: UInt32, bits: UInt32, integer: Bool) -> Float {
        let word = (marker << 16 | bits) << 8
        return integer ? Float(bitPattern: word) : Float(Int32(bitPattern: word)) / 2_147_483_648
    }

    /// The 24-bit DoP word in a sample.
    static func word(_ sample: Float, integer: Bool) -> UInt32 {
        integer ? sample.bitPattern >> 8 : UInt32(bitPattern: Int32((sample * 8_388_608).rounded())) & 0xFF_FFFF
    }

    /// Stereo music frames numbered `numbers` (left bits = the number, right = the number + 0x8000), the markers by the
    /// decoder's frame parity from `firstMarkerOdd`.
    static func music(_ numbers: Range<Int>, firstMarkerOdd: Bool = false, integer: Bool) -> [Float] {
        numbers.enumerated().flatMap { i, n -> [Float] in
            let marker: UInt32 = (i + (firstMarkerOdd ? 1 : 0)) % 2 == 0 ? 0x05 : 0xFA
            return [sample(marker: marker, bits: UInt32(n), integer: integer), sample(marker: marker, bits: UInt32(n) | 0x8000, integer: integer)]
        }
    }

    final class Output {
        let ring: OpaquePointer
        let ctx: OpaquePointer
        let integer: Bool
        var samples: [Float] = []        // everything rendered, interleaved stereo

        init(integer: Bool) {
            ring = nrt_ring_create(4096, 2)!
            ctx = nrt_context_create(ring, 512)!
            self.integer = integer
            nrt_context_set_passthrough(ctx, true)
            nrt_context_set_integer(ctx, integer)
            nrt_context_set_dop(ctx, true)
        }
        deinit { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }

        func write(_ frames: [Float]) { #expect(nrt_ring_write(ring, frames, UInt32(frames.count / 2)) == UInt32(frames.count / 2)) }

        @discardableResult
        func render(_ frames: Int) -> ArraySlice<Float> {
            var out = [Float](repeating: 1, count: 2 * frames)
            out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(frames), 2) }
            samples += out
            return samples[(samples.count - 2 * frames)...]
        }

        /// Left words of everything rendered.
        var words: [UInt32] { stride(from: 0, to: samples.count, by: 2).map { DoPSilenceTests.word(samples[$0], integer: integer) } }
        /// Numbers of the music frames rendered, in order.
        var numbers: [Int] { words.filter { $0 & 0xFFFF != 0x6969 }.map { Int($0 & 0xFFFF) } }
        var idleCount: Int { words.count - numbers.count }

        /// Every frame: one marker on both channels, never the same twice in a row; idle frames exactly DSD silence.
        func expectUnbrokenMarkers() {
            var last: UInt32 = 0
            for f in 0..<samples.count / 2 {
                let left = DoPSilenceTests.word(samples[2 * f], integer: integer), right = DoPSilenceTests.word(samples[2 * f + 1], integer: integer)
                let marker = left >> 16
                #expect(marker == 0x05 || marker == 0xFA)
                #expect(right >> 16 == marker)
                #expect(marker != last, "two \(String(marker, radix: 16)) markers in a row at frame \(f)")
                last = marker
                if left & 0xFFFF == 0x6969 {
                    let idle = DoPSilenceTests.sample(marker: marker, bits: 0x6969, integer: integer)
                    #expect(samples[2 * f].bitPattern == idle.bitPattern && samples[2 * f + 1].bitPattern == idle.bitPattern)
                }
            }
        }
    }

    @Test("Paused, a DoP stream sends idle frames that carry the markers on; resumed, the music follows without a repeated marker",
          arguments: [false, true])
    func pauseAndResume(integer: Bool) {
        let output = Output(integer: integer)
        let written = Self.music(0..<300, integer: integer)
        output.write(written)
        output.render(101)                                   // frames 0…100: ends on 0x05
        nrt_context_set_muted(output.ctx, true)
        let paused = output.render(257)
        #expect(stride(from: paused.startIndex, to: paused.endIndex, by: 2).allSatisfy { Self.word(paused[$0], integer: integer) & 0xFFFF == 0x6969 })
        #expect(nrt_ring_readable(output.ring) == 199)       // nothing taken while paused
        #expect(nrt_context_take_peak(output.ctx, 0) == 0)   // meters read silence
        nrt_context_set_muted(output.ctx, false)
        output.render(250)
        output.expectUnbrokenMarkers()
        #expect(output.numbers == Array(0..<300))            // every music frame once, in order
        // 257 idle frames after frame 100 (0x05) end on 0xFA, as frame 101 begins: one more idle frame goes first. The
        // ring runs dry after frame 299: idle to the end of the slice, an underrun.
        #expect(output.idleCount == 257 + 1 + 50)
        #expect(nrt_context_take_underruns(output.ctx) == 1)
        // The music frames are the very bits written.
        let musicOut = stride(from: 0, to: output.samples.count, by: 2).filter { Self.word(output.samples[$0], integer: integer) & 0xFFFF != 0x6969 }
            .flatMap { [output.samples[$0], output.samples[$0 + 1]] }
        #expect(musicOut.map(\.bitPattern) == written.map(\.bitPattern))
    }

    @Test("Holding for a network read and running dry send idle frames too, never zeros")
    func stallsAndUnderruns() {
        let output = Output(integer: false)
        nrt_context_set_rebuffer(output.ctx, 200)
        output.write(Self.music(0..<50, integer: false))
        output.render(128)                                   // too little buffered: hold
        #expect(nrt_context_is_starved(output.ctx) && nrt_ring_readable(output.ring) == 50)
        // Frame 49 carries 0xFA; the next track starts on 0xFA too (a join nothing lined up): one idle frame goes between.
        output.write(Self.music(50..<250, firstMarkerOdd: true, integer: false))
        output.render(300)
        output.expectUnbrokenMarkers()
        #expect(output.numbers == Array(0..<250))
        #expect(output.idleCount == 128 + 1 + 49)            // held, the join, then dry to the end of the slice
        #expect(!output.samples.contains(0))
    }

    @Test("A seek or skip keeps a DoP output running: the I/O thread drops the old look-ahead, idle frames go out meanwhile")
    func discardWhileRunning() {
        let output = Output(integer: false)
        output.write(Self.music(0..<500, integer: false))
        output.render(64)
        nrt_context_set_muted(output.ctx, true)
        let target = nrt_context_discard(output.ctx)
        #expect(target == 500)
        output.render(64)
        #expect(nrt_ring_total_read(output.ring) == 500 && nrt_ring_readable(output.ring) == 0)
        output.write(Self.music(1000..<1100, firstMarkerOdd: true, integer: false))   // the new position
        nrt_context_set_muted(output.ctx, false)
        output.render(101)
        output.expectUnbrokenMarkers()
        #expect(output.numbers == Array(0..<64) + Array(1000..<1100))
    }

    @Test("PCM silence stays zeros")
    func pcmUnchanged() {
        let ring = nrt_ring_create(256, 2)!
        let ctx = nrt_context_create(ring, 64)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        var out = [Float](repeating: 1, count: 64)
        nrt_context_set_muted(ctx, true)
        nrt_context_render_interleaved(ctx, &out, 32, 2)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test("A paused DoP output runs on for the release setting, and never more than ten minutes")
    func pauseHold() {
        #expect(PlaybackEngine.pauseHold(release: 30, running: true) == 30)
        #expect(PlaybackEngine.pauseHold(release: 600, running: true) == 600)
        #expect(PlaybackEngine.pauseHold(release: 3_600, running: true) == PlaybackEngine.maxRunningPause)
        #expect(PlaybackEngine.pauseHold(release: .infinity, running: true) == PlaybackEngine.maxRunningPause)
        #expect(PlaybackEngine.pauseHold(release: 3_600, running: false) == 3_600)   // stopped and held: the setting alone
    }

    @Test("Before a DoP output stops, a few buffers of idle frames go out (at most 50 ms)")
    func idleOut() {
        #expect(abs(OutputSession.idleOutSeconds(bufferFrames: 512, sampleRate: 176_400) - 1_536 / 176_400.0) < 1e-12)
        #expect(OutputSession.idleOutSeconds(bufferFrames: 8_192, sampleRate: 176_400) == 0.05)
        #expect(OutputSession.idleOutSeconds(bufferFrames: 512, sampleRate: 0) == 0)
    }
}
