//
// Vespertine: left/right balance. The law (only the far side is turned down, the center is exactly untouched), the menu's
// steps, the render path (a copy at the center, a ramp on a change, never integer words or anything but stereo), which
// streams take it, and what the signal path says.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

private func output(_ uid: String, channels: Int = 2) -> OutputDevice {
    OutputDevice(id: 0, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                 capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: channels, supportsDoP: false),
                 hasHardwareVolume: false, isDefault: false)
}

@Suite("Balance: the law")
struct BalanceLawTests {
    @Test("The center is exactly (1, 1)")
    func center() {
        let g = BalanceLaw.gains(0)
        #expect(g.left == 1 && g.right == 1)
        let negativeZero = BalanceLaw.gains(-0.0)
        #expect(negativeZero.left == 1 && negativeZero.right == 1)
    }

    @Test("The far side follows a quarter cosine", arguments: [(0.25, 0.923879533), (0.50, 0.707106781), (0.75, 0.382683432)])
    func table(balance: Double, far: Double) {
        #expect(abs(BalanceLaw.gains(balance).left - far) < 1e-9)
        #expect(abs(BalanceLaw.gains(-balance).right - far) < 1e-9)
    }

    @Test("All the way over, the far side is exact silence")
    func extremes() {
        #expect(BalanceLaw.gains(1).left == 0 && BalanceLaw.gains(1).right == 1)
        #expect(BalanceLaw.gains(-1).right == 0 && BalanceLaw.gains(-1).left == 1)
    }

    @Test("The near side is exactly 1, the far side only ever falls, left and right mirror, and nothing is above 1")
    func shape() {
        var last = 1.0
        for step in 0...20 {
            let b = Double(step * 5) / 100
            let right = BalanceLaw.gains(b), left = BalanceLaw.gains(-b)
            #expect(right.right == 1 && left.left == 1)
            #expect(right.left == left.right)
            #expect(right.left <= last && right.left >= 0 && right.left <= 1)
            last = right.left
        }
    }

    @Test("Out of range is clamped, and what isn't a number is the center")
    func clamping() {
        #expect(BalanceLaw.gains(1.5).left == 0)
        #expect(BalanceLaw.gains(-2).right == 0)
        for odd in [Double.nan, .infinity, -.infinity] {
            #expect(BalanceLaw.clamped(odd) == 0)
            #expect(BalanceLaw.gains(odd).left == 1 && BalanceLaw.gains(odd).right == 1)
        }
    }

    @Test("Whole points, and the detent at the center")
    func pointsAndDetent() {
        #expect(BalanceLaw.points(0.2) == 20 && BalanceLaw.points(-0.35) == -35 && BalanceLaw.points(3) == 100)
        #expect(BalanceLaw.snapped(0.03) == 0 && BalanceLaw.snapped(-0.02) == 0)
        #expect(BalanceLaw.snapped(0.05) == 0.05 && BalanceLaw.snapped(-0.5) == -0.5)
    }
}

@Suite("Balance: the Controls menu's steps")
struct BalanceControlsTests {
    @Test("Five points a press, stopping at the ends")
    func steps() {
        #expect(BalanceControls.apply(.right, to: 0) == 0.05)
        #expect(BalanceControls.apply(.left, to: 0) == -0.05)
        #expect(BalanceControls.apply(.right, to: 0.95) == 1)
        #expect(BalanceControls.apply(.right, to: 1) == 1)
        #expect(BalanceControls.apply(.left, to: -1) == -1)
        #expect(BalanceControls.apply(.right, to: .nan) == 0.05)
    }

    @Test("Center goes to exactly 0 from anywhere")
    func center() {
        #expect(BalanceControls.apply(.center, to: 0.65) == 0)
        #expect(BalanceControls.apply(.center, to: -1) == 0)
    }

    @Test("Twenty presses one way and twenty back end exactly on the center")
    func noDrift() {
        var b = 0.0
        for _ in 0..<20 { b = BalanceControls.apply(.right, to: b) }
        #expect(b == 1)
        for _ in 0..<20 { b = BalanceControls.apply(.left, to: b) }
        #expect(b == 0)
        for _ in 0..<7 { b = BalanceControls.apply(.left, to: b) }
        #expect(b == -0.35)
    }

    @Test("A value between steps (the slider's) moves to the next whole step")
    func offGrid() {
        #expect(BalanceControls.apply(.right, to: 0.12) == 0.15)
        #expect(BalanceControls.apply(.left, to: 0.12) == 0.05)
    }
}

