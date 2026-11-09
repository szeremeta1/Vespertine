//
// Vespertine — the analogue meters' ballistics: a VU needle (IEC 60268-17) and a BBC peak programme meter
// (IEC 60268-10 Type IIa), sample by sample.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Two channels of VU and PPM, fed with each new block of samples.
///
/// - VU: the needle is a damped mass on a spring driven by the full-wave rectified signal. Damping 0.81 and a natural
///   frequency of 13.4 rad/s give the standard's ballistics: 99 % of a step in 300 ms, 1.3 % overshoot. Its scale is
///   linear in voltage, as on the real meter: 0 VU is 71 % of the way across and +3 VU the end.
/// - PPM: a rectifier that charges quickly (a 10 ms burst reads 2 dB under a steady tone, as the standard asks) and
///   falls 24 dB in 2.8 s.
///
/// Both read a sine at the reference level as 0 VU and PPM 4.
public struct VisualizerMeters: Sendable, Equatable {
    public static let vuDamping = 0.81
    public static let vuNaturalFrequency = 13.42
    /// A sine's average rectified level over its RMS (2√2/π).
    static let averageOverRMS = 2 * 2.0.squareRoot() / .pi
    /// Where 0 VU sits on the needle's travel (+3 VU is the end).
    public static let zeroVU = 1 / pow(10, 3.0 / 20)
    /// The needle's stops: resting on the left pin, pegged on the right one.
    public static let vuTravel = 0.0...1.08
    /// The PPM mark where the peak light starts (6, the BBC's highest permitted peak; the face prints no red).
    public static let ppmRedMark = 6.0
    public static let ppmAttack = 0.00276
    public static let ppmFallDBPerSecond = 24 / 2.8
    /// Type I (DIN, Nordic): a 5 ms burst reads 2 dB under a steady tone, and it falls 20 dB in 1.7 s.
    public static let typeIAttack = 0.001276
    public static let typeIFallDBPerSecond = 20 / 1.7
    /// The top of the cassette deck's scale, in VU (0 VU sits at half the travel).
    public static let wideTop = 6.0
    public static let wideZeroVU = 1 / pow(10, wideTop / 20)

