// Draws proposals for the iPhone app's icon, option A "Evening": today's brass crescent on obsidian, refined.
// Proposals only: nothing here replaces RemoteApp's AppIcon until one is chosen.
// Usage: swift scripts/make-ios-icon-proposals.swift docs/design/ios-icon-proposals
//   A1  the crescent alone, larger and optically centred, with the warm glow
//   A2  the crescent over a single thin horizon line
//   A3  the crescent with a faint ring of light (a quieter glow, a deeper field)
// Each comes as <name>.png (1024 px, opaque, square: iOS rounds the corners), <name>-tinted.png (greyscale on black,
// for iOS's tinted appearance; the dark appearance uses the main image), and all of them on one sheet, also at
// home-screen sizes: proposals.png.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

enum Variant: String, CaseIterable { case A1 = "A1-crescent", A2 = "A2-horizon", A3 = "A3-halo" }

func draw(_ variant: Variant, tinted: Bool, px: Int = 1024) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Field: obsidian, a little lifted towards the top left (black for the tinted appearance).
    let field: [CGColor] = tinted ? [c(0x000000), c(0x000000)] : (variant == .A3 ? [c(0x141418), c(0x09090A)] : [c(0x1C1C21), c(0x0B0B0D)])
    let bg = CGGradient(colorsSpace: nil, colors: field as CFArray, locations: [0, 1])!
    func paintField() { ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]) }
    paintField()

    // The crescent: bigger than today's (radius 0.25 → 0.30) and nudged so its visual weight sits in the middle.
    let r = s * (variant == .A2 ? 0.275 : 0.30)
    let center = CGPoint(x: s * 0.485, y: s * (variant == .A2 ? 0.545 : 0.5))
    let glowCenter = CGPoint(x: center.x + r * 0.1, y: center.y)
    func paintGlow() {
        guard !tinted else { return }
        switch variant {
        case .A3:
            // A ring of light just outside the crescent's edge.
            let ring = CGGradient(colorsSpace: nil, colors: [c(0xC8A66A, 0), c(0xC8A66A, 0.16), c(0xC8A66A, 0)] as CFArray, locations: [0.55, 0.72, 1])!
            ctx.drawRadialGradient(ring, startCenter: center, startRadius: 0, endCenter: center, endRadius: r * 1.75, options: [])
        default:
            let glow = CGGradient(colorsSpace: nil, colors: [c(0xC8A66A, 0.24), c(0xC8A66A, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: s * 0.5, options: [])
        }
    }
    paintGlow()

    let disc = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    let metal: [CGColor] = tinted ? [c(0xFFFFFF), c(0xD0D0D0), c(0x8A8A8A)] : [c(0xF0DAAA), c(0xC8A66A), c(0x7C6541)]
    let brass = CGGradient(colorsSpace: nil, colors: metal as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(brass, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    // The bite, filled with the field again.
    let br = r * 0.86
    ctx.addEllipse(in: CGRect(x: center.x + r * 0.42 - br, y: center.y + r * 0.22 - br, width: 2 * br, height: 2 * br))
    ctx.clip()
    paintField()
    paintGlow()
    ctx.restoreGState()

    if variant == .A2 {
        // One thin horizon line, fading at both ends.
        let y = s * 0.2, half = s * 0.27
        let line = CGGradient(colorsSpace: nil, colors: [c(tinted ? 0xFFFFFF : 0xE7CD98, 0), c(tinted ? 0xFFFFFF : 0xE7CD98, 0.85), c(tinted ? 0xFFFFFF : 0xE7CD98, 0)] as CFArray, locations: [0, 0.5, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: s * 0.5 - half, y: y - s * 0.004, width: half * 2, height: s * 0.008))
        ctx.drawLinearGradient(line, start: CGPoint(x: s * 0.5 - half, y: y), end: CGPoint(x: s * 0.5 + half, y: y), options: [])
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var all: [(String, CGImage, CGImage)] = []
for variant in Variant.allCases {
    let main = draw(variant, tinted: false), tinted = draw(variant, tinted: true)
    try! png(main).write(to: out.appendingPathComponent("\(variant.rawValue).png"))
    try! png(tinted).write(to: out.appendingPathComponent("\(variant.rawValue)-tinted.png"))
    all.append((variant.rawValue, main, tinted))
}

// The sheet: each proposal large, tinted, and at 120 px and 60 px with the home screen's rounded corners; today's icon last.
let today = CommandLine.arguments.count > 2 ? NSImage(contentsOfFile: CommandLine.arguments[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
let columns = all.count + (today == nil ? 0 : 1)
let cell = 420, pad = 40, height = 420 + 420 + 200 + 3 * pad + 70
let sheet = CGContext(data: nil, width: columns * (cell + pad) + pad, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
sheet.setFillColor(c(0x2A2A30))
sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
func place(_ image: CGImage, _ rect: CGRect) {
    sheet.saveGState()
    sheet.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil))
    sheet.clip()
    sheet.interpolationQuality = .high
    sheet.draw(image, in: rect)
    sheet.restoreGState()
}
let labels = NSGraphicsContext(cgContext: sheet, flipped: false)
for column in 0..<columns {
    let x = CGFloat(pad + column * (cell + pad))
    let name: String, main: CGImage, tinted: CGImage?
    if column < all.count { (name, main, tinted) = (all[column].0, all[column].1, all[column].2) } else { (name, main, tinted) = ("today", today!, nil) }
    place(main, CGRect(x: x, y: CGFloat(height - pad - 420), width: 420, height: 420))
    if let tinted { place(tinted, CGRect(x: x, y: CGFloat(height - 2 * pad - 840), width: 420, height: 420)) }
    place(main, CGRect(x: x, y: CGFloat(pad + 70), width: 120, height: 120))
    place(main, CGRect(x: x + 160, y: CGFloat(pad + 70), width: 60, height: 60))
    if let tinted { place(tinted, CGRect(x: x + 260, y: CGFloat(pad + 70), width: 60, height: 60)) }
    NSGraphicsContext.current = labels
    NSString(string: name).draw(at: CGPoint(x: x, y: CGFloat(pad)), withAttributes: [
        .font: NSFont(name: "JetBrains Mono", size: 26) ?? NSFont.monospacedSystemFont(ofSize: 26, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.925, green: 0.902, blue: 0.855, alpha: 1)])
}
try! png(sheet.makeImage()!).write(to: out.appendingPathComponent("proposals.png"))