@Suite("Balance: the render path")
struct BalanceRenderTests {
    private func render(_ ctx: OpaquePointer, _ frames: Int, channels: Int = 2) -> [Float] {
        var out = [Float](repeating: 7, count: frames * channels)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(frames), UInt32(channels)) }
        return out
    }

    /// 24-bit-like values over the whole range, interleaved.
    private func signal(_ frames: Int, channels: Int = 2) -> [Float] {
        (0..<frames * channels).map { Float(Int32(truncatingIfNeeded: $0 &* 2_654_435_761) >> 8) / 8_388_608 }
    }

    @Test("Centered, the output is a copy, bit for bit, with dither set")
    func centerIsACopy() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 24)
        nrt_context_set_balance(ctx, 1, 1, 480)
        let input = signal(2000)
        #expect(nrt_ring_write(ring, input, 2000) == 2000)
        #expect(render(ctx, 2000).map(\.bitPattern) == input.map(\.bitPattern))
    }

    @Test("Half way right: the left is down 3 dB, the right untouched")
    func halfRight() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 0)
        let sides = BalanceLaw.gains(0.5)
        nrt_context_set_balance(ctx, sides.left, sides.right, 480)
        #expect(nrt_ring_write(ring, [Float](repeating: 0.5, count: 2000), 1000) == 1000)
        let out = render(ctx, 1000)
        for f in 0..<1000 {
            #expect(abs(out[2 * f] - Float(0.5 * 0.707106781)) < 1e-6, "frame \(f)")
            #expect(out[2 * f + 1] == 0.5, "frame \(f)")
        }
    }

    @Test("All the way left: the right is exact silence, the left untouched")
    func fullLeft() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 0)
        let sides = BalanceLaw.gains(-1)
        nrt_context_set_balance(ctx, sides.left, sides.right, 480)
        let input = signal(1000)
        #expect(nrt_ring_write(ring, input, 1000) == 1000)
        let out = render(ctx, 1000)
        for f in 0..<1000 {
            #expect(out[2 * f].bitPattern == input[2 * f].bitPattern, "frame \(f)")
            #expect(out[2 * f + 1] == 0, "frame \(f)")
        }
    }

    @Test("Balance and the volume multiply")
    func withGain() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 0.5, 0)
        nrt_context_set_balance(ctx, BalanceLaw.gains(0.5).left, 1, 480)
        #expect(nrt_ring_write(ring, [Float](repeating: 0.5, count: 200), 100) == 100)
        let out = render(ctx, 100)
        #expect(abs(out[0] - Float(0.5 * 0.5 * 0.707106781)) < 1e-6)
        #expect(abs(out[1] - 0.25) < 1e-7)
    }

    @Test("One channel or six: balance is ignored and the output stays a copy", arguments: [1, 6])
    func notStereo(channels: Int) {
        let ring = nrt_ring_create(8192, UInt32(channels))!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 24)
        nrt_context_set_balance(ctx, 0, 1, 480)
        let input = signal(500, channels: channels)
        #expect(nrt_ring_write(ring, input, 500) == 500)
        #expect(render(ctx, 500, channels: channels).map(\.bitPattern) == input.map(\.bitPattern))
    }

    @Test("Integer words are never scaled")
    func integerMode() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_integer(ctx, true)
        nrt_context_set_balance(ctx, 0, 1, 480)
        // Int32 words carried in the ring's float slots.
        let input: [Float] = (0..<1000).map { Float(bitPattern: UInt32(truncatingIfNeeded: $0 &* 2_654_435_761) & 0x7F7F_FFFF) }
        #expect(nrt_ring_write(ring, input, 500) == 500)
        #expect(render(ctx, 500).map(\.bitPattern) == input.map(\.bitPattern))
    }

    @Test("A change is a ramp: not there on the first frame, never rising, never under the target, there within 20 ms")
    func ramp() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 0)
        #expect(nrt_ring_write(ring, [Float](repeating: 0.5, count: 2 * 2100), 2100) == 2100)
        #expect(render(ctx, 100).allSatisfy { $0 == 0.5 })          // centered: a copy
        nrt_context_set_balance(ctx, 0, 1, 480)                     // all the way right, 10 ms at 48 kHz
        let out = render(ctx, 2000)
        #expect(out[0] < 0.5 && out[0] > 0.49, "the first frame has only begun to move")
        var last: Float = 0.5
        for f in 0..<2000 {
            #expect(out[2 * f] <= last && out[2 * f] >= 0, "frame \(f)")
            #expect(out[2 * f + 1] == 0.5, "the near side never moves")
            last = out[2 * f]
        }
        #expect(out[2 * 400] > 0, "still on its way before 10 ms")
        for f in 960..<2000 { #expect(out[2 * f] == 0, "frame \(f)") }
    }

    @Test("Back at the center, the ramp ends and the output is a copy again, bit for bit")
    func backToCopy() {
        let ring = nrt_ring_create(8192, 2)!, ctx = nrt_context_create(ring, 4096)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_gain(ctx, 1, 24)
        nrt_context_set_balance(ctx, 1, 0.5, 480)
        let input = signal(3000)
        #expect(nrt_ring_write(ring, input, 3000) == 3000)
        let first = render(ctx, 500)
        #expect(first.map(\.bitPattern) != input[0..<1000].map(\.bitPattern))
        nrt_context_set_balance(ctx, 1, 1, 480)
        _ = render(ctx, 500)                                        // the ramp back (240 frames) is inside this slice
        #expect(render(ctx, 2000).map(\.bitPattern) == input[2000..<6000].map(\.bitPattern))
    }
}

