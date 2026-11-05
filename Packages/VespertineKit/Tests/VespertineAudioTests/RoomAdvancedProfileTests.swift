//
// Vespertine — room correction, Guided and Advanced: one strength control for the whole correction, a house target
// curve, limits and cutoffs that are held to what playback can run, hand-edited bands, per-speaker trim, and the
// measured positions the average is made from.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

private let rates = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000]

private func combinedPeak(_ p: RoomProfile) -> Double {
    let bandsPeak = p.filters.channels.values.map { bands in rates.map { EQPreset(name: "", bands: bands).peakDB(sampleRate: $0) }.max() ?? 0 }.max() ?? 0
    return bandsPeak + p.filters.preampDB
}

@Suite("Room correction strength")
struct RoomStrengthTests {
    @Test("Full strength plays the profile exactly as saved")
    func fullStrength() throws {
        let p = try ProfileFixtures.profile()
        #expect(p.effectiveStrength == 1 && p.atStrength == p)
        var q = p
        q.strength = 1
        #expect(q.atStrength.filters == p.filters)
    }

    @Test("Half strength halves every band's gain and keeps their frequencies and Q")
    func halfStrength() throws {
        var p = try ProfileFixtures.profile()
        p.strength = 0.5
        let scaled = p.atStrength
        for speaker in [RoomSpeaker.left, .right] {
            let before = try #require(p.filters.channels[speaker]), after = try #require(scaled.filters.channels[speaker])
            #expect(before.count == after.count && !before.isEmpty)
            for (b, a) in zip(before, after) {
                #expect(abs(a.gainDB - b.gainDB / 2) < 0.051)
                #expect(a.frequency == b.frequency && a.q == b.q && a.kind == b.kind)
            }
        }
        #expect(scaled.alignment == p.alignment, "delay and level trim are not part of strength")
    }

    @Test("Zero strength corrects nothing but keeps the speakers lined up")
    func zeroStrength() throws {
        var p = try ProfileFixtures.profile()
        p.strength = 0
        let scaled = p.atStrength
        #expect(scaled.filters.channels.values.allSatisfy { $0.allSatisfy { !$0.isActive } })
        #expect(scaled.filters.preampDB == 0)
        #expect(scaled.alignment(for: .left).delayMs == 0.4)
    }

    @Test("At any strength the corrected signal can't rise above 0 dB: the preamp is recomputed")
    func headroom() throws {
        // A profile with boosts, so scaling the preamp alone would be wrong.
        var p = try ProfileFixtures.profile()
        p.filters.channels[.left] = [EQBand(kind: .peak, frequency: 60, gainDB: 3, q: 1), EQBand(kind: .peak, frequency: 120, gainDB: -8, q: 3)]
        p.filters.preampDB = -3.5
        for s in stride(from: 0.0, through: 1.0, by: 0.1) {
            p.strength = s
            #expect(combinedPeak(p.atStrength) <= 0.001, "strength \(s)")
        }
        // Less correction never needs more headroom than the full one.
        p.strength = 0.3
        #expect(p.atStrength.filters.preampDB >= p.filters.preampDB)
    }

    @Test("Strength is held to 0…1, and a damaged value can't switch correction into something louder")
    func clampedStrength() throws {
        var p = try ProfileFixtures.profile()
        p.strength = 7
        #expect(p.effectiveStrength == 1)
        p.strength = -2
        #expect(p.effectiveStrength == 0)
        p.strength = .nan
        #expect(p.effectiveStrength == 1)
    }

    @Test("Playback uses the scaled filters; a profile of impulse responses ignores the control")
    func playbackUsesStrength() throws {
        var p = try ProfileFixtures.profile()
        p.strength = 0.5
        let playback = RoomCorrectionPlayback(profile: p)
        #expect(playback.channels[0].bands == p.atStrength.filters.channels[.left])
        #expect(playback.preampDB == p.atStrength.filters.preampDB)
        #expect(p.supportsStrength)
        p.impulses = [.left: RoomImpulse(file: "x", name: "x", sampleRate: 48_000, frames: 10)]
        #expect(!p.supportsStrength && p.atStrength == p)
    }
}

