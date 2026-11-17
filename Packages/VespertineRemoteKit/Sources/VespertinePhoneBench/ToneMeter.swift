//
// Vespertine: a meter for a test tone. Given the samples a player put out while it played a steady tone, it says how
// loud the tone was, where the tone stopped and for how long (a gap), and whether the join between two songs is any
// rougher than the rest of the recording (a click). It is what the phone bench reads its captures with, in place of a
// person listening for silence and clicks between songs.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// How a click is found: a steady sine obeys x[n] = 2·cos(w)·x[n-1] − x[n-2] whatever its level and phase, so what is
// left over when that is taken away (the residual) is nothing for a clean tone and jumps wherever the tone is broken: a
// step, a skipped or repeated stretch, a change of phase, an edge of silence. A lossy encoding leaves a residual of its
// own all the way through, so the join is held against the worst of the recording away from the join, not against zero.
//
// How a slip is found: the tone crosses zero on a fixed beat. The beat is taken from before the join and from after it;
// if the second song came in so much as a fraction of a sample early or late (a frame of the encoder's delay or padding
// left in, a buffer dropped), the beats don't line up, and by how much is the slip. It can't see a slip of a whole
// number of the tone's cycles, which is what the silence and the residual are for.
//

import Foundation

public enum ToneMeter {
    /// A stretch where the tone wasn't there.
    public struct Gap: Codable, Equatable, Sendable {
        /// Where it starts, in seconds from the first sample given.
        public var at: Double
        public var milliseconds: Double

        public init(at: Double, milliseconds: Double) {
            self.at = at
            self.milliseconds = milliseconds
        }
    }

    public struct Reading: Codable, Equatable, Sendable {
        /// Seconds of tone that were read (silence before and after it isn't counted).
        public var seconds: Double
        /// The tone's frequency, as found.
        public var toneHz: Double
        /// The tone's level: its RMS in dB relative to full scale, the gaps left out.
        public var level: Double
        /// Every stretch inside the recording where the tone stopped for half a millisecond or more.
        public var gaps: [Gap]
        /// The largest residual near the join, in dB relative to the tone; nil when no join was named.
        public var joinResidual: Double?
        /// The largest residual everywhere else, in dB relative to the tone.
        public var elsewhereResidual: Double
        /// The join is rougher than the rest of the recording by more than `clickMargin` (and by enough to matter).
        public var click: Bool
        /// How far the tone after the join is out of step with the tone before it, in samples (positive: late), within
        /// half a cycle either way; nil when no join was named or there is too little tone on one side of it.
        public var joinSlip: Double?
        /// The level after the join less the level before it, in dB; nil as `joinSlip`.
        public var levelStep: Double?
    }

    /// A sample under this fraction of the loudest one counts as silence.
    public static let silence: Float = 0.05
    /// The shortest silence called a gap, in seconds. A tone above about 40 Hz is never this long under `silence`.
    public static let shortestGap = 0.0005
    /// What is left out at each end of the tone, in seconds: where a recording starts and stops is not a join.
    public static let edge = 0.02
    /// How much rougher than the rest (dB) the join must be to be called a click.
    public static let clickMargin = 6.0
    /// A residual under this (dB relative to the tone) is never called a click, however clean the rest is.
    public static let clickFloor = -60.0

