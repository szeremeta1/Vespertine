//
// Vespertine: synthetic songs for the beat tests. Everything is generated from a seed, so every run hears the same
// thing, and each song says where its drums are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import VespertineVisualizer

enum BeatFixtures {
    struct Song {
        var samples: [Float]
        var rate: Double
        /// When each kick drum starts, in seconds.
        var kicks: [Double] = []
        /// When each snare starts.
        var snares: [Double] = []
        /// When each hi-hat starts.
        var hats: [Double] = []
    }

    /// A small deterministic noise source (an LCG; quality doesn't matter here).
    struct Noise {
        var state: UInt32
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
    }

    /// A dance track: a kick on every beat (or none), a snare on beats 2 and 4 (or none), hi-hats between the beats, a
    /// bass line that never stops (a held note per bar, the hard case: the lows are always full) and a pad. Peaks near
    /// `level`.
    static func dance(bpm: Double, seconds: Double, rate: Double = 44_100, kick: Bool = true, snare: Bool = true,
                      hats: Bool = true, bass: Float = 0.35, level: Float = 0.9, kickLevels: [Float] = [0.6],
                      seed: UInt32 = 7) -> Song {
        let frames = Int(seconds * rate)
        var x = [Float](repeating: 0, count: frames)
        var song = Song(samples: [], rate: rate)
        var noise = Noise(state: seed)
        let beat = 60 / bpm
        func add(at start: Double, length: Double, _ sample: (Double) -> Float) {
            let from = Int(start * rate), count = Int(length * rate)
            guard from < frames else { return }
            for i in 0..<min(count, frames - from) { x[from + i] += sample(Double(i) / rate) }
        }
        // The bass: one held note per bar, joined without a gap, with a little second harmonic.
        let notes: [Double] = [55, 65.41, 49, 73.42]
        var phase = 0.0
        for i in 0..<frames {
            let bar = Int(Double(i) / rate / (beat * 4))
            let hz = notes[bar % notes.count]
            phase += 2 * .pi * hz / rate
            x[i] += bass * Float(sin(phase) + 0.3 * sin(2 * phase))
        }
        // The pad: a chord with a slow tremolo.
        for i in 0..<frames {
            let t = Double(i) / rate
            let tremolo = 0.75 + 0.25 * sin(2 * .pi * 0.3 * t)
            x[i] += Float(0.05 * tremolo * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.18 * t) + sin(2 * .pi * 329.63 * t)))
        }
        var n = 0
        var t = 0.25   // the first beat, a little way in
        while t < seconds - 0.3 {
            if kick {
                let amplitude = kickLevels[n % kickLevels.count]
                song.kicks.append(t)
                // A sine falling from 150 to 50 Hz, with the beater's click.
                add(at: t, length: 0.3) { s in
                    let sweep = 50 * s + (100 / 30) * (1 - exp(-30 * s))   // the integral of 50 + 100 e^(-30 s)
                    return amplitude * Float(sin(2 * .pi * sweep) * exp(-s * 14))
                }
                add(at: t, length: 0.004) { _ in amplitude * 0.5 * noise.next() }
            }
            if snare, n % 2 == 1 {
                song.snares.append(t)
                add(at: t, length: 0.2) { s in Float(0.3 * exp(-s * 28)) * (noise.next() + 0.5 * Float(sin(2 * .pi * 190 * s))) }
            }
            if hats {
                let at = t + beat / 2
                song.hats.append(at)
                var previous: Float = 0
                add(at: at, length: 0.05) { s in
                    // Noise with the lows taken out (a first difference).
                    let v = noise.next(), high = v - previous
                    previous = v
                    return Float(0.10 * exp(-s * 110)) * high
                }
            }
            n += 1
            t += beat
        }
        // A soft limiter, as a master has, and the level asked for.
        let peak = x.map { abs(tanh($0)) }.max() ?? 1
        song.samples = x.map { tanh($0) / max(peak, 1e-6) * level }
        return song
    }

    /// Held chords that change slowly and swell in and out: music with no beat at all.
    static func pad(seconds: Double, rate: Double = 44_100) -> Song {
        let frames = Int(seconds * rate)
        let chords: [[Double]] = [[110, 220, 277.18, 329.63], [98, 196, 246.94, 293.66], [130.81, 261.63, 329.63, 392]]
        var x = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / rate
            // Each chord lasts 4 s and fades into the next over a second.
            let position = t / 4, index = Int(position), within = position - Double(index)
            let fade = min(1, within * 4), out = min(1, (1 - within) * 4)
            let swell = 0.6 + 0.4 * sin(2 * .pi * 0.11 * t)
            var v = 0.0
            for hz in chords[index % chords.count] { v += sin(2 * .pi * hz * t) }
            x[i] = Float(0.12 * v * swell * min(fade, out).squareRoot())
        }
        return Song(samples: x, rate: rate)
    }

    /// Runs a song through the analyzer as the window would, one frame every `1 / fps` seconds (each stretched or
    /// squeezed by up to `jitter` of itself, as a busy timer's are), telling it exactly how many samples are new, and
    /// returns every frame with the time its newest sample was played.
    static func analyze(_ song: Song, fps: Double = 60, jitter: Double = 0, exact: Bool = true,
                        analyzer: VisualizerAnalyzer = VisualizerAnalyzer()) -> [(time: Double, frame: VisualizerFrame)] {
        let n = VisualizerAnalyzer.fftSize(for: song.rate)
        var out: [(Double, VisualizerFrame)] = []
        var noise = Noise(state: 99)
        var t = Double(n) / song.rate, lastEnd = 0
        let total = Double(song.samples.count) / song.rate
        while t < total {
            let end = Int(t * song.rate)
            let window = Array(song.samples[(end - n)..<end])
            let dt = lastEnd == 0 ? 1 / fps : Double(end - lastEnd) / song.rate
            let frame = analyzer.process(left: window, right: window, sampleRate: song.rate, fresh: true, dt: dt,
                                         advanced: exact && lastEnd > 0 ? end - lastEnd : nil)
            out.append((t, frame))
            lastEnd = end
            t += (1 / fps) * (1 + jitter * Double(noise.next()))
        }
        return out
    }

    /// The times of the frames that say a beat started.
    static func beats(_ frames: [(time: Double, frame: VisualizerFrame)]) -> [Double] {
        frames.filter(\.frame.beat).map(\.time)
    }

    /// How many of `expected` have one of `found` within `tolerance` after them (a beat is only known once it has
    /// begun), and how many of `found` belong to none.
    static func match(_ found: [Double], to expected: [Double], tolerance: Double = 0.07) -> (hits: Int, strays: Int) {
        let hits = expected.filter { e in found.contains { $0 >= e - 0.01 && $0 <= e + tolerance } }.count
        let strays = found.filter { f in !expected.contains { f >= $0 - 0.01 && f <= $0 + tolerance } }.count
        return (hits, strays)
    }
}
