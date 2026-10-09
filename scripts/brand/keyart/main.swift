// Key art for releases, posts and galleries: one feature per image, built from docs/screenshots.
// Writes docs/press/<feature>-<size>.png. Usage: scripts/brand/build.sh
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

let out = Brand.repo.appendingPathComponent("docs/press").path
let shots = Brand.repo.appendingPathComponent("docs/screenshots")

struct Feature {
    var id: String, shot: String, headline: String, sub: String
    var chips: [(String, Chip)]
    var focus: CGRect    // the readout to magnify, in screenshot pixels (2400×1500, top-left origin)
    var trademarks: String? = nil
}
enum Chip { case brass, copper, plain }

let features = [
    Feature(id: "bit-perfect", shot: "bit-perfect-fiio-24-192",
            headline: "Every sample, untouched.",
            sub: "Vespertine plays your music bit-perfect, switches your DAC to each file’s own sample rate, and shows you the proof.",
            chips: [("● BIT-PERFECT", .brass), ("EXCLUSIVE", .plain), ("24-BIT · 192 kHz", .plain)], focus: CGRect(x: 1826, y: 826, width: 564, height: 590)),
    Feature(id: "stereo-and-surround", shot: "stereo-and-surround-versions",
            headline: "Stereo or surround, on its own.",
            sub: "When an album comes in both, Vespertine plays the version your output can carry: 5.1 for surround and Spatial Audio, stereo for a stereo DAC.",
            chips: [("DSD64 · 5.1", .plain), ("+ STEREO", .plain), ("○ SPATIAL · HEAD TRACKED", .copper)], focus: CGRect(x: 370, y: 575, width: 1100, height: 390)),
    Feature(id: "spatial-audio", shot: "spatial-audio-airpods-max",
            headline: "Your 5.1 albums, all around you.",
            sub: "Surround albums play as head-tracked Spatial Audio on AirPods, each channel placed where it belongs.",
            chips: [("5.1 · 6 CHANNELS", .plain), ("○ SPATIAL · HEAD TRACKED", .copper), ("32 / 48", .plain)], focus: CGRect(x: 1826, y: 284, width: 564, height: 622),
            trademarks: "AirPods is a trademark of Apple Inc. Vespertine is not affiliated with Apple."),
    Feature(id: "native-dsd", shot: "dsd-native-dop",
            headline: "Native DSD, not a conversion.",
            sub: "DSD64 to DSD512 goes to DACs that accept it as DoP, bit for bit, and is converted only for those that don’t.",
            chips: [("● NATIVE DSD · DoP", .brass), ("DSD64 · 2.8 MHz", .plain), ("32 / 176.4", .plain)], focus: CGRect(x: 1826, y: 600, width: 564, height: 560)),
    Feature(id: "fake-hi-res", shot: "fake-hi-res-detection",
            headline: "Know when hi-res isn’t.",
            sub: "Spectral analysis flags upsampled, padded and lossy-sourced files, with the measurements to back it up.",
            chips: [("○ LOSSY ORIGIN?", .copper), ("LIKELY", .plain)], focus: CGRect(x: 1826, y: 150, width: 564, height: 900)),
]

