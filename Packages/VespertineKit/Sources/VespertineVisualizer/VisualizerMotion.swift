//
// Vespertine — motion the renderer works out on the CPU for the newer modes: the Smooth spectrum's springs and the
// Vinyl cover moving between the label and its sleeve.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A critically damped spring: it reaches its target as fast as it can without overshooting, from wherever it is and
/// however fast it's moving. Stepped exactly (not integrated), so it moves the same at 30, 60 or 120 frames a second.
struct CriticalSpring {
    var value: Double
    var velocity: Double = 0

    init(_ value: Double) { self.value = value }

    /// Moves toward `target` over `dt` seconds, with angular frequency `omega` (rad/s; about 3.9 / omega seconds to
    /// cover 90 % of the way).
    mutating func step(toward target: Double, omega: Double, dt: Double) {
        guard dt > 0, omega > 0, value.isFinite, velocity.isFinite, target.isFinite else {
            if !value.isFinite || !velocity.isFinite { value = target.isFinite ? target : 0; velocity = 0 }
            return
        }
        let e0 = value - target
        let decay = exp(-omega * dt)
        let k = velocity + omega * e0
        value = target + (e0 + k * dt) * decay
        velocity = (velocity - omega * k * dt) * decay
    }
}

/// The Smooth spectrum's bars. Each band is first blurred a little with its neighbours (1 4 6 4 1), so the bars move
/// together as a wave rather than one by one, then follows that as a critically damped spring: no snap and no
/// overshoot. Rising is quicker than falling, as with the classic bars, but both are softer. With Reduce Motion both
/// are slower still.
struct VisualizerSpectrumSmoother {
    /// Angular frequencies (rad/s): about 0.18 s to rise 90 % of the way, 0.39 s to fall.
    static let rise = 22.0, fall = 10.0
    /// How much slower everything moves with Reduce Motion.
    static let calmFactor = 0.5

    private(set) var values: [Float] = []
    private var springs: [CriticalSpring] = []
    private var blurred: [Double] = []

    /// The next frame's bars for the analyzer's `bands`, `dt` seconds after the last.
    mutating func step(_ bands: [Float], dt: Double, calm: Bool) -> [Float] {
        let n = bands.count
        guard n > 0 else { values = []; springs = []; return [] }
        Self.blur(bands, into: &blurred)
        if springs.count != n {
            // A new band count (or the first frame): start where the music is, still.
            springs = blurred.map { CriticalSpring($0) }
            values = blurred.map { Float($0) }
            return values
        }
        let slow = calm ? Self.calmFactor : 1
        let step = min(max(dt, 0), 0.25)
        if values.count != n { values = .init(repeating: 0, count: n) }
        for i in 0..<n {
            let target = blurred[i]
            let omega = (target > springs[i].value ? Self.rise : Self.fall) * slow
            springs[i].step(toward: target, omega: omega, dt: step)
            // Bars live in 0…1; at either end the spring stops rather than pressing on.
            if springs[i].value < 0 { springs[i].value = 0; springs[i].velocity = max(0, springs[i].velocity) }
            if springs[i].value > 1 { springs[i].value = 1; springs[i].velocity = min(0, springs[i].velocity) }
            values[i] = Float(springs[i].value)
        }
        return values
    }

    mutating func reset() {
        values = []
        springs = []
    }

    /// A 1 4 6 4 1 blur across the bands (the weights renormalized at the ends); anything not finite reads as 0.
    static func blur(_ bands: [Float], into out: inout [Double]) {
        let n = bands.count
        if out.count != n { out = .init(repeating: 0, count: n) }
        let weights: [Double] = [1, 4, 6, 4, 1]
        for i in 0..<n {
            var sum = 0.0, total = 0.0
            for k in -2...2 where i + k >= 0 && i + k < n {
                let v = Double(bands[i + k])
                sum += (v.isFinite ? min(max(v, 0), 1) : 0) * weights[k + 2]
                total += weights[k + 2]
            }
            out[i] = sum / total
        }
    }
}

