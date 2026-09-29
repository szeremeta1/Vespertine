// Builds docs/brand/: the Vespertine logo set (SVG + PNG) and the one-page brand guide (PDF + PNG).
// Usage: scripts/brand/build.sh
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

let out = Brand.repo.appendingPathComponent("docs/brand").path
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// MARK: Lockup geometry (chosen 2026-09-29: light lowercase wordmark, crescent to the left)

/// Wordmark: "vespertine", Newsreader Light, display optical size, tracking −0.01 em.
func wordmark(_ size: CGFloat) -> (path: CGPath, width: CGFloat) {
    Brand.textPath("vespertine", font: Brand.serif(size, weight: 300), tracking: -0.01)
}

struct Lockup {
    var mark: CGPath          // crescent, positioned
    var word: CGPath          // wordmark, positioned
    var bounds: CGRect        // visual bounds of both
}

/// Horizontal: crescent 0.92× the type size, gap 0.34×, crescent sits 0.18 of its height below the baseline.
func horizontal(_ size: CGFloat) -> Lockup {
    let w = wordmark(size), m = size * 0.92, gap = size * 0.34
    let mark = Brand.crescent(size: m).copy(using: [CGAffineTransform(translationX: 0, y: -m * 0.18)])!
    let word = w.path.copy(using: [CGAffineTransform(translationX: m + gap, y: 0)])!
    return Lockup(mark: mark, word: word, bounds: mark.boundingBoxOfPath.union(word.boundingBoxOfPath))
}

/// Stacked: crescent centred over the wordmark, 0.8× the type size, 0.28× above the x-height.
func stacked(_ size: CGFloat) -> Lockup {
    let w = wordmark(size), m = size * 0.8
    let wordBox = w.path.boundingBoxOfPath
    let mark = Brand.crescent(size: m).copy(using: [CGAffineTransform(translationX: wordBox.midX - m / 2, y: wordBox.maxY + size * 0.28)])!
    return Lockup(mark: mark, word: w.path, bounds: mark.boundingBoxOfPath.union(wordBox))
}

enum Scheme { case dark, light, monoIvory, monoBlack }

/// Draws a lockup with its bounds' origin at `origin` (y up).
func draw(_ l: Lockup, in ctx: CGContext, at origin: CGPoint, scheme: Scheme) {
    ctx.saveGState()
    ctx.translateBy(x: origin.x - l.bounds.minX, y: origin.y - l.bounds.minY)
    switch scheme {
    case .dark, .light:
        Brand.fillBrass(ctx, l.mark)
        ctx.addPath(l.word); ctx.setFillColor(Brand.color(scheme == .dark ? Brand.text : Brand.base)); ctx.fillPath()
    case .monoIvory, .monoBlack:
        ctx.setFillColor(Brand.color(scheme == .monoIvory ? Brand.text : 0x000000))
        ctx.addPath(l.mark); ctx.addPath(l.word); ctx.fillPath()
    }
    ctx.restoreGState()
}

// MARK: SVG

