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
        Cue(scene: .bitPerfect, recording: "bitperfect", sourceStart: 0.8),
        Cue(scene: .dsd, recording: "dsd", sourceStart: 2.0),
        Cue(scene: .versions, recording: "versions", sourceStart: 2.0),
        Cue(scene: .spatial, recording: "spatial", sourceStart: 2.0),
        Cue(scene: .analysis, recording: "analysis", sourceStart: 2.0),
        Cue(scene: .library, recording: "albums", sourceStart: 0.6),
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

    init(_ paths: Paths) {
        self.paths = paths
        logo = loadImage(paths.brand.appendingPathComponent("logo.png"))
        mark = loadImage(paths.brand.appendingPathComponent("mark.png"))
        for cue in Cue.all {
            let frame = firstFrame(of: paths.recording(cue.recording), at: cue.sourceStart + 0.5)
            poster[cue.recording] = frame
            let bg = sampleColor(frame, at: CGRect(x: 110, y: 14, width: 60, height: 24))
            sidebarColor[cue.recording] = Color(.sRGB, red: bg.r, green: bg.g, blue: bg.b)
            sidebars[cue.recording] = keyedSidebar(frame, background: bg)
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
        return keyOut(ctx.makeImage()!, background: bg)
    }
}