@Suite("Room target: house curve")
struct RoomHouseCurveTests {
    @Test("A house curve is read from REW-style text: frequency and level per line, comments and a header skipped")
    func parse() throws {
        let text = """
        * REW target
        Freq(Hz) SPL(dB)
        20 4.0
        100,2.0
        1000\t0
        10000; -3.5
        # trailing note
        """
        let curve = try RoomTargetCurve.house(text: text, name: "My house curve")
        #expect(curve.name == "My house curve" && curve.anchors.count == 4)
        #expect(curve.db(at: 1_000) == 0 && curve.db(at: 20) == 4 && curve.db(at: 10_000) == -3.5)
        // Straight in dB over log frequency between anchors; held flat beyond the ends.
        #expect(abs(curve.db(at: pow(10, 2.5)) - 1.0) < 1e-9)
        #expect(curve.db(at: 5) == 4 && curve.db(at: 20_000) == -3.5)
    }

    @Test("A house curve with too few points, a frequency out of order or a level that isn't sane is refused with the line")
    func refused() {
        #expect(throws: RoomTargetError.tooFewPoints) { _ = try RoomTargetCurve.house(text: "100 1", name: "x") }
        #expect(throws: RoomTargetError.notAscending(line: 2)) { _ = try RoomTargetCurve.house(text: "200 1\n100 2", name: "x") }
        #expect(throws: RoomTargetError.unreadable(line: 2)) { _ = try RoomTargetCurve.house(text: "100 1\nhello world", name: "x") }
        #expect(throws: RoomTargetError.outOfRange(line: 1)) { _ = try RoomTargetCurve.house(text: "100 60\n200 0", name: "x") }
        #expect(throws: RoomTargetError.outOfRange(line: 1)) { _ = try RoomTargetCurve.house(text: "1 0\n200 0", name: "x") }
        #expect(throws: RoomTargetError.tooFewPoints) { _ = try RoomTargetCurve.house(text: "", name: "x") }
    }

    @Test("A flat house curve designs the same filters as the Flat preset")
    func flatEquivalent() throws {
        let measured = try ProfileFixtures.curve { ProfileFixtures.mode(120, 12, 4)($0) }
        let house = try RoomTargetCurve.house(text: "20 0\n20000 0", name: "Mine")
        let a = try RoomFilterDesigner.design(measured, options: RoomFilterDesignOptions(target: .flat))
        let b = try RoomFilterDesigner.design(measured, options: RoomFilterDesignOptions(target: house))
        #expect(a.bands.map { [$0.frequency, $0.gainDB, $0.q] } == b.bands.map { [$0.frequency, $0.gainDB, $0.q] })
    }

    @Test("A house curve with a bass rise leaves more bass than the flat target does")
    func bassRise() throws {
        let measured = try ProfileFixtures.curve { _ in 0 }
        let house = try RoomTargetCurve.house(text: "20 6\n60 6\n200 0\n20000 0", name: "Rise")
        let design = try RoomFilterDesigner.design(measured, options: RoomFilterDesignOptions(target: house))
        // The room is flat, the target asks for 6 dB more at 50 Hz: the design may boost there, never above +3.
        let at50 = design.correctionDB(at: [50])[0]
        #expect(at50 > 1 && at50 <= 3.05)
    }

    @Test("The curve is stored with the profile's options and survives a save and reload")
    func codable() throws {
        let house = try RoomTargetCurve.house(text: "20 3\n1000 0\n20000 -4", name: "Mine")
        let options = RoomFilterDesignOptions(target: house)
        let back = try JSONDecoder().decode(RoomFilterDesignOptions.self, from: JSONEncoder().encode(options))
        #expect(back == options && back.target.anchors.count == 3)
    }
}

@Suite("Room design limits")
struct RoomDesignLimitsTests {
    @Test("Limits are clamped to what the filters and the real-time code can run")
    func clamped() {
        var o = RoomFilterDesignOptions(range: 1...90_000, maxBoostDB: 40, maxCutDB: 99, maxBands: 500, minQ: 0, maxCutQ: 1_000, maxBoostQ: -3)
        o = o.clamped
        #expect(o.range.lowerBound >= 10 && o.range.upperBound <= 20_000)
        #expect(o.maxBoostDB <= 12 && o.maxBoostDB >= 0 && o.maxCutDB <= 30 && o.maxCutDB >= 0)
        #expect(o.maxBands >= 1 && o.maxBands <= RoomCorrectionPlayback.maxBandsPerChannel)
        #expect(o.minQ >= EQBand.qRange.lowerBound && o.maxCutQ <= EQBand.qRange.upperBound && o.maxBoostQ >= o.minQ)
        #expect(o.maxCutQ >= o.minQ && o.maxBoostQ <= EQBand.qRange.upperBound)
    }

