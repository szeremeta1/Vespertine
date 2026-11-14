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

/// What the Club style and the particles do with the beat, worked out on the CPU each frame and handed to the
/// shaders: a punch that jumps on every beat and springs back, the rings each beat sends out, the lasers' turning,
/// the tunnel's rush, and (for Waves) the ribbons' sizes and travel and how far the fans of beams are open.
/// Everything is stepped with the frame's own time, so it moves the same at 60 and 120 frames a second.
struct VisualizerClubMotion {
    /// 0 at rest. A beat throws it up (to about its strength, within a twentieth of a second) and it springs back
    /// with one small bounce: the core, the room's zoom and the particles' burst ride it. Always 0 with Reduce Motion.
    private(set) var punch: Double = 0
    private var punchVelocity: Double = 0
    /// The lasers' angle (radians, wrapped).
    private(set) var laserAngle: Double = 0
    /// The tunnel's rings: how far they've run, in rings (wrapped to 0…1).
    private(set) var tunnel: Double = 0
    /// Which colours the lasers and rings take, 0…1 round the theme's brighter half: it steps on every beat.
    private(set) var colourTurn: Double = 0
    /// Beats so far (which way the lasers turn, how open the fans are).
    private(set) var beats = 0
    /// The rings: radius, strength, width, colour (as `VisualizerUniforms.rings`).
    private(set) var rings: [SIMD4<Float>] = []
    /// Waves: how far the fans of beams are open against their rest (1), swinging open and shut with the beats.
    private(set) var fanOpening = CriticalSpring(1)
    /// Waves: the three ribbons (lows, mids, highs): how large each is, 0…1, and how far each has travelled (radians).
    private(set) var ribbonSize = SIMD3<Double>(0, 0, 0)
    private(set) var ribbonPhase = SIMD3<Double>(0, 0, 0)
    /// Waves: the beams' ripples and their sway (seconds of each one's own clock).
    private(set) var ripple: Double = 0
    private(set) var sway: Double = 0

    static let punchFrequency = 26.0   // rad/s
    static let punchDamping = 0.42
    static let maximumRings = 16

    struct Input {
        var bass: Double = 0, mid: Double = 0, treble: Double = 0
        /// Sudden sounds in the lows, mids and highs (`VisualizerFrame.transients`).
        var transients = SIMD3<Double>(0, 0, 0)
        /// Beats that began since the last step, and how hard the newest was (0…1).
        var beats = 0
        var strength: Double = 0
        /// Whether anything is playing, 0…1 (eased).
        var signal: Double = 0
    }

    mutating func step(_ input: Input, dt: Double, calm: Bool) {
        let dt = min(max(dt, 0), 0.25)
        let beat = input.beats > 0
        let strength = min(max(input.strength, 0), 1)

        // The punch: a damped spring, kicked by the beat. Stepped in slices of at most 4 ms, so a slow frame doesn't
        // change how it rings.
        if calm {
            punch = 0; punchVelocity = 0
        } else {
            if beat { punchVelocity += Self.punchFrequency * 1.55 * (0.35 + 0.65 * strength) }
            var left = dt
            while left > 1e-9 {
                let h = min(left, 0.004)
                let w = Self.punchFrequency
                punchVelocity += (-w * w * punch - 2 * Self.punchDamping * w * punchVelocity) * h
                punch += punchVelocity * h
                left -= h
            }
            punch = min(max(punch, -0.5), 1.5)
            if abs(punch) < 1e-4 && abs(punchVelocity) < 1e-3 { punch = 0; punchVelocity = 0 }
        }

        // Rings: out from the middle on every beat, faster and brighter the harder it was.
        for i in rings.indices {
            rings[i].x += Float(dt) * (0.75 + 0.6 * rings[i].y)
            rings[i].y *= Float(exp(-dt / 0.8))
        }
        rings.removeAll { $0.y < 0.01 || $0.x > 2.6 }
        if beat {
            beats += 1
            colourTurn = (colourTurn + 0.17).truncatingRemainder(dividingBy: 1)
            rings.insert(SIMD4(Float(0.12 + 0.06 * input.bass), Float(0.3 + 0.7 * strength), Float(0.012 + 0.02 * strength),
                               Float(0.5 + 0.5 * colourTurn)), at: 0)
            if rings.count > Self.maximumRings { rings.removeLast() }
        }

        // Lasers: turning with the mids, thrown on by each beat, the other way every eight beats.
        let direction: Double = (beats / 8) % 2 == 0 ? 1 : -1
        let spin = calm ? 0.08 : 0.16 + 0.7 * input.mid
        laserAngle = (laserAngle + direction * (dt * spin + (beat && !calm ? 0.10 + 0.22 * strength : 0)))
            .truncatingRemainder(dividingBy: 2 * .pi)

        // The tunnel: rings a second, more with the mids, and a surge after each beat (the punch).
        tunnel = (tunnel + dt * (calm ? 0.12 : 0.22 + 0.5 * input.mid * input.signal + 0.9 * max(0, punch)))
            .truncatingRemainder(dividingBy: 1)

        // Waves. The fans of beams swing open on one beat and shut on the next; the ripples run faster with the mids
        // and surge with the punch; the sway drifts on its own clock.
        let slow = calm ? 0.35 : 1.0
        fanOpening.step(toward: calm ? 1 : (beats % 2 == 0 ? 0.72 : 1.3), omega: 9, dt: dt)
        ripple += dt * (1.2 + 2.6 * input.mid * input.signal + 5 * max(0, punch)) * slow
        sway += dt * (0.35 + 0.5 * input.mid * input.signal) * slow
        // Each ribbon is as large as its part of the music is loud, and jumps with that part's hits; it travels
        // faster the louder that part is. The lows' ribbon is pushed on by each beat.
        let levels = SIMD3(input.bass, input.mid, input.treble) * input.signal
        let speeds = SIMD3(1.1, 2.3, 4.2)
        for b in 0..<3 {
            let target = min(1, max(0.55 * levels[b] + 0.25 * max(0, punch), calm ? 0 : input.transients[b] * input.signal))
            let rate = target > ribbonSize[b] ? 0.03 : 0.22
            ribbonSize[b] += (target - ribbonSize[b]) * (1 - exp(-dt / rate))
            ribbonPhase[b] += dt * speeds[b] * (0.5 + 1.6 * levels[b]) * slow
        }
        if beat && !calm { ribbonPhase.x += 0.5 * strength }
    }

    /// The shader's periods for the clocks it takes wrapped: every use of each repeats within it.
    static let ripplePeriod = 4 * Double.pi
    static let swayPeriod = 2 * Double.pi * 30 / 0.35
    static let ribbonPeriod = 2 * Double.pi * 10
}
