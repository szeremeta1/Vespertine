//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
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

    @Test("Defaults: bars in brass, no strobe")
    func defaultsAreQuiet() {
        let s = VisualizerSettings.load(from: defaults())
        #expect(s == VisualizerSettings())
        #expect(s.style == .bars && s.theme == .brass && !s.strobe && s.decibelScale && s.peakCaps)
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
        s.showsTrackInfo = false
        s.save(to: d)
        #expect(VisualizerSettings.load(from: d) == s)
    }

    @Test("Missing, unknown and out-of-range values fall back or are pulled into range")
    func lenient() throws {
        let d = defaults()
        d.set(#"{"style":"lava-lamp","theme":"ice","sensitivity":99,"bandCount":70,"rpm":78,"spectrogramSeconds":-3}"#.data(using: .utf8),
              forKey: VisualizerSettings.defaultsKey)
        let s = VisualizerSettings.load(from: d)
        #expect(s.style == .bars)
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