    /// Reads `samples` (one channel). `join`: the seconds, from the first sample, between which two songs met.
    /// nil when there is no tone to read: silence, or less than a tenth of a second of sound.
    public static func read(_ samples: [Float], rate: Double, join: ClosedRange<Double>? = nil) -> Reading? {
        guard rate > 0, samples.count > 8 else { return nil }
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        guard peak > 0.0001 else { return nil }
        let quiet = peak * silence
        var first = 0
        while first < samples.count, abs(samples[first]) <= quiet { first += 1 }
        var last = samples.count - 1
        while last > first, abs(samples[last]) <= quiet { last -= 1 }
        let margin = Int(edge * rate)
        first += margin
        last -= margin
        guard Double(last - first) >= 0.1 * rate else { return nil }

        // Gaps: runs of silence. Between them the tone passes through zero too, but never for this long.
        let shortest = max(2, Int(shortestGap * rate))
        var gaps: [Gap] = []
        var silent = [Bool](repeating: false, count: samples.count)
        var run = 0
        var index = first
        while index <= last + 1 {
            let isQuiet = index <= last && abs(samples[index]) <= quiet
            if isQuiet {
                run += 1
            } else {
                if run >= shortest {
                    let start = index - run
                    gaps.append(Gap(at: Double(start) / rate, milliseconds: Double(run) / rate * 1000))
                    for inside in start..<index { silent[inside] = true }
                }
                run = 0
            }
            index += 1
        }

        // The tone's level and frequency, from where it sounds.
        var power = 0.0, counted = 0
        var across = 0.0, along = 0.0
        index = first + 1
        while index < last {
            if !silent[index] {
                let here = Double(samples[index])
                power += here * here
                counted += 1
                if !silent[index - 1], !silent[index + 1] {
                    across += here * (Double(samples[index + 1]) + Double(samples[index - 1]))
                    along += here * here
                }
            }
            index += 1
        }
        guard counted > 0, along > 0, power > 0 else { return nil }
        let rms = (power / Double(counted)).squareRoot()
        let amplitude = rms * 2.0.squareRoot()
        let cosine = min(1, max(-1, across / (2 * along)))
        let toneHz = acos(cosine) * rate / (2 * Double.pi)

        // The residual, near the join and everywhere else.
        var nearJoin = 0.0, elsewhere = 0.0
        let joinFirst = join.map { Int($0.lowerBound * rate) } ?? Int.max
        let joinLast = join.map { Int($0.upperBound * rate) } ?? Int.min
        index = first + 2
        while index <= last {
            let left = abs(Double(samples[index]) - 2 * cosine * Double(samples[index - 1]) + Double(samples[index - 2]))
            if index >= joinFirst, index <= joinLast { nearJoin = max(nearJoin, left) } else { elsewhere = max(elsewhere, left) }
            index += 1
        }
        func relative(_ value: Double) -> Double { value > 0 ? max(-200, 20 * log10(value / amplitude)) : -200 }
        let joinResidual = join == nil ? nil : relative(nearJoin)
        let elsewhereResidual = relative(elsewhere)
        let click = joinResidual.map { $0 > clickFloor && $0 > elsewhereResidual + clickMargin } ?? false

        // The beat before the join and after it.
        var joinSlip: Double?, levelStep: Double?
        if join != nil, toneHz > 0 {
            let cycle = rate / toneHz
            let before = beat(samples, silent, from: first, to: min(last, joinFirst - 1), cycle: cycle)
            let after = beat(samples, silent, from: max(first, joinLast + 1), to: last, cycle: cycle)
            if let before, let after {
                // One straight line through each side's crossings, both with the same slope (the cycle, which so many
                // crossings give to the millionth): how far apart the two lines sit, less whole cycles, is the slip.
                func line(_ times: [Double], _ turns: [Double]) -> (time: Double, turn: Double, across: Double, along: Double) {
                    var time = 0.0, turn = 0.0
                    for index in times.indices {
                        time += times[index]
                        turn += turns[index]
                    }
                    time /= Double(times.count)
                    turn /= Double(times.count)
                    var across = 0.0, along = 0.0
                    for index in times.indices {
                        across += (turns[index] - turn) * (times[index] - time)
                        along += (turns[index] - turn) * (turns[index] - turn)
                    }
                    return (time, turn, across, along)
                }
                let early = line(before.times, before.turns), late = line(after.times, after.turns)
                let exact = (early.across + late.across) / (early.along + late.along)
                if exact > 0 {
                    var apart = ((late.time - exact * late.turn) - (early.time - exact * early.turn)) / exact
                    apart -= apart.rounded()
                    joinSlip = apart * exact
                }
                if before.power > 0, after.power > 0 { levelStep = 10 * log10(after.power / before.power) }
            }
        }
        return Reading(seconds: Double(last - first + 1) / rate, toneHz: toneHz, level: 20 * log10(rms), gaps: gaps,
                       joinResidual: joinResidual, elsewhereResidual: elsewhereResidual, click: click, joinSlip: joinSlip, levelStep: levelStep)
    }

    /// Where the tone crosses zero going up between two samples, to a fraction of a sample, and its mean power there.
    /// nil with fewer than five crossings.
    private static func beat(_ samples: [Float], _ silent: [Bool], from: Int, to: Int, cycle: Double) -> (times: [Double], turns: [Double], power: Double)? {
        guard to - from > 8 else { return nil }
        var times: [Double] = [], turns: [Double] = []
        var power = 0.0, counted = 0
        var index = from + 1
        while index <= to {
            let here = Double(samples[index]), behind = Double(samples[index - 1])
            if !silent[index] {
                power += here * here
                counted += 1
            }
            if behind < 0, here >= 0, !silent[index], !silent[index - 1] {
                let time = Double(index - 1) + behind / (behind - here)
                // Noise can cross twice where the tone crosses once.
                if let last = times.last, let turn = turns.last {
                    if time - last >= cycle / 2 {
                        // Counted by how far on it is, so a silence between two crossings doesn't lose the count.
                        turns.append(turn + max(1, ((time - last) / cycle).rounded()))
                        times.append(time)
                    }
                } else {
                    times.append(time)
                    turns.append(0)
                }
            }
            index += 1
        }
        guard times.count >= 5, counted > 0 else { return nil }
        return (times, turns, power / Double(counted))
    }
}