/// Greedy word wrap into lines no wider than `width`.
func wrap(_ s: String, font: CTFont, width: CGFloat, tracking: CGFloat = 0) -> [String] {
    var lines: [String] = [], line = ""
    for word in s.split(separator: " ") {
        let candidate = line.isEmpty ? String(word) : line + " " + word
        if Brand.textPath(candidate, font: font, tracking: tracking).width > width, !line.isEmpty { lines.append(line); line = String(word) }
        else { line = candidate }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

func render(_ f: Feature, W: Int, H: Int, name: String) {
    let w = CGFloat(W), h = CGFloat(H), u = h / 900   // layout unit: 1 at 900 px tall
    let ctx = Brand.context(W, H)
    Brand.field(ctx, glowAt: CGPoint(x: w * 0.68, y: h * 0.52), glowRadius: w * 0.55, glow: 0.12)
    func fill(_ p: CGPath, _ c: UInt32, _ a: CGFloat = 1, at o: CGPoint) {
        ctx.saveGState(); ctx.translateBy(x: o.x, y: o.y); ctx.addPath(p); ctx.setFillColor(Brand.color(c, a)); ctx.fillPath(); ctx.restoreGState()
    }
    let margin = 72 * u, column = w * 0.36

    // Screenshot: large, to the right, bleeding off the right edge, with a window shadow and hairline.
    let image = NSImage(contentsOf: shots.appendingPathComponent("\(f.shot).png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    // The whole window, right of the text column: the readouts are the point, so nothing is cropped.
    let shotW = min(w - margin * 2.2 - column - margin * 0.7, (h - margin * 1.6) * CGFloat(image.width) / CGFloat(image.height))
    let shotH = shotW * CGFloat(image.height) / CGFloat(image.width)
    let shotX = w - shotW - margin * 0.7, shotY = (h - shotH) / 2 + 6 * u
    let frame = CGRect(x: shotX, y: shotY, width: shotW, height: shotH)
    let radius = 16 * u
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * u), blur: 60 * u, color: Brand.color(0x000000, 0.7))
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.setFillColor(Brand.color(Brand.window)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: frame)
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(Brand.color(Brand.text, 0.14)); ctx.setLineWidth(1.2 * u); ctx.strokePath()
    // Fade the screenshot into the field on its left edge so the text column stays calm.
    let fade = CGGradient(colorsSpace: nil, colors: [Brand.color(Brand.base, 0.9), Brand.color(Brand.base, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: shotX - 1, y: 0), end: CGPoint(x: shotX + 90 * u, y: 0), options: [.drawsBeforeStartLocation])
    // Magnified readout, overlapping the window's lower left, with a brass hairline.
    if let crop = image.cropping(to: f.focus) {
        let maxW = shotW * (f.focus.width > f.focus.height * 1.6 ? 0.62 : 0.4), maxH = h * 0.46
        let scale = min(maxW / f.focus.width, maxH / f.focus.height)
        let iw = f.focus.width * scale, ih = f.focus.height * scale
        let inset = CGRect(x: shotX - shotW * 0.09, y: max(margin * 1.5, shotY - ih * 0.28), width: iw, height: ih)
        let r2 = 12 * u
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 50 * u, color: Brand.color(0x000000, 0.8))
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: r2, cornerHeight: r2, transform: nil)); ctx.setFillColor(Brand.color(Brand.panel)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(CGPath(roundedRect: inset, cornerWidth: r2, cornerHeight: r2, transform: nil)); ctx.clip()
        ctx.interpolationQuality = .high; ctx.draw(crop, in: inset); ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: inset.insetBy(dx: 0.6, dy: 0.6), cornerWidth: r2, cornerHeight: r2, transform: nil))
        ctx.setStrokeColor(Brand.color(Brand.brass, 0.5)); ctx.setLineWidth(1.4 * u); ctx.strokePath()
    }

    // Text column.
    var y = h - margin
    let logoSize = 34 * u
    let logo = Brand.textPath("vespertine", font: Brand.serif(logoSize, weight: 300), tracking: -0.01)
    let m = logoSize * 0.92
    ctx.saveGState(); ctx.translateBy(x: margin, y: y - logoSize * 0.75 - m * 0.18); Brand.fillBrass(ctx, Brand.crescent(size: m)); ctx.restoreGState()
    fill(logo.path, Brand.text, at: CGPoint(x: margin + m + logoSize * 0.34, y: y - logoSize * 0.75))
    y -= 170 * u

    let hf = Brand.serif(66 * u, weight: 300)
    for line in wrap(f.headline, font: hf, width: column, tracking: -0.015) {
        fill(Brand.textPath(line, font: hf, tracking: -0.015).path, Brand.text, at: CGPoint(x: margin, y: y - CTFontGetAscent(hf)))
        y -= 76 * u
    }
    y -= 16 * u
    let sf = Brand.sans(22 * u)
    for line in wrap(f.sub, font: sf, width: column * 0.96) {
        fill(Brand.textPath(line, font: sf).path, Brand.text2, at: CGPoint(x: margin, y: y - CTFontGetAscent(sf)))
        y -= 34 * u
    }
    y -= 34 * u
    // Chips, wrapping to a second row if needed.
    let cf = Brand.mono(14.5 * u, weight: 500)
    var x = margin
    for (label, kind) in f.chips {
        let t = Brand.textPath(label, font: cf, tracking: 0.1)
        let cw = t.width + 30 * u, ch = 38 * u
        if x + cw > margin + column { x = margin; y -= ch + 12 * u }
        let r = CGRect(x: x, y: y - ch, width: cw, height: ch)
        let stroke: (UInt32, CGFloat) = kind == .brass ? (Brand.brass, 0.55) : kind == .copper ? (Brand.copper, 0.6) : (Brand.text, 0.16)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil))
        ctx.setStrokeColor(Brand.color(stroke.0, stroke.1)); ctx.setLineWidth(1.4 * u); ctx.strokePath()
        let tc: UInt32 = kind == .brass ? Brand.brassHi : kind == .copper ? Brand.copper : Brand.text2
        fill(t.path, tc, at: CGPoint(x: x + 15 * u, y: r.midY - CTFontGetCapHeight(cf) / 2))
        x += cw + 10 * u
    }

    // Footer.
    let ff = Brand.mono(13.5 * u, weight: 500)
    fill(Brand.textPath("FREE & OPEN SOURCE · MACOS 14.4+ · SZEREMETA1.GITHUB.IO/VESPERTINE", font: ff, tracking: 0.12).path, Brand.text3,
         at: CGPoint(x: margin, y: margin * 0.8))
    if let tm = f.trademarks {
        let tf = Brand.sans(11.5 * u)
        fill(Brand.textPath(tm, font: tf).path, Brand.text3, 0.8, at: CGPoint(x: margin, y: margin * 0.8 - 26 * u))
    }
    Brand.writePNG(ctx, to: "\(out)/\(name).png")
}

let sizes = [("hero", 2400, 1350), ("x", 1600, 900), ("producthunt", 1270, 760)]
for f in features {
    for (label, W, H) in sizes { render(f, W: W, H: H, name: "\(f.id)-\(label)") }
}
print("key art written to \(out)")
