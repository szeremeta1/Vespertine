// SPDX-License-Identifier: GPL-3.0-or-later
// Renders the README/site tour: slow zooms across the screenshots in docs/screenshots with captions,
// ending on a title card. Writes raw BGRA frames to stdout for ffmpeg, e.g.
//   swift scripts/make-tour.swift 1200 750 30 | ffmpeg -f rawvideo -pix_fmt bgra -s 1200x750 -r 30 -i - tour.mp4
import AppKit
import CoreText

let args = CommandLine.arguments
let W = args.count > 1 ? Int(args[1])! : 1200
let H = args.count > 2 ? Int(args[2])! : 750
let fps = args.count > 3 ? Double(args[3])! : 30
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func image(_ name: String) -> CGImage {
    let url = root.appendingPathComponent(name)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("can't read \(url.path)") }
    return img
}

/// A shot: one screenshot, a crop rectangle (in the screenshot's pixels, top-left origin) that eases
/// from `from` to `to`, and a caption.
struct Shot { let file: String; let from: CGRect; let to: CGRect; let caption: String }

let full = CGRect(x: 0, y: 0, width: 2400, height: 1500)
let shots: [Shot] = [
    Shot(file: "docs/screenshots/multichannel-albums.png", from: full,
         to: CGRect(x: 520, y: 150, width: 1600, height: 1000),
         caption: "Your library, every format: SACD, DTS CDs, 5.1 FLAC, DSD"),
    Shot(file: "docs/screenshots/bit-perfect-fiio-24-192.png", from: full,
         to: CGRect(x: 1290, y: 540, width: 1110, height: 693.75),
         caption: "BIT-PERFECT appears only when its conditions are met"),
    Shot(file: "docs/screenshots/dsd-native-dop.png", from: full,
         to: CGRect(x: 1290, y: 540, width: 1110, height: 693.75),
         caption: "DSD64 to DSD512, native over DoP on DACs that accept it"),
    Shot(file: "docs/screenshots/stereo-and-surround-versions.png", from: full,
         to: CGRect(x: 1080, y: 140, width: 1320, height: 825),
         caption: "Stereo and 5.1 listed once; it plays the one your output suits"),
    Shot(file: "docs/screenshots/spatial-audio-airpods-max.png", from: CGRect(x: 600, y: 375, width: 1800, height: 1125),
         to: CGRect(x: 1380, y: 745, width: 1020, height: 637.5),
         caption: "A DTS 5.1 CD as head-tracked Spatial Audio on AirPods Max"),
    Shot(file: "docs/screenshots/fake-hi-res-detection.png", from: CGRect(x: 1340, y: 170, width: 1060, height: 662.5),
         to: CGRect(x: 1340, y: 560, width: 1060, height: 662.5),
         caption: "Flags upsampled, lossy-sourced and “AI-enhanced” files"),
]
let images = shots.map { image($0.file) }
let lockup = image("docs/brand/logo.png")   // crescent + "vespertine", with its clear space

let hold = 4.2, fade = 0.5, endHold = 3.4
let shotStep = hold - fade
let total = Double(shots.count) * shotStep + fade + endHold
let frames = Int((total * fps).rounded())

func ease(_ t: Double) -> Double { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    let t = CGFloat(t)
    return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                  width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
ctx.interpolationQuality = .high
let scale = CGFloat(W) / 1200

// Artwork uses open fonts (docs/design/fonts): Apple's licence covers New York and SF only for interface mock-ups.
for file in ["Newsreader[opsz,wght].ttf", "Inter[opsz,wght].ttf", "JetBrainsMono[wght].ttf"] {
    CTFontManagerRegisterFontsForURL(root.appendingPathComponent("docs/design/fonts/\(file)") as CFURL, .process, nil)
}

/// A variable font at a weight, with its optical size following the point size where it has one.
func openFont(_ family: String, _ size: CGFloat, weight: CGFloat) -> NSFont {
    let points = size * scale
    let axes: [NSNumber: CGFloat] = [NSNumber(value: 0x7767_6874): weight,                       // 'wght'
                                     NSNumber(value: 0x6F70_737A): min(max(points, 6), 72)]      // 'opsz'
    let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .variation: axes])
    guard let font = NSFont(descriptor: descriptor, size: points), font.familyName == family else {
        fatalError("\(family) isn't available; see docs/design/fonts")
    }
    return font
}

