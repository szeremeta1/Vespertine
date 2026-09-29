// Draws the Vespertine app icon (obsidian field, brass crescent, waveform) at every macOS size.
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    // Full-bleed field; macOS applies the squircle mask.
    let bg = CGGradient(colorsSpace: nil, colors: [c(0x1C1C21), c(0x0B0B0D)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    // Ambient glow.
    let glow = CGGradient(colorsSpace: nil, colors: [c(0xC8A66A, 0.22), c(0xC8A66A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.56), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.56), endRadius: s * 0.48, options: [])
    // Crescent: brass disc with an offset "bite" filled by the field colour.
    let r = s * 0.25
    let center = CGPoint(x: s * 0.5, y: s * 0.57)
    let disc = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    let brass = CGGradient(colorsSpace: nil, colors: [c(0xF0DAAA), c(0xC8A66A), c(0x7C6541)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(brass, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    let br = r * 0.86
    let bite = CGRect(x: center.x + r * 0.42 - br, y: center.y + r * 0.22 - br, width: 2 * br, height: 2 * br)
    ctx.addEllipse(in: bite)
    ctx.clip()
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.56), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.56), endRadius: s * 0.48, options: [])
    ctx.restoreGState()
    // Waveform baseline.
    ctx.setStrokeColor(c(0xE7CD98, 0.9))
    ctx.setLineCap(.round)
    let heights: [CGFloat] = [0.02, 0.05, 0.09, 0.06, 0.12, 0.08, 0.04, 0.10, 0.06, 0.03, 0.05, 0.02]
    let w = s * 0.024
    ctx.setLineWidth(w)
    let startX = s * 0.5 - CGFloat(heights.count - 1) * w * 1.1
    for (i, h) in heights.enumerated() {
        let x = startX + CGFloat(i) * w * 2.2
        ctx.move(to: CGPoint(x: x, y: s * 0.22 - h * s * 0.5))
        ctx.addLine(to: CGPoint(x: x, y: s * 0.22 + h * s * 0.5))
    }
    ctx.strokePath()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! draw(pt * scale).write(to: out.appendingPathComponent(name))
        images.append(#"{ "idiom": "mac", "size": "\#(pt)x\#(pt)", "scale": "\#(scale)x", "filename": "\#(name)" }"#)
    }
}
try! #"{ "images": [ \#(images.joined(separator: ",\n")) ], "info": { "author": "xcode", "version": 1 } }"#
    .write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("icon written")
