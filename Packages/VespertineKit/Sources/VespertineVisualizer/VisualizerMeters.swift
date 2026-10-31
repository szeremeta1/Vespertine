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
    public static let ppmAttack = 0.00276
    public static let ppmFallDBPerSecond = 24 / 2.8

    /// The VU needles, as a fraction of their travel (0 at rest, `zeroVU` at 0 VU).
    public private(set) var vu = SIMD2<Double>(0, 0)
    private var vuVelocity = SIMD2<Double>(0, 0)
    /// The PPM's rectifiers, as a linear peak level (1 is full scale).
    private var ppmLevel = SIMD2<Double>(0, 0)

    private var rate: Double = 0
    private var attack: Double = 0
    private var fall: Double = 1
    /// What a steady sine reads on the PPM against its true peak (the rectifier can't quite reach the top of each
    /// half cycle), measured once per rate so the sine reads its level exactly.
    private var ppmCalibration: Double = 1

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
                let x = i < count ? Double(abs(samples[i])) : 0
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
    }

    /// The PPM's reading in dB against the reference (0 is PPM 4; each mark is 4 dB), floor -40.
    public func ppm(referenceDBFS: Double) -> SIMD2<Double> {
        let peak = pow(10, referenceDBFS / 20) * 2.0.squareRoot() * ppmCalibration
        return SIMD2(Self.decibels(ppmLevel.x / peak), Self.decibels(ppmLevel.y / peak))
    }

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
