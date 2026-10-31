//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import simd
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer settings and window state")
struct VisualizerSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "VisualizerSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Defaults: the spinning record in the Vespertine colours, no strobe, its warning not yet accepted")
    func defaultsAreQuiet() {
        let s = VisualizerSettings.load(from: defaults())
        #expect(s == VisualizerSettings())
        #expect(s.style == .vinyl && s.theme == .vespertine && !s.strobe && !s.strobeWarningAccepted && s.decibelScale && s.peakCaps)
        #expect(s.scopeMode == .goniometer && s.meterKind == .vu && s.meterReference == nil && s.mirrorLayout == .circle && s.particleTrails)
        #expect(VisualizerTheme.allCases.first == .vespertine)
    }

    @Test("The Vespertine theme is the app's own palette: obsidian surface, copper, brass and ivory")
    func vespertineTheme() {
        // App/Sources/Theme/Theme.swift, site/src/styles/global.css and docs/brand: surface #16161A, copper #C98B5B,
        // brass #C8A66A, ivory #ECE6DA.
        #expect(VisualizerTheme.vespertine.stops == [0x16161A, 0xC98B5B, 0xC8A66A, 0xECE6DA].map(VisualizerTheme.rgb))
        #expect(Set(VisualizerTheme.allCases.map(\.stops)).count == VisualizerTheme.allCases.count)
    }

    @Test("The strobe can't be on until its warning is accepted, even from a hand-edited file")
    func strobeNeedsTheWarning() {
        let d = defaults()
        d.set(#"{"style":"club","strobe":true}"#.data(using: .utf8), forKey: VisualizerSettings.defaultsKey)
        #expect(!VisualizerSettings.load(from: d).strobe)
        d.set(#"{"style":"club","strobe":true,"strobeWarningAccepted":true}"#.data(using: .utf8), forKey: VisualizerSettings.defaultsKey)
        #expect(VisualizerSettings.load(from: d).strobe)
        var s = VisualizerSettings()
        s.strobe = true
        #expect(!s.normalized.strobe)
    }

    @Test("Everything chosen comes back")
    func roundTrip() {
        let d = defaults()
        var s = VisualizerSettings()
        s.style = .vinyl
        s.theme = .neon
        s.sensitivity = 2.5
        s.decibelScale = false
        s.bandCount = 96
        s.peakCaps = false
        s.spectrogramSeconds = 20
        s.tonearm = false
        s.rpm = 45
        s.strobe = true
        s.strobeWarningAccepted = true
        s.showsTrackInfo = false
        s.scopeMode = .oscilloscope
        s.meterKind = .ppm
        s.meterReference = -14
        s.mirrorLayout = .line
        s.particleTrails = false
        s.save(to: d)
        #expect(VisualizerSettings.load(from: d) == s)
    }

    @Test("Missing, unknown and out-of-range values fall back or are pulled into range")
    func lenient() throws {
        let d = defaults()
        d.set(#"{"style":"lava-lamp","theme":"ice","sensitivity":99,"bandCount":70,"rpm":78,"spectrogramSeconds":-3,"meterReference":-15,"meterKind":"led"}"#.data(using: .utf8),
              forKey: VisualizerSettings.defaultsKey)
        let s = VisualizerSettings.load(from: d)
        #expect(s.style == .vinyl)
        #expect(s.meterReference == -14)
        #expect(s.meterKind == .vu)
        #expect(s.theme == .ice)
        #expect(s.sensitivity == 4)
        #expect(s.bandCount == 64)
        #expect(s.rpm == 45)
        #expect(s.spectrogramSeconds == 4)
        #expect(s.tonearm)
        d.set(Data("not json".utf8), forKey: VisualizerSettings.defaultsKey)
        #expect(VisualizerSettings.load(from: d) == VisualizerSettings())
    }

    static let main = VisualizerWindowState.Display(id: 1, name: "Built-in Retina Display",
                                                    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))
    static let side = VisualizerWindowState.Display(id: 7, name: "LG UltraFine",
                                                    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                                    visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    @Test("Back on the display it was on, where it was")
    func sameDisplay() {
        let state = VisualizerWindowState(frame: CGRect(x: 2000, y: 200, width: 1600, height: 900), displayID: 7,
                                          displayName: "LG UltraFine", fullScreen: true)
        let placed = state.placement(among: [Self.main, Self.side])
        #expect(placed?.display == Self.side)
        #expect(placed?.frame == state.frame)
    }

    @Test("The same display under a new ID is found by its name")
    func byName() {
        let state = VisualizerWindowState(frame: CGRect(x: 2000, y: 200, width: 1600, height: 900), displayID: 3,
                                          displayName: "LG UltraFine", fullScreen: false)
        #expect(state.placement(among: [Self.main, Self.side])?.display == Self.side)
    }

    @Test("Its display gone, it opens centred on the main display, shrunk to fit")
    func displayGone() {
        let state = VisualizerWindowState(frame: CGRect(x: 2000, y: 200, width: 1600, height: 900), displayID: 7,
                                          displayName: "LG UltraFine", fullScreen: true)
        let placed = state.placement(among: [Self.main])
        #expect(placed?.display == Self.main)
        #expect(placed?.frame == CGRect(x: 0, y: 22, width: 1512, height: 900))
    }

    @Test("A frame partly off its display is moved back on, and a tiny one grows to the minimum")
    func keptOnScreen() {
        let state = VisualizerWindowState(frame: CGRect(x: 1300, y: -100, width: 800, height: 500), displayID: 1,
                                          displayName: nil, fullScreen: false)
        #expect(state.placement(among: [Self.main])?.frame == CGRect(x: 712, y: 0, width: 800, height: 500))
        let tiny = VisualizerWindowState(frame: CGRect(x: 10, y: 10, width: 20, height: 20), displayID: 1, displayName: nil, fullScreen: false)
        #expect(tiny.placement(among: [Self.main])?.frame.size == VisualizerWindowState.minimumSize)
        #expect(state.placement(among: []) == nil)
    }

    @Test("The window state round-trips through the defaults")
    func windowRoundTrip() {
        let d = defaults()
        #expect(VisualizerWindowState.load(from: d) == nil)
        let state = VisualizerWindowState(frame: CGRect(x: 1, y: 2, width: 800, height: 600), displayID: 9, displayName: "TV", fullScreen: true)
        state.save(to: d)
        #expect(VisualizerWindowState.load(from: d) == state)
    }

    @Test("Each theme has four colours from dark to bright")
    func themes() {
        for theme in VisualizerTheme.allCases {
            let luminance = theme.stops.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }
            #expect(theme.stops.count == 4)
            #expect(luminance == luminance.sorted(), "\(theme)")
        }
    }
}

