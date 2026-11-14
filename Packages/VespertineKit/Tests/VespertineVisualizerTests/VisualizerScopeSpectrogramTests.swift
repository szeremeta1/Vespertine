//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import Metal
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer spectrogram") @MainActor
struct VisualizerSpectrogramTests {
    static let size = CGSize(width: 400, height: 200)

    private func renderer(seconds: Double = 4) throws -> VisualizerRenderer {
        let renderer = try #require(VisualizerRenderer())
        renderer.settings.style = .spectrogram
        renderer.settings.spectrogramSeconds = seconds
        renderer.settings.showsTrackInfo = false
        return renderer
    }

    private func frame(level: Float) -> VisualizerFrame {
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.fine = .init(repeating: level, count: 512)
        frame.hasSignal = level > 0
        return frame
    }

    /// The brightness (largest channel, 0…255) of the plot's column `fromRight` pixels in from its right edge, halfway up.
    private func brightness(_ pixels: [UInt8], fromRight: Int) -> Int {
        let x = Int(Self.size.width) - 28 - 1 - fromRight, y = Int(Self.size.height) / 2
        let i = (y * Int(Self.size.width) + x) * 4
        return Int(max(pixels[i], pixels[i + 1], pixels[i + 2]))
    }

    @Test("The newest edge shows the newest sound: after loud music stops, no stripe of the old music shows at the right edge")
    func noStaleEdge() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try renderer()
        let scene = VisualizerScene(isPlaying: true)
        // Loud for longer than the whole history, so every column is bright; then silence for a second and a half.
        for _ in 0..<300 { _ = renderer.renderOffscreen(frame: frame(level: 0.9), scene: scene, size: Self.size, scale: 1, dt: 1.0 / 60) }
        var worst = 0
        for i in 0..<90 {
            // Uneven frames, so the scroll's fraction takes every value.
            let dt = 1.0 / 60 * (0.7 + 0.6 * Double(i % 7) / 6)
            let pixels = try #require(renderer.renderOffscreen(frame: frame(level: 0), scene: scene, size: Self.size, scale: 1, dt: dt))
            if i >= 4 { worst = max(worst, brightness(pixels, fromRight: 0), brightness(pixels, fromRight: 1)) }
        }
        #expect(worst < 30, "the right edge reached \(worst) of 255 during silence")
        // And the old music is still there further left.
        let pixels = try #require(renderer.renderOffscreen(frame: frame(level: 0), scene: scene, size: Self.size, scale: 1, dt: 1.0 / 60))
        #expect(brightness(pixels, fromRight: 250) > 120)
    }

    @Test("Louder is brighter, all the way up, in every theme (it used to be one flat colour from the middle up)", arguments: VisualizerTheme.allCases)
    func louderIsBrighter(theme: VisualizerTheme) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var last = -20
        for level: Float in [0.15, 0.3, 0.45, 0.6, 0.75, 0.9] {
            let renderer = try renderer()
            renderer.settings.theme = theme
            var pixels: [UInt8] = []
            for _ in 0..<40 {
                pixels = try #require(renderer.renderOffscreen(frame: frame(level: level), scene: VisualizerScene(isPlaying: true), size: Self.size, scale: 1, dt: 1.0 / 60))
            }
            let b = brightness(pixels, fromRight: 10)
            #expect(b >= last + 12, "\(theme): level \(level) is \(b), the level below was \(last)")
            last = b
        }
    }
}

@Suite("Visualizer oscilloscope trigger") @MainActor
struct VisualizerScopeTriggerTests {
    /// A bass note with a loud hi-hat-like tone and noise on top, starting at `phase` of the bass.
    private func samples(bass: Double, phase: Double, ripple: Float = 0.5) -> [SIMD2<Float>] {
        var noise = BeatFixtures.Noise(state: 5)
        return (0..<VisualizerFrame.stereoCount).map { i in
            let t = Double(i) / 48_000
            let v = Float(0.5 * sin(2 * .pi * bass * t + phase)) + ripple * Float(sin(2 * .pi * 7_300 * t)) + 0.1 * noise.next()
            return SIMD2(v, v)
        }
    }

    @Test("A bass note under loud highs: every sweep starts at the same point of the bass, so the picture stands still",
          arguments: [60.0, 110.0, 240.0])
    func steadyUnderHighs(bass: Double) {
        let span = 1024
        var phases: [Double] = []
        for k in 0..<12 {
            let phase = Double(k) * 0.523
            let start = VisualizerRenderer.scopeTrigger(samples(bass: bass, phase: phase), span: span)
            #expect(start >= 1 && start <= VisualizerFrame.stereoCount - span)
            // The bass's phase where the sweep starts: 0 is its rising zero crossing.
            var at = (2 * .pi * bass * Double(start) / 48_000 + phase).truncatingRemainder(dividingBy: 2 * .pi)
            if at > .pi { at -= 2 * .pi }
            phases.append(at)
        }
        #expect(phases.allSatisfy { abs($0) < 0.5 }, "the sweeps started at \(phases.map { ($0 * 100).rounded() / 100 }) rad of the bass")
    }

    @Test("A plain tone starts on its rising zero crossing, and silence or a tone too slow to cross runs free")
    func plainAndFree() {
        let tone = (0..<VisualizerFrame.stereoCount).map { i -> SIMD2<Float> in
            let v = Float(0.7 * sin(2 * .pi * 1000 * Double(i) / 48_000 + 1))
            return SIMD2(v, v)
        }
        let start = VisualizerRenderer.scopeTrigger(tone, span: 1024)
        var at = (2 * .pi * 1000 * Double(start) / 48_000 + 1).truncatingRemainder(dividingBy: 2 * .pi)
        if at > .pi { at -= 2 * .pi }
        #expect(abs(at) < 0.3, "started at \(at) rad")
        let silent = [SIMD2<Float>](repeating: .zero, count: VisualizerFrame.stereoCount)
        #expect(VisualizerRenderer.scopeTrigger(silent, span: 1024) == VisualizerFrame.stereoCount - 1024)
        let offset = [SIMD2<Float>](repeating: SIMD2(0.3, 0.3), count: VisualizerFrame.stereoCount)
        #expect(VisualizerRenderer.scopeTrigger(offset, span: 1024) == VisualizerFrame.stereoCount - 1024)
    }
}