func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    openFont("Newsreader", size, weight: weight == .medium ? 500 : 400)
}

func draw(_ text: String, font: NSFont, color c: CGColor, centerX: CGFloat, baselineFromTop y: CGFloat, kern: CGFloat = 0) -> CGFloat {
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: c)!, .kern: kern])
    let line = CTLineCreateWithAttributedString(attr)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.textPosition = CGPoint(x: centerX - width / 2, y: CGFloat(H) - y)
    CTLineDraw(line, ctx)
    return width
}

/// Draws a shot at local time `t` (seconds since it started) with the given opacity.
func drawShot(_ i: Int, _ t: Double, alpha: CGFloat) {
    let s = shots[i]
    // Hold, glide for about a second, hold: still frames keep the GIF small.
    let r = lerp(s.from, s.to, ease((t - 0.9) / 1.1))
    let img = images[i]
    // Map the crop rect (top-left origin) onto the whole frame (bottom-left origin).
    let sx = CGFloat(W) / r.width, sy = CGFloat(H) / r.height
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.draw(img, in: CGRect(x: -r.minX * sx, y: -(ih - r.maxY) * sy, width: iw * sx, height: ih * sy))
    ctx.restoreGState()

    // Caption, fading in after the cut and out before the next.
    let captionAlpha = alpha * CGFloat(ease((t - 0.25) / 0.45) * (1 - ease((t - (hold - 0.55)) / 0.45)))
    guard captionAlpha > 0.001 else { return }
    let font = serif(25)
    let attr = NSAttributedString(string: s.caption, attributes: [.font: font])
    let textW = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    let pillH = 54 * scale, pillW = textW + 44 * scale
    let pill = CGRect(x: (CGFloat(W) - pillW) / 2, y: 30 * scale, width: pillW, height: pillH)
    ctx.saveGState()
    ctx.setAlpha(captionAlpha)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
    ctx.setFillColor(color(0x09090A, 0.86)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
    ctx.setStrokeColor(color(0xC8A66A, 0.45)); ctx.setLineWidth(1 * scale); ctx.strokePath()
    _ = draw(s.caption, font: font, color: color(0xECE6DA), centerX: CGFloat(W) / 2,
             baselineFromTop: CGFloat(H) - pill.minY - pillH / 2 + 8.5 * scale)
    ctx.restoreGState()
}

func drawEndCard(alpha: CGFloat) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setFillColor(color(0x09090A)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let glow = CGGradient(colorsSpace: space, colors: [color(0xC8A66A, 0.16), color(0xC8A66A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: Int(Double(H) * 0.58)), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: Int(Double(H) * 0.58)), endRadius: 460 * scale, options: [])
    let lockupW = 640 * scale, lockupH = lockupW * CGFloat(lockup.height) / CGFloat(lockup.width)
    ctx.draw(lockup, in: CGRect(x: (CGFloat(W) - lockupW) / 2, y: CGFloat(H) - 196 * scale - lockupH, width: lockupW, height: lockupH))
    _ = draw("The free, bit-perfect music player for Mac", font: serif(30), color: color(0xECE6DA), centerX: CGFloat(W) / 2, baselineFromTop: 470 * scale)
    let mono = openFont("JetBrains Mono", 17, weight: 400)
    _ = draw("OPEN SOURCE · GPL-3.0 · MACOS 26+", font: mono, color: color(0xA29B8F), centerX: CGFloat(W) / 2, baselineFromTop: 540 * scale, kern: 2 * scale)
    _ = draw("github.com/szeremeta1/Vespertine", font: openFont("Inter", 20, weight: 500), color: color(0xC8A66A), centerX: CGFloat(W) / 2, baselineFromTop: 590 * scale)
    ctx.restoreGState()
}

let out = FileHandle.standardOutput
for f in 0..<frames {
    let time = Double(f) / fps
    ctx.setFillColor(color(0x09090A)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for i in shots.indices {
        let start = Double(i) * shotStep
        let t = time - start
        guard t >= 0, t < hold else { continue }
        // Each shot fades in over the previous one; the first starts from black.
        drawShot(i, t, alpha: CGFloat(ease(t / fade)))
    }
    let endStart = Double(shots.count) * shotStep
    if time >= endStart { drawEndCard(alpha: CGFloat(ease((time - endStart) / fade))) }
    let data = Data(bytes: ctx.data!, count: W * H * 4)
    out.write(data)
}