@Suite("Visualizer renderer")
@MainActor
struct VisualizerRendererTests {
    @Test("Every style renders a picture, offscreen", arguments: VisualizerStyle.allCases)
    func renders(style: VisualizerStyle) throws {
        guard let renderer = VisualizerRenderer() else { return }   // no Metal device (CI without a GPU)
        renderer.settings.style = style
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.bands = (0..<64).map { Float($0) / 64 }
        frame.peaks = frame.bands
        frame.fine = (0..<512).map { Float($0) / 512 }
        frame.hasSignal = true
        frame.bass = 0.8
        frame.beat = true
        frame.stereo = (0..<VisualizerFrame.stereoCount).map { SIMD2(Float(sin(Double($0) * 0.03)), Float(cos(Double($0) * 0.05))) * 0.4 }
        frame.vu = SIMD2(0.6, 0.7)
        var bytes: [UInt8]?
        for _ in 0..<10 {
            bytes = renderer.renderOffscreen(frame: frame, scene: VisualizerScene(title: "Song", artist: "Artist", progress: 0.3, isPlaying: true),
                                             size: CGSize(width: 320, height: 180), scale: 1, dt: 1 / 60)
        }
        let pixels = try #require(bytes)
        #expect(pixels.count == 320 * 180 * 4)
        // Not one flat colour: something was drawn.
        let distinct = Set(stride(from: 0, to: pixels.count, by: 4 * 97).map { pixels[$0] })
        #expect(distinct.count > 8)
    }

    @Test("The strobe flashes only when on, accepted, and neither Reduce Motion nor Dim Flashing Lights is on")
    func strobeGate() throws {
        guard let renderer = VisualizerRenderer() else { return }
        renderer.settings.style = .club
        renderer.settings.strobe = true
        #expect(!renderer.strobeAllowed)
        renderer.settings.strobeWarningAccepted = true
        #expect(renderer.strobeAllowed)
        renderer.reduceMotion = true
        #expect(!renderer.strobeAllowed)
        renderer.reduceMotion = false
        renderer.reduceFlashing = true
        #expect(!renderer.strobeAllowed)
    }

