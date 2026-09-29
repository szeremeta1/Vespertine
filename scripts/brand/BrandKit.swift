// Vespertine brand kit: the crescent mark and the wordmark as vector paths (outlined from the OFL fonts the
// site ships), plus helpers to write them as SVG and to draw them into PNGs. Shared by the brand scripts.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreText

enum Brand {
    static let base: UInt32 = 0x09090A, window: UInt32 = 0x0D0D0F, surface: UInt32 = 0x16161A, raised: UInt32 = 0x1C1C21
    static let text: UInt32 = 0xECE6DA, text2: UInt32 = 0xA29B8F, text3: UInt32 = 0x69645C
    static let brass: UInt32 = 0xC8A66A, brassHi: UInt32 = 0xE7CD98, brassLo: UInt32 = 0x7C6541, copper: UInt32 = 0xC98B5B
    static let onBrass: UInt32 = 0x1A140A

    static func color(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    static func hex(_ h: UInt32) -> String { String(format: "#%06X", h) }

    /// The repo, found from this file's location (scripts/brand/).
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Fonts (variable OFL fonts self-hosted by the website)

    static func font(_ file: String, size: CGFloat, weight: CGFloat, opticalSize: CGFloat? = nil) -> CTFont {
        let url = repo.appendingPathComponent("site/assets/fonts/\(file).woff2") as CFURL
        let d = (CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor])[0]
        let base = CTFontCreateWithFontDescriptor(d, size, nil)
        var variation: [NSNumber: NSNumber] = [:]
        for axis in (CTFontCopyVariationAxes(base) as? [[String: Any]]) ?? [] {
            guard let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                  let name = axis[kCTFontVariationAxisNameKey as String] as? String else { continue }
            if name == "Weight" { variation[id] = NSNumber(value: Double(weight)) }
            if name == "Optical Size", let o = opticalSize { variation[id] = NSNumber(value: Double(o)) }
        }
        let attrs = [kCTFontVariationAttribute: variation] as CFDictionary
        return CTFontCreateCopyWithAttributes(base, size, nil, CTFontDescriptorCreateWithAttributes(attrs))
    }
    static func serif(_ size: CGFloat, weight: CGFloat = 500) -> CTFont { font("Newsreader", size: size, weight: weight, opticalSize: min(72, max(6, size))) }
    static func sans(_ size: CGFloat, weight: CGFloat = 400) -> CTFont { font("Inter", size: size, weight: weight) }
    static func mono(_ size: CGFloat, weight: CGFloat = 400) -> CTFont { font("JetBrainsMono", size: size, weight: weight) }

    /// Text as one path (baseline at y = 0, y up), with tracking in ems. Returns the path and its advance width.
    static func textPath(_ string: String, font: CTFont, tracking: CGFloat = 0) -> (path: CGPath, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTKernAttributeName as NSAttributedString.Key: tracking * CTFontGetSize(font)]))
        let path = CGMutablePath()
        var width: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (g, p) in zip(glyphs, positions) {
                if let gp = CTFontCreatePathForGlyph(runFont, g, nil) {
                    path.addPath(gp, transform: CGAffineTransform(translationX: p.x, y: p.y))
                }
            }
        }
        width = CTLineGetTypographicBounds(line, nil, nil, nil) - tracking * CTFontGetSize(font) // no trailing tracking
        return (path, width)
    }

    // MARK: The crescent (same geometry as scripts/make-icon.swift): a disc minus an offset bite.

    /// Crescent in a box of `size` with its disc centred; y up.
    static func crescent(size: CGFloat) -> CGPath {
        let r = size / 2, c = CGPoint(x: r, y: r)
        let disc = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        let br = r * 0.86
        let bite = CGPath(ellipseIn: CGRect(x: c.x + r * 0.42 - br, y: c.y + r * 0.22 - br, width: 2 * br, height: 2 * br), transform: nil)
        return disc.subtracting(bite)
    }

    // MARK: Output

    /// SVG `d` attribute for a path in a y-down box of the given height.
    static func svgPath(_ path: CGPath, height: CGFloat) -> String {
        var d = ""
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "") }
        func p(_ pt: CGPoint) -> String { "\(f(pt.x)) \(f(height - pt.y))" }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint: d += "M\(p(e.points[0]))"
            case .addLineToPoint: d += "L\(p(e.points[0]))"
            case .addQuadCurveToPoint: d += "Q\(p(e.points[0])) \(p(e.points[1]))"
            case .addCurveToPoint: d += "C\(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2]))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func writePNG(_ ctx: CGContext, to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    }

    /// Fills a path with the brass gradient used by the icon (light top-left to dark bottom-right).
    static func fillBrass(_ ctx: CGContext, _ path: CGPath) {
        let box = path.boundingBoxOfPath
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: nil, colors: [color(0xF0DAAA), color(brass), color(brassLo)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
        ctx.restoreGState()
    }

    /// The obsidian field with the icon's soft brass glow, for key art.
    static func field(_ ctx: CGContext, glowAt: CGPoint? = nil, glowRadius: CGFloat = 0, glow: CGFloat = 0.14) {
        let w = CGFloat(ctx.width), h = CGFloat(ctx.height)
        let bg = CGGradient(colorsSpace: nil, colors: [color(0x141418), color(base)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        if let at = glowAt {
            let g = CGGradient(colorsSpace: nil, colors: [color(brass, glow), color(brass, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: at, startRadius: 0, endCenter: at, endRadius: glowRadius, options: [])
        }
    }
}
