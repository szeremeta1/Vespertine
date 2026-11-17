//
// Vespertine: the bench's tone meter says what is true of tones made here: a whole tone has no gap and no click, a
// silence is measured to the tenth of a millisecond, a skipped stretch is a click, and a noisy tone isn't one.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertinePhoneBench

private let rate = 48_000.0

/// `seconds` of a tone at half scale, starting at `phase` frames into it.
private func tone(_ seconds: Double, hz: Double = 1_000, scale: Double = 0.5, from phase: Int = 0) -> [Float] {
    var out: [Float] = []
    let frames = Int(seconds * rate)
    out.reserveCapacity(frames)
    var frame = 0
    while frame < frames {
        out.append(Float(scale * sin(2 * Double.pi * hz * Double(phase + frame) / rate)))
        frame += 1
    }
    return out
}

/// The same numbers every run.
private func noise(_ count: Int, scale: Float) -> [Float] {
    var state: UInt32 = 12_345
    var out: [Float] = []
    out.reserveCapacity(count)
    var made = 0
    while made < count {
        state = state &* 1_664_525 &+ 1_013_904_223
        out.append((Float(state >> 8) / Float(1 << 24) * 2 - 1) * scale)
        made += 1
    }
    return out
}

@Suite struct ToneMeterReads {
    @Test func aWholeToneHasNoGapAndNoClick() throws {
        let reading = try #require(ToneMeter.read(tone(3), rate: rate, join: 1.0...2.0))
        #expect(reading.gaps.isEmpty)
        #expect(!reading.click)
        #expect(abs(reading.toneHz - 1_000) < 0.5)
        #expect(abs(reading.level - 20 * log10(0.5 / 2.0.squareRoot())) < 0.01)
        #expect((reading.joinResidual ?? 0) < -100, "a clean tone leaves nothing over")
        #expect(abs(reading.seconds - 2.96) < 0.01, "the ends are left out")
        #expect(abs((reading.joinSlip ?? 99)) < 0.01 && abs((reading.levelStep ?? 99)) < 0.001)
    }

    @Test(arguments: [0.6, 30.0, 80.0]) func aSilenceIsMeasured(milliseconds: Double) throws {
        let silent = Int(milliseconds / 1000 * rate)
        let first = tone(1.5)
        let samples = first + [Float](repeating: 0, count: silent) + tone(1.5, from: first.count)
        let reading = try #require(ToneMeter.read(samples, rate: rate, join: 1.0...2.0))
        #expect(reading.gaps.count == 1)
        let gap = try #require(reading.gaps.first)
        #expect(abs(gap.milliseconds - milliseconds) < 0.1)
        #expect(abs(gap.at - 1.5) < 0.001)
        #expect(reading.click, "the edges of a silence are a break in the tone too")
        // A silence is no slip: the tone carries on from where it stopped (0.6 ms is 28 frames and a bit, which it rounds to).
        if milliseconds > 1 { #expect(abs((reading.joinSlip ?? 99)) < 0.01) }
        #expect(abs(reading.level - 20 * log10(0.5 / 2.0.squareRoot())) < 0.01, "the silence isn't counted in the level")
    }

    @Test func aSkippedStretchIsAClickAndNotAGap() throws {
        let first = tone(1.5)
        // 37 frames of the tone never played: no silence, but the tone jumps.
        let samples = first + tone(1.5, from: first.count + 37)
        let reading = try #require(ToneMeter.read(samples, rate: rate, join: 1.0...2.0))
        #expect(reading.gaps.isEmpty)
        #expect(reading.click)
        #expect((reading.joinResidual ?? -200) > -40)
        // 37 frames early: the same as 11 late, a cycle being 48.
        #expect(abs((reading.joinSlip ?? 99) - 11) < 0.01)
    }

    @Test func aSliverOfASampleOutOfStepIsMeasured() throws {
        // The second half is the tone a quarter of a sample on: nothing a residual would call a click.
        var samples = tone(1.5)
        var frame = 0
        while frame < 72_000 {
            samples.append(Float(0.5 * sin(2 * Double.pi * 1_000 * (Double(72_000 + frame) + 0.25) / rate)))
            frame += 1
        }
        let reading = try #require(ToneMeter.read(samples, rate: rate, join: 1.0...2.0))
        #expect(abs((reading.joinSlip ?? 99) + 0.25) < 0.01)
        #expect(reading.gaps.isEmpty)
    }

    @Test func aChangeOfLevelAtTheJoinIsMeasured() throws {
        let first = tone(1.5)
        let samples = first + tone(1.5, scale: 0.25, from: first.count)
        let reading = try #require(ToneMeter.read(samples, rate: rate, join: 1.0...2.0))
        #expect(abs((reading.levelStep ?? 99) + 6.0206) < 0.001)
        #expect(abs((reading.joinSlip ?? 99)) < 0.01)
    }

    @Test func aBreakAwayFromTheJoinIsNotTheJoins() throws {
        let first = tone(0.5)
        let samples = first + tone(2.5, from: first.count + 37)
        let reading = try #require(ToneMeter.read(samples, rate: rate, join: 1.0...2.0))
        #expect(!reading.click)
        #expect(reading.elsewhereResidual > -40)
    }

    @Test func aNoisyToneThatIsWholeIsNotAClick() throws {
        // What a lossy encoding leaves: noise 40 dB under the tone, all the way through.
        var samples = tone(3)
        let hiss = noise(samples.count, scale: 0.005)
        var index = 0
        while index < samples.count {
            samples[index] += hiss[index]
            index += 1
        }
        let reading = try #require(ToneMeter.read(samples, rate: rate, join: 1.0...2.0))
        #expect(reading.gaps.isEmpty)
        #expect(!reading.click)
        #expect(abs(reading.toneHz - 1_000) < 10)
        #expect(abs((reading.joinSlip ?? 99)) < 0.05)
    }

    @Test func theLevelFollowsTheTone() throws {
        let loud = try #require(ToneMeter.read(tone(1), rate: rate))
        let quiet = try #require(ToneMeter.read(tone(1, scale: 0.5 * pow(10, -6.2 / 20)), rate: rate))
        #expect(abs(quiet.level - loud.level + 6.2) < 0.001)
        #expect(loud.joinResidual == nil && !loud.click && loud.joinSlip == nil && loud.levelStep == nil)
    }

    @Test func silenceBeforeAndAfterIsNotAGap() throws {
        let quiet = [Float](repeating: 0, count: 4_800)
        let reading = try #require(ToneMeter.read(quiet + tone(1) + quiet, rate: rate))
        #expect(reading.gaps.isEmpty)
        #expect(abs(reading.seconds - 0.96) < 0.01)
    }

    @Test func nothingToReadIsSaidSo() {
        #expect(ToneMeter.read([Float](repeating: 0, count: 48_000), rate: rate) == nil)
        #expect(ToneMeter.read(tone(0.05), rate: rate) == nil)
        #expect(ToneMeter.read([], rate: rate) == nil)
    }

    @Test func aCaptureIsWrittenAsAWaveFile() {
        let data = BenchReport.wave([[0, 0.5, -0.5], [1, 0, -1]], rate: 48_000)
        #expect(data.count == 44 + 3 * 2 * 4)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8) && Array(data[8..<16]) == Array("WAVEfmt ".utf8))
        // The second frame's left sample: 0.5 as a 32-bit float, low byte first.
        #expect(Array(data[52..<56]) == [0x00, 0x00, 0x00, 0x3f])
    }
}
