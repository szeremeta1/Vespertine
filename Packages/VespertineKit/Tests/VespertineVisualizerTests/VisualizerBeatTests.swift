//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineVisualizer

/// The beats everything in the visualizer moves to (the Club rings and lasers, the particles, the strobe), found in
/// songs made for the purpose (`BeatFixtures`): drums over a bass line that never stops, as in real music, not kicks
/// on silence.
@Suite("Visualizer beats")
struct VisualizerBeatTests {
    /// The first seconds teach the detector what loud is; the song is judged after them.
    static let settle = 2.0

    static func after(_ times: [Double], _ from: Double = settle) -> [Double] { times.filter { $0 >= from } }

    @Test("Kicks under a bass line that never stops are found one by one, and the hi-hats between them are not beats",
          arguments: [60.0, 120.0])
    func kicksUnderBass(fps: Double) {
        let song = BeatFixtures.dance(bpm: 124, seconds: 14)
        let found = Self.after(BeatFixtures.beats(BeatFixtures.analyze(song, fps: fps)))
        let kicks = Self.after(song.kicks)
        let (hits, strays) = BeatFixtures.match(found, to: kicks)
        #expect(Double(hits) >= 0.92 * Double(kicks.count), "found \(hits) of \(kicks.count) kicks")
        #expect(Double(strays) <= 0.08 * Double(kicks.count), "\(strays) beats where there was no kick")
    }

    @Test("A backbeat with no kick drum (snares on 2 and 4) is the beat")
    func backbeat() {
        let song = BeatFixtures.dance(bpm: 100, seconds: 14, kick: false)
        let found = Self.after(BeatFixtures.beats(BeatFixtures.analyze(song)))
        let snares = Self.after(song.snares)
        let (hits, strays) = BeatFixtures.match(found, to: snares)
        #expect(Double(hits) >= 0.9 * Double(snares.count), "found \(hits) of \(snares.count) snares")
        #expect(strays <= 2, "\(strays) beats where there was no snare")
    }

    @Test("Slow, fast and in between: the beats are found and the tempo is right (a very fast song may read as half)",
          arguments: [84.0, 100, 128, 150, 174])
    func tempo(bpm: Double) throws {
        let song = BeatFixtures.dance(bpm: bpm, seconds: 16)
        let frames = BeatFixtures.analyze(song)
        let kicks = Self.after(song.kicks)
        let (hits, _) = BeatFixtures.match(Self.after(BeatFixtures.beats(frames)), to: kicks)
        #expect(Double(hits) >= 0.9 * Double(kicks.count), "found \(hits) of \(kicks.count) kicks at \(bpm) BPM")
        let tempo = try #require(frames.last?.frame.tempo, "no tempo at \(bpm) BPM")
        #expect(abs(tempo - bpm) < 2.5 || (bpm > 160 && abs(tempo - bpm / 2) < 1.5), "tempo \(tempo) for \(bpm) BPM")
    }

    @Test("Music without a beat (held chords that swell and change) has next to none")
    func noBeatNoBeats() {
        let frames = BeatFixtures.analyze(BeatFixtures.pad(seconds: 16))
        let found = Self.after(BeatFixtures.beats(frames))
        #expect(found.count <= 3, "\(found.count) beats in 14 s of pads")
    }

    @Test("A quiet master and a loud one give the same beats")
    func levelDoesNotMatter() {
        let loud = BeatFixtures.dance(bpm: 118, seconds: 12, level: 0.95)
        let quiet = BeatFixtures.dance(bpm: 118, seconds: 12, level: 0.03)
        let a = Self.after(BeatFixtures.beats(BeatFixtures.analyze(loud)))
        let b = Self.after(BeatFixtures.beats(BeatFixtures.analyze(quiet)))
        let kicks = Self.after(loud.kicks)
        #expect(Double(BeatFixtures.match(b, to: kicks).hits) >= 0.9 * Double(kicks.count))
        #expect(abs(a.count - b.count) <= 1, "\(a.count) beats loud, \(b.count) quiet")
    }

