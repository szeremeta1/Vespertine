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

    /// The red of a meter's peak light (top right of its face), 1x scale, after `frames` frames of a 1 kHz sine at
    /// `amplitude` (with one full-scale sample in it when `spike`), the meters' reference fixed at `reference` dBFS.
    static func lightRed(kind: VisualizerMeterKind, amplitude: Float, sensitivity: Float = 1, reference: Float? = nil,
                         spike: Bool = false, frames: Int = 1, right: Bool = false) throws -> Float {
        let renderer = try #require(VisualizerRenderer(), "no Metal device")
        var settings = VisualizerSettings()
        settings.style = .meters
        settings.meterKind = kind
        settings.sensitivity = Double(sensitivity)
        renderer.settings = settings
        var c = VisualizerAnalyzer.Configuration()
        c.sensitivity = sensitivity
        c.meterReferenceDB = reference
        let analyzer = VisualizerAnalyzer(configuration: c)
        let rate = 48_000.0
        var x = VisualizerAnalyzerTests.sine(1000, amplitude: amplitude, rate: rate, frames: VisualizerAnalyzer.fftSize(for: rate))
        if spike { x[x.count - 100] = 1 }
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

    /// A sine's peak amplitude that reads `vu` dB on a meter whose reference is -18 dBFS (RMS): 0 VU is a -15 dBFS peak.
    static func amplitude(vu: Float) -> Float { pow(10, (-15 + vu) / 20) }

    @Test("A full-scale signal lights the peak light", arguments: [VisualizerMeterKind.vu, .ppm])
    func lightsOnFullScale(kind: VisualizerMeterKind) throws {
        let off = try Self.lightRed(kind: kind, amplitude: 0.05)
        let on = try Self.lightRed(kind: kind, amplitude: 1)
        #expect(off < 0.3, "off \(off)")
        #expect(on > 0.8, "on \(on)")
        #expect(try Self.lightRed(kind: kind, amplitude: 1, right: true) > 0.8)
    }

    @Test("The needle in the red lights the light with no clip: from 0 VU on the VU, from mark 6 on the PPM")
    func needleInRed() throws {
        // +2 VU is a -13 dBFS peak; +10 dB is PPM 6½ at -5 dBFS. Neither clips.
        #expect(try Self.lightRed(kind: .vu, amplitude: Self.amplitude(vu: 2), reference: -18, frames: 90) > 0.8)
        #expect(try Self.lightRed(kind: .vu, amplitude: Self.amplitude(vu: 2), reference: -18, frames: 90, right: true) > 0.8)
        #expect(try Self.lightRed(kind: .ppm, amplitude: Self.amplitude(vu: 10), reference: -18, frames: 90) > 0.8)
    }

    @Test("The needle below the red, with no clip, leaves the light dark")
    func needleBelowRed() throws {
        // -6 VU on the VU; +4 dB (PPM 5) on the PPM.
        #expect(try Self.lightRed(kind: .vu, amplitude: Self.amplitude(vu: -6), reference: -18, frames: 90) < 0.3)
        #expect(try Self.lightRed(kind: .ppm, amplitude: Self.amplitude(vu: 4), reference: -18, frames: 90) < 0.3)
    }

    @Test("The slider moves the needle, and the light with it")
    func followsSensitivity() throws {
        // A -6 VU tone against -18 dBFS: dark. With the slider at 4x the reference drops 12 dB and the needle reads
        // +6 VU, into the red (the peak is at -21 dBFS, no clip).
        let a = Self.amplitude(vu: -6)
        #expect(try Self.lightRed(kind: .vu, amplitude: a, reference: -18, frames: 90) < 0.3)
        #expect(try Self.lightRed(kind: .vu, amplitude: a, sensitivity: 4, reference: -18, frames: 90) > 0.8)
    }

    @Test("A true clip lights the light with the slider down and the needle low")
    func clipStillShows() throws {
        // Quiet music (-40 dBFS) with one full-scale sample, the slider at 0.25x: the needle is nowhere near the red.
        for kind in [VisualizerMeterKind.vu, .ppm] {
            #expect(try Self.lightRed(kind: kind, amplitude: 0.01, sensitivity: 0.25, reference: -18, spike: true) > 0.8)
            #expect(try Self.lightRed(kind: kind, amplitude: 0.01, sensitivity: 0.25, reference: -18) < 0.3)
        }
        #expect(try Self.lightRed(kind: .vu, amplitude: 1, sensitivity: 0.25) > 0.8)
    }

    @Test("peakLit: needle in the red or a clip, nothing else")
    func peakLitRules() {
        let quiet = SIMD2<Float>(-30, -30)
        let zero = Float(VisualizerMeters.zeroVU) * 1.001
        let low = SIMD2<Float>(0.3, 0.3), ppmLow = SIMD2<Float>(0, 0)
        func lit(_ peak: SIMD2<Float>, _ vu: SIMD2<Float>, _ ppm: SIMD2<Float>, _ kind: VisualizerMeterKind) -> [Bool] {
            let r = VisualizerRenderer.peakLit(peakDB: peak, vu: vu, ppm: ppm, kind: kind)
            return [r.x, r.y]
        }
        #expect(lit(quiet, low, ppmLow, .vu) == [false, false])
        #expect(lit(quiet, SIMD2(zero, 0.3), ppmLow, .vu) == [true, false])
        #expect(lit(quiet, SIMD2(0.3, 1.08), ppmLow, .vu) == [false, true])
        #expect(lit(SIMD2(-1, -1.5), low, ppmLow, .vu) == [true, false])
        // The PPM reads its own value, not the VU's: mark 6 is +8 dB.
        #expect(lit(quiet, SIMD2(1, 1), SIMD2(7.9, 8), .ppm) == [false, true])
        #expect(lit(quiet, low, SIMD2(0, 0), .ppm) == [false, false])
        #expect(lit(SIMD2(-0.5, -30), low, ppmLow, .ppm) == [true, false])
    }
}
