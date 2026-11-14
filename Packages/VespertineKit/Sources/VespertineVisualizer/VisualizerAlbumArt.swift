//
// Vespertine: the Album Art colour theme: a palette of the cover's own colours, how it becomes the visualizer's
// colours, and the short fade between one song's palette and the next.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import simd

/// Up to five distinct colours taken from a cover, dark to bright: the colours a person would name looking at it,
/// not the average of its pixels. Extraction is deterministic (a variance-driven split of the cover's colours into
/// boxes, then a few rounds of k-means, in OKLab), so the same cover always gives the same palette, and it's meant to
/// run off the main thread (`extract` is a plain function of the image).
///
/// What decides it:
/// - A pixel is a colour when it's far enough from grey for how dark it is (a near-black with a warm cast is black,
///   not brown). Pixels count for more the more vivid they are, so a red chair in a brown room is found as red.
/// - Of the clusters, the ones kept are the largest and most vivid first, each clearly different from the ones
///   already kept, and no more than two dull ones, so wood, skin and shadow don't fill every place.
/// - A dark colour is made readable by raising its lightness and keeping its hue and its saturation, not by mixing
///   it with white.
/// - A cover with no colour to speak of (black and white, sepia) gives its own greys, with whatever tint it has.
///   Only a cover that is all but black, or no cover, gives no palette.
public struct AlbumArtPalette: Sendable, Equatable {
    /// The cover's colours, dark to bright, each bright enough to read against the visualizer's dark background.
    public let colors: [SIMD3<Float>]
    /// How much of the gradient each colour gets (they sum to 1): a cover that is mostly yellow draws mostly in
    /// yellow, with its other colours as narrower bands.
    public let weights: [Float]
    /// The index (in `colors`) of the cover's main colour, and of its second (the main one again if it has one).
    public let primary: Int
    public let secondary: Int
    /// The cover has no colour to speak of: these are its greys.
    public let isNeutral: Bool

    public static let maxColors = 5
    /// The ramp the shaders run along, dark to bright.
    public static let rampSize = 6
    /// The least brightness (Rec. 709 weights on the sRGB values, as the built-in themes are ordered) a colour drawn
    /// on the background may have: about that of the built-in themes' dimmest drawn colour (Ice's blue, 0.30).
    public static let minimumLuminance: Float = 0.30

    /// The picture is looked at this small: 64 × 64 pixels is plenty for a cover's colours, and small type survives.
    static let sample = 64
    /// OKLab chroma (distance from grey; a pure red is about 0.26) a pixel needs to be a colour: this much at mid
    /// lightness and above, more the darker it is, and nothing under `minimumLightness` is.
    static let minimumChroma: Float = 0.035
    static let darkChroma: Float = 0.09
    static let minimumLightness: Float = 0.13
    /// Under this share of the picture in colour, the cover is black and white (or sepia, or blank).
    static let minimumColourShare = 0.03
    /// Colours closer than this in OKLab are one colour; clusters under this share of the coloured pixels are dropped.
    static let distinctDistance: Float = 0.10
    static let minimumClusterShare: Float = 0.012
    /// A cluster under this chroma is a dull one (browns, beiges, greyed blues): at most two are kept.
    static let dullChroma: Float = 0.075
    /// The lightness (OKLab) dark colours are raised to.
    static let liftedLightness: Float = 0.60
    /// No colour gets less of the gradient than this.
    static let minimumWeight: Float = 0.12

    init(colors: [SIMD3<Float>], weights: [Float]? = nil, primary: Int? = nil, secondary: Int? = nil, isNeutral: Bool = false) {
        self.colors = colors
        let given = weights.map { $0.count == colors.count ? $0 : nil } ?? nil
        let even = [Float](repeating: 1 / Float(max(colors.count, 1)), count: colors.count)
        self.weights = Self.normalized(given ?? even)
        self.primary = min(max(primary ?? colors.count - 1, 0), max(colors.count - 1, 0))
        self.secondary = min(max(secondary ?? self.primary, 0), max(colors.count - 1, 0))
        self.isNeutral = isNeutral
    }

    /// Weights that sum to 1, none under `minimumWeight` (when there's room for that).
    private static func normalized(_ w: [Float]) -> [Float] {
        guard !w.isEmpty else { return [] }
        let total = max(w.reduce(0, +), 1e-9)
        var out = w.map { max($0 / total, 0) }
        let floor = min(minimumWeight, 1 / Float(w.count))
        out = out.map { max($0, floor) }
        let sum = out.reduce(0, +)
        return out.map { $0 / sum }
    }