/// The album cover between the record's label and its sleeve, as drawn this frame.
struct VisualizerCoverPose: Equatable, Sendable {
    /// How far the layout has moved to make room for the sleeve: 0 (label only) to 1.
    var layout: Double
    /// How much of the sleeve shows, 0…1.
    var opacity: Double
    /// The sleeve's offset to the left of where it rests, in the record's units (the record's radius is 0.86).
    var offset: Double
    /// In front of the record (1) or behind it (0); between the two only while it dissolves (Reduce Motion).
    var front: Double

    static let label = VisualizerCoverPose(layout: 0, opacity: 0, offset: VisualizerCoverMotion.away, front: 1)
}

/// Moves the cover between its three places. The sleeve slides in from the left and out again; going from in front
/// of the record to behind it (or back), it's pulled out to the left until it's clear of the record and platter,
/// changes sides there, and slides back, so it never passes through them. With Reduce Motion nothing slides: the
/// layout changes at once and the sleeve fades in, out, or from one side to the other.
struct VisualizerCoverMotion {
    /// Where the sleeve is drawn from when it slides in (and goes to when it slides out): off to the left.
    static let away = -1.2
    /// Pulled this far left, the sleeve is clear of the platter (its right edge left of -0.95).
    static let clear = -1.1
    /// How far it's pulled to change sides (a little past `clear`, so the spring gets there briskly).
    static let pull = -1.3
    static let omega = 16.0
    /// Reduce Motion's fades, per second.
    static let fadeRate = 1 / 0.3

    private(set) var pose = VisualizerCoverPose.label
    private var layout = CriticalSpring(0)
    private var opacity = CriticalSpring(0)
    private var offset = CriticalSpring(away)

    init(_ cover: VisualizerVinylCover = .label) { settle(at: cover) }

    /// Puts the cover straight in place, with no motion.
    mutating func settle(at cover: VisualizerVinylCover) {
        let sleeve = cover != .label
        layout = CriticalSpring(sleeve ? 1 : 0)
        opacity = CriticalSpring(sleeve ? 1 : 0)
        offset = CriticalSpring(sleeve ? 0 : Self.away)
        pose = VisualizerCoverPose(layout: layout.value, opacity: opacity.value, offset: offset.value,
                                   front: cover == .sleeveBehind ? 0 : 1)
    }

    /// Whether the sleeve, as it is now, could overlap the record or the platter.
    var overlapsRecord: Bool { pose.opacity > 0.001 && pose.offset > Self.clear }

    mutating func advance(toward cover: VisualizerVinylCover, dt: Double, calm: Bool) {
        let dt = min(max(dt, 0), 0.25)
        let sleeve = cover != .label
        let wantFront: Double = cover == .sleeveBehind ? 0 : 1
        var front = pose.front
        if calm {
            // Nothing slides: the layout changes at once and the sleeve fades in or out where it rests, or dissolves
            // from one side of the record to the other.
            let fade = Self.fadeRate * dt
            layout = CriticalSpring(sleeve ? 1 : 0)
            let o = sleeve ? min(1, opacity.value + fade) : max(0, opacity.value - fade)
            if sleeve {
                front = opacity.value <= 0.001 ? wantFront : front < wantFront ? min(wantFront, front + fade) : max(wantFront, front - fade)
            }
            opacity = CriticalSpring(o)
            offset = CriticalSpring(sleeve || o > 0 ? 0 : Self.away)
        } else {
            // A sleeve that's on the wrong side changes sides only where it can't be seen passing the record.
            if sleeve && front != wantFront && !overlapsRecord { front = wantFront }
            let switching = sleeve && front != wantFront
            layout.step(toward: sleeve ? 1 : 0, omega: Self.omega, dt: dt)
            opacity.step(toward: sleeve ? 1 : 0, omega: Self.omega * 1.4, dt: dt)
            offset.step(toward: switching ? Self.pull : sleeve ? 0 : Self.away, omega: Self.omega, dt: dt)
            layout.value = min(max(layout.value, 0), 1)
            opacity.value = min(max(opacity.value, 0), 1)
        }
        pose = VisualizerCoverPose(layout: layout.value, opacity: opacity.value, offset: offset.value, front: front)
        if !calm && sleeve && pose.front != wantFront && !overlapsRecord { pose.front = wantFront }
    }
}