    @Test("High sample rates find the same beats", arguments: [48_000.0, 96_000, 192_000])
    func sampleRates(rate: Double) {
        let song = BeatFixtures.dance(bpm: 124, seconds: 10, rate: rate)
        let kicks = Self.after(song.kicks)
        let (hits, strays) = BeatFixtures.match(Self.after(BeatFixtures.beats(BeatFixtures.analyze(song))), to: kicks)
        #expect(Double(hits) >= 0.9 * Double(kicks.count), "found \(hits) of \(kicks.count) kicks at \(rate) Hz")
        #expect(strays <= 1)
    }

    @Test("Frames that come unevenly (a busy timer) find the same beats as even ones")
    func unevenFrames() {
        let song = BeatFixtures.dance(bpm: 124, seconds: 12)
        let even = Self.after(BeatFixtures.beats(BeatFixtures.analyze(song)))
        let uneven = Self.after(BeatFixtures.beats(BeatFixtures.analyze(song, jitter: 0.45)))
        #expect(abs(even.count - uneven.count) <= 1, "\(even.count) beats evenly, \(uneven.count) unevenly")
        #expect(BeatFixtures.match(uneven, to: Self.after(song.kicks)).strays <= 1)
    }

    @Test("Without being told how many samples are new, it works them out from the time and still finds the beats")
    func withoutExactCounts() {
        let song = BeatFixtures.dance(bpm: 124, seconds: 12)
        let found = Self.after(BeatFixtures.beats(BeatFixtures.analyze(song, exact: false)))
        let kicks = Self.after(song.kicks)
        #expect(Double(BeatFixtures.match(found, to: kicks).hits) >= 0.9 * Double(kicks.count))
    }

    @Test("A hard kick is a stronger beat than a soft one")
    func strength() {
        // Hard, soft, hard, soft…
        let song = BeatFixtures.dance(bpm: 110, seconds: 14, snare: false, hats: false, kickLevels: [0.7, 0.18])
        let frames = BeatFixtures.analyze(song)
        var hard: [Float] = [], soft: [Float] = []
        for (i, kick) in song.kicks.enumerated() where kick >= Self.settle {
            guard let hit = frames.first(where: { $0.frame.beat && $0.time >= kick - 0.01 && $0.time <= kick + 0.07 }) else { continue }
            if i % 2 == 0 { hard.append(hit.frame.beatStrength) } else { soft.append(hit.frame.beatStrength) }
        }
        #expect(hard.count >= 8, "found \(hard.count) hard kicks")
        let hardMean = hard.reduce(0, +) / Float(max(hard.count, 1))
        let softMean = soft.isEmpty ? 0 : soft.reduce(0, +) / Float(soft.count)
        #expect(hardMean > 0.7, "hard kicks' strength \(hardMean)")
        #expect(hardMean > softMean + 0.25, "hard \(hardMean), soft \(softMean)")
        #expect(frames.allSatisfy { (0...1).contains($0.frame.beatStrength) && (0...1).contains($0.frame.beatPulse) })
    }

    @Test("Every beat is counted, so a reader that sees only some frames (the window draws on its own clock) misses none and doubles none")
    func countedBeats() {
        let song = BeatFixtures.dance(bpm: 140, seconds: 12)
        let frames = BeatFixtures.analyze(song, fps: 120)
        let flagged = frames.filter(\.frame.beat).count
        #expect(flagged >= 20)
        #expect(Int(frames.last!.frame.beatCount) == flagged)
        // A reader that takes every third frame, and one that takes some frames twice.
        var seen = 0, last: UInt32 = 0
        for (i, f) in frames.enumerated() where i % 3 == 0 {
            seen += Int(f.frame.beatCount &- last)
            last = f.frame.beatCount
        }
        #expect(seen == flagged)
        seen = 0; last = 0
        for f in frames {
            for _ in 0..<2 {
                seen += Int(f.frame.beatCount &- last)
                last = f.frame.beatCount
            }
        }
        #expect(seen == flagged)
    }

