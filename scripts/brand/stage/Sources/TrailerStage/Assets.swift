// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Which recording each scene shows, and from where. Scenes stay visible a little past their bar lines
/// so transitions can show both sides.
struct Cue {
    let scene: Scene
    let recording: String
    let sourceStart: Double
    var key: String { "\(recording)@\(sourceStart)" }
    static let overlap = 0.75

    func isVisible(at t: Double) -> Bool {
        t >= scene.range.lowerBound - Cue.overlap && t <= scene.range.upperBound + Cue.overlap
    }

    static let all: [Cue] = [
        // 0.14.2: real recordings on the Fosi Audio ZD3. The inspector glides down to the signal path (Lazar Berman:
        // 1.59-4.44 s, 111 pt; Claudja Barry: 1.47-3.87 s, 84 pt): bit-perfect's glide ends before the push into
        // Now Playing, DSD's before its scene appears, so the lifts and the light land on a still page.
        Cue(scene: .bitPerfect, recording: "bitperfect", sourceStart: 2.5),
        Cue(scene: .dsd, recording: "dsd", sourceStart: 4.7),
        // The Room Correction window (780 × 877 pt) recorded from the 0.14 app: its Curve Reveal starts 3.11 s in, which
        // lands on beat 1.5 of the scene.
        Cue(scene: .room, recording: "room", sourceStart: 1.722),
        Cue(scene: .versions, recording: "versions", sourceStart: 2.0),
        // 0.14.2: Billie Eilish's 7.1 album on AirPods Max, Spatial · head tracked, all eight meters (the same page as the
        // 5.1 recording it replaces; it stays still, only the meters and spectrum move).
        Cue(scene: .spatial, recording: "spatial", sourceStart: 2.0),
        Cue(scene: .analysis, recording: "analysis", sourceStart: 2.0),
        Cue(scene: .languages, recording: "languages", sourceStart: 1.0),
        Cue(scene: .library, recording: "albums", sourceStart: 0.6),
        // The Visualizer window: Spectrum on a Dolby Atmos track rendered by macOS, and Vinyl. The Vinyl recording (~56 fps,
        // uneven) goes through vinyl-even.py first, so its label turns by the same angle on every frame of the trailer.
        Cue(scene: .atmos, recording: "atmos", sourceStart: 3.0),
        Cue(scene: .vinyl, recording: "vinyl", sourceStart: 3.0),
    ]
    static func `for`(_ scene: Scene) -> Cue? { all.first { $0.scene == scene } }
}

/// Stills and derived art, prepared once.
final class Assets {
    let paths: Paths
    let logo: CGImage          // crescent + "vespertine", transparent
    let mark: CGImage          // the crescent alone
    var sidebars: [String: CGImage] = [:]      // keyed sidebar per recording, for floating over glass
    var sidebarColor: [String: Color] = [:]    // the sidebar's own background, to patch the capture indicator
    var poster: [String: CGImage] = [:]        // a representative frame per recording
    var chromeColor: [String: Color] = [:]     // the window's background beside its buttons (the Visualizer has no sidebar)
    let languageWall: CGImage  // Vespertine in every interface language

    init(_ paths: Paths) {
        self.paths = paths
        logo = loadImage(paths.brand.appendingPathComponent("logo.png"))
        mark = loadImage(paths.brand.appendingPathComponent("mark.png"))
        languageWall = loadImage(paths.repo.appendingPathComponent("docs/screenshots/languages-wall.png"))
        for cue in Cue.all {
            let frame = firstFrame(of: paths.recording(cue.recording), at: cue.sourceStart + 0.5)
            poster[cue.recording] = frame
            let bg = sampleColor(frame, at: CGRect(x: 110, y: 14, width: 60, height: 24))
            sidebarColor[cue.recording] = Color(.sRGB, red: bg.r, green: bg.g, blue: bg.b)
            sidebars[cue.recording] = keyedSidebar(frame, background: bg)
            let chrome = sampleColor(frame, at: CGRect(x: 76, y: 2, width: 8, height: 28))
            chromeColor[cue.recording] = Color(.sRGB, red: chrome.r, green: chrome.g, blue: chrome.b)
        }
    }

    /// The sidebar with its capture indicator painted out and its background keyed away.
    private func keyedSidebar(_ frame: CGImage, background bg: (r: Double, g: Double, b: Double)) -> CGImage {
        let side = crop(frame, AppWindow.sidebar)
        let w = side.width, h = side.height, s = CGFloat(w) / AppWindow.sidebar.width
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(side, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Indicator area (window buttons) back to plain sidebar; buttons are redrawn as vectors on top.
        ctx.setFillColor(CGColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        let r = AppWindow.indicator
        ctx.fill(CGRect(x: r.minX * s, y: CGFloat(h) - r.maxY * s, width: r.width * s, height: r.height * s))
        // 1.0's sidebar picks up the window beside it in a faint gradient toward its right edge (up to 0.06 from the
        // sampled colour); a wider tolerance keys that away with the rest instead of leaving a pale smudge on the glass.
        return keyOut(ctx.makeImage()!, background: bg, tolerance: 0.075)
    }
}