@Suite("Balance: which streams take it")
struct BalanceSettingsTests {
    private func plan(channels: Int = 2, deviceChannels: Int = 2) -> OutputPlan {
        FormatPlanner.plan(source: SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: channels),
                           device: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: deviceChannels, supportsDoP: false))
    }

    @Test("Each output has its own; none stored, zero, or not a number is the center")
    func perOutput() {
        var s = EngineSettings()
        #expect(s.balance(for: output("DAC")) == nil)
        s.deviceBalances = ["DAC": 0.2, "HDMI": -0.5, "Zero": 0, "Odd": .nan, "Far": 7]
        #expect(s.balance(for: output("DAC")) == 0.2)
        #expect(s.balance(for: output("HDMI")) == -0.5)
        #expect(s.balance(for: output("Zero")) == nil)
        #expect(s.balance(for: output("Odd")) == nil)
        #expect(s.balance(for: output("Far")) == 1)
        #expect(s.balance(for: output("Other")) == nil)
        #expect(s.balance(for: nil) == nil)
    }

    @Test("Stereo PCM takes it")
    func stereoPCM() {
        var s = EngineSettings()
        s.deviceBalances = ["DAC": 0.2]
        #expect(s.balanceBypass(for: output("DAC"), plan: plan()) == nil)
        #expect(s.appliedBalance(for: output("DAC"), plan: plan()) == 0.2)
        #expect(s.appliedBalance(for: output("Other"), plan: plan()) == nil)
    }

    @Test("DoP and bitstream never do, and the stored value stays")
    func passthrough() {
        var s = EngineSettings()
        s.deviceBalances = ["DAC": 0.2]
        for mode in [OutputPlan.Mode.dop, .bitstream] {
            var p = plan()
            p.mode = mode
            #expect(s.balanceBypass(for: output("DAC"), plan: p) == .passthrough)
            #expect(s.appliedBalance(for: output("DAC"), plan: p) == nil)
        }
        #expect(s.balance(for: output("DAC")) == 0.2)
    }

    @Test("Spatial Audio, one channel, more than two, and speaker groups don't")
    func otherStreams() {
        var s = EngineSettings()
        s.deviceBalances = ["DAC": 0.2]
        var spatial = plan()
        spatial.spatial = .fixed
        #expect(s.balanceBypass(for: output("DAC"), plan: spatial) == .spatial)
        #expect(s.balanceBypass(for: output("DAC", channels: 6), plan: plan(channels: 6, deviceChannels: 6)) == .notStereo)
        #expect(s.balanceBypass(for: output("DAC"), plan: plan(channels: 1)) == .notStereo)
        let group = output(SpeakerGroup.outputUIDPrefix + "A")
        #expect(s.balanceBypass(for: group, plan: plan()) == .notStereo)
    }
}

@Suite("Balance: what the signal path says")
struct BalanceSignalPathTests {
    private func path(mode: OutputPlan.Mode = .pcm) -> SignalPath {
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2)
        let device = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
        return SignalPath(source: source, decoderName: "Test", plan: FormatPlanner.plan(source: source, device: device),
                          applied: AppliedFormat(sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 2, exclusive: true, bufferFrames: 512),
                          deviceName: "DAC", deviceUID: "DAC", deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "speaker"), volume: .fixed)
    }

    @Test("Centered, a bit-perfect path stays bit-perfect; off center it is digital gain; back at the center it is bit-perfect again")
    func offCenter() {
        var p = path()
        #expect(p.isBitPerfect && !p.modifiesSamples && p.statusLine == "BIT-PERFECT")
        p.balance = 0.2
        #expect(!p.isBitPerfect && p.modifiesSamples && p.statusLine == "DIGITAL GAIN")
        p.balance = 0
        #expect(p.isBitPerfect && !p.modifiesSamples)
    }

    @Test("A balance that is chosen but not applied changes nothing about the claim")
    func bypassed() {
        var p = path()
        p.bypassedBalance = .passthrough
        #expect(p.isBitPerfect && !p.modifiesSamples)
    }
}
