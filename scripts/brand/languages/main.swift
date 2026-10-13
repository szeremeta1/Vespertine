// Lays the languages shots (the same window in six languages) out as one grid, each named underneath in English.
// Usage: languages <out.png> <shot-ja.png> <shot-de.png> …   (the language code is the part after the last "-")
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreText

let names = ["ja": "Japanese", "de": "German", "uk": "Ukrainian", "ar": "Arabic", "pt-BR": "Portuguese (Brazil)", "zh-Hans": "Chinese (Simplified)",
             "fr": "French", "es": "Spanish", "ko": "Korean", "hi": "Hindi", "he": "Hebrew"]
let args = Array(CommandLine.arguments.dropFirst())
let out = args[0], shots = Array(args.dropFirst())
let columns = 3, rows = (shots.count + columns - 1) / columns
let tileW = 1200, tileH = 750, gutter = 48, margin = 72, label = 72
let w = margin * 2 + columns * tileW + (columns - 1) * gutter
let h = margin * 2 + rows * (tileH + label) + (rows - 1) * gutter
let ctx = Brand.context(w, h)
ctx.setFillColor(Brand.color(Brand.base)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.interpolationQuality = .high
for (i, path) in shots.enumerated() {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("can't read \(path)") }
    let col = i % columns, row = i / columns
    let x = margin + col * (tileW + gutter)
    let top = h - margin - row * (tileH + label + gutter)          // CG's origin is bottom-left
    ctx.draw(image, in: CGRect(x: x, y: top - tileH, width: tileW, height: tileH))
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let code = stem.components(separatedBy: "languages-").last ?? stem
    let text = NSAttributedString(string: names[code] ?? code, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): Brand.sans(30, weight: 450),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): Brand.color(Brand.text2)])
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: CGFloat(x) + (CGFloat(tileW) - width) / 2, y: CGFloat(top - tileH - label + 22))
    CTLineDraw(line, ctx)
}
Brand.writePNG(ctx, to: out)
print("\(out): \(w)×\(h)")
