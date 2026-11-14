//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
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
    /// Dark to bright, give or take the rounding of colours lifted to the same floor.
    private func isAscending(_ l: [Float]) -> Bool { zip(l, l.dropFirst()).allSatisfy { $0 <= $1 + 1e-4 } }
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
        #expect(isAscending(l))
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

    @Test("Nearly black, transparent and missing artwork have no palette (the default colours are used)")
    func noColourNoPalette() {
        #expect(AlbumArtPalette.extract(from: image(background: (0, 0, 0))) == nil)
        #expect(AlbumArtPalette.extract(from: image(background: (8, 2, 2))) == nil)
        #expect(AlbumArtPalette.extract(from: image(background: (14, 14, 16), rects: [(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), (30, 30, 30))])) == nil)
        #expect(AlbumArtPalette.extract(from: nil) == nil)
    }

    /// OKLab chroma: how far a colour is from grey (a pure sRGB red is about 0.26, a pastel about 0.05).
    private func chroma(_ c: SIMD3<Float>) -> Float {
        let lab = AlbumArtPalette.oklab(fromSRGB: c)
        return (lab.y * lab.y + lab.z * lab.z).squareRoot()
    }

    /// A picture from raw pixels: `colour(x, y)` in sRGB 0…255 for x and y in 0…1 (y down), with a little grain, as a
    /// photograph or a scan has.
    private func picture(side: Int = 240, grain: Int = 10, _ colour: (Double, Double) -> (Int, Int, Int)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        var state: UInt32 = 12345
        func noise() -> Int {
            state = state &* 1_664_525 &+ 1_013_904_223
            return grain == 0 ? 0 : Int(state >> 16) % (2 * grain + 1) - grain
        }
        for y in 0..<side {
            for x in 0..<side {
                let c = colour((Double(x) + 0.5) / Double(side), (Double(y) + 0.5) / Double(side)), n = noise()
                let i = (y * side + x) * 4
                bytes[i] = UInt8(min(255, max(0, c.0 + n))); bytes[i + 1] = UInt8(min(255, max(0, c.1 + n))); bytes[i + 2] = UInt8(min(255, max(0, c.2 + n)))
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test("A portrait in browns with a red chair and green lettering: the red and the green are in the palette, not five browns")
    func vividOverDull() throws {
        // Six shades of wood, skin and shadow fill nine tenths of the cover; the chair and the lettering are small.
        let browns: [(Int, Int, Int)] = [(58, 40, 30), (92, 62, 44), (128, 90, 62), (160, 118, 86), (190, 150, 116), (214, 180, 150)]
        let cover = picture { x, y in
            if y < 0.09 && x > 0.1 && x < 0.9 { return (40, 170, 120) }       // lettering across the top
            if y > 0.78 && x > 0.3 && x < 0.62 { return (190, 28, 34) }       // the chair
            return browns[min(5, Int((x * 0.6 + y * 0.4) * 6))]
        }
        let palette = try #require(AlbumArtPalette.extract(from: cover))
        let reds = palette.colors.filter { (hue($0) < 20 || hue($0) > 340) && chroma($0) > 0.14 }
        let greens = palette.colors.filter { abs(hue($0) - 157) < 25 && chroma($0) > 0.09 }
        #expect(reds.count == 1, "\(palette.colors)")
        #expect(greens.count == 1, "\(palette.colors)")
        // And the picture is still mostly brown: one or two of them are there too.
        #expect(palette.colors.contains { abs(hue($0) - 25) < 20 && chroma($0) < 0.12 })
    }

    @Test("A cover that is mostly one colour draws mostly in that colour, and its black isn't turned into a brown")
    func dominantColourFillsTheGradient() throws {
        // Mustard yellow, a black dog with a warm cast, a small red hat.
        let cover = picture { x, y in
            if x > 0.3 && x < 0.7 && y > 0.3 && y < 0.8 { return (34, 26, 22) }
            if x > 0.42 && x < 0.56 && y > 0.14 && y < 0.3 { return (196, 40, 44) }
            return (237, 191, 89)
        }
        let palette = try #require(AlbumArtPalette.extract(from: cover))
        let yellow = SIMD3<Float>(237, 191, 89) / 255
        #expect(palette.colors.contains { simd_distance($0, yellow) < 0.08 })
        #expect(palette.colors.contains { (hue($0) < 15 || hue($0) > 345) && chroma($0) > 0.14 })
        // Nothing in it is the dog: no colour is a dull brown.
        #expect(palette.colors.allSatisfy { chroma($0) > 0.09 }, "\(palette.colors)")
        // The gradient the bars are drawn along is yellow for most of its length.
        let yellowSlots = palette.ramp.dropFirst().filter { simd_distance($0, yellow) < 0.12 }.count
        #expect(yellowSlots >= 3, "\(palette.ramp)")
        // The accent everything is lit in is the yellow.
        #expect(simd_distance(palette.stops[2], yellow) < 0.12)
    }

    @Test("A dark colour is made bright enough to read by lifting it, not by washing it out with white")
    func darkStaysSaturated() throws {
        for dark in [SIMD3<Float>(10, 20, 90), SIMD3<Float>(90, 8, 20), SIMD3<Float>(8, 60, 30)] {
            let c = (UInt8(dark.x), UInt8(dark.y), UInt8(dark.z))
            let palette = try #require(AlbumArtPalette.extract(from: image(background: c)))
            let out = palette.colors[0]
            #expect(luminance(out) >= AlbumArtPalette.minimumLuminance - 0.001)
            #expect(abs(hue(out) - hue(dark / 255)) < 14 || abs(hue(out) - hue(dark / 255)) > 346, "\(dark) became \(out)")
            #expect(chroma(out) >= 0.9 * chroma(dark / 255), "\(dark) (chroma \(chroma(dark / 255))) became \(out) (chroma \(chroma(out)))")
        }
    }

    @Test("A black-and-white cover draws in its own greys (a sepia one in warm greys), not in the default copper")
    func greysForGreyCovers() throws {
        let photograph = picture { x, y in
            let v = Int(30 + 200 * (0.5 + 0.5 * sin(x * 7) * cos(y * 5)))
            return (v, v, v)
        }
        let palette = try #require(AlbumArtPalette.extract(from: photograph))
        #expect(palette.colors.count >= 2)
        #expect(palette.colors.allSatisfy { $0.max() - $0.min() < 0.05 }, "\(palette.colors)")
        #expect(isAscending(palette.colors.map(luminance)))
        let colours = VisualizerColors(theme: .albumArt, palette: palette)
        #expect(colours.usesRamp)
        #expect(colours.stops != VisualizerTheme.vespertine.stops)
        #expect(colours.stops.dropFirst().allSatisfy { $0.max() - $0.min() < 0.06 })
        // White with black type.
        let type = try #require(AlbumArtPalette.extract(from: image(background: (250, 250, 250), rects: [(CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1), (10, 10, 10))])))
        #expect(type.colors.allSatisfy { $0.max() - $0.min() < 0.05 })
        // Sepia keeps its warmth, faintly.
        let sepia = try #require(AlbumArtPalette.extract(from: picture { x, y in
            let v = 0.15 + 0.7 * (0.5 + 0.5 * sin(x * 6 + y * 4))
            return (Int(255 * v), Int(255 * v * 0.93), Int(255 * v * 0.84))
        }))
        #expect(sepia.colors.allSatisfy { $0.x >= $0.y && $0.y >= $0.z })
        #expect(sepia.colors.allSatisfy { chroma($0) < 0.06 })
    }

    @Test("Grain doesn't change the colours: a noisy scan gives the palette of the clean picture, near enough")
    func grain() throws {
        func cover(_ grain: Int) -> CGImage {
            picture(grain: grain) { x, _ in x < 0.5 ? (30, 90, 200) : (230, 120, 30) }
        }
        let clean = try #require(AlbumArtPalette.extract(from: cover(0))), noisy = try #require(AlbumArtPalette.extract(from: cover(22)))
        #expect(clean.colors.count == 2 && noisy.colors.count == 2)
        for (a, b) in zip(clean.colors, noisy.colors) { #expect(simd_distance(a, b) < 0.08) }
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
            #expect(isAscending(l))
            #expect(luminance(palette.ramp[0]) < 0.06, "the lowest stop stays a dark background")
            #expect(palette.stops.count == 4)
            let ls = palette.stops.map(luminance)
            #expect(isAscending(ls))
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

    @Test("A cover stored as a JPEG, decoded as the app decodes it, gives the colours of the picture it was made from")
    func throughAJPEG() throws {
        let cover = picture { x, y in y < 0.5 ? (24, 110, 200) : (240, 150, 40) }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cover, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try #require(VisualizerArtworkImage.load(data: data as Data))
        let direct = try #require(AlbumArtPalette.extract(from: cover)), stored = try #require(AlbumArtPalette.extract(from: decoded))
        #expect(direct.colors.count == 2 && stored.colors.count == 2)
        for (a, b) in zip(direct.colors, stored.colors) { #expect(simd_distance(a, b) < 0.06) }
    }

    @Test("On screen: with a blue cover the Album Art bars are blue, with an orange one orange, and without one the default copper")
    @MainActor
    func drawnInTheCoversColours() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        func bars(_ cover: CGImage?) throws -> SIMD3<Float> {
            let renderer = try #require(VisualizerRenderer())
            renderer.settings.style = .bars
            renderer.settings.theme = .albumArt
            renderer.settings.showsTrackInfo = false
            if let cover {
                #expect(renderer.setArtwork(cover))
                renderer.setAlbumPalette(AlbumArtPalette.extract(from: cover), animated: false)
            }
            var frame = VisualizerFrame.silent(bands: 64, fine: 512)
            frame.bands = .init(repeating: 0.8, count: 64)
            frame.peaks = frame.bands
            frame.hasSignal = true
            let size = CGSize(width: 320, height: 180)
            let pixels = try #require(renderer.renderOffscreen(frame: frame, scene: VisualizerScene(isPlaying: true), size: size, scale: 1, dt: 1.0 / 60))
            // The mean colour of the middle of the plot, where the bars are (BGRA).
            var sum = SIMD3<Float>.zero, n: Float = 0
            for y in 80..<130 { for x in 100..<220 {
                let i = (y * 320 + x) * 4
                sum += SIMD3(Float(pixels[i + 2]), Float(pixels[i + 1]), Float(pixels[i])); n += 1
            } }
            return sum / n / 255
        }
        let blue = try bars(picture { _, _ in (28, 92, 214) })
        #expect(blue.z > blue.x * 1.6 && blue.z > 0.3, "\(blue)")
        let orange = try bars(picture { _, _ in (240, 130, 30) })
        #expect(orange.x > orange.z * 2 && orange.x > 0.4, "\(orange)")
        let none = try bars(nil)
        #expect(none.x > none.y && none.y > none.z, "\(none)")      // copper and brass
        let grey = try bars(picture { x, _ in let v = Int(40 + 200 * x); return (v, v, v) })
        #expect(abs(grey.x - grey.z) < 0.04, "\(grey)")
    }
}