    /// The palette of a cover, or nil when it has none (no cover, or all but black): the theme then draws in the
    /// default colours.
    public static func extract(from image: CGImage?) -> AlbumArtPalette? {
        guard let image, let pixels = samplePixels(image) else { return nil }
        var points: [Point] = []
        var labs: [SIMD3<Float>] = []
        labs.reserveCapacity(pixels.count)
        for p in pixels {
            let lab = oklab(fromSRGB: p)
            labs.append(lab)
            let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            guard isColour(lightness: lab.x, chroma: c) else { continue }
            // Vivid pixels count for more (up to about six times a barely coloured one).
            let vivid = min(max(c / 0.06, 0.5), 3.2)
            points.append(Point(lab: lab, weight: vivid * vivid.squareRoot(), chroma: c))
        }
        guard points.count >= 8, Double(points.count) / Double(pixels.count) >= minimumColourShare else { return greys(labs) }

        var centres = split(points, into: maxColors + 5)
        for _ in 0..<6 { centres = refine(centres, points) }
        let (weight, count) = weights(of: centres, points)
        let totalWeight = max(weight.reduce(0, +), 1), totalCount = max(count.reduce(0, +), 1)

        // The largest and most vivid first; a colour too close to one already taken, or too rare to matter, is left
        // out, and so is a third dull one.
        func chroma(_ c: SIMD3<Float>) -> Float { (c.y * c.y + c.z * c.z).squareRoot() }
        func score(_ i: Int) -> Float { (weight[i] / totalWeight).squareRoot() * (0.25 + chroma(centres[i]) / 0.12) }
        let order = centres.indices.sorted { score($0) != score($1) ? score($0) > score($1) : $0 < $1 }
        var kept: [Int] = []
        var dull = 0
        for i in order {
            guard count[i] / totalCount >= minimumClusterShare || kept.isEmpty else { continue }
            guard kept.allSatisfy({ simd_distance(centres[$0], centres[i]) >= distinctDistance }) else { continue }
            let isDull = chroma(centres[i]) < dullChroma
            if isDull && dull >= 2 && !kept.isEmpty { continue }
            if isDull { dull += 1 }
            kept.append(i)
            if kept.count == maxColors { break }
        }
        guard !kept.isEmpty else { return greys(labs) }
        // Every coloured pixel belongs to the kept colour nearest it: that's how much of the gradient each gets.
        let keptCentres = kept.map { centres[$0] }
        var share = [Float](repeating: 0, count: kept.count)
        for p in points { share[nearest(p.lab, keptCentres)] += 1 + 0.5 * p.weight }
        // Dark to bright by the cover's own brightness: lifting two dark colours to the floor would leave them tied.
        let sorted = kept.indices.sorted {
            let a = luminance(srgb(fromOKLab: keptCentres[$0])), b = luminance(srgb(fromOKLab: keptCentres[$1]))
            return a != b ? a < b : $0 < $1
        }
        return AlbumArtPalette(colors: sorted.map { displayed(keptCentres[$0]) }, weights: sorted.map { share[$0] },
                               primary: sorted.firstIndex(of: 0), secondary: sorted.firstIndex(of: kept.count > 1 ? 1 : 0))
    }

    /// Whether a pixel of this lightness and chroma (OKLab) is a colour rather than a grey, a black or a white.
    static func isColour(lightness: Float, chroma: Float) -> Bool {
        guard lightness >= minimumLightness else { return false }
        // The darker, the more chroma it takes: from `darkChroma` at the darkest to `minimumChroma` from 0.4 up.
        let t = min(max((lightness - minimumLightness) / (0.4 - minimumLightness), 0), 1)
        return chroma >= darkChroma + (minimumChroma - darkChroma) * t
    }

    /// The palette of a cover without colour: three greys from its own lights and darks, with its own tint (a sepia
    /// print stays warm). Nil when it's all but black.
    private static func greys(_ labs: [SIMD3<Float>]) -> AlbumArtPalette? {
        guard !labs.isEmpty else { return nil }
        let lightness = labs.map(\.x).sorted()
        func at(_ q: Float) -> Float { lightness[min(lightness.count - 1, Int(q * Float(lightness.count - 1)))] }
        guard at(0.9) >= 0.3 else { return nil }
        var tint = SIMD2<Float>(0, 0)
        for lab in labs { tint += SIMD2(lab.y, lab.z) }
        tint /= Float(labs.count)
        let length = simd_length(tint)
        if length > 0.03 { tint *= 0.03 / length }
        // Its mid grey, its light grey and its white, kept apart and readable.
        let mid = min(max(at(0.5), 0.60), 0.72), light = min(max(at(0.8), mid + 0.12), 0.86), white = min(max(at(0.97), light + 0.08), 0.96)
        let colours = [mid, light, white].map { srgb(fromOKLab: SIMD3($0, tint.x, tint.y)) }
        return AlbumArtPalette(colors: colours, weights: [0.3, 0.4, 0.3], primary: 1, secondary: 0, isNeutral: true)
    }

