//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import Metal
import Testing
@testable import VespertineVisualizer

/// The beat strobe, from the switch to the flash: on real analysis of a song (not a frame made up to flash), through
/// the renderer, to the pixels.
@Suite("Visualizer strobe") @MainActor
struct VisualizerStrobeTests {
    static let size = CGSize(width: 64, height: 36)

    /// Plays a song through the analyzer and the renderer as the window does and counts the flashes (the strobe's
    /// level jumping up), and the brightest the middle of the picture got.
    static func flashes(_ renderer: VisualizerRenderer, song: BeatFixtures.Song, from: Double = 2) -> (count: Int, times: [Double], brightest: Int) {
        var count = 0, last: Float = 0, brightest = 0
        var times: [Double] = []
        for (time, frame) in BeatFixtures.analyze(song) {
            guard let pixels = renderer.renderOffscreen(frame: frame, scene: VisualizerScene(isPlaying: true), size: size, scale: 1, dt: 1.0 / 60) else { continue }
            if time >= from {
                if renderer.strobeLevel > last + 0.1 { count += 1; times.append(time) }
                // A corner, away from the core and the beams: dark unless the whole window flashes.
                let i = (4 * Int(size.width) + 4) * 4
                brightest = max(brightest, Int(min(pixels[i], pixels[i + 1], pixels[i + 2])))
            }
            last = renderer.strobeLevel
        }
        return (count, times, brightest)
    }

    static func club(_ mode: VisualizerClubMode, strobe: Bool) throws -> VisualizerRenderer {
        let renderer = try #require(VisualizerRenderer())
        renderer.settings.style = .club
        renderer.settings.clubMode = mode
        renderer.settings.showsTrackInfo = false
        if strobe {
            let turnedOn = renderer.settings.turnStrobe(on: true)
            #expect(!turnedOn)      // asks first
            renderer.settings.acceptStrobeWarning()
        }
        return renderer
    }

    @Test("Switched on, it flashes the whole window on a song's hard beats, in both Club modes", arguments: VisualizerClubMode.allCases)
    func flashesOnASong(mode: VisualizerClubMode) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let song = BeatFixtures.dance(bpm: 124, seconds: 12)
        let renderer = try Self.club(mode, strobe: true)
        let on = Self.flashes(renderer, song: song)
        // 10 s of kicks at 124 BPM is about 20 beats; at most one flash every 0.4 s lets through every one (0.48 s apart).
        #expect(on.count >= 14, "\(on.count) flashes in 10 s")
        #expect(on.brightest >= 150, "the corner only reached \(on.brightest) of 255")
        // Each flash is on a kick.
        #expect(BeatFixtures.match(on.times, to: song.kicks, tolerance: 0.09).strays <= 1)
        let gaps = zip(on.times.dropFirst(), on.times).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= VisualizerRenderer.flashInterval - 1e-6 }, "\(gaps)")
    }

    @Test("Switched off, the same song never flashes, and the corner stays dark")
    func offNeverFlashes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let song = BeatFixtures.dance(bpm: 124, seconds: 8)
        let renderer = try Self.club(.classic, strobe: false)
        let off = Self.flashes(renderer, song: song)
        #expect(off.count == 0)
        #expect(off.brightest < 110, "the corner reached \(off.brightest) of 255 with the strobe off")
    }

    @Test("Only hard beats flash: soft ones between them don't")
    func onlyHardBeats() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        // Hard, soft, hard, soft, 1.1 s from hard to hard.
        let song = BeatFixtures.dance(bpm: 110, seconds: 14, snare: false, hats: false, kickLevels: [0.7, 0.18])
        let renderer = try Self.club(.classic, strobe: true)
        let on = Self.flashes(renderer, song: song)
        let hard = song.kicks.enumerated().filter { $0.offset % 2 == 0 && $0.element >= 2 }.map(\.element)
        let soft = song.kicks.enumerated().filter { $0.offset % 2 == 1 && $0.element >= 2 }.map(\.element)
        #expect(BeatFixtures.match(on.times, to: hard, tolerance: 0.09).hits >= hard.count - 1)
        #expect(BeatFixtures.match(on.times, to: soft, tolerance: 0.09).hits <= 1)
    }

    @Test("A frame the window draws twice flashes once; a beat in a frame it never drew still flashes")
    func followsTheCount() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try #require(VisualizerRenderer())
        renderer.settings.style = .club
        renderer.settings.acceptStrobeWarning()
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.hasSignal = true
        frame.beatStrength = 1
        let scene = VisualizerScene(isPlaying: true)
        func draw(_ dt: Double = 1.0 / 60) { _ = renderer.renderOffscreen(frame: frame, scene: scene, size: Self.size, scale: 1, dt: dt) }
        draw()
        #expect(renderer.strobeLevel == 0)
        // A beat, in a frame drawn twice.
        frame.beat = true; frame.beatCount = 1
        draw()
        let first = renderer.strobeLevel
        #expect(first > 0.5)
        for _ in 0..<30 { draw() }      // half a second of the same frame: it falls away and doesn't flash again
        #expect(renderer.strobeLevel == 0)
        // The next beat came and went between two draws: the frame drawn says only that the count went up.
        frame.beat = false; frame.beatCount = 2
        draw()
        #expect(renderer.strobeLevel > 0.5)
    }

    @Test("With Reduce Motion or Dim Flashing Lights on, or the warning not accepted, a song never flashes")
    func gatesHoldOnASong() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let song = BeatFixtures.dance(bpm: 124, seconds: 6)
        for gate in 0..<3 {
            let renderer = try Self.club(.classic, strobe: true)
            switch gate {
            case 0: renderer.reduceMotion = true
            case 1: renderer.reduceFlashing = true
            default: renderer.settings.strobeWarningAccepted = false
            }
            #expect(Self.flashes(renderer, song: song).count == 0, "gate \(gate)")
        }
    }

    @Test("The switch: on asks for the warning the first time, then turns on; off always turns off")
    func theSwitch() {
        var s = VisualizerSettings()
        var done = s.turnStrobe(on: true)
        #expect(!done)                              // not yet: the warning has to be accepted
        #expect(!s.strobe)
        s.acceptStrobeWarning()
        #expect(s.strobe && s.strobeWarningAccepted)
        done = s.turnStrobe(on: false)
        #expect(done)
        #expect(!s.strobe)
        done = s.turnStrobe(on: true)               // accepted before: no question
        #expect(done)
        #expect(s.strobe)
        #expect(s.normalized.strobe)
        // And it survives saving.
        let defaults = UserDefaults(suiteName: "vespertine-strobe-\(UUID())")!
        s.save(to: defaults)
        #expect(VisualizerSettings.load(from: defaults).strobe)
    }
}