    @Test("A range whose ends are swapped or touching is put right instead of failing the design")
    func rangeOrder() {
        let swapped = RoomFilterDesignOptions(range: 500...500).clamped
        #expect(swapped.range.upperBound >= swapped.range.lowerBound * 1.1)
        #expect(RoomFilterDesignOptions.default.clamped == .default)
        #expect(RoomFilterDesignOptions(maxBoostDB: .nan, maxCutDB: .infinity).clamped.maxBoostDB.isFinite)
    }

    @Test("Cut and boost limits hold in the design")
    func limitsHold() throws {
        let mode = try ProfileFixtures.curve { ProfileFixtures.mode(100, 15, 4)($0) }
        var options = RoomFilterDesignOptions(target: .flat)
        options.maxCutDB = 6
        let design = try RoomFilterDesigner.design(mode, options: options.clamped)
        #expect(design.bands.allSatisfy { $0.gainDB >= -6.0001 })
        options.maxCutDB = 18
        options.maxBoostDB = 0
        let dip = try ProfileFixtures.curve { ProfileFixtures.mode(300, -5, 1.2)($0) }
        let noBoost = try RoomFilterDesigner.design(dip, options: options.clamped)
        #expect(noBoost.bands.allSatisfy { $0.gainDB <= 0 })
    }

    @Test("A low and a high cutoff keep the correction inside them")
    func cutoffs() throws {
        let measured = try ProfileFixtures.curve { f in ProfileFixtures.mode(60, 10, 4)(f) + ProfileFixtures.mode(1_500, 8, 3)(f) }
        let options = RoomFilterDesignOptions(target: .flat, range: 100...800).clamped
        let design = try RoomFilterDesigner.design(measured, options: options)
        #expect(design.bands.allSatisfy { $0.frequency >= 99.9 && $0.frequency <= 800.1 })
    }
}

@Suite("Room band editing")
struct RoomBandEditingTests {
    @Test("Edited bands replace the speaker's filters, the profile is marked as hand-edited and the preamp follows")
    func edit() throws {
        var p = try ProfileFixtures.profile()
        let bands = [EQBand(kind: .peak, frequency: 80, gainDB: 4, q: 1), EQBand(kind: .lowShelf, frequency: 120, gainDB: 2, q: 0.7)]
        try p.setBands(bands, for: .left)
        #expect(p.filters.channels[.left] == bands && p.filtersEdited == true)
        #expect(p.filters.preampDB < 0, "boosts need headroom")
        #expect(combinedPeak(p) <= 0.001)
        // Other speaker untouched.
        #expect(p.filters.channels[.right] == (try ProfileFixtures.profile()).filters.channels[.right])
    }