    @Test("Goniometer: mono is upright, left alone leans left, right alone leans right, out of phase lies across")
    func goniometer() {
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        let size = CGSize(width: 800, height: 600)
        let g = VisualizerLayout.goniometer(in: size)
        func points(_ l: Float, _ r: Float) -> [SIMD4<Float>] {
            frame.stereo = (0..<VisualizerFrame.stereoCount).map { i in
                let s = Float(sin(Double(i) * 0.05)) * 0.5
                return SIMD2(s * l, s * r)
            }
            var out: [SIMD4<Float>] = []
            VisualizerRenderer.scopePoints(frame: frame, mode: .goniometer, size: size, scale: 1, gain: 1, brightness: 1, into: &out)
            return out
        }
        func direction(_ p: [SIMD4<Float>]) -> SIMD2<Float> {
            // The point farthest up (or, if flat, farthest right), from the centre.
            let c = SIMD2(Float(g.centre.x), Float(g.centre.y))
            let far = p.max { simd_length(SIMD2($0.x, $0.y) - c) < simd_length(SIMD2($1.x, $1.y) - c) }!
            var d = SIMD2(far.x, far.y) - c
            if d.y > 0 || (abs(d.y) < 1e-3 && d.x < 0) { d = -d }
            return simd_normalize(d)
        }
        let mono = direction(points(1, 1)), left = direction(points(1, 0)), right = direction(points(0, 1)), wide = direction(points(1, -1))
        #expect(abs(mono.x) < 1e-3 && mono.y < -0.99)                         // straight up (y down)
        #expect(left.x < -0.7 && left.y < -0.7)                               // up and to the left
        #expect(right.x > 0.7 && right.y < -0.7)                              // up and to the right
        #expect(abs(wide.y) < 1e-3)                                           // across
        #expect(points(1, 1).count == 1024)
    }

    @Test("Oscilloscope: each sweep starts on a rising zero crossing, left above right")
    func oscilloscope() {
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.stereo = (0..<VisualizerFrame.stereoCount).map { i in
            let s = Float(sin(Double(i) * 2 * .pi / 100 + 1.0)) * 0.5
            return SIMD2(s, s)
        }
        let size = CGSize(width: 800, height: 600)
        let screen = VisualizerLayout.oscilloscope(in: size)
        var out: [SIMD4<Float>] = []
        VisualizerRenderer.scopePoints(frame: frame, mode: .oscilloscope, size: size, scale: 1, gain: 1, brightness: 1, into: &out)
        #expect(out.count == 2048)
        let leftZero = Float(screen.minY + screen.height * 0.25)
        #expect(abs(out[0].y - leftZero) < 5)                                  // starts at zero…
        #expect(out[5].y < leftZero)                                          // …going up
        #expect(out[0].w == 1 && out[1024].w == 2 && out[1024].y > out[0].y)
        #expect(abs(screen.width / screen.height - 1.25) < 1e-9)
    }

    @Test("Two meters fit the window, side by side when it's wide, one above the other when it's tall")
    func meterLayout() {
        for size in [CGSize(width: 1280, height: 720), CGSize(width: 600, height: 900), CGSize(width: 480, height: 300)] {
            let faces = VisualizerLayout.meterFaces(in: size)
            #expect(faces.count == 2)
            #expect(!faces[0].insetBy(dx: -1, dy: -1).intersects(faces[1].insetBy(dx: -1, dy: -1)))
            for f in faces {
                let b = f.height * VisualizerLayout.bezel
                #expect(f.insetBy(dx: -b, dy: -b).minX >= 0 && f.insetBy(dx: -b, dy: -b).maxX <= size.width, "\(size)")
                #expect(abs(f.width / f.height - VisualizerLayout.meterAspect) < 1e-9)
            }
            #expect(size.width > size.height ? faces[0].minY == faces[1].minY : faces[0].minX == faces[1].minX)
        }
    }

    @Test("The tonearm puts the stylus on the record, at the radius asked for")
    func tonearm() {
        for r in [0.83, 0.6, 0.4] {
            let a = VisualizerRenderer.armAngle(stylusRadius: r)
            let s = VisualizerRenderer.armPivot + VisualizerRenderer.armLength * SIMD2(cos(a), sin(a))
            #expect(abs((s.x * s.x + s.y * s.y).squareRoot() - r) < 1e-9)
            #expect(s.x > 0)   // on the right of the record, under the pivot
        }
    }
}
