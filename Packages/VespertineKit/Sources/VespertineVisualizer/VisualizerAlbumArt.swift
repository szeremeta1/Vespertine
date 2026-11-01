//
// Vespertine — the Album Art colour theme: a palette of the cover's own colours, how it becomes the visualizer's
// colours, and the short fade between one song's palette and the next.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import simd

/// Up to five distinct colours taken from a cover, dark to bright. Extraction is deterministic (a variance-driven
/// split of the cover's colours into boxes, then a few rounds of k-means, in OKLab), so the same cover always gives
/// the same palette, and it's meant to run off the main thread (`extract` is a plain function of the image).
public struct AlbumArtPalette: Sendable, Equatable {
    /// The cover's colours, dark to bright, each bright enough to read against the visualizer's dark background.
    public let colors: [SIMD3<Float>]

    public static let maxColors = 5
    /// The ramp the shaders run along, dark to bright.
    public static let rampSize = 6
    /// The least brightness (Rec. 709 weights on the sRGB values, as the built-in themes are ordered) a colour drawn
    /// on the background may have: about that of the built-in themes' dimmest drawn colour (Ice's blue, 0.30).
    public static let minimumLuminance: Float = 0.30

    /// The picture is looked at this small: 48 × 48 pixels is plenty for a cover's colours.
    static let sample = 48
    /// A pixel counts as colour when it's neither grey (chroma, max - min of sRGB, under this) nor black.
    static let minimumChroma: Float = 0.08
    static let minimumValue: Float = 0.18
    /// Under this share of the picture in colour, the cover is grayscale, blank or too dark and has no palette.
    static let minimumColourShare = 0.04
    /// Colours closer than this in OKLab are one colour; clusters under this share of the colour are dropped.
    static let distinctDistance: Float = 0.09
    static let minimumClusterShare: Float = 0.025

    init(colors: [SIMD3<Float>]) { self.colors = colors }

    /// The palette of a cover, or nil when it has none to speak of (no cover, grayscale, blank, or too dark): the
    /// theme then draws in the default colours.
    public static func extract(from image: CGImage?) -> AlbumArtPalette? {
        guard let image, let pixels = samplePixels(image) else { return nil }
        var points: [Point] = []
        var counted = 0
        for p in pixels {
            counted += 1
            let mx = max(p.x, p.y, p.z), mn = min(p.x, p.y, p.z)
            guard mx - mn >= minimumChroma, mx >= minimumValue else { continue }
            points.append(Point(lab: oklab(fromSRGB: p), weight: 1))
        }
        guard counted > 0, points.count >= 8, Double(points.count) / Double(counted) >= minimumColourShare else { return nil }

        var centres = split(points, into: maxColors + 3)
        for _ in 0..<6 { centres = refine(centres, points) }
        let weights = weights(of: centres, points)
        let total = max(weights.reduce(0, +), 1)

        // The heaviest first; a colour too close to one already taken, or too rare to matter, is left out.
        var kept: [SIMD3<Float>] = []
        for i in centres.indices.sorted(by: { weights[$0] != weights[$1] ? weights[$0] > weights[$1] : $0 < $1 }) {
            guard weights[i] / total >= minimumClusterShare || kept.isEmpty else { continue }
            guard kept.allSatisfy({ simd_distance($0, centres[i]) >= distinctDistance }) else { continue }
            kept.append(centres[i])
            if kept.count == maxColors { break }
        }
        guard !kept.isEmpty else { return nil }
        // Dark to bright by the cover's own brightness: lifting two dark colours to the floor would leave them tied.
        let colours = kept.map { srgb(fromOKLab: $0) }.sorted { luminance($0) < luminance($1) }
        return AlbumArtPalette(colors: colours.map(readable))
    }

    /// Six colours from dark to bright for the shaders' gradient: a dark tint of the palette's darkest colour (the
    /// background end), then the palette's colours run through evenly. A single colour runs up to a paler tint of
    /// itself.
    public var ramp: [SIMD3<Float>] {
        var line = colors
        if line.count == 1 { line.append(Self.mix(line[0], .one, 0.6)) }
        let dark = colors[0] * (0.05 / max(Self.luminance(colors[0]), 0.05))
        var out = [dark]
        let slots = Self.rampSize - 1
        for i in 0..<slots {
            let t = Float(i) / Float(slots - 1) * Float(line.count - 1)
            let j = min(Int(t), line.count - 2)
            out.append(Self.mix(line[j], line[j + 1], t - Float(j)))
        }
        return out
    }