    @Test("Values outside what a band can be are clamped; non-numbers are refused; more than 24 bands are refused")
    func validation() throws {
        var p = try ProfileFixtures.profile()
        try p.setBands([EQBand(kind: .peak, frequency: 5, gainDB: 90, q: 0)], for: .left)
        let b = try #require(p.filters.channels[.left]?.first)
        #expect(b.frequency == EQBand.frequencyRange.lowerBound && b.gainDB == EQBand.gainRange.upperBound && b.q == EQBand.qRange.lowerBound)
        #expect(throws: RoomProfileError.invalidBand) { try p.setBands([EQBand(kind: .peak, frequency: .nan, gainDB: 0, q: 1)], for: .left) }
        #expect(throws: RoomProfileError.tooManyBands(RoomCorrectionPlayback.maxBandsPerChannel)) {
            try p.setBands((0..<25).map { EQBand(frequency: 50 + Double($0) * 10, gainDB: -1, q: 2) }, for: .left)
        }
        #expect(throws: RoomProfileError.speakerNotInProfile(.center)) { try p.setBands([], for: .center) }
        // A refused edit changes nothing.
        #expect(p.filters.channels[.left]?.count == 1)
    }

    @Test("Resetting to the design brings back the fitted filters and clears the edited mark")
    func reset() throws {
        let original = try ProfileFixtures.profile()
        var p = original
        try p.setBands([], for: .left)
        try p.setBands([], for: .right)
        let reset = try p.redesigned()
        #expect(reset.filtersEdited == nil && reset.filters.channels == original.filters.channels)
        #expect(throws: RoomProfileError.noMeasurement) {
            var imported = original
            imported.measured = nil
            _ = try imported.redesigned()
        }
    }

    @Test("Redesign with new options keeps the name, tags, strength and trims")
    func redesignKeeps() throws {
        var p = try ProfileFixtures.profile()
        p.tags = RoomProfileTags(speakers: "A", room: "B", position: "C")
        p.strength = 0.7
        var options = try #require(p.designOptions)
        options.maxCutDB = 6
        let next = try p.redesigned(options: options)
        #expect(next.name == p.name && next.id == p.id && next.tags == p.tags && next.strength == 0.7 && next.alignment == p.alignment)
        #expect(next.designOptions?.maxCutDB == 6)
        #expect(next.filters.channels.values.allSatisfy { $0.allSatisfy { $0.gainDB >= -6.0001 } })
    }

    @Test("Each speaker's trim: level and delay are held to what playback runs")
    func trim() throws {
        var p = try ProfileFixtures.profile()
        p.setAlignment(RoomSpeakerAlignment(delayMs: 90, levelDB: -80), for: .right)
        #expect(p.alignment(for: .right) == RoomSpeakerAlignment(delayMs: 40, levelDB: -30))
        p.setAlignment(RoomSpeakerAlignment(delayMs: .nan, levelDB: 3), for: .left)
        #expect(p.alignment(for: .left).delayMs == 0 && p.alignment(for: .left).levelDB == 3)
        #expect(p.alignment(for: .left) == p.alignment?[.left])
    }
}

@Suite("Room positions")
struct RoomPositionAveragingTests {
    @Test("Leaving a position out averages the others in power, per speaker")
    func exclude() throws {
        var p = try ProfileFixtures.profile()
        let a = try ProfileFixtures.curve { _ in 0 }, b = try ProfileFixtures.curve { _ in 6 }, c = try ProfileFixtures.curve { _ in -4 }
        p.positionCurves = [.left: [a, b, c], .right: [c, a, b]]
        try p.setExcludedPositions([1])
        #expect(p.excludedPositions == [1])
        let expected = try RoomCurve.powerAverage([a, c])
        let measured = try #require(p.measured?[.left])
        #expect(zip(measured.db, expected.db).allSatisfy { abs($0 - $1) < 1e-9 })
        let right = try #require(p.measured?[.right])
        #expect(zip(right.db, try RoomCurve.powerAverage([c, b]).db).allSatisfy { abs($0 - $1) < 1e-9 })
        // Bringing it back restores the full average.
        try p.setExcludedPositions([])
        #expect(p.excludedPositions == nil)
        let full = try RoomCurve.powerAverage([a, b, c])
        #expect(zip(try #require(p.measured?[.left]).db, full.db).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test("At least one position must stay, and a profile that kept no positions can't be re-averaged")
    func guards() throws {
        var p = try ProfileFixtures.profile()
        #expect(throws: RoomProfileError.noMeasurement) { try p.setExcludedPositions([0]) }
        let a = try ProfileFixtures.curve { _ in 0 }
        p.positionCurves = [.left: [a, a]]
        #expect(throws: RoomProfileError.noPositionsLeft) { try p.setExcludedPositions([0, 1]) }
        #expect(p.excludedPositions == nil, "a refused change leaves the profile as it was")
        // A position number that doesn't exist is ignored rather than excluding everything.
        try p.setExcludedPositions([7])
        #expect(p.excludedPositions == nil)
    }

    @Test("The positions a measurement was made at are kept with the profile, so they can be left out later")
    func keptFromMeasurement() throws {
        let p = try ProfileFixtures.profile()
        let a = try ProfileFixtures.curve { _ in 0 }, b = try ProfileFixtures.curve { _ in 2 }
        let kept = RoomProfile.positionCurves(from: [0: [.left: a], 1: [.left: b]])
        #expect(kept[.left] == [a, b])
        #expect(p.positionCount == 0)
    }
}
