//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer analysis")
struct VisualizerAnalyzerTests {
    static func sine(_ hz: Double, amplitude: Float = 1, rate: Double, frames: Int, phase: Double = 0) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate + phase)) }
    }

    /// Where `hz` falls among the fine bins (log-spaced from 20 Hz to 20 kHz).
    static func fineIndex(_ hz: Double, count: Int = 512) -> Double { log(hz / 20) / log(1000) * Double(count) }

    static func flat() -> VisualizerAnalyzer.Configuration {
        var c = VisualizerAnalyzer.Configuration()
        c.tiltDBPerOctave = 0
        return c
    }

    @Test("A sine lands in its own fine bin and band", arguments: [(100.0, 48_000.0), (1000, 44_100), (5000, 96_000), (12_000, 192_000)])
    func sineLandsInItsBin(hz: Double, rate: Double) {
        let analyzer = VisualizerAnalyzer(configuration: Self.flat())
        let n = VisualizerAnalyzer.fftSize(for: rate)
        let x = Self.sine(hz, rate: rate, frames: n)
        let frame = analyzer.process(left: x, right: x, sampleRate: rate, fresh: true, dt: 1 / 60)
        let loudest = frame.fine.indices.max { frame.fine[$0] < frame.fine[$1] }!
        // Within three fine bins, or one FFT bin where those are wider (the lows): the FFT can't tell closer.
        let found = 20 * pow(1000, (Double(loudest) + 0.5) / 512)
        let resolution = max(hz * (pow(1000, 3.0 / 512) - 1), rate / Double(n))
        #expect(abs(found - hz) <= resolution, "\(hz) Hz peaked at \(found) Hz")
        let band = frame.bands.indices.max { frame.bands[$0] < frame.bands[$1] }!
        #expect(band == loudest * frame.bands.count / frame.fine.count)
        // Far from the tone there's nothing (Hann's side lobes are far below the floor an octave away).
        let far = Int(Self.fineIndex(hz < 1000 ? hz * 4 : hz / 4))
        #expect(frame.fine[far] < 0.05)
    }

    @Test("Levels are calibrated: a sine at -6 dBFS on a bin centre reads -6 dB")
    func calibrated() {
        let rate = 48_000.0, n = 4096
        let hz = 85 * rate / Double(n)   // ≈ 996 Hz, exactly on bin 85
        var c = Self.flat()
        c.attack = 0.0001
        let analyzer = VisualizerAnalyzer(configuration: c)
        let x = Self.sine(hz, amplitude: 0.5, rate: rate, frames: n)
        let frame = analyzer.process(left: x, right: x, sampleRate: rate, fresh: true, dt: 1 / 60)
        let expected = (-6.02 - c.floorDB) / -c.floorDB
        #expect(abs((frame.fine.max() ?? 0) - expected) < 0.01)
        #expect(abs((frame.bands.max() ?? 0) - expected) < 0.01)
        #expect(abs(frame.rmsDB.x - -9.03) < 0.1)    // a sine's RMS is 3 dB under its peak
        #expect(abs(frame.peakDB.x - -6.02) < 0.1)
        #expect(frame.hasSignal)
    }

    @Test("Sensitivity raises the display by its gain")
    func sensitivity() {
        let rate = 48_000.0, n = 4096, hz = 85 * rate / Double(n)
        var c = Self.flat()
        c.attack = 0.0001
        c.sensitivity = 2   // +6 dB
        let analyzer = VisualizerAnalyzer(configuration: c)
        let x = Self.sine(hz, amplitude: 0.25, rate: rate, frames: n)
        let frame = analyzer.process(left: x, right: x, sampleRate: rate, fresh: true, dt: 1 / 60)
        #expect(abs((frame.fine.max() ?? 0) - (-6.02 - c.floorDB) / -c.floorDB) < 0.01)
    }

    @Test("Linear bars: amplitude, full height at -12 dBFS")
    func linear() {
        #expect(VisualizerAnalyzer.display(-12, floor: -72, linear: true) == 1)
        #expect(abs(VisualizerAnalyzer.display(-18.0206, floor: -72, linear: true) - 0.5) < 0.001)
        #expect(VisualizerAnalyzer.display(0, floor: -72, linear: true) == 1)
        #expect(VisualizerAnalyzer.display(-200, floor: -72, linear: true) < 1e-6)
    }

    @Test("Silence: nothing shows, nothing is a number it shouldn't be, no beats")
    func silence() {
        let analyzer = VisualizerAnalyzer()
        let zeros = [Float](repeating: 0, count: 4096)
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        for _ in 0..<120 { frame = analyzer.process(left: zeros, right: zeros, sampleRate: 44_100, fresh: true, dt: 1 / 60) }
        #expect(frame.fine.allSatisfy { $0 == 0 })
        #expect(frame.bands.allSatisfy { $0 == 0 } && frame.peaks.allSatisfy { $0 == 0 })
        #expect(!frame.hasSignal && !frame.beat && frame.beatPulse == 0)
        #expect(frame.rmsDB == SIMD2(-100, -100))
        #expect([frame.bass, frame.mid, frame.treble].allSatisfy { $0.isFinite && $0 == 0 })
        #expect(frame.tempo == nil)
    }

    @Test("Peaks hold, then fall; bars fall faster than their peaks")
    func peakHold() {
        let rate = 48_000.0, n = 4096, hz = 85 * rate / Double(n)
        let analyzer = VisualizerAnalyzer(configuration: Self.flat())
        let tone = Self.sine(hz, rate: rate, frames: n), quiet = [Float](repeating: 0, count: n)
        let dt = 1.0 / 60
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        for _ in 0..<30 { frame = analyzer.process(left: tone, right: tone, sampleRate: rate, fresh: true, dt: dt) }
        let band = frame.bands.indices.max { frame.bands[$0] < frame.bands[$1] }!
        let top = frame.peaks[band]
        #expect(top > 0.95)
        // Within the hold time (0.7 s) the peak stays where it was, while the bar falls away.
        for _ in 0..<36 { frame = analyzer.process(left: quiet, right: quiet, sampleRate: rate, fresh: true, dt: dt) }
        #expect(frame.peaks[band] == top)
        #expect(frame.bands[band] < 0.2)
        // After it, it falls, faster and faster, down to the bar.
        for _ in 0..<12 { frame = analyzer.process(left: quiet, right: quiet, sampleRate: rate, fresh: true, dt: dt) }
        let falling = frame.peaks[band]
        #expect(falling < top)
        for _ in 0..<60 { frame = analyzer.process(left: quiet, right: quiet, sampleRate: rate, fresh: true, dt: dt) }
        #expect(frame.peaks[band] < falling * 0.5)
        #expect(frame.peaks[band] >= frame.bands[band])
    }

    @Test("Nothing new (paused) falls away as from silence, even though the old samples are still there")
    func staleFallsAway() {
        let analyzer = VisualizerAnalyzer()
        let tone = Self.sine(440, rate: 48_000, frames: 4096)
        _ = analyzer.process(left: tone, right: tone, sampleRate: 48_000, fresh: true, dt: 1 / 60)
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        for _ in 0..<120 { frame = analyzer.process(left: tone, right: tone, sampleRate: 48_000, fresh: false, dt: 1 / 60) }
        #expect(frame.bands.allSatisfy { $0 < 0.01 })
        #expect(!frame.hasSignal)
    }

    /// Kicks (a falling 55 Hz thump, 120 ms) at `bpm` over a quiet pad, as stereo samples at `rate`.
    static func kicks(bpm: Double, seconds: Double, rate: Double) -> [Float] {
        let frames = Int(seconds * rate), period = Int(60 / bpm * rate)
        var x = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i % period) / rate
            let kick = t < 0.12 ? sin(2 * .pi * (55 + 90 * exp(-t * 40)) * t) * exp(-t * 18) : 0
            x[i] = Float(0.7 * kick + 0.05 * sin(2 * .pi * 660 * Double(i) / rate))
        }
        return x
    }

    @Test("Beats: kicks at 120 BPM are found one by one, at 60 and 120 frames a second, and the tempo is 120", arguments: [60.0, 120.0])
    func beats(fps: Double) {
        let rate = 44_100.0, n = 4096, seconds = 10.0
        let x = Self.kicks(bpm: 120, seconds: seconds, rate: rate)
        let analyzer = VisualizerAnalyzer()
        var beats: [Double] = []
        var last = VisualizerFrame.silent(bands: 64, fine: 512)
        var t = 0.2
        while t < seconds {
            let end = Int(t * rate)
            let window = Array(x[max(0, end - n)..<end])
            last = analyzer.process(left: window, right: window, sampleRate: rate, fresh: window.count == n, dt: 1 / fps)
            if last.beat { beats.append(t) }
            t += 1 / fps
        }
        // 20 kicks in 10 s; the first one or two teach the threshold.
        #expect((17...20).contains(beats.count), "found \(beats.count) beats")
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 0.5) < 0.05 }, "\(gaps)")
        #expect(abs((last.tempo ?? 0) - 120) < 3)
    }

    @Test("A steady tone has no beats once it's going")
    func steadyToneNoBeats() {
        let rate = 48_000.0, n = 4096
        let x = Self.sine(80, amplitude: 0.5, rate: rate, frames: Int(rate * 5))
        let analyzer = VisualizerAnalyzer()
        var beats = 0
        var t = 0.5
        while t < 5 {
            let end = Int(t * rate)
            let w = Array(x[(end - n)..<end])
            if analyzer.process(left: w, right: w, sampleRate: rate, fresh: true, dt: 1 / 60).beat, t > 1 { beats += 1 }
            t += 1 / 60
        }
        #expect(beats == 0)
    }

    @Test("Tempo needs regular beats, and folds into 70–180 BPM")
    func tempo() {
        #expect(VisualizerAnalyzer.tempo([0, 1, 2]) == nil)
        #expect(abs((VisualizerAnalyzer.tempo(stride(from: 0, to: 10, by: 0.25).map { $0 }) ?? 0) - 120) < 0.01)   // 240 → 120
        #expect(abs((VisualizerAnalyzer.tempo(stride(from: 0, to: 20, by: 1.2).map { $0 }) ?? 0) - 100) < 0.01)    // 50 → 100
        #expect(VisualizerAnalyzer.tempo([0, 0.3, 1.4, 1.6, 3.5, 3.7, 5.9]) == nil)
    }

    @Test("FFT sizes keep about 85 ms at every rate")
    func sizes() {
        #expect(VisualizerAnalyzer.fftSize(for: 44_100) == 4096)
        #expect(VisualizerAnalyzer.fftSize(for: 48_000) == 4096)
        #expect(VisualizerAnalyzer.fftSize(for: 96_000) == 8192)
        #expect(VisualizerAnalyzer.fftSize(for: 192_000) == 16384)
        #expect(VisualizerAnalyzer.fftSize(for: 384_000) == 16384)
    }

    @Test("Changing the band count resizes the bars without disturbing anything else")
    func bandCount() {
        let analyzer = VisualizerAnalyzer()
        let x = Self.sine(440, rate: 48_000, frames: 4096)
        #expect(analyzer.process(left: x, right: x, sampleRate: 48_000, fresh: true, dt: 1 / 60).bands.count == 64)
        analyzer.configuration.bandCount = 128
        let frame = analyzer.process(left: x, right: x, sampleRate: 48_000, fresh: true, dt: 1 / 60)
        #expect(frame.bands.count == 128 && frame.peaks.count == 128 && frame.fine.count == 512)
    }
}

@Suite("Visualizer feed")
struct VisualizerFeedTests {
    @Test("Reads the source, analyzes what's new, and counts overtaken copies as dropped frames")
    func feed() {
        let position = Locked<UInt64>(0)
        let overtaken = Locked(false)
        let feed = VisualizerFeed { left, right in
            if overtaken.value { return VisualizerTapRead(frames: 0, position: 0, sampleRate: 48_000, isDSD: false) }
            let p = position.value
            for i in left.indices { left[i] = Float(sin(Double(i) * 0.2)); right[i] = left[i] }
            return VisualizerTapRead(frames: left.count, position: p, sampleRate: 48_000, isDSD: false)
        }
        feed.prepareForTesting()
        position.value = 1
        feed.tick()
        #expect(feed.frame.hasSignal)
        overtaken.value = true
        feed.tick()
        #expect(feed.stats.dropped == 1 && feed.stats.frames == 1)
    }
}

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
