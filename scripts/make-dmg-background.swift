// Renders the Obsidian & Brass DMG window background at 1x and 2x.
// Usage: swift scripts/make-dmg-background.swift <version> <output-dir>
// Layout contract (points, top-left origin) — must match scripts/dmg-settings.py:
//   window 660×420, icons 128 pt, app centred at (180, 212), Applications at (480, 212)
import AppKit

let args = CommandLine.arguments
let version = args.count > 1 ? args[1] : "0.0.0"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")
let W: CGFloat = 660, H: CGFloat = 420
let appCenter = CGPoint(x: 180, y: 212), appsCenter = CGPoint(x: 480, y: 212)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let brass = color(0xC8A66A), brassHi = color(0xE7CD98), brassLo = color(0x7C6541)
let ivory = color(0xECE6DA), text2 = color(0xA29B8F), text3 = color(0x69645C)

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, design: NSFontDescriptor.SystemDesign = .default) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func drawText(_ s: String, _ f: NSFont, _ c: NSColor, centerX: CGFloat, top: CGFloat, kern: CGFloat = 0) {
    let attr = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
    let size = attr.size()
    attr.draw(at: CGPoint(x: centerX - size.width / 2 + kern / 2, y: H - top - size.height))
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Obsidian field with a soft vertical falloff.
    NSGradient(colors: [color(0x16161A), color(0x0B0B0D)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    // Warm ambient glow behind the stage.
    NSGradient(colors: [brass.withAlphaComponent(0.13), brass.withAlphaComponent(0)])!
        .draw(fromCenter: CGPoint(x: W / 2, y: H - 212), radius: 0, toCenter: CGPoint(x: W / 2, y: H - 212), radius: 300, options: [])
    // Fine grain so the gradient never bands.
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<Int(W * H * 0.06) {
        let x = CGFloat.random(in: 0..<W, using: &rng), y = CGFloat.random(in: 0..<H, using: &rng)
        color(0xFFFFFF, CGFloat.random(in: 0.006...0.02, using: &rng)).setFill()
        NSRect(x: x, y: y, width: 1 / scale, height: 1 / scale).fill()
    }

    // Wordmark.
    drawText("Nocturne", font(30, .regular, design: .serif), ivory, centerX: W / 2, top: 38)
    drawText("HI-RES AUDIO PLAYER", font(9.5, .semibold, design: .monospaced), brass, centerX: W / 2, top: 80, kern: 2.6)

    // Stages: soft spotlight under each icon (no strokes, so nothing collides with Finder's labels).
    for c in [appCenter, appsCenter] {
        NSGradient(colors: [color(0xFFFFFF, 0.05), color(0xFFFFFF, 0)])!
            .draw(fromCenter: CGPoint(x: c.x, y: H - c.y), radius: 0, toCenter: CGPoint(x: c.x, y: H - c.y), radius: 92, options: [])
    }

    // Brass label tags. Finder always draws icon labels in black over a background picture,
    // so each label sits on a brass tag (dark text on brass, like the app's buttons).
    // Finder centres labels 82 pt below the icon centre at 128 pt icons / 13 pt text.
    for c in [appCenter, appsCenter] {
        let tag = NSRect(x: c.x - 58, y: H - (c.y + 82) - 11, width: 116, height: 22)
        let path = NSBezierPath(roundedRect: tag, xRadius: 11, yRadius: 11)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        NSGradient(colors: [brassHi, brass])!.draw(in: path, angle: -90)
        ctx.restoreGState()
        color(0xFFFFFF, 0.35).setStroke()
        let rim = NSBezierPath(roundedRect: tag.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
        rim.lineWidth = 0.5
        rim.stroke()
    }

    // Brass arrow from app to Applications.
    let y = H - appCenter.y
    let x0 = appCenter.x + 96, x1 = appsCenter.x - 96
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: x0, y: y))
    shaft.curve(to: CGPoint(x: x1, y: y), controlPoint1: CGPoint(x: x0 + 40, y: y + 16), controlPoint2: CGPoint(x: x1 - 40, y: y + 16))
    shaft.lineWidth = 1.6
    shaft.lineCapStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 8, color: brass.withAlphaComponent(0.55).cgColor)
    brassHi.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: x1 - 10, y: y + 7))
    head.line(to: CGPoint(x: x1, y: y))
    head.line(to: CGPoint(x: x1 - 10, y: y - 6))
    head.lineWidth = 1.6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
    ctx.restoreGState()

    // Instructions and provenance.
    drawText("Drag Nocturne into Applications to install", font(12.5, .regular), text2, centerX: W / 2, top: 336)
    drawText("VERSION \(version) · UNIVERSAL · NOTARIZED BY APPLE", font(9, .medium, design: .monospaced), text3, centerX: W / 2, top: 362, kern: 1.4)

    // Hairline frame.
    color(0xECE6DA, 0.06).setStroke()
    let frame = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1))
    frame.lineWidth = 1
    frame.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try! render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("wrote \(outDir.path)/background.png and background@2x.png")