func svg(_ l: Lockup, scheme: Scheme, pad: CGFloat) -> String {
    let b = l.bounds, W = b.width + 2 * pad, H = b.height + 2 * pad
    let t = CGAffineTransform(translationX: pad - b.minX, y: pad - b.minY)
    let mark = Brand.svgPath(l.mark.copy(using: [t])!, height: H), word = Brand.svgPath(l.word.copy(using: [t])!, height: H)
    let markBox = l.mark.copy(using: [t])!.boundingBoxOfPath
    var s = String(format: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %.0f %.0f" width="%.0f" height="%.0f">"#, W, H, W, H) + "\n"
    s += "<title>Vespertine</title>\n"
    switch scheme {
    case .dark, .light:
        // Gradient runs top-left to bottom-right across the crescent, as in the icon.
        s += String(format: #"<defs><linearGradient id="brass" gradientUnits="userSpaceOnUse" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f">"#,
                    markBox.minX, H - markBox.maxY, markBox.maxX, H - markBox.minY)
        s += ##"<stop offset="0" stop-color="#F0DAAA"/><stop offset="0.55" stop-color="\##(Brand.hex(Brand.brass))"/><stop offset="1" stop-color="\##(Brand.hex(Brand.brassLo))"/></linearGradient></defs>"## + "\n"
        s += #"<path fill="url(#brass)" d="\#(mark)"/>"# + "\n"
        s += #"<path fill="\#(Brand.hex(scheme == .dark ? Brand.text : Brand.base))" d="\#(word)"/>"# + "\n"
    case .monoIvory, .monoBlack:
        s += #"<path fill="\#(scheme == .monoIvory ? Brand.hex(Brand.text) : "#000000")" d="\#(mark)\#(word)"/>"# + "\n"
    }
    return s + "</svg>\n"
}

func svgMark(flat: Bool) -> String {
    let m = Brand.crescent(size: 512), d = Brand.svgPath(m, height: 512)
    if flat { return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><title>Vespertine</title><path fill="\#(Brand.hex(Brand.brass))" d="\#(d)"/></svg>"# + "\n" }
    return ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><title>Vespertine</title><defs><linearGradient id="brass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#F0DAAA"/><stop offset="0.55" stop-color="\##(Brand.hex(Brand.brass))"/><stop offset="1" stop-color="\##(Brand.hex(Brand.brassLo))"/></linearGradient></defs><path fill="url(#brass)" d="\##(d)"/></svg>"## + "\n"
}

func write(_ s: String, _ name: String) { try! s.write(toFile: "\(out)/\(name)", atomically: true, encoding: .utf8) }

// MARK: PNG

func png(_ l: Lockup, scheme: Scheme, width: Int, background: UInt32?, name: String) {
    let pad = l.bounds.height * 0.5
    let scale = CGFloat(width) / (l.bounds.width + 2 * pad)
    let height = Int(((l.bounds.height + 2 * pad) * scale).rounded())
    let ctx = Brand.context(width, height)
    if let bg = background { ctx.setFillColor(Brand.color(bg)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
    ctx.scaleBy(x: scale, y: scale)
    draw(l, in: ctx, at: CGPoint(x: pad, y: pad), scheme: scheme)
    Brand.writePNG(ctx, to: "\(out)/\(name)")
}

let h = horizontal(200), s = stacked(200)
for (l, base) in [(h, "logo"), (s, "logo-stacked")] {
    let pad = l.bounds.height * 0.5
    write(svg(l, scheme: .dark, pad: pad), "\(base).svg")
    write(svg(l, scheme: .light, pad: pad), "\(base)-on-light.svg")
    write(svg(l, scheme: .monoIvory, pad: pad), "\(base)-mono-ivory.svg")
    write(svg(l, scheme: .monoBlack, pad: pad), "\(base)-mono-black.svg")
    png(l, scheme: .dark, width: 2400, background: nil, name: "\(base).png")
    png(l, scheme: .light, width: 2400, background: nil, name: "\(base)-on-light.png")
    png(l, scheme: .dark, width: 2400, background: Brand.base, name: "\(base)-on-obsidian.png")
}
write(svgMark(flat: false), "mark.svg")
write(svgMark(flat: true), "mark-flat.svg")
do {
    let ctx = Brand.context(1024, 1024)
    Brand.fillBrass(ctx, Brand.crescent(size: 1024))
    Brand.writePNG(ctx, to: "\(out)/mark.png")
}

// MARK: Brand guide (one page, drawn once into a PDF and a PNG)

func guide(_ ctx: CGContext, W: CGFloat, H: CGFloat) {
    func fill(_ path: CGPath, _ c: UInt32, _ a: CGFloat = 1, at p: CGPoint) {
        ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.addPath(path); ctx.setFillColor(Brand.color(c, a)); ctx.fillPath(); ctx.restoreGState()
    }
    func text(_ s: String, _ font: CTFont, _ c: UInt32, _ x: CGFloat, _ yTop: CGFloat, tracking: CGFloat = 0) {
        let t = Brand.textPath(s, font: font, tracking: tracking)
        fill(t.path, c, at: CGPoint(x: x, y: H - yTop - CTFontGetAscent(font)))
    }
    func rule(_ yTop: CGFloat) { ctx.setFillColor(Brand.color(Brand.text, 0.12)); ctx.fill(CGRect(x: 120, y: H - yTop, width: W - 240, height: 1.5)) }
    func section(_ s: String, _ yTop: CGFloat) { text(s.uppercased(), Brand.mono(22, weight: 500), Brand.brass, 120, yTop, tracking: 0.16); rule(yTop + 50) }

    Brand.field(ctx, glowAt: CGPoint(x: W * 0.72, y: H - 330), glowRadius: 900, glow: 0.10)

    // Header
    draw(horizontal(150), in: ctx, at: CGPoint(x: 120, y: H - 300), scheme: .dark)
    text("Brand guide", Brand.serif(46, weight: 400), Brand.text2, 120, 340)
    text("BIT-PERFECT HI-RES AUDIO FOR MACOS · 2026", Brand.mono(20, weight: 500), Brand.text3, 120, 410, tracking: 0.14)

    // Logos
    section("Logo", 520)
    let panelTop: CGFloat = 610, panelH: CGFloat = 420
    let panels: [(UInt32, Scheme, Lockup, String)] = [
        (Brand.base, .dark, horizontal(96), "Primary · on obsidian"),
        (0xF4F1EA, .light, horizontal(96), "On light"),
        (Brand.base, .dark, stacked(96), "Stacked · square spaces"),
    ]
    let pw = (W - 240 - 2 * 40) / 3
    for (i, p) in panels.enumerated() {
        let x = 120 + CGFloat(i) * (pw + 40)
        let r = CGRect(x: x, y: H - panelTop - panelH, width: pw, height: panelH)
        ctx.setFillColor(Brand.color(p.0)); ctx.fill(r)
        ctx.setStrokeColor(Brand.color(Brand.text, 0.12)); ctx.setLineWidth(1.5); ctx.stroke(r)
        draw(p.2, in: ctx, at: CGPoint(x: r.midX - p.2.bounds.width / 2, y: r.midY - p.2.bounds.height / 2), scheme: p.1)
        text(p.3, Brand.sans(22, weight: 500), Brand.text2, x, panelTop + panelH + 22)
    }
    let rulesTop = panelTop + panelH + 90
    for (i, line) in ["Clear space: half the crescent's height on every side. Minimum size: 24 px tall (screen), 8 mm (print).",
                      "The wordmark is always lowercase, Newsreader Light, and always paired with the crescent in brass.",
                      "Don't recolour the crescent, stretch or rotate the lockup, add effects, or set the name in another typeface."].enumerated() {
        text(line, Brand.sans(24), Brand.text2, 120, rulesTop + CGFloat(i) * 42)
    }

    // Colour
    let colourTop = rulesTop + 190
    section("Colour", colourTop)
    let swatches: [(UInt32, String, String)] = [
        (Brand.base, "Obsidian", "background"), (Brand.surface, "Surface", "panels, cards"), (Brand.text, "Ivory", "text, wordmark"),
        (Brand.text2, "Ash", "secondary text"), (Brand.brass, "Brass", "accent, bit-perfect"), (Brand.brassHi, "Brass light", "highlights"),
        (Brand.brassLo, "Brass dark", "gradient end"), (Brand.copper, "Copper", "converted / warning"),
    ]
    let sw = (W - 240 - 7 * 24) / 8, swTop = colourTop + 90
    for (i, s) in swatches.enumerated() {
        let x = 120 + CGFloat(i) * (sw + 24)
        let r = CGRect(x: x, y: H - swTop - 200, width: sw, height: 200)
        ctx.setFillColor(Brand.color(s.0)); ctx.fill(r)
        ctx.setStrokeColor(Brand.color(Brand.text, 0.14)); ctx.setLineWidth(1.5); ctx.stroke(r)
        text(s.1, Brand.sans(22, weight: 600), Brand.text, x, swTop + 220)
        text(Brand.hex(s.0), Brand.mono(20), Brand.brass, x, swTop + 256)
        text(s.2, Brand.sans(18), Brand.text3, x, swTop + 290)
    }
    text("Brass means untouched signal; copper means something was converted. Keep brass rare: one accent per view.",
         Brand.sans(24), Brand.text2, 120, swTop + 350)

    // Type
    let typeTop = swTop + 450
    section("Type", typeTop)
    text("Late-night listening", Brand.serif(96, weight: 300), Brand.text, 120, typeTop + 90)
    text("Newsreader Light · display and wordmark", Brand.mono(20), Brand.text3, 120, typeTop + 222, tracking: 0.04)
    text("Dark Side of the Moon", Brand.serif(56, weight: 500), Brand.text, 120, typeTop + 280)
    text("Newsreader Medium · names of things: albums, headlines", Brand.mono(20), Brand.text3, 120, typeTop + 358, tracking: 0.04)
    text("Every sample reaches your DAC exactly as it was recorded.", Brand.sans(36), Brand.text2, 120, typeTop + 416)
    text("Inter · interface and body text", Brand.mono(20), Brand.text3, 120, typeTop + 472, tracking: 0.04)
    text("24-bit · 192 kHz · unity 0.0 dB", Brand.mono(36, weight: 500), Brand.brass, 120, typeTop + 530)
    text("JetBrains Mono · every number that describes the signal", Brand.mono(20), Brand.text3, 120, typeTop + 586, tracking: 0.04)

    // Labels
    let chipTop = typeTop + 680
    section("Labels", chipTop)
    var x: CGFloat = 120
    for (label, brass) in [("● BIT-PERFECT", true), ("EXCLUSIVE", false), ("32 / 192", false), ("NATIVE DSD · DoP", true), ("HI-RES LOSSLESS", false)] {
        let f = Brand.mono(24, weight: 500), t = Brand.textPath(label, font: f, tracking: 0.08)
        let r = CGRect(x: x, y: H - chipTop - 90 - 56, width: t.width + 44, height: 56)
        ctx.setStrokeColor(Brand.color(brass ? Brand.brass : Brand.text, brass ? 0.55 : 0.14)); ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath()
        fill(t.path, brass ? Brand.brassHi : Brand.text2, at: CGPoint(x: x + 22, y: r.midY - CTFontGetCapHeight(f) / 2))
        x += r.width + 20
    }
    text("Monospaced capitals with a 1 px hairline border; the brass variant carries a dot. Numbers are always the real ones.",
         Brand.sans(24), Brand.text2, 120, chipTop + 180)

    // Voice + legal
    let voiceTop = chipTop + 270
    section("Voice", voiceTop)
    for (i, line) in ["Calm, exact, unhurried. Say what happens to the signal, in plain words and real numbers.",
                      "Show, don't claim: a readback, a spectrum, a measurement. Never \"best\", \"ultimate\" or \"studio-grade\".",
                      "Free and open source (GPL-3.0). No logos of Apple, Dolby, DTS or AirPods, only their names in plain text."].enumerated() {
        text(line, Brand.sans(26), Brand.text2, 120, voiceTop + 90 + CGFloat(i) * 46)
    }
    text("Vespertine is not affiliated with Apple, Dolby Laboratories or Xperi/DTS. Their names are trademarks of their owners.",
         Brand.sans(19), Brand.text3, 120, H - 110)
    text("Fonts: Newsreader, Inter, JetBrains Mono (SIL Open Font License)", Brand.sans(19), Brand.text3, 120, H - 76)
}

let GW: CGFloat = 2400, GH: CGFloat = 3300
do {
    let ctx = Brand.context(Int(GW), Int(GH))
    guide(ctx, W: GW, H: GH)
    Brand.writePNG(ctx, to: "\(out)/brand-guide.png")
    var box = CGRect(x: 0, y: 0, width: GW / 2, height: GH / 2)
    let pdf = CGContext(URL(fileURLWithPath: "\(out)/brand-guide.pdf") as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Vespertine brand guide"] as CFDictionary)!
    pdf.beginPDFPage(nil); pdf.scaleBy(x: 0.5, y: 0.5); guide(pdf, W: GW, H: GH); pdf.endPDFPage(); pdf.closePDF()
}
print("brand kit written to \(out)")
