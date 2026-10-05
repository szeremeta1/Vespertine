//
// Vespertine — cover art for the Nomad's media widget: 80×80, 256 colours, in LVGL's indexed-8 image layout.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import ImageIO

public enum NomadArtwork {
    /// LVGL v9 image header: magic, color format (I8 = 0x0A), flags, width, height, stride, reserved.
    static let magic: UInt8 = 0x19
    static let formatIndexed8: UInt8 = 0x0A
    static let headerBytes = 12
    static let paletteBytes = 256 * 4

    /// The bytes `mp.write_artwork` carries for `image`: cropped to a square from the centre, scaled to 80×80.
    public static func encode(_ image: CGImage) -> Data? {
        let side = NomadProtocol.artworkSide
        guard let rgba = rasterize(image, side: side) else { return nil }
        return encode(rgba: rgba, side: side)
    }

    /// Same, from encoded image data (JPEG, PNG, …).
    public static func encode(imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image)
    }

    /// `rgba`: side × side pixels, 4 bytes each (R, G, B, A), alpha already composited onto black.
    static func encode(rgba: [UInt8], side: Int) -> Data {
        let pixelCount = side * side
        let colors = (0..<pixelCount).map { i in RGB(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) }
        let palette = MedianCut.palette(for: colors, size: 256)
        let lookup = NearestColor(palette: palette)

        var out = Data(capacity: headerBytes + paletteBytes + pixelCount)
        out.append(contentsOf: [magic, formatIndexed8, 0, 0])
        for value in [side, side, side, 0] {
            out.append(UInt8(value & 0xFF)); out.append(UInt8(value >> 8))
        }
        for i in 0..<256 {
            let c = i < palette.count ? palette[i] : RGB(0, 0, 0)
            out.append(contentsOf: [c.b, c.g, c.r, 0xFF])   // BGRA
        }
        for color in colors { out.append(lookup.index(of: color)) }
        return out
    }

    /// The image back out of the LVGL bytes (RGBA, side × side), for checking what was written.
    public static func decode(_ data: Data) -> (side: Int, rgba: [UInt8])? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes + paletteBytes, bytes[0] == magic, bytes[1] == formatIndexed8 else { return nil }
        let width = Int(bytes[4]) | Int(bytes[5]) << 8, height = Int(bytes[6]) | Int(bytes[7]) << 8
        let stride = Int(bytes[8]) | Int(bytes[9]) << 8
        guard width == height, stride >= width, bytes.count >= headerBytes + paletteBytes + stride * height else { return nil }
        var rgba = [UInt8](); rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = Int(bytes[headerBytes + paletteBytes + y * stride + x])
                let p = headerBytes + index * 4
                rgba.append(contentsOf: [bytes[p + 2], bytes[p + 1], bytes[p], 0xFF])
            }
        }
        return (width, rgba)
    }

    private static func rasterize(_ image: CGImage, side: Int) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let crop = min(w, h)
        guard let square = image.cropping(to: CGRect(x: (w - crop) / 2, y: (h - crop) / 2, width: crop, height: crop)) else { return nil }
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .high
            context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? buffer : nil
    }
}

// MARK: - Quantizing

struct RGB: Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

enum MedianCut {
    /// Up to `size` colors that stand for `colors`: the box with the widest spread is split at its median until there
    /// are enough boxes, and each box becomes the average of what's in it.
    static func palette(for colors: [RGB], size: Int) -> [RGB] {
        // Histogram first: a cover has far fewer distinct colors than pixels, and most of them repeat.
        var counts: [RGB: Int] = [:]
        for c in colors { counts[c, default: 0] += 1 }
        let distinct = counts.map { (color: $0.key, count: $0.value) }
        if distinct.count <= size { return distinct.map(\.color).sorted { ($0.r, $0.g, $0.b) < ($1.r, $1.g, $1.b) } }

        var boxes = [distinct]
        while boxes.count < size {
            // The splittable box with the widest channel range.
            var best: (index: Int, channel: Int, range: Int)?
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let (channel, range) = widest(box)
                if range > (best?.range ?? 0) { best = (i, channel, range) }
            }
            guard let best else { break }
            var box = boxes[best.index]
            box.sort { value($0.color, best.channel) < value($1.color, best.channel) }
            // Split where the pixel count, not the color count, is halved.
            let total = box.reduce(0) { $0 + $1.count }
            var running = 0, cut = 1
            for (i, entry) in box.enumerated() {
                running += entry.count
                if running * 2 >= total { cut = min(max(i + 1, 1), box.count - 1); break }
            }
            boxes[best.index] = Array(box[..<cut])
            boxes.append(Array(box[cut...]))
        }
        return boxes.map(average).sorted { ($0.r, $0.g, $0.b) < ($1.r, $1.g, $1.b) }
    }

    private static func value(_ c: RGB, _ channel: Int) -> Int { channel == 0 ? Int(c.r) : channel == 1 ? Int(c.g) : Int(c.b) }

    private static func widest(_ box: [(color: RGB, count: Int)]) -> (channel: Int, range: Int) {
        var low = [255, 255, 255], high = [0, 0, 0]
        for (c, _) in box {
            for ch in 0..<3 { let v = value(c, ch); low[ch] = min(low[ch], v); high[ch] = max(high[ch], v) }
        }
        // The eye is most sensitive to green, then red: weigh the ranges so a dark gradient isn't split by its blue.
        let weighted = [(high[0] - low[0]) * 3, (high[1] - low[1]) * 4, (high[2] - low[2]) * 2]
        let channel = weighted.indices.max { weighted[$0] < weighted[$1] }!
        return (channel, weighted[channel])
    }

    private static func average(_ box: [(color: RGB, count: Int)]) -> RGB {
        var r = 0, g = 0, b = 0, n = 0
        for (c, count) in box { r += Int(c.r) * count; g += Int(c.g) * count; b += Int(c.b) * count; n += count }
        n = max(n, 1)
        return RGB(UInt8((r + n / 2) / n), UInt8((g + n / 2) / n), UInt8((b + n / 2) / n))
    }
}

/// Nearest palette entry by squared distance, weighted toward green like the split was.
struct NearestColor {
    let palette: [RGB]

    init(palette: [RGB]) { self.palette = palette }

    func index(of color: RGB) -> UInt8 {
        var best = 0, bestDistance = Int.max
        for (i, p) in palette.enumerated() {
            let dr = Int(p.r) - Int(color.r), dg = Int(p.g) - Int(color.g), db = Int(p.b) - Int(color.b)
            let d = dr * dr * 3 + dg * dg * 4 + db * db * 2
            if d < bestDistance { best = i; bestDistance = d; if d == 0 { break } }
        }
        return UInt8(best)
    }
}
