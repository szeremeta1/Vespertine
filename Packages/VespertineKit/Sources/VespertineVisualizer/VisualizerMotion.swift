//
// Vespertine: motion the renderer works out on the CPU for the newer modes: the Smooth spectrum's springs and the
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
    /// How far the sleeve is slid to the right of where it rests (left is negative), in the record's units (the
    /// record's radius is 0.86).
    var offset: Double
    /// In front of the record (1) or behind it (0); always one or the other.
    var front: Double
    /// Where it rests: 0 in front (upright, level with the record), 1 behind (further left, turned 4°); between the
    /// two only on its way from one to the other (see `VisualizerLayout.sleeveRest`).
    var place: Double

    static let label = VisualizerCoverPose(layout: 0, opacity: 0, offset: VisualizerCoverMotion.away, front: 1, place: 0)

    /// How far right the sleeve reaches (its corners), in the record's units.
    var rightEdge: Double {
        let rest = VisualizerLayout.sleeveRest(place: CGFloat(place))
        return Double(rest.x + VisualizerLayout.sleeveReach(tilt: rest.tilt)) + offset
    }
}

/// Moves the cover between its three places. The sleeve slides in from the left and out again; going from in front
/// of the record to behind it (or back), it's pulled out to the left until it's clear of the record and platter,
/// changes sides there, and slides back into its other place, turning as it goes, so it never passes through them.
/// With Reduce Motion nothing slides or turns: the sleeve fades out where it is, everything moves at once, and it
/// fades in where it goes.
struct VisualizerCoverMotion {
    /// Where the sleeve is drawn from when it slides in (and goes to when it slides out): this far left of its rest.
    static let away = -1.2
    /// With its right edge left of this, the sleeve is clear of the platter (radius 0.95), so it can change sides.
    static let clearEdge = -0.97
    /// How far it's pulled to change sides: its right edge to here (a little past `clearEdge`, so the spring gets
    /// there briskly).
    static let pullEdge = -1.3
    static let omega = 16.0
    /// Reduce Motion's fades, per second.
    static let fadeRate = 1 / 0.3

    private(set) var pose = VisualizerCoverPose.label
    private var layout = CriticalSpring(0)
    private var opacity = CriticalSpring(0)
    private var offset = CriticalSpring(away)
    private var place = CriticalSpring(0)

    init(_ cover: VisualizerVinylCover = .label) { settle(at: cover) }

    private static func place(of cover: VisualizerVinylCover) -> Double { cover == .sleeveBehind ? 1 : 0 }
    private static func front(of cover: VisualizerVinylCover) -> Double { cover == .sleeveBehind ? 0 : 1 }

    /// Puts the cover straight in place, with no motion.
    mutating func settle(at cover: VisualizerVinylCover) {
        let sleeve = cover != .label
        layout = CriticalSpring(sleeve ? 1 : 0)
        opacity = CriticalSpring(sleeve ? 1 : 0)
        offset = CriticalSpring(sleeve ? 0 : Self.away)
        place = CriticalSpring(Self.place(of: cover))
        pose = VisualizerCoverPose(layout: layout.value, opacity: opacity.value, offset: offset.value,
                                   front: Self.front(of: cover), place: place.value)
    }

    /// Whether the sleeve, as it is now, could overlap the record or the platter.
    var overlapsRecord: Bool { pose.opacity > 0.001 && pose.rightEdge > Self.clearEdge }

    mutating func advance(toward cover: VisualizerVinylCover, dt: Double, calm: Bool) {
        let dt = min(max(dt, 0), 0.25)
        let sleeve = cover != .label
        let wantFront = Self.front(of: cover), wantPlace = Self.place(of: cover)
        var front = pose.front
        // Out of sight, it's wherever it's going next.
        if opacity.value <= 0.001 {
            front = wantFront
            if sleeve { place = CriticalSpring(wantPlace) }
        }
        if calm {
            // Nothing slides or turns: it fades out where it is, and once it's gone everything moves at once (the
            // turntable too) and it fades in where it's going.
            let fade = Self.fadeRate * dt
            let there = sleeve && front == wantFront && abs(place.value - wantPlace) < 1e-9
            if there || opacity.value <= 0.001 {
                layout = CriticalSpring(sleeve ? 1 : 0)
                opacity = CriticalSpring(sleeve ? min(1, opacity.value + fade) : 0)
            } else {
                opacity = CriticalSpring(max(0, opacity.value - fade))
            }
            offset = CriticalSpring(sleeve || opacity.value > 0 ? 0 : Self.away)
        } else {
            // A sleeve that's on the wrong side changes sides only where it can't be seen passing the record.
            if sleeve && front != wantFront && !overlapsRecord { front = wantFront }
            let switching = sleeve && front != wantFront
            layout.step(toward: sleeve ? 1 : 0, omega: Self.omega, dt: dt)
            opacity.step(toward: sleeve ? 1 : 0, omega: Self.omega * 1.4, dt: dt)
            // Pulled out, it keeps its turn; back in, it turns to its new place as it slides there.
            if sleeve && !switching { place.step(toward: wantPlace, omega: Self.omega, dt: dt) }
            place.value = min(max(place.value, 0), 1)
            let pull = Self.pullEdge - VisualizerCoverPose(layout: 0, opacity: 0, offset: 0, front: front, place: place.value).rightEdge
            offset.step(toward: switching ? pull : sleeve ? 0 : Self.away, omega: Self.omega, dt: dt)
            layout.value = min(max(layout.value, 0), 1)
            opacity.value = min(max(opacity.value, 0), 1)
        }
        pose = VisualizerCoverPose(layout: layout.value, opacity: opacity.value, offset: offset.value, front: front,
                                   place: place.value)
        if !calm && sleeve && pose.front != wantFront && !overlapsRecord { pose.front = wantFront }
    }
}