    /// Six colours from dark to bright for the shaders' gradient: a dark tint of the cover's main colour (the
    /// background end), then the palette's colours, each over as much of the rest as its share of the cover. A
    /// single colour runs up to a paler tint of itself.
    public var ramp: [SIMD3<Float>] {
        var line = colors, share = weights
        if line.count == 1 {
            line.append(Self.mix(line[0], .one, 0.55))
            share = [0.6, 0.4]
        }
        let main = colors[primary]
        let dark = main * (0.05 / max(Self.luminance(main), 0.05))
        // Each colour sits at the middle of its share of the line; between two, they blend.
        var centre: [Float] = []
        var run: Float = 0
        for w in share { centre.append(run + w / 2); run += w }
        var out = [dark]
        let slots = Self.rampSize - 1
        for i in 0..<slots {
            let x = Float(i) / Float(slots - 1)
            var j = 0
            while j < centre.count - 2 && x > centre[j + 1] { j += 1 }
            let span = max(centre[j + 1] - centre[j], 1e-6)
            // Hold each colour over the middle of its band and blend only near the joins.
            let t = min(max((x - centre[j]) / span, 0), 1)
            out.append(Self.mix(line[j], line[j + 1], t * t * (3 - 2 * t)))
        }
        return out
    }

    /// The four colours the shaders use by role (dark surface, mid, accent, highlight), as the built-in themes have:
    /// a dark tint of the main colour, the second colour, the main colour, and the brightest made paler.
    public var stops: [SIMD3<Float>] {
        let main = colors[primary]
        let surface = main * (0.05 / max(Self.luminance(main), 0.05))
        let mid = secondary != primary ? colors[secondary] : Self.mix(main, surface, 0.35)
        let brightest = colors[colors.count - 1]
        return [surface, mid, main, Self.mix(brightest, .one, colors.count == 1 ? 0.55 : 0.35)]
    }

    // MARK: Colour

    static func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

    /// A cluster's colour as it's drawn: at least `liftedLightness` light, with its hue, and as much of its chroma
    /// as sRGB has at that lightness; lighter still if that isn't yet bright enough to read on the background.
    static func displayed(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        var lightness = max(lab.x, liftedLightness)
        var out = fitted(SIMD3(lightness, lab.y, lab.z))
        while luminance(out) < minimumLuminance && lightness < 0.96 {
            lightness += 0.02
            out = fitted(SIMD3(lightness, lab.y, lab.z))
        }
        return out
    }

    /// The sRGB colour for an OKLab one, its chroma brought in (hue and lightness kept) until it fits sRGB.
    static func fitted(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        if let c = srgbIfInGamut(lab) { return c }
        var low: Float = 0, high: Float = 1
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if srgbIfInGamut(SIMD3(lab.x, lab.y * mid, lab.z * mid)) != nil { low = mid } else { high = mid }
        }
        return srgb(fromOKLab: SIMD3(lab.x, lab.y * low, lab.z * low))
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

    private static func linearRGB(fromOKLab c: SIMD3<Float>) -> SIMD3<Float> {
        let l = pow(c.x + 0.3963377774 * c.y + 0.2158037573 * c.z, 3)
        let m = pow(c.x - 0.1055613458 * c.y - 0.0638541728 * c.z, 3)
        let s = pow(c.x - 0.0894841775 * c.y - 1.2914855480 * c.z, 3)
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    static func srgb(fromOKLab c: SIMD3<Float>) -> SIMD3<Float> {
        let rgb = linearRGB(fromOKLab: c)
        return simd_clamp(SIMD3(encoded(max(rgb.x, 0)), encoded(max(rgb.y, 0)), encoded(max(rgb.z, 0))), .zero, .one)
    }

    /// The sRGB colour, or nil when the OKLab one is outside sRGB (by more than rounding).
    private static func srgbIfInGamut(_ c: SIMD3<Float>) -> SIMD3<Float>? {
        let rgb = linearRGB(fromOKLab: c)
        guard rgb.min() >= -0.002, rgb.max() <= 1.002 else { return nil }
        return simd_clamp(SIMD3(encoded(max(rgb.x, 0)), encoded(max(rgb.y, 0)), encoded(max(rgb.z, 0))), .zero, .one)
    }

    // MARK: Pixels

    /// The picture as 64 × 64 sRGB pixels (0…1), transparent ones left out.
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
        var chroma: Float
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
        let total = points.reduce(Float(0)) { $0 + $1.weight }
        while boxes.count < count {
            var best = -1, bestSpread: Float = 0.0005 * total   // a box this tight is one colour
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

    /// Each centre's points: their summed weight, and how many they are.
    private static func weights(of centres: [SIMD3<Float>], _ points: [Point]) -> (weight: [Float], count: [Float]) {
        var w = [Float](repeating: 0, count: centres.count), n = w
        for p in points {
            let i = nearest(p.lab, centres)
            w[i] += p.weight
            n[i] += 1
        }
        return (w, n)
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
