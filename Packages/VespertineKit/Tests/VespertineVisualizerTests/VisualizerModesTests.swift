//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer modes: settings")
struct VisualizerModeSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "VisualizerModeSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func load(_ json: String) -> VisualizerSettings {
        let d = defaults()
        d.set(json.data(using: .utf8), forKey: VisualizerSettings.defaultsKey)
        return VisualizerSettings.load(from: d)
    }

    @Test("Defaults: Spectrum and Club as they were, the cover on the label")
    func defaultModes() {
        let s = VisualizerSettings()
        #expect(s.spectrumMode == .classic && s.clubMode == .classic && s.vinylCover == .label)
        #expect(VisualizerSpectrumMode.allCases == [.classic, .noPeaks, .smooth])
        #expect(VisualizerClubMode.allCases == [.classic, .waves])
        #expect(VisualizerVinylCover.allCases == [.label, .sleeveFront, .sleeveBehind])
    }

    @Test("Each mode and cover placement is saved and comes back",
          arguments: VisualizerSpectrumMode.allCases, VisualizerVinylCover.allCases)
    func roundTrip(spectrum: VisualizerSpectrumMode, cover: VisualizerVinylCover) {
        for club in VisualizerClubMode.allCases {
            let d = defaults()
            var s = VisualizerSettings()
            s.spectrumMode = spectrum
            s.clubMode = club
            s.vinylCover = cover
            s.save(to: d)
            let back = VisualizerSettings.load(from: d)
            #expect(back == s)
            #expect(back.spectrumMode == spectrum && back.clubMode == club && back.vinylCover == cover)
        }
    }

    @Test("Settings from before the modes: Spectrum without peak caps stays without them")
    func migratesPeakCaps() {
        // Peak Caps used to be one switch for Spectrum and Mirrored.
        let off = load(#"{"style":"bars","peakCaps":false}"#)
        #expect(off.spectrumMode == .noPeaks && !off.peakCaps)
        let on = load(#"{"style":"bars","peakCaps":true}"#)
        #expect(on.spectrumMode == .classic && on.peakCaps)
        #expect(load(#"{"style":"bars"}"#).spectrumMode == .classic)
        // Once there's a mode, it's the mode that counts, and Mirrored keeps its own switch.
        let both = load(#"{"peakCaps":false,"spectrumMode":"smooth"}"#)
        #expect(both.spectrumMode == .smooth && !both.peakCaps)
        #expect(load(#"{"peakCaps":true,"spectrumMode":"noPeaks"}"#).spectrumMode == .noPeaks)
    }

    @Test("Unknown modes fall back to the defaults, and leave everything else alone")
    func unknownModes() {
        let s = load(#"{"style":"club","theme":"neon","spectrumMode":"wobbly","clubMode":"disco","vinylCover":"gatefold"}"#)
        #expect(s.spectrumMode == .classic && s.clubMode == .classic && s.vinylCover == .label)
        #expect(s.style == .club && s.theme == .neon)
        let wrongType = load(#"{"spectrumMode":3,"clubMode":true,"vinylCover":null}"#)
        #expect(wrongType.spectrumMode == .classic && wrongType.clubMode == .classic && wrongType.vinylCover == .label)
    }

    @Test("A click on the cover goes label, sleeve in front, sleeve behind, and round again")
    func coverCycle() {
        #expect(VisualizerVinylCover.label.next == .sleeveFront)
        #expect(VisualizerVinylCover.sleeveFront.next == .sleeveBehind)
        #expect(VisualizerVinylCover.sleeveBehind.next == .label)
        for c in VisualizerVinylCover.allCases { #expect(c.next.next.next == c) }
        #expect(Set(VisualizerVinylCover.allCases.map(\.next)).count == 3)
    }

    @Test("The record's speed is still 33⅓ by default and only 33⅓ or 45")
    func speedUntouched() {
        #expect(VisualizerSettings().rpm == 100.0 / 3)
        #expect(load(#"{"rpm":40,"vinylCover":"sleeveBehind"}"#).rpm == 100.0 / 3)
        #expect(load(#"{"rpm":45,"vinylCover":"sleeveBehind"}"#).rpm == 45)
    }
}

@Suite("Visualizer modes: motion")
struct VisualizerMotionTests {
    @Test("A critically damped spring gets there without overshooting, and moves the same at any frame rate")
    func spring() {
        var a = CriticalSpring(0), b = CriticalSpring(0)
        var last = 0.0
        for _ in 0..<60 {
            a.step(toward: 1, omega: 20, dt: 1.0 / 60)
            #expect(a.value >= last && a.value <= 1)
            last = a.value
        }
        for _ in 0..<120 { b.step(toward: 1, omega: 20, dt: 1.0 / 120) }
        #expect(abs(a.value - b.value) < 1e-9 && abs(a.velocity - b.velocity) < 1e-9)
        // 90 % of the way in about 3.89 / omega.
        var c = CriticalSpring(0)
        c.step(toward: 1, omega: 20, dt: 3.89 / 20)
        #expect(abs(c.value - 0.9) < 0.001)
        // Not finite: it lands on the target rather than spreading NaNs.
        var d = CriticalSpring(.nan)
        d.step(toward: 0.4, omega: 20, dt: 0.01)
        #expect(d.value == 0.4 && d.velocity == 0)
    }

    @Test("Smooth spectrum: blurred across neighbours, a flat spectrum stays flat")
    func blur() {
        var out: [Double] = []
        VisualizerSpectrumSmoother.blur([0, 0, 0, 1, 0, 0, 0], into: &out)
        #expect(out.map { ($0 * 16).rounded() } == [0, 1, 4, 6, 4, 1, 0])
        VisualizerSpectrumSmoother.blur([Float](repeating: 0.5, count: 9), into: &out)
        #expect(out.allSatisfy { abs($0 - 0.5) < 1e-12 })
        VisualizerSpectrumSmoother.blur([.nan, .infinity, 2, -1], into: &out)
        #expect(out.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    @Test("Smooth spectrum: rises softly, falls slower, never overshoots, the same at 60 and 120 frames a second")
    func smoother() {
        let n = 32
        let quiet = [Float](repeating: 0, count: n), loud = [Float](repeating: 0.8, count: n)
        var s60 = VisualizerSpectrumSmoother(), s120 = VisualizerSpectrumSmoother()
        #expect(s60.step(quiet, dt: 1.0 / 60, calm: false) == quiet)   // the first frame starts where the music is
        _ = s120.step(quiet, dt: 1.0 / 120, calm: false)
        var last: Float = 0
        var risen: Double?
        for frame in 1...60 {
            let v = s60.step(loud, dt: 1.0 / 60, calm: false)[n / 2]
            _ = s120.step(loud, dt: 1.0 / 120, calm: false)
            _ = s120.step(loud, dt: 1.0 / 120, calm: false)
            #expect(v >= last && v <= 0.8 + 1e-6, "frame \(frame)")
            last = v
            if risen == nil && v >= 0.72 { risen = Double(frame) / 60 }
        }
        #expect(abs(s60.values[n / 2] - s120.values[n / 2]) < 1e-5)
        // Softer than the analyzer's own bars (15 ms) but still prompt: 90 % in about 0.18 s.
        let rise = try! #require(risen)
        #expect(rise > 0.12 && rise < 0.25, "\(rise) s")
        var fallen: Double?
        for frame in 1...120 {
            let v = s60.step(quiet, dt: 1.0 / 60, calm: false)[n / 2]
            #expect(v <= last && v >= 0)
            last = v
            if fallen == nil && v <= 0.08 { fallen = Double(frame) / 60 }
        }
        let fall = try! #require(fallen)
        #expect(fall > rise * 1.8 && fall < 0.6, "\(fall) s")
    }

    @Test("Smooth spectrum: calmer still with Reduce Motion, and a new band count starts afresh")
    func smootherCalmAndCounts() {
        var a = VisualizerSpectrumSmoother(), b = VisualizerSpectrumSmoother()
        let quiet = [Float](repeating: 0, count: 64), loud = [Float](repeating: 1, count: 64)
        _ = a.step(quiet, dt: 1.0 / 60, calm: false)
        _ = b.step(quiet, dt: 1.0 / 60, calm: true)
        for _ in 0..<6 {
            _ = a.step(loud, dt: 1.0 / 60, calm: false)
            _ = b.step(loud, dt: 1.0 / 60, calm: true)
        }
        #expect(b.values[10] < a.values[10] * 0.75)
        let fewer = a.step([Float](repeating: 0.3, count: 32), dt: 1.0 / 60, calm: false)
        #expect(fewer.count == 32 && fewer.allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(a.step([], dt: 1.0 / 60, calm: false).isEmpty)
        // A long stall (a window that was covered) doesn't throw it off.
        let after = a.step([Float](repeating: 0.6, count: 32), dt: 30, calm: false)
        #expect(after.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    /// Runs the cover toward `target` for `seconds`, checking at every frame that the sleeve never changes sides
    /// where it could be seen passing through the record (over it in the frames before and after).
    private func run(_ m: inout VisualizerCoverMotion, to target: VisualizerVinylCover, seconds: Double, calm: Bool = false,
                     fps: Double = 60) {
        for _ in 0..<Int(seconds * fps) {
            let before = m.pose
            let overlapped = m.overlapsRecord
            m.advance(toward: target, dt: 1 / fps, calm: calm)
            // Changing sides is only seen if the sleeve is over the record both before and after.
            if !calm && before.front != m.pose.front {
                #expect(!overlapped || !m.overlapsRecord, "the sleeve changed sides over the record: \(before) → \(m.pose)")
            }
            #expect(m.pose.opacity >= 0 && m.pose.opacity <= 1 && m.pose.layout >= 0 && m.pose.layout <= 1)
        }
    }

    @Test("The sleeve slides in, changes sides clear of the record, and slides out, settling each time")
    func coverMotion() {
        var m = VisualizerCoverMotion(.label)
        #expect(m.pose == VisualizerCoverPose.label)
        run(&m, to: .sleeveFront, seconds: 1)
        #expect(abs(m.pose.layout - 1) < 1e-3 && abs(m.pose.opacity - 1) < 1e-3 && abs(m.pose.offset) < 1e-3 && m.pose.front == 1)
        // Front to behind: pulled out left, past the platter, before it changes sides.
        var deepest = 0.0
        var probe = m
        for _ in 0..<90 {
            probe.advance(toward: .sleeveBehind, dt: 1.0 / 60, calm: false)
            deepest = min(deepest, probe.pose.offset)
        }
        #expect(deepest <= VisualizerCoverMotion.clear)
        run(&m, to: .sleeveBehind, seconds: 1.5)
        #expect(m.pose.front == 0 && abs(m.pose.offset) < 1e-3 && abs(m.pose.opacity - 1) < 1e-3)
        run(&m, to: .label, seconds: 1.5)
        #expect(m.pose.opacity < 1e-3 && m.pose.layout < 1e-3)
        // Clicked again while it's still moving, it goes where it was last asked.
        run(&m, to: .sleeveFront, seconds: 0.1)
        run(&m, to: .sleeveBehind, seconds: 0.1)
        run(&m, to: .label, seconds: 0.1)
        run(&m, to: .sleeveFront, seconds: 0.15)
        run(&m, to: .sleeveBehind, seconds: 2)
        #expect(m.pose.front == 0 && abs(m.pose.offset) < 1e-3 && abs(m.pose.opacity - 1) < 1e-3 && abs(m.pose.layout - 1) < 1e-3)
    }

    @Test("Reduce Motion: nothing slides; the layout changes at once and the sleeve fades")
    func coverCalm() {
        var m = VisualizerCoverMotion(.label)
        m.advance(toward: .sleeveFront, dt: 1.0 / 60, calm: true)
        #expect(m.pose.layout == 1 && m.pose.offset == 0 && m.pose.front == 1 && m.pose.opacity > 0 && m.pose.opacity < 0.2)
        for _ in 0..<30 {
            m.advance(toward: .sleeveFront, dt: 1.0 / 60, calm: true)
            #expect(m.pose.offset == 0)
        }
        #expect(m.pose.opacity == 1)
        // Front to behind: a dissolve where it lies.
        m.advance(toward: .sleeveBehind, dt: 1.0 / 60, calm: true)
        #expect(m.pose.front > 0 && m.pose.front < 1 && m.pose.offset == 0)
        for _ in 0..<30 { m.advance(toward: .sleeveBehind, dt: 1.0 / 60, calm: true) }
        #expect(m.pose.front == 0 && m.pose.offset == 0)
        m.advance(toward: .label, dt: 1.0 / 60, calm: true)
        #expect(m.pose.layout == 0 && m.pose.offset == 0)
        for _ in 0..<30 { m.advance(toward: .label, dt: 1.0 / 60, calm: true) }
        #expect(m.pose.opacity == 0)
    }

    @Test("Settled where it was left, with no motion (the window opening, another style shown)")
    func coverSettle() {
        for c in VisualizerVinylCover.allCases {
            let m = VisualizerCoverMotion(c)
            #expect(m.pose.layout == (c == .label ? 0 : 1) && m.pose.opacity == (c == .label ? 0 : 1))
            #expect(m.pose.front == (c == .sleeveBehind ? 0 : 1))
            var still = m
            still.advance(toward: c, dt: 1.0 / 60, calm: false)
            #expect(abs(still.pose.offset - m.pose.offset) < 1e-9 && abs(still.pose.layout - m.pose.layout) < 1e-9)
        }
    }
}

@Suite("Visualizer modes: layout")
struct VisualizerVinylLayoutTests {
    static let sizes = [CGSize(width: 1280, height: 720), CGSize(width: 480, height: 300), CGSize(width: 600, height: 900),
                        CGSize(width: 2560, height: 1080), CGSize(width: 3024, height: 1964), CGSize(width: 900, height: 900)]

    @Test("On the label, the turntable is exactly where it always was")
    func labelLayoutUnchanged() {
        for size in Self.sizes {
            for arm in [true, false] {
                let l = VisualizerLayout.vinyl(in: size, tonearm: arm, sleeve: 0)
                let unit = 0.5 * min(size.width, size.height) * 0.92
                #expect(abs(l.unit - unit) < 1e-9)
                #expect(abs(l.centre.x - (size.width * 0.5 - (arm ? unit * 0.18 * min(1, size.width / size.height) : 0))) < 1e-9)
                #expect(abs(l.centre.y - size.height * 0.5) < 1e-9)
            }
        }
    }

    @Test("With the sleeve, everything fits the window: sleeve, record, light ring and tonearm")
    func sleeveFits() {
        for size in Self.sizes {
            for arm in [true, false] {
                let l = VisualizerLayout.vinyl(in: size, tonearm: arm, sleeve: 1)
                let left = l.centre.x + (VisualizerLayout.sleeveCentre - VisualizerLayout.sleeveHalf) * l.unit
                let right = l.centre.x + (arm ? VisualizerLayout.armReach : VisualizerLayout.ringReach) * l.unit
                #expect(left >= 0 && right <= size.width, "\(size) arm \(arm): \(left)…\(right)")
                #expect(l.centre.y - l.unit >= 0 && l.centre.y + l.unit <= size.height, "\(size)")
                // Never larger than without the sleeve.
                #expect(l.unit <= VisualizerLayout.vinyl(in: size, tonearm: arm, sleeve: 0).unit + 1e-9)
            }
        }
        // Halfway, it's between the two.
        let size = CGSize(width: 1280, height: 720)
        let a = VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: 0), b = VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: 1)
        let m = VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: 0.5)
        #expect(m.centre.x > min(a.centre.x, b.centre.x) && m.centre.x < max(a.centre.x, b.centre.x))
        // Nonsense in, the label layout out.
        #expect(VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: .nan) == a)
    }

    /// A point in the window at (x, y) in the record's own units (y up), for a layout.
    private func point(_ x: CGFloat, _ y: CGFloat, _ l: (centre: CGPoint, unit: CGFloat)) -> CGPoint {
        CGPoint(x: l.centre.x + x * l.unit, y: l.centre.y - y * l.unit)
    }

    @Test("A click lands on the cover: the label always; the sleeve as much of it as shows")
    func hitTest() {
        let size = CGSize(width: 1280, height: 720)
        let label = VisualizerCoverMotion(.label).pose, front = VisualizerCoverMotion(.sleeveFront).pose
        let behind = VisualizerCoverMotion(.sleeveBehind).pose
        let l0 = VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: 0), l1 = VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: 1)
        func hit(_ p: CGPoint, _ pose: VisualizerCoverPose) -> Bool { VisualizerLayout.vinylCoverHit(p, in: size, tonearm: true, pose: pose) }
        // The label.
        #expect(hit(point(0.2, 0.1, l0), label))
        #expect(hit(point(0.25, -0.1, l1), front) && hit(point(0.25, -0.1, l1), behind))
        // The grooves, the platter, the background: not the cover.
        #expect(!hit(point(0.6, 0, l0), label))
        #expect(!hit(point(-1.3, 0, l0), label))
        #expect(!hit(CGPoint(x: 4, y: 4), label))
        // The sleeve's left half shows either way; its right half only in front of the record.
        #expect(hit(point(-1.4, 0.5, l1), front) && hit(point(-1.4, 0.5, l1), behind))
        #expect(hit(point(-0.5, 0.2, l1), front))
        #expect(!hit(point(-0.5, 0.2, l1), behind))
        // Past the sleeve's edge, or below it.
        #expect(!hit(point(-1.85, 0, l1), front))
        #expect(!hit(point(-1.0, -0.95, l1), front))
    }
}

@Suite("Visualizer modes: drawing")
@MainActor
struct VisualizerModeRenderTests {
    private func musicFrame() -> VisualizerFrame {
        var frame = VisualizerFrame.silent(bands: 64, fine: 512)
        frame.bands = (0..<64).map { 0.25 + 0.5 * Float(abs(sin(Double($0) * 0.37))) }
        frame.peaks = frame.bands.map { min(1, $0 + 0.15) }
        frame.fine = (0..<512).map { 0.2 + 0.6 * Float(abs(sin(Double($0) * 0.05))) }
        frame.hasSignal = true
        frame.bass = 0.7
        frame.mid = 0.6
        frame.treble = 0.5
        frame.beatPulse = 0.4
        frame.time = 3
        return frame
    }

    private func render(_ configure: (inout VisualizerSettings) -> Void, calm: Bool = false, frames: Int = 30,
                        size: CGSize = CGSize(width: 320, height: 180)) -> [UInt8]? {
        guard let renderer = VisualizerRenderer() else { return nil }
        var s = VisualizerSettings()
        configure(&s)
        renderer.settings = s
        renderer.reduceMotion = calm
        var bytes: [UInt8]?
        let frame = musicFrame()
        for _ in 0..<frames {
            bytes = renderer.renderOffscreen(frame: frame, scene: VisualizerScene(title: "Song", artist: "Artist", progress: 0.3, isPlaying: true),
                                             size: size, scale: 1, dt: 1 / 60)
        }
        return bytes
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 1) { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    @Test("Every new mode draws a picture of its own")
    func newModesDraw() throws {
        guard let classic = render({ $0.style = .bars }) else { return }   // no Metal device
        let noPeaks = try #require(render { $0.style = .bars; $0.spectrumMode = .noPeaks })
        let smooth = try #require(render { $0.style = .bars; $0.spectrumMode = .smooth })
        #expect(difference(classic, noPeaks) > 0.05)
        #expect(difference(classic, smooth) > 0.5)
        #expect(difference(noPeaks, smooth) > 0.5)
        let club = try #require(render { $0.style = .club })
        let waves = try #require(render { $0.style = .club; $0.clubMode = .waves })
        #expect(difference(club, waves) > 2)
        let label = try #require(render { $0.style = .vinyl })
        let front = try #require(render { $0.style = .vinyl; $0.vinylCover = .sleeveFront })
        let behind = try #require(render { $0.style = .vinyl; $0.vinylCover = .sleeveBehind })
        #expect(difference(label, front) > 2 && difference(label, behind) > 2 && difference(front, behind) > 0.5)
        for picture in [noPeaks, smooth, waves, front, behind] {
            #expect(Set(stride(from: 0, to: picture.count, by: 4 * 97).map { picture[$0] }).count > 8)
        }
    }

    @Test("No Peaks and Smooth draw no peak caps, even with Peak Caps (Mirrored's switch) on; Classic draws them even with it off")
    func peakCapsFollowTheMode() throws {
        guard let renderer = VisualizerRenderer() else { return }
        var frame = musicFrame()
        frame.bands = [Float](repeating: 0.2, count: 64)
        frame.peaks = [Float](repeating: 0.8, count: 64)
        // The signal light eases in over a few frames (and Mirrored draws with it): settle it first.
        for _ in 0..<600 {
            _ = renderer.renderOffscreen(frame: frame, scene: VisualizerScene(isPlaying: true), size: CGSize(width: 32, height: 18), scale: 1, dt: 1 / 60)
        }
        func picture(_ mode: VisualizerSpectrumMode, caps: Bool, peaks: [Float]) -> [UInt8] {
            renderer.settings.style = .bars
            renderer.settings.spectrumMode = mode
            renderer.settings.peakCaps = caps
            frame.peaks = peaks
            return renderer.renderOffscreen(frame: frame, scene: VisualizerScene(isPlaying: true), size: CGSize(width: 320, height: 180),
                                            scale: 1, dt: 1 / 60) ?? []
        }
        let none = [Float](repeating: 0, count: 64), high = [Float](repeating: 0.8, count: 64)
        #expect(difference(picture(.noPeaks, caps: true, peaks: none), picture(.noPeaks, caps: true, peaks: high)) == 0)
        #expect(difference(picture(.smooth, caps: true, peaks: none), picture(.smooth, caps: true, peaks: high)) == 0)
        #expect(difference(picture(.classic, caps: false, peaks: none), picture(.classic, caps: false, peaks: high)) > 0.05)
        // Mirrored still follows its switch.
        renderer.settings.style = .mirrored
        func mirrored(caps: Bool, peaks: [Float]) -> [UInt8] {
            renderer.settings.peakCaps = caps
            frame.peaks = peaks
            return renderer.renderOffscreen(frame: frame, scene: VisualizerScene(isPlaying: true), size: CGSize(width: 320, height: 180),
                                            scale: 1, dt: 1 / 60) ?? []
        }
        #expect(difference(mirrored(caps: false, peaks: none), mirrored(caps: false, peaks: high)) == 0)
        #expect(difference(mirrored(caps: true, peaks: none), mirrored(caps: true, peaks: high)) > 0.05)
    }

    @Test("Waves move less from frame to frame with Reduce Motion")
    func wavesCalm() throws {
        func motion(calm: Bool) -> Double? {
            guard let renderer = VisualizerRenderer() else { return nil }
            renderer.settings.style = .club
            renderer.settings.clubMode = .waves
            renderer.reduceMotion = calm
            let frame = musicFrame()   // the same sound every frame: what changes is the motion alone
            var pictures: [[UInt8]] = []
            for _ in 0..<40 {
                pictures.append(renderer.renderOffscreen(frame: frame, scene: VisualizerScene(isPlaying: true), size: CGSize(width: 320, height: 180),
                                                         scale: 1, dt: 1 / 60) ?? [])
            }
            return difference(pictures[30], pictures[39])
        }
        guard let lively = motion(calm: false), let calm = motion(calm: true) else { return }
        #expect(lively > 0.1)
        #expect(calm < lively * 0.6, "calm \(calm), lively \(lively)")
    }

    @Test("The renderer's cover follows the setting, and only the Vinyl style takes clicks on it")
    func rendererCover() throws {
        guard let renderer = VisualizerRenderer() else { return }
        let size = CGSize(width: 640, height: 360)
        renderer.settings.style = .vinyl
        renderer.settings.vinylCover = .sleeveBehind
        _ = renderer.renderOffscreen(frame: musicFrame(), scene: VisualizerScene(isPlaying: true), size: size, scale: 1, dt: 1 / 60)
        // Switched to while another style showed, it's already in place: no slide on the first frame.
        #expect(renderer.coverPose == VisualizerCoverMotion(.sleeveBehind).pose)
        let l = VisualizerLayout.vinyl(in: size, tonearm: true, sleeve: 1)
        #expect(renderer.vinylCoverHit(at: l.centre, in: size))
        renderer.settings.style = .bars
        #expect(!renderer.vinylCoverHit(at: l.centre, in: size))
        // A click (the setting moving on) slides it, and it settles.
        renderer.settings.style = .vinyl
        renderer.settings.vinylCover = renderer.settings.vinylCover.next
        for _ in 0..<90 {
            _ = renderer.renderOffscreen(frame: musicFrame(), scene: VisualizerScene(isPlaying: true), size: CGSize(width: 64, height: 36),
                                         scale: 1, dt: 1 / 60)
        }
        #expect(renderer.coverPose.opacity < 1e-3 && renderer.coverPose.layout < 1e-3)
    }

    @Test("The record turns at 33⅓ RPM whatever the cover does")
    func speedUnchanged() throws {
        // One full turn at 33⅓ RPM takes 1.8 s: the same picture of the record after it (the sleeve still).
        guard let a = render({ $0.style = .vinyl; $0.vinylCover = .sleeveFront; $0.tonearm = false }, frames: 120),
              let b = render({ $0.style = .vinyl; $0.vinylCover = .sleeveFront; $0.tonearm = false }, frames: 120 + 108) else { return }
        #expect(difference(a, b) < 0.5)
    }
}
