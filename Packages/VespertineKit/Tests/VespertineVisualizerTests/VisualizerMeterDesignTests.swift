//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer meter designs")
struct VisualizerMeterDesignTests {
    static let rate = 48_000.0
    static let reference = -18.0

    /// A sine of `hz` whose RMS is `db` dBFS.
    static func tone(_ db: Double, frames: Int, hz: Double = 1000) -> [Float] {
        let peak = pow(10, db / 20) * 2.0.squareRoot()
        return (0..<frames).map { Float(peak * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// Runs `meters` over left and right in 1 ms blocks, calling `read` after each.
    static func run(_ meters: inout VisualizerMeters, _ left: [Float], _ right: [Float]? = nil, read: (VisualizerMeters) -> Void = { _ in }) {
        let right = right ?? left
        let block = Int(rate / 1000)
        var i = 0
        while i < left.count {
            let end = min(i + block, left.count)
            let l = Array(left[i..<end]), r = Array(right[i..<end])
            l.withUnsafeBufferPointer { lb in
                r.withUnsafeBufferPointer { rb in meters.process(left: lb, right: rb, sampleRate: rate, referenceDBFS: reference) }
            }
            read(meters)
            i = end
        }
    }

    static func silence(_ meters: inout VisualizerMeters, ms: Int, read: (VisualizerMeters) -> Void = { _ in }) {
        for _ in 0..<ms {
            meters.process(left: UnsafeBufferPointer(start: nil, count: 0), right: UnsafeBufferPointer(start: nil, count: 0),
                           silentFrames: Int(rate / 1000), sampleRate: rate, referenceDBFS: reference)
            read(meters)
        }
    }

    static func meters(_ extras: VisualizerMeters.Extras) -> VisualizerMeters {
        var m = VisualizerMeters()
        m.extras = extras
        return m
    }

    // MARK: Ballistics

    @Test("Type I (DIN, Nordic; IEC 60268-10): a steady tone at the reference reads 0 dB; a 5 kHz burst of 5 ms reads 2 dB under the steady tone, one of 10 ms 1 dB under")
    func typeIIntegration() {
        var steadyMeter = Self.meters(.typeI)
        var steady = -40.0
        Self.run(&steadyMeter, Self.tone(Self.reference, frames: Int(Self.rate))) { steady = $0.ppmTypeI(referenceDBFS: Self.reference).x }
        #expect(abs(steady) < 0.1, "steady 1 kHz read \(steady) dB")

        func burst(_ ms: Double) -> Double {
            var m = Self.meters(.typeI)
            var top = -40.0
            Self.run(&m, Self.tone(Self.reference, frames: Int(Self.rate * ms / 1000), hz: 5000)) { top = max(top, $0.ppmTypeI(referenceDBFS: Self.reference).x) }
            return top
        }
        var long = Self.meters(.typeI)
        var steady5k = -40.0
        Self.run(&long, Self.tone(Self.reference, frames: Int(Self.rate / 2), hz: 5000)) { steady5k = $0.ppmTypeI(referenceDBFS: Self.reference).x }
        let five = burst(5) - steady5k, ten = burst(10) - steady5k
        #expect(abs(five - -2) < 0.5, "5 ms burst read \(five) dB")
        #expect(abs(ten - -1) < 0.5, "10 ms burst read \(ten) dB")
        // Type I integrates faster than Type II: the same 5 ms burst reads higher on it.
        var typeII = VisualizerMeters()
        var top = -40.0
        Self.run(&typeII, Self.tone(Self.reference, frames: Int(Self.rate * 0.005), hz: 5000)) { top = max(top, $0.ppm(referenceDBFS: Self.reference).x) }
        #expect(burst(5) > top + 1)
    }

    @Test("Type I: falls 20 dB in 1.7 s (Type II: 24 dB in 2.8 s)")
    func typeIFall() {
        var m = Self.meters(.typeI)
        Self.run(&m, Self.tone(Self.reference + 5, frames: Int(Self.rate / 2)))
        let start = m.ppmTypeI(referenceDBFS: Self.reference).x
        var end = start
        Self.silence(&m, ms: 1700) { end = $0.ppmTypeI(referenceDBFS: Self.reference).x }
        #expect(abs(start - end - 20) < 0.5, "fell \(start - end) dB in 1.7 s")
    }

    @Test("M and S (BBC M6): a tone in both channels reads 0 on M and nothing on S; in one channel, -6 on both; out of phase, nothing on M and 0 on S")
    func midSide() {
        func read(_ l: [Float], _ r: [Float]) -> SIMD2<Double> {
            var m = Self.meters(.midSide)
            var out = SIMD2<Double>(-40, -40)
            Self.run(&m, l, r) { out = $0.ppmMidSide(referenceDBFS: Self.reference) }
            return out
        }
        let x = Self.tone(Self.reference, frames: Int(Self.rate))
        let silent = [Float](repeating: 0, count: x.count)
        let both = read(x, x), left = read(x, silent), opposite = read(x, x.map { -$0 })
        #expect(abs(both.x) < 0.1 && both.y <= -39.9, "both: \(both)")
        #expect(abs(left.x - -6.02) < 0.15 && abs(left.y - -6.02) < 0.15, "left only: \(left)")
        #expect(opposite.x <= -39.9 && abs(opposite.y) < 0.1, "out of phase: \(opposite)")
    }

    @Test("The cassette deck's +6 scale: the same VU needle (99 % in 300 ms, 1 to 1.5 % overshoot), 0 VU at half its travel")
    func wideVU() {
        var m = Self.meters(.wideVU)
        var trace: [Double] = []
        Self.run(&m, Self.tone(Self.reference, frames: Int(Self.rate * 1.5))) { trace.append($0.vuWide.x) }
        let steady = trace.suffix(300).reduce(0, +) / 300
        #expect(abs(20 * log10(steady / VisualizerMeters.wideZeroVU)) < 0.1, "0 VU read \(steady)")
        #expect(abs(VisualizerMeters.wideZeroVU - 0.5012) < 1e-3)
        let reached = trace.firstIndex { $0 >= 0.99 * steady }.map { Double($0 + 1) } ?? .infinity
        #expect(reached >= 270 && reached <= 330, "99 % after \(reached) ms")
        let overshoot = (trace.max() ?? 0) / steady - 1
        #expect(overshoot >= 0.008 && overshoot <= 0.016, "overshoot \(overshoot * 100) %")
    }

    @Test("The extras never change the standard needles: VU and Type IIa read exactly the same with or without them")
    func extrasLeaveTheStandardAlone() {
        var rng = SplitMix64(seed: 42)
        let l = (0..<Int(Self.rate)).map { _ in Float.random(in: -0.4...0.4, using: &rng) }
        let r = (0..<Int(Self.rate)).map { _ in Float.random(in: -0.2...0.2, using: &rng) }
        var plain = VisualizerMeters(), all = Self.meters([.typeI, .midSide, .wideVU])
        var a: [SIMD2<Double>] = [], b: [SIMD2<Double>] = []
        Self.run(&plain, l, r) { a.append($0.vu); a.append($0.ppm(referenceDBFS: Self.reference)) }
        Self.run(&all, l, r) { b.append($0.vu); b.append($0.ppm(referenceDBFS: Self.reference)) }
        #expect(a == b)
    }

    // MARK: Balance meter

    @Test("Balance: centred for equal channels, toward the louder side by its dB difference (±6 dB across), centred when both are quiet")
    func balance() {
        func settle(_ vu: SIMD2<Double>) -> Double {
            var needle = VisualizerBalanceNeedle()
            for _ in 0..<240 { needle.advance(vu: vu, dt: 1.0 / 120) }
            return needle.position
        }
        let zero = VisualizerMeters.zeroVU
        #expect(abs(settle(SIMD2(zero, zero))) < 1e-6)
        let right3 = settle(SIMD2(zero * pow(10, -3.0 / 20), zero))
        #expect(abs(right3 - 0.5) < 0.01, "right 3 dB louder read \(right3)")
        let left6 = settle(SIMD2(zero, zero * pow(10, -6.0 / 20)))
        #expect(abs(left6 - -1) < 0.01, "left 6 dB louder read \(left6)")
        // Past the scale it rests on its stop.
        #expect(settle(SIMD2(zero, zero * 0.01)) >= -1.12 - 1e-9)
        // Nothing to compare: under -26 VU on both sides it stays in the middle.
        let quiet = VisualizerMeters.vuTravel(decibels: -30)
        #expect(abs(settle(SIMD2(quiet, quiet * 0.5))) < 1e-6)
    }

    @Test("Balance: its own movement, with the VU's damping (it overshoots a step by 1 to 1.5 %)")
    func balanceBallistics() {
        var needle = VisualizerBalanceNeedle()
        let zero = VisualizerMeters.zeroVU
        var top = 0.0
        for _ in 0..<1200 {
            needle.advance(vu: SIMD2(zero * pow(10, -3.0 / 20), zero), dt: 1.0 / 1000)
            top = max(top, needle.position)
        }
        let overshoot = top / 0.5 - 1
        #expect(overshoot >= 0.008 && overshoot <= 0.016, "overshoot \(overshoot * 100) %")
    }

    // MARK: Scales

    @Test("BBC and EBU scales: marks 13.17° apart, the reference (PPM 4, TEST) upright, 4 dB a mark, resting below mark 1")
    func sifamScale() {
        #expect(abs(MeterPlan.sifamAngle(ppm: 0)) < 1e-12)
        for m in 1...7 {
            #expect(abs(MeterPlan.sifamAngle(ppm: Double(m - 4) * 4) - MeterPlan.sifamMarkAngle(Double(m))) < 1e-12)
        }
        #expect(abs(MeterPlan.sifamMarkAngle(7) - MeterPlan.sifamMarkAngle(1) - MeterPlan.deg(79)) < 1e-12)
        #expect(MeterPlan.sifamAngle(ppm: -24) == MeterPlan.sifamRest)
        #expect(MeterPlan.sifamAngle(ppm: 40) == MeterPlan.sifamStop)
    }

    @Test("Nordic scale: -36 to +12 dB evenly, 6 dB a mark, TEST (the reference) at +20°")
    func nordicScale() {
        #expect(abs(MeterPlan.nordicAngle(0) - MeterPlan.deg(20)) < 1e-12)
        #expect(abs(MeterPlan.nordicAngle(-36) - MeterPlan.deg(-40)) < 1e-12)
        #expect(abs(MeterPlan.nordicAngle(12) - MeterPlan.deg(40)) < 1e-12)
        #expect(abs((MeterPlan.nordicAngle(-6) - MeterPlan.nordicAngle(-12)) - MeterPlan.deg(10)) < 1e-12)
        #expect(MeterPlan.nordicAngle(-50) == MeterPlan.sifamRest)
    }

    @Test("DIN scale: -50 to +5 dB, rising all the way and opening out toward the top; the reference reads -9")
    func dinScale() {
        #expect(MeterPlan.dinFraction(-50) == 0 && MeterPlan.dinFraction(5) == 1)
        var last = -1.0, lastStep = 0.0
        for db in stride(from: -50.0, through: 5, by: 5) {
            let x = MeterPlan.dinFraction(db)
            #expect(x > last)
            if db > -45 { #expect(x - last >= lastStep * 0.95, "step at \(db)") }
            lastStep = x - last
            last = x
        }
        // The analyzer's reference is the alignment level, printed at -9 on the DIN scale (0 is the permitted maximum).
        let instrument = MeterPlan.make(.din, in: CGSize(width: 1280, height: 720)).instruments[0]
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.ppmTypeI = SIMD2(0, 0)
        let read = VisualizerRenderer.needles(design: .din, instrument: instrument, frame: frame, balance: 0).a
        #expect(abs(read - MeterPlan.dinFraction(-9)) < 1e-12)
    }

    @Test("VU designs: the needle reads 0 VU where the face prints it (71 % of the travel, 50 % on the +6 scale)")
    func vuDesignScales() {
        for design in [MeterDesign.broadcast, .console, .tape] {
            let zero = MeterPlan.vuAngle(design, travel: VisualizerMeters.zeroVU)
            #expect(abs(zero - (-MeterPlan.swing(design) + 2 * MeterPlan.swing(design) * 0.7079)) < 1e-3)
        }
        #expect(abs(MeterPlan.vuAngle(.cassette, travel: VisualizerMeters.wideZeroVU) - MeterPlan.deg(41) * (2 * 0.5012 - 1)) < 1e-3)
    }

    @Test("Needles: twin meters show A and B (red, green) and M and S (white, yellow); each single meter shows its own channel")
    func needles() {
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.ppm = SIMD2(-4, 4)
        frame.ppmMidSide = SIMD2(0, -8)
        let plan = MeterPlan.make(.bbcStereo, in: CGSize(width: 1280, height: 720))
        let ab = VisualizerRenderer.needles(design: .bbcStereo, instrument: plan.instruments[0], frame: frame, balance: 0)
        let ms = VisualizerRenderer.needles(design: .bbcStereo, instrument: plan.instruments[1], frame: frame, balance: 0)
        #expect(ab.a == MeterPlan.sifamAngle(ppm: -4) && ab.b == MeterPlan.sifamAngle(ppm: 4))
        #expect(ms.a == MeterPlan.sifamAngle(ppm: 0) && ms.b == MeterPlan.sifamAngle(ppm: -8))
        let bbc = MeterPlan.make(.bbc, in: CGSize(width: 1280, height: 720))
        #expect(VisualizerRenderer.needles(design: .bbc, instrument: bbc.instruments[1], frame: frame, balance: 0).a == MeterPlan.sifamAngle(ppm: 4))
        #expect(VisualizerRenderer.needles(design: .bbc, instrument: bbc.instruments[0], frame: frame, balance: 0).b == nil)
    }

    // MARK: Layout and settings

    @Test("Every design fits its window, wide or tall: instruments inside the window, faces never overlapping")
    func layouts() {
        for design in MeterDesign.allCases {
            for size in [CGSize(width: 1280, height: 720), CGSize(width: 480, height: 300), CGSize(width: 600, height: 1000), CGSize(width: 2560, height: 1080)] {
                let plan = MeterPlan.make(design, in: size)
                let bounds = CGRect(origin: .zero, size: size)
                #expect(!plan.instruments.isEmpty)
                for m in plan.instruments {
                    #expect(bounds.contains(m.window) && bounds.contains(m.housing), "\(design) at \(size)")
                    #expect(m.housing.contains(m.window.insetBy(dx: 0.5, dy: 0.5)), "\(design) at \(size)")
                }
                for (i, a) in plan.instruments.enumerated() {
                    for b in plan.instruments[(i + 1)...] { #expect(!a.window.intersects(b.window), "\(design) at \(size)") }
                }
                #expect(plan.instruments.filter { $0.kind == .balance }.count == (design.hasBalance ? 1 : 0))
            }
        }
    }

    @Test("Settings: Original by default, each mode keeps its own design, unknown or missing designs fall back to Original")
    func settings() throws {
        let d = VisualizerSettings()
        #expect(d.vuDesign == .original && d.ppmDesign == .original)
        var s = VisualizerSettings()
        s.style = .meters
        s.vuDesign = .tape
        s.ppmDesign = .bbcStereo
        let back = try JSONDecoder().decode(VisualizerSettings.self, from: JSONEncoder().encode(s))
        #expect(back.vuDesign == .tape && back.ppmDesign == .bbcStereo)
        let odd = try JSONDecoder().decode(VisualizerSettings.self, from: Data(#"{"style":"meters","vuDesign":"mcintosh","ppmDesign":7}"#.utf8))
        #expect(odd.vuDesign == .original && odd.ppmDesign == .original && odd.style == .meters)
        let old = try JSONDecoder().decode(VisualizerSettings.self, from: Data(#"{"style":"meters","meterKind":"ppm"}"#.utf8))
        #expect(old.vuDesign == .original && old.ppmDesign == .original && old.meterKind == .ppm)
    }

    @Test("Each design asks the analyzer only for the ballistics it draws; the originals ask for none")
    func extras() {
        var s = VisualizerSettings()
        s.style = .meters
        #expect(s.meterExtras.isEmpty)
        s.meterKind = .ppm
        s.ppmDesign = .din
        #expect(s.meterExtras == .typeI)
        s.ppmDesign = .nordic
        #expect(s.meterExtras == .typeI)
        s.ppmDesign = .bbcStereo
        #expect(s.meterExtras == .midSide)
        s.ppmDesign = .bbc
        #expect(s.meterExtras.isEmpty)
        s.meterKind = .vu
        s.vuDesign = .cassette
        #expect(s.meterExtras == .wideVU)
        s.style = .vinyl
        #expect(s.meterExtras.isEmpty)
        #expect(MeterDesign(VisualizerSettings()) == nil)
    }
}
