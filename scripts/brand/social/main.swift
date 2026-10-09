// SPDX-License-Identifier: GPL-3.0-or-later
// Native rendering of the social-preview.html layout for hubs without a WebKit service.
// Uses the HTML's copy and the existing brand fonts, artwork and layout.
import AppKit
import Foundation

let template = try String(contentsOf: Brand.repo.appendingPathComponent("docs/design/social-preview.html"), encoding: .utf8)
func matches(_ pattern: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).map {
        String(template[Range($0.range(at: 1), in: template)!])
    }
}
func plain(_ s: String) -> String {
    s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
}
let lede = plain(matches("<p class=\"lede\">(.*?)</p>")[0])
let chips = matches("<span class=\"chip\">(.*?)</span>").map(plain)
let foot = plain(matches("<div class=\"foot\">(.*?)</div>")[0])
let shot = NSImage(contentsOf: Brand.repo.appendingPathComponent("docs/screenshots/bit-perfect-fiio-24-96.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let logo = NSImage(contentsOf: Brand.repo.appendingPathComponent("docs/brand/logo.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!

func render(wide: Bool) {
    let W = wide ? 1200 : 1280, H = wide ? 630 : 640
    let ctx = Brand.context(W, H), height: CGFloat = wide ? 672 : 640, offset: CGFloat = wide ? 16 : 0
    ctx.scaleBy(x: CGFloat(W) / 1280, y: CGFloat(W) / 1280)
    ctx.setFillColor(Brand.color(Brand.base)); ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: height))
    let glow = CGGradient(colorsSpace: nil, colors: [Brand.color(Brand.brass, 0.17), Brand.color(Brand.brass, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 1024, y: height * 0.54), startRadius: 0,
                           endCenter: CGPoint(x: 1024, y: height * 0.54), endRadius: 600, options: [])
    func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: height - top - h, width: w, height: h)
    }
    func text(_ s: String, _ font: CTFont, _ c: UInt32, x: CGFloat, top: CGFloat, tracking: CGFloat = 0) {
        let t = Brand.textPath(s, font: font, tracking: tracking)
        ctx.saveGState(); ctx.translateBy(x: x, y: height - top - CTFontGetAscent(font)); ctx.addPath(t.path)
        ctx.setFillColor(Brand.color(c)); ctx.fillPath(); ctx.restoreGState()
    }
    let window = rect(596, 46 + offset, 740, 552)
    ctx.saveGState(); ctx.addPath(CGPath(roundedRect: window, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.clip()
    ctx.draw(shot, in: rect(452, 46 + offset, 883, 883 * 1500 / 2400))
    ctx.setFillColor(Brand.color(0, 0.22)); ctx.fill(window); ctx.restoreGState()
    let panel = rect(818, 80 + offset, 427, 516)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -25), blur: 60, color: Brand.color(0, 0.8))
    ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setFillColor(Brand.color(Brand.panel)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.clip(to: rect(818, 98 + offset, 427, 484))
    ctx.draw(shot, in: rect(818 - 1424, 98 + offset - 421, 1872, 1170)); ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setStrokeColor(Brand.color(Brand.brass, 0.3)); ctx.setLineWidth(1); ctx.strokePath()
    ctx.draw(logo, in: rect(42, 106 + offset, 500, 138))
    let font = Brand.serif(32, weight: 400)
    var line = "", top: CGFloat = 258 + offset
    for word in lede.split(separator: " ") {
        let next = line.isEmpty ? String(word) : line + " " + word
        if Brand.textPath(next, font: font).width > 470, !line.isEmpty {
            text(line, font, Brand.text, x: 76, top: top); top += 39.04; line = String(word)
        } else { line = next }
    }
    text(line, font, Brand.text, x: 76, top: top); top += 39.04 + 28
    var x: CGFloat = 76
    let mono = Brand.mono(13, weight: 400)
    for chip in chips {
        let label = chip.uppercased(), width = Brand.textPath(label, font: mono, tracking: 1.5 / 13).width + 20
        if x + width > 546 { x = 76; top += 39 }
        ctx.addPath(CGPath(roundedRect: rect(x, top, width, 31), cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setStrokeColor(Brand.color(Brand.text, 0.14)); ctx.setLineWidth(1); ctx.strokePath()
        text(label, mono, Brand.text2, x: x + 10, top: top + 6, tracking: 1.5 / 13); x += width + 9
    }
    text(foot, Brand.sans(17), Brand.text2, x: 76, top: height - (wide ? 58 : 42) - 21)
    Brand.writePNG(ctx, to: Brand.repo.appendingPathComponent("site/assets/\(wide ? "og-wide" : "og").png").path)
}
render(wide: false)
render(wide: true)