    /// Ballistics run besides the VU and Type IIa pair, for the designs that need them. Off by default: each costs a
    /// little for every sample.
    public struct Extras: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// A pair of Type I PPMs (DIN, Nordic).
        public static let typeI = Extras(rawValue: 1)
        /// Type IIa PPMs on the sum and difference, M = (A + B) / 2 and S = (A − B) / 2: the BBC's M6 alignment, where M
        /// reads 6 dB under A + B.
        public static let midSide = Extras(rawValue: 2)
        /// A pair of VU needles on a scale that runs to +6 VU (the same movement, with 0 VU at half its travel).
        public static let wideVU = Extras(rawValue: 4)
    }
    public var extras: Extras = []

    /// The VU needles, as a fraction of their travel (0 at rest, `zeroVU` at 0 VU).
    public private(set) var vu = SIMD2<Double>(0, 0)
    private var vuVelocity = SIMD2<Double>(0, 0)
    /// The PPM's rectifiers, as a linear peak level (1 is full scale).
    private var ppmLevel = SIMD2<Double>(0, 0)
    /// The extras: VU needles on the +6 scale, Type I rectifiers, and Type IIa rectifiers on M and S.
    public private(set) var vuWide = SIMD2<Double>(0, 0)
    private var vuWideVelocity = SIMD2<Double>(0, 0)
    private var typeILevel = SIMD2<Double>(0, 0)
    private var midSideLevel = SIMD2<Double>(0, 0)

    private var rate: Double = 0
    private var attack: Double = 0
    private var fall: Double = 1
    /// What a steady sine reads on the PPM against its true peak (the rectifier can't quite reach the top of each
    /// half cycle), measured once per rate so the sine reads its level exactly.
    private var ppmCalibration: Double = 1
    private var typeIAttackStep: Double = 0
    private var typeIFall: Double = 1
    private var typeICalibration: Double = 1

    public init() {}

    private mutating func prepare(rate r: Double) {
        guard r != rate else { return }
        rate = r
        attack = 1 - exp(-1 / (r * Self.ppmAttack))
        fall = pow(10, -Self.ppmFallDBPerSecond / 20 / r)
        // A 1 kHz sine at full scale for 0.3 s.
        var level = 0.0
        for n in 0..<Int(r * 0.3) {
            let v = abs(sin(2 * .pi * 1000 * Double(n) / r))
            level = v > level ? level + (v - level) * attack : level * fall
        }
        ppmCalibration = level > 0.5 ? level : 1
        typeIAttackStep = 1 - exp(-1 / (r * Self.typeIAttack))
        typeIFall = pow(10, -Self.typeIFallDBPerSecond / 20 / r)
        level = 0
        for n in 0..<Int(r * 0.3) {
            let v = abs(sin(2 * .pi * 1000 * Double(n) / r))
            level = v > level ? level + (v - level) * typeIAttackStep : level * typeIFall
        }
        typeICalibration = level > 0.5 ? level : 1
    }

    /// Runs the meters over new samples (pass empty buffers with `silentFrames` to let them fall while nothing plays).
    /// `referenceDBFS` is the RMS of the sine that reads 0 VU and PPM 4.
    public mutating func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>, silentFrames: Int = 0,
                                 sampleRate: Double, referenceDBFS: Double) {
        prepare(rate: sampleRate > 0 ? sampleRate : 48_000)
        let reference = pow(10, referenceDBFS / 20)
        // Rectified sample to needle drive: a sine at the reference averages to 0 VU.
        let drive = Self.zeroVU / (reference * Self.averageOverRMS)
        let dt = 1 / rate, w = Self.vuNaturalFrequency, z = Self.vuDamping
        let stiffness = w * w * dt, damping = 2 * z * w * dt
        let low = Self.vuTravel.lowerBound, high = Self.vuTravel.upperBound
        let count = min(left.count, right.count)
        // Each channel on its own, in plain scalars (this runs for every sample).
        for c in 0..<2 {
            let samples = c == 0 ? left : right
            var position = vu[c], speed = vuVelocity[c], level = ppmLevel[c]
            for i in 0..<(count + max(0, silentFrames)) {
                let x = i < count ? Self.rectified(samples[i]) : 0
                // Semi-implicit Euler: the needle's acceleration, then its speed, then where it is.
                speed += stiffness * (x * drive - position) - damping * speed
                position += speed * dt
                if position < low { position = low; speed = max(0, speed) }
                if position > high { position = high; speed = -0.2 * abs(speed) }
                level = x > level ? level + (x - level) * attack : level * fall
            }
            vu[c] = position
            vuVelocity[c] = speed
            ppmLevel[c] = level
        }
        guard !extras.isEmpty else { return }
        let frames = count + max(0, silentFrames)
        if extras.contains(.wideVU) {
            // The same needle as above, driven so 0 VU lands at half the travel.
            let wideDrive = Self.wideZeroVU / (reference * Self.averageOverRMS)
            for c in 0..<2 {
                let samples = c == 0 ? left : right
                var position = vuWide[c], speed = vuWideVelocity[c]
                for i in 0..<frames {
                    let x = i < count ? Self.rectified(samples[i]) : 0
                    speed += stiffness * (x * wideDrive - position) - damping * speed
                    position += speed * dt
                    if position < low { position = low; speed = max(0, speed) }
                    if position > high { position = high; speed = -0.2 * abs(speed) }
                }
                vuWide[c] = position
                vuWideVelocity[c] = speed
            }
        }
        if extras.contains(.typeI) {
            for c in 0..<2 {
                let samples = c == 0 ? left : right
                var level = typeILevel[c]
                for i in 0..<frames {
                    let x = i < count ? Self.rectified(samples[i]) : 0
                    level = x > level ? level + (x - level) * typeIAttackStep : level * typeIFall
                }
                typeILevel[c] = level
            }
        }
        if extras.contains(.midSide) {
            var m = midSideLevel.x, s = midSideLevel.y
            for i in 0..<frames {
                let a = i < count ? Self.finite(left[i]) : 0, b = i < count ? Self.finite(right[i]) : 0
                let xm = abs(a + b) * 0.5, xs = abs(a - b) * 0.5
                m = xm > m ? m + (xm - m) * attack : m * fall
                s = xs > s ? s + (xs - s) * attack : s * fall
            }
            midSideLevel = SIMD2(m, s)
        }
    }

    /// The PPM's reading in dB against the reference (0 is PPM 4; each mark is 4 dB), floor -40.
    public func ppm(referenceDBFS: Double) -> SIMD2<Double> {
        let peak = pow(10, referenceDBFS / 20) * 2.0.squareRoot() * ppmCalibration
        return SIMD2(Self.decibels(ppmLevel.x / peak), Self.decibels(ppmLevel.y / peak))
    }

    /// The Type I PPMs' reading in dB against the reference (a sine at the reference reads 0), floor -40.
    public func ppmTypeI(referenceDBFS: Double) -> SIMD2<Double> {
        let peak = pow(10, referenceDBFS / 20) * 2.0.squareRoot() * typeICalibration
        return SIMD2(Self.decibels(typeILevel.x / peak), Self.decibels(typeILevel.y / peak))
    }

    /// The M and S PPMs' readings (Type IIa, M6) in dB against the reference, floor -40: the same tone in both channels
    /// reads 0 on M and nothing on S; a tone in one channel reads -6 on both.
    public func ppmMidSide(referenceDBFS: Double) -> SIMD2<Double> {
        let peak = pow(10, referenceDBFS / 20) * 2.0.squareRoot() * ppmCalibration
        return SIMD2(Self.decibels(midSideLevel.x / peak), Self.decibels(midSideLevel.y / peak))
    }

    /// A sample's magnitude; a NaN or infinite one (a corrupt float file) counts as silence, because one of them in the
    /// needle's spring would leave it NaN for good.
    @inline(__always) static func rectified(_ sample: Float) -> Double { sample.isFinite ? Double(abs(sample)) : 0 }
    @inline(__always) static func finite(_ sample: Float) -> Double { sample.isFinite ? Double(sample) : 0 }

    static func decibels(_ x: Double) -> Double { x > 1e-5 ? max(-40, 20 * log10(x)) : -40 }

    /// A VU level in dB to the needle's travel, as the scale is printed (linear in voltage).
    public static func vuTravel(decibels db: Double) -> Double { zeroVU * pow(10, db / 20) }

    /// A PPM reading (dB against the reference) to the needle's travel on the BBC scale: marks 1 to 7 evenly spaced,
    /// 4 dB apart (PPM 4 is the reference), rest below mark 1.
    public static func ppmTravel(decibels db: Double) -> Double {
        let mark = 4 + db / 4
        if mark >= 1 { return min(vuTravel.upperBound, ppmMark(mark)) }
        // Below mark 1 the needle falls to its rest over another 12 dB.
        return ppmMark(1) * max(0, 1 + (db + 12) / 12)
    }

    /// Where mark `m` (1…7) is printed.
    public static func ppmMark(_ m: Double) -> Double { 0.1 + (m - 1) * 0.15 }
}