    @Test("The pulse jumps on a beat and has all but gone a third of a second later")
    func pulse() {
        let song = BeatFixtures.dance(bpm: 60, seconds: 10, snare: false, hats: false)
        let frames = BeatFixtures.analyze(song)
        let beat = frames.firstIndex { $0.frame.beat && $0.time > 4 }!
        #expect(frames[beat].frame.beatPulse > 0.7)
        let later = frames[beat...].first { $0.time > frames[beat].time + 0.35 }!
        #expect(later.frame.beatPulse < 0.2)
    }

    @Test("Paused or silent: no beats, the pulse falls away, and the count stands still")
    func silence() {
        let song = BeatFixtures.dance(bpm: 124, seconds: 6)
        let analyzer = VisualizerAnalyzer()
        let frames = BeatFixtures.analyze(song, analyzer: analyzer)
        let count = frames.last!.frame.beatCount
        let n = VisualizerAnalyzer.fftSize(for: song.rate)
        let stale = Array(song.samples.suffix(n))
        var last = frames.last!.frame
        for _ in 0..<90 {   // paused: the old samples are still there, nothing is new
            last = analyzer.process(left: stale, right: stale, sampleRate: song.rate, fresh: false, dt: 1.0 / 60)
            #expect(!last.beat)
        }
        #expect(last.beatCount == count)
        #expect(last.beatPulse < 0.01)
        #expect(last.tempo == nil)
        let silent = [Float](repeating: 0, count: n)
        for _ in 0..<120 {
            last = analyzer.process(left: silent, right: silent, sampleRate: song.rate, fresh: true, dt: 1.0 / 60, advanced: 735)
            #expect(!last.beat)
            #expect(last.beatPulse.isFinite && last.beatStrength.isFinite)
        }
    }

    @Test("Playing again after a pause doesn't count the join as a beat")
    func resumeIsNotABeat() {
        let song = BeatFixtures.pad(seconds: 8)
        let analyzer = VisualizerAnalyzer()
        _ = BeatFixtures.analyze(song, analyzer: analyzer)
        let n = VisualizerAnalyzer.fftSize(for: song.rate)
        let window = Array(song.samples[100_000..<(100_000 + n)])
        for _ in 0..<30 { _ = analyzer.process(left: window, right: window, sampleRate: song.rate, fresh: false, dt: 1.0 / 60) }
        var beats = 0
        for i in 0..<60 {
            let from = 100_000 + i * 735
            let w = Array(song.samples[from..<(from + n)])
            if analyzer.process(left: w, right: w, sampleRate: song.rate, fresh: true, dt: 1.0 / 60, advanced: i == 0 ? nil : 735).beat { beats += 1 }
        }
        #expect(beats == 0)
    }

    @Test("The feed tells the analyzer how many samples are new from the tap's own count")
    func feedCountsNewSamples() {
        let song = BeatFixtures.dance(bpm: 124, seconds: 10)
        let rate = song.rate
        final class Cursor: @unchecked Sendable { var end = 0 }
        let cursor = Cursor()
        let feed = VisualizerFeed { left, right in
            let n = left.count, end = cursor.end
            guard end >= n, end <= song.samples.count else { return VisualizerTapRead(frames: 0, position: 0, sampleRate: rate, isDSD: false) }
            for i in 0..<n { left[i] = song.samples[end - n + i]; right[i] = left[i] }
            return VisualizerTapRead(frames: n, position: UInt64(end), sampleRate: rate, isDSD: false)
        }
        feed.prepareForTesting()
        // The feed's own clock is the wall clock, which says nothing here (the loop runs as fast as it can): only the
        // tap's count of frames can tell it that each tick brought 13 ms of music.
        var beats = 0, last: UInt32 = 0
        var kicksHeard = 0
        cursor.end = 4096
        while cursor.end + 588 < song.samples.count {
            cursor.end += 588
            feed.tick()
            let frame = feed.frame
            beats += Int(frame.beatCount &- last)
            last = frame.beatCount
        }
        kicksHeard = song.kicks.filter { $0 > 0.2 }.count
        #expect(beats >= kicksHeard - 4 && beats <= kicksHeard + 1, "\(beats) beats for \(kicksHeard) kicks")
    }
}
