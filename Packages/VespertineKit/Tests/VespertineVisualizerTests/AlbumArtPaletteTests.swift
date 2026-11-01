//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import simd
import Testing
@testable import VespertineVisualizer

@Suite("Album Art colours")
struct AlbumArtPaletteTests {
    /// An image painted from rectangles in unit coordinates (0…1, origin top left), each in sRGB 0…255.
    private func image(width: Int = 200, height: Int = 200, background: (UInt8, UInt8, UInt8),
                       rects: [(CGRect, (UInt8, UInt8, UInt8))] = []) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ rect: CGRect, _ c: (UInt8, UInt8, UInt8)) {
            ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
            ctx.fill(CGRect(x: rect.minX * CGFloat(width), y: rect.minY * CGFloat(height),
                            width: rect.width * CGFloat(width), height: rect.height * CGFloat(height)))
        }
        fill(CGRect(x: 0, y: 0, width: 1, height: 1), background)
        for (rect, c) in rects { fill(rect, c) }
        return ctx.makeImage()!
    }

    private func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    private func hue(_ c: SIMD3<Float>) -> Float {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        guard d > 0 else { return 0 }
        var h: Float = mx == c.x ? (c.y - c.z) / d : mx == c.y ? 2 + (c.z - c.x) / d : 4 + (c.x - c.y) / d
        if h < 0 { h += 6 }
        return h * 60
    }

    @Test("A solid colour gives one colour of that hue")
    func solid() throws {
        let palette = try #require(AlbumArtPalette.extract(from: image(background: (200, 40, 60))))
        #expect(palette.colors.count == 1)
        let c = palette.colors[0]
        #expect(abs(hue(c) - hue(SIMD3<Float>(200, 40, 60) / 255)) < 8)
        #expect(c.x > c.y && c.x > c.z)
    }

    @Test("Two colours give two distinct colours, dark to bright, near the originals")
    func twoColours() throws {
        let img = image(background: (200, 30, 30), rects: [(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), (30, 70, 220))])
        let palette = try #require(AlbumArtPalette.extract(from: img))
        #expect(palette.colors.count == 2)
        let l = palette.colors.map(luminance)
        #expect(l == l.sorted())
        let reds = palette.colors.filter { hue($0) < 30 || hue($0) > 330 }, blues = palette.colors.filter { abs(hue($0) - 225) < 30 }
        #expect(reds.count == 1 && blues.count == 1)
        #expect(simd_distance(palette.colors[0], palette.colors[1]) > 0.2)
    }

    @Test("A small accent on a large field is still found")
    func accent() throws {
        let img = image(background: (30, 90, 200), rects: [(CGRect(x: 0.1, y: 0.1, width: 0.25, height: 0.25), (240, 190, 40))])
        let palette = try #require(AlbumArtPalette.extract(from: img))
        #expect(palette.colors.contains { abs(hue($0) - 45) < 20 })
        #expect(palette.colors.contains { abs(hue($0) - 220) < 20 })
    }

    @Test("Many colours give at most five, all distinct")
    func manyColours() throws {
        let tints: [(UInt8, UInt8, UInt8)] = [(220, 40, 40), (230, 140, 30), (230, 220, 40), (40, 190, 80), (40, 120, 220), (150, 50, 200), (240, 90, 160)]
        let rects = tints.enumerated().map { (CGRect(x: Double($0.offset) / 7, y: 0, width: 1.0 / 7, height: 1), $0.element) }
        let palette = try #require(AlbumArtPalette.extract(from: image(width: 280, background: (0, 0, 0), rects: rects)))
        #expect((3...AlbumArtPalette.maxColors).contains(palette.colors.count))
        for i in palette.colors.indices { for j in palette.colors.indices where j > i {
            #expect(simd_distance(palette.colors[i], palette.colors[j]) > 0.15)
        } }
    }

    @Test("Grayscale, nearly black and blank artwork have no palette (the default colours are used)")
    func noColourNoPalette() {
        #expect(AlbumArtPalette.extract(from: image(background: (128, 128, 128), rects: [(CGRect(x: 0, y: 0, width: 0.5, height: 1), (20, 20, 20))])) == nil)
        #expect(AlbumArtPalette.extract(from: image(background: (255, 255, 255))) == nil)
        #expect(AlbumArtPalette.extract(from: image(background: (0, 0, 0))) == nil)
        #expect(AlbumArtPalette.extract(from: image(background: (8, 2, 2))) == nil)
        #expect(AlbumArtPalette.extract(from: nil) == nil)
    }

    @Test("Every colour is bright enough to read against the dark background")
    func contrast() throws {
        // A deep navy cover: the raw colour would vanish against the background.
        let palette = try #require(AlbumArtPalette.extract(from: image(background: (10, 20, 90), rects: [(CGRect(x: 0, y: 0, width: 0.5, height: 1), (70, 10, 20))])))
        for c in palette.colors { #expect(luminance(c) >= AlbumArtPalette.minimumLuminance - 0.001) }
        #expect(palette.ramp.dropFirst().allSatisfy { luminance($0) >= AlbumArtPalette.minimumLuminance - 0.001 })
    }

    @Test("It is deterministic: the same picture gives the same palette")
    func deterministic() throws {
        let img = image(background: (200, 30, 30), rects: [(CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5), (30, 200, 90)), (CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3), (30, 70, 220))])
        let a = try #require(AlbumArtPalette.extract(from: img)), b = try #require(AlbumArtPalette.extract(from: img))
        #expect(a == b)
    }

    @Test("A palette always makes a six-colour ramp from dark to bright and four theme stops")
    func ramp() throws {
        for img in [image(background: (200, 40, 60)),
                    image(background: (200, 30, 30), rects: [(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), (30, 70, 220))])] {
            let palette = try #require(AlbumArtPalette.extract(from: img))
            #expect(palette.ramp.count == AlbumArtPalette.rampSize)
            let l = palette.ramp.map(luminance)
            #expect(l == l.sorted())
            #expect(luminance(palette.ramp[0]) < 0.06, "the lowest stop stays a dark background")
            #expect(palette.stops.count == 4)
            let ls = palette.stops.map(luminance)
            #expect(ls == ls.sorted())
            #expect(palette.ramp.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.min() >= 0 && $0.max() <= 1 })
        }
    }

    @Test("No artwork: the Album Art theme draws in the default colours")
    func fallback() {
        #expect(VisualizerTheme.allCases.contains(.albumArt))
        let colours = VisualizerColors(theme: .albumArt, palette: nil)
        #expect(colours.stops == VisualizerTheme.vespertine.stops)
        #expect(!colours.usesRamp)
        // Other themes ignore the artwork.
        let palette = AlbumArtPalette.extract(from: image(background: (200, 40, 60)))
        #expect(VisualizerColors(theme: .neon, palette: palette).stops == VisualizerTheme.neon.stops)
        #expect(VisualizerColors(theme: .albumArt, palette: palette).usesRamp)
    }

    @Test("Changing track fades between palettes over a short time, and ends exactly on the new one")
    func crossfade() throws {
        let red = try #require(AlbumArtPalette.extract(from: image(background: (200, 30, 30))))
        let blue = try #require(AlbumArtPalette.extract(from: image(background: (30, 60, 220))))
        var fade = VisualizerColorFade(duration: 0.6)
        fade.set(red, animated: false)
        #expect(fade.current(theme: .albumArt).ramp == red.ramp)
        fade.set(blue, animated: true)
        fade.advance(by: 0.3)
        let mid = fade.current(theme: .albumArt).ramp
        #expect(mid != red.ramp && mid != blue.ramp)
        fade.advance(by: 0.5)
        #expect(fade.current(theme: .albumArt).ramp == blue.ramp)
        // Losing the artwork fades back to the defaults.
        fade.set(nil, animated: true)
        fade.advance(by: 1)
        #expect(fade.current(theme: .albumArt).stops == VisualizerTheme.vespertine.stops)
    }
}
