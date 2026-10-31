//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import Metal
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer meters' peak lights")
@MainActor
struct VisualizerPeakLightTests {
    static let size = CGSize(width: 1200, height: 700)

    /// The red of the left meter's peak light (top right of its face), 1x scale, from a frame at `amplitude`.
    static func lightRed(kind: VisualizerMeterKind, amplitude: Float, sensitivity: Float = 1, frames: Int = 1, right: Bool = false) throws -> Float {
        let renderer = try #require(VisualizerRenderer(), "no Metal device")
        var settings = VisualizerSettings()
        settings.style = .meters
        settings.meterKind = kind
        settings.sensitivity = Double(sensitivity)
        renderer.settings = settings
        var c = VisualizerAnalyzer.Configuration()
        c.sensitivity = sensitivity
        let analyzer = VisualizerAnalyzer(configuration: c)
        let rate = 48_000.0
        let x = VisualizerAnalyzerTests.sine(1000, amplitude: amplitude, rate: rate, frames: VisualizerAnalyzer.fftSize(for: rate))
        var pixels: [UInt8] = []
        for _ in 0..<frames {
            let frame = analyzer.process(left: x, right: x, sampleRate: rate, fresh: true, dt: 1 / 60)
            pixels = try #require(renderer.renderOffscreen(frame: frame, scene: VisualizerScene(), size: Self.size, scale: 1, dt: 1 / 60))
        }
        let face = VisualizerLayout.meterFaces(in: Self.size)[right ? 1 : 0]
        let x0 = Int(face.maxX - 0.09 * face.height), y0 = Int(face.minY + 0.1 * face.height)
        let i = (y0 * Int(Self.size.width) + x0) * 4
        // BGRA.
        return Float(pixels[i + 2]) / 255
    }

    @Test("A full-scale signal lights the VU's peak light", arguments: [VisualizerMeterKind.vu, .ppm])
    func lightsOnFullScale(kind: VisualizerMeterKind) throws {
        let off = try Self.lightRed(kind: kind, amplitude: 0.05)
        let on = try Self.lightRed(kind: kind, amplitude: 1)
        #expect(off < 0.3, "off \(off)")
        #expect(on > 0.8, "on \(on)")
        #expect(try Self.lightRed(kind: kind, amplitude: 1, right: true) > 0.8)
    }

    @Test("The sensitivity slider raises the light's reach with the display's gain")
    func followsSensitivity() throws {
        // -10.5 dBFS peaks: dark at unity, lit with the slider up 12 dB.
        #expect(try Self.lightRed(kind: .vu, amplitude: 0.3) < 0.3)
        #expect(try Self.lightRed(kind: .vu, amplitude: 0.3, sensitivity: 4) > 0.8)
        #expect(try Self.lightRed(kind: .vu, amplitude: 0.3, sensitivity: 2) < 0.3)
    }

    @Test("Turning the slider down never hides a real clip")
    func clipStillShows() throws {
        #expect(try Self.lightRed(kind: .vu, amplitude: 1, sensitivity: 0.25) > 0.8)
    }
}