    /// The four colours the shaders use by role (dark surface, mid, accent, highlight), as the built-in themes have.
    public var stops: [SIMD3<Float>] {
        let r = ramp
        return [r[0], r[2], r[4], Self.mix(r[5], .one, 0.3)]
    }

    // MARK: Colour

    static func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

    /// The colour lightened toward white until it can be read on the dark background.
    static func readable(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_clamp(c, .zero, .one)
        let l = luminance(c)
        guard l < minimumLuminance else { return c }
        // Solve luminance(mix(c, white, t)) = minimum; luminance(white) = 1.
        let t = (minimumLuminance - l) / (1 - l)
        return mix(c, .one, min(max(t, 0), 1))
    }

    private static func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func encoded(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    static func oklab(fromSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        let r = linear(c.x), g = linear(c.y), b = linear(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func srgb(fromOKLab c: SIMD3<Float>) -> SIMD3<Float> {
        let l = pow(c.x + 0.3963377774 * c.y + 0.2158037573 * c.z, 3)
        let m = pow(c.x - 0.1055613458 * c.y - 0.0638541728 * c.z, 3)
        let s = pow(c.x - 0.0894841775 * c.y - 1.2914855480 * c.z, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return simd_clamp(SIMD3(encoded(max(r, 0)), encoded(max(g, 0)), encoded(max(b, 0))), .zero, .one)
    }

    // MARK: Pixels

    /// The picture as 48 × 48 sRGB pixels (0…1), transparent ones left out.
    private static func samplePixels(_ image: CGImage) -> [SIMD3<Float>]? {
        let n = sample
        var data = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            let a = Float(data[i * 4 + 3]) / 255
            guard a >= 0.5 else { continue }
            // Premultiplied: divide the coverage back out.
            out.append(simd_clamp(SIMD3(Float(data[i * 4]), Float(data[i * 4 + 1]), Float(data[i * 4 + 2])) / (255 * a), .zero, .one))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Clustering

    private struct Point {
        var lab: SIMD3<Float>
        var weight: Float
    }

    /// Splits the points into up to `count` boxes: always the box with the most spread (summed squared distance from
    /// its mean) goes next, cut across its widest axis at the mean, so a small patch of a very different colour is
    /// set apart before a large field is cut finer. Returns the boxes' means.
    private static func split(_ points: [Point], into count: Int) -> [SIMD3<Float>] {
        var boxes: [[Point]] = [points]
        func mean(_ box: [Point]) -> SIMD3<Float> {
            var sum = SIMD3<Float>.zero, w: Float = 0
            for p in box { sum += p.lab * p.weight; w += p.weight }
            return w > 0 ? sum / w : .zero
        }
        func spread(_ box: [Point]) -> Float {
            let m = mean(box)
            return box.reduce(0) { $0 + $1.weight * simd_length_squared($1.lab - m) }
        }
        while boxes.count < count {
            var best = -1, bestSpread: Float = 0.0005 * Float(points.count)   // a box this tight is one colour
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let s = spread(box)
                if s > bestSpread { best = i; bestSpread = s }
            }
            guard best >= 0 else { break }
            let box = boxes[best], m = mean(box)
            var variance = SIMD3<Float>.zero
            for p in box { let d = p.lab - m; variance += p.weight * d * d }
            let axis = variance.x >= variance.y && variance.x >= variance.z ? 0 : (variance.y >= variance.z ? 1 : 2)
            let low = box.filter { $0.lab[axis] <= m[axis] }, high = box.filter { $0.lab[axis] > m[axis] }
            guard !low.isEmpty, !high.isEmpty else { break }
            boxes[best] = low
            boxes.append(high)
        }
        return boxes.map(mean)
    }

    /// One round of k-means: each point to its nearest centre (the first on a tie), each centre to its points' mean.
    private static func refine(_ centres: [SIMD3<Float>], _ points: [Point]) -> [SIMD3<Float>] {
        var sums = [SIMD3<Float>](repeating: .zero, count: centres.count), weights = [Float](repeating: 0, count: centres.count)
        for p in points {
            let i = nearest(p.lab, centres)
            sums[i] += p.lab * p.weight
            weights[i] += p.weight
        }
        return centres.indices.map { weights[$0] > 0 ? sums[$0] / weights[$0] : centres[$0] }
    }

    private static func weights(of centres: [SIMD3<Float>], _ points: [Point]) -> [Float] {
        var w = [Float](repeating: 0, count: centres.count)
        for p in points { w[nearest(p.lab, centres)] += p.weight }
        return w
    }

    private static func nearest(_ lab: SIMD3<Float>, _ centres: [SIMD3<Float>]) -> Int {
        var best = 0, bestD = Float.greatestFiniteMagnitude
        for (i, c) in centres.enumerated() {
            let d = simd_length_squared(lab - c)
            if d < bestD { best = i; bestD = d }
        }
        return best
    }
}

/// The colours a frame is drawn in: the four role colours every shader uses, and the six-colour ramp the gradients
/// run along when a palette is in use.
public struct VisualizerColors: Sendable, Equatable {
    /// Four colours from dark to bright (the theme's `stops`).
    public var stops: [SIMD3<Float>]
    /// Six colours from dark to bright: the album's palette, or the theme's own stops spread over six.
    public var ramp: [SIMD3<Float>]
    /// 0 draws gradients through `stops` (every built-in theme, and Album Art without a palette); 1 through `ramp`.
    public var rampWeight: Float

    public var usesRamp: Bool { rampWeight > 0 }

    /// The colours for a theme. Album Art with no palette (no cover, grayscale, too dark) is the default theme.
    public init(theme: VisualizerTheme, palette: AlbumArtPalette?) {
        if theme == .albumArt, let palette {
            stops = palette.stops
            ramp = palette.ramp
            rampWeight = 1
        } else {
            stops = theme.stops
            ramp = Self.spread(stops, over: AlbumArtPalette.rampSize)
            rampWeight = 0
        }
    }

    init(stops: [SIMD3<Float>], ramp: [SIMD3<Float>], rampWeight: Float) {
        self.stops = stops
        self.ramp = ramp
        self.rampWeight = rampWeight
    }

    static func spread(_ stops: [SIMD3<Float>], over count: Int) -> [SIMD3<Float>] {
        (0..<count).map { i in
            let t = Float(i) / Float(count - 1) * Float(stops.count - 1)
            let j = min(Int(t), stops.count - 2)
            return AlbumArtPalette.mix(stops[j], stops[j + 1], t - Float(j))
        }
    }

    static func blend(_ a: VisualizerColors, _ b: VisualizerColors, _ t: Float) -> VisualizerColors {
        VisualizerColors(stops: zip(a.stops, b.stops).map { AlbumArtPalette.mix($0, $1, t) },
                         ramp: zip(a.ramp, b.ramp).map { AlbumArtPalette.mix($0, $1, t) },
                         rampWeight: a.rampWeight + (b.rampWeight - a.rampWeight) * t)
    }
}

/// The Album Art colours changing from one song's palette to the next's over a short fade (the renderer advances it
/// by each frame's time). Other themes are never faded.
public struct VisualizerColorFade: Sendable, Equatable {
    public var duration: Double
    private var from = VisualizerColors(theme: .albumArt, palette: nil)
    private var to = VisualizerColors(theme: .albumArt, palette: nil)
    private var elapsed: Double

    public init(duration: Double = 0.8) {
        self.duration = duration
        elapsed = duration
    }

    /// Fades to a new palette from whatever is showing now (nil: back to the default colours), or jumps there.
    public mutating func set(_ palette: AlbumArtPalette?, animated: Bool) {
        let target = VisualizerColors(theme: .albumArt, palette: palette)
        guard target != to else { return }
        from = animated ? current(theme: .albumArt) : target
        to = target
        elapsed = animated ? 0 : duration
    }

    public mutating func advance(by dt: Double) {
        if dt.isFinite, dt > 0 { elapsed = min(elapsed + dt, duration) }
    }

    public var isFading: Bool { elapsed < duration }

    public func current(theme: VisualizerTheme) -> VisualizerColors {
        guard theme == .albumArt else { return VisualizerColors(theme: theme, palette: nil) }
        guard elapsed < duration, duration > 0 else { return to }
        let x = Float(max(0, elapsed / duration))
        return VisualizerColors.blend(from, to, x * x * (3 - 2 * x))
    }
}
