// SPDX-License-Identifier: GPL-3.0-or-later
// Source media: window recordings of the real app (2880×1800, the 1440×900 pt window at 2×), stills,
// brand art and fonts.
import AVFoundation
import AppKit
import CoreImage
import CoreText

/// Paths the stage reads from. `raw` holds the window recordings made with raw/tools/rec.sh.
struct Paths {
    let repo: URL
    let raw: URL
    var fonts: URL { repo.appendingPathComponent("docs/design/fonts") }
    var brand: URL { repo.appendingPathComponent("docs/brand") }
    func recording(_ name: String) -> URL { raw.appendingPathComponent("\(name).mov") }
}

/// Geometry of the recorded window, in points (the recordings are 2× these).
enum AppWindow {
    static let size = CGSize(width: 1440, height: 900)
    static let scale: CGFloat = 2
    static let sidebar = CGRect(x: 0, y: 0, width: 232, height: 824)
    static let inspector = CGRect(x: 1091, y: 50, width: 349, height: 774)
    static let transport = CGRect(x: 0, y: 824, width: 1440, height: 76)
    static let content = CGRect(x: 232, y: 0, width: 859, height: 824)
    /// macOS draws a purple "being recorded" pill over the window buttons; it is covered by clean buttons.
    static let indicator = CGRect(x: 0, y: 6, width: 104, height: 40)
}

// MARK: - Video

/// Sequential frame access to a recording. `frame(at:)` returns the newest frame at or before `t`
/// (seconds from `start`), so a 57–60 fps recording maps cleanly onto the 60 fps timeline.
final class VideoSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CGImage?
    private var pending: (Double, CGImage)?
    private let start: Double
    private static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    init(_ url: URL, from start: Double) throws {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var loaded: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in loaded = tracks?.first; semaphore.signal() }
        semaphore.wait()
        guard let track = loaded else { throw NSError(domain: "stage", code: 1, userInfo: [NSLocalizedDescriptionKey: "no video in \(url.lastPathComponent)"]) }
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 6000), duration: .positiveInfinity)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        self.start = start
    }

    private func read() -> (Double, CGImage)? {
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = VideoSource.context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return (sample.presentationTimeStamp.seconds - start, cg)
    }

    func frame(at t: Double) -> CGImage? {
        if pending == nil { pending = read() }
        while let next = pending, next.0 <= t { current = next.1; pending = read() }
        if current == nil { current = pending?.1 }
        return current
    }
}

// MARK: - Stills

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("can't read \(url.path)")
    }
    return image
}

func firstFrame(of url: URL, at seconds: Double) -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let semaphore = DispatchSemaphore(value: 0)
    var result: CGImage?
    generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { image, _, _ in result = image; semaphore.signal() }
    semaphore.wait()
    guard let result else { fatalError("no frame at \(seconds) s in \(url.lastPathComponent)") }
    return result
}

/// Crops a rectangle given in window points out of a 2× frame.
func crop(_ image: CGImage, _ rect: CGRect) -> CGImage {
    let s = CGFloat(image.width) / AppWindow.size.width
    return image.cropping(to: CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral)!
}

/// Turns a flat panel into a transparent one: pixels close to `background` become clear, so the
/// panel's text and icons can float over real Liquid Glass. The matte is soft to keep antialiasing.
func keyOut(_ image: CGImage, background: (r: Double, g: Double, b: Double), tolerance: Double = 0.035, softness: Double = 0.09) -> CGImage {
    let w = image.width, h = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in 0..<(w * h) {
        let r = Double(p[i * 4]) / 255, g = Double(p[i * 4 + 1]) / 255, b = Double(p[i * 4 + 2]) / 255
        let d = sqrt(pow(r - background.r, 2) + pow(g - background.g, 2) + pow(b - background.b, 2))
        let a = smooth((d - tolerance) / softness)
        // Un-mix the background so light text doesn't keep a dark fringe.
        func unmix(_ c: Double, _ k: Double) -> UInt8 {
            guard a > 0.001 else { return 0 }
            let straight = min(1, max(0, (c - k * (1 - a)) / a))
            return UInt8(straight * a * 255)
        }
        p[i * 4] = unmix(r, background.r); p[i * 4 + 1] = unmix(g, background.g); p[i * 4 + 2] = unmix(b, background.b)
        p[i * 4 + 3] = UInt8(a * 255)
    }
    return ctx.makeImage()!
}

/// Average colour of a small area (window points) of a frame, as 0…1 sRGB.
func sampleColor(_ image: CGImage, at rect: CGRect) -> (r: Double, g: Double, b: Double) {
    let region = crop(image, rect)
    let w = region.width, h = region.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(region, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var r = 0.0, g = 0.0, b = 0.0
    for i in 0..<(w * h) { r += Double(p[i * 4]); g += Double(p[i * 4 + 1]); b += Double(p[i * 4 + 2]) }
    let n = Double(w * h) * 255
    return (r / n, g / n, b / n)
}

// MARK: - Fonts

/// Brand fonts (SIL OFL), registered for this process only. Apple's New York and SF appear only
/// inside the app's own interface, which is what their licence covers.
enum BrandFont {
    static func register(_ paths: Paths) {
        for file in ["Newsreader[opsz,wght].ttf", "Inter[opsz,wght].ttf", "JetBrainsMono[wght].ttf"] {
            CTFontManagerRegisterFontsForURL(paths.fonts.appendingPathComponent(file) as CFURL, .process, nil)
        }
    }

    static func make(_ family: String, _ size: CGFloat, weight: CGFloat) -> NSFont {
        let axes: [NSNumber: CGFloat] = [NSNumber(value: 0x7767_6874): weight, NSNumber(value: 0x6F70_737A): min(max(size, 6), 72)]
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .variation: axes])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { fatalError("\(family) isn't registered") }
        return font
    }

    static func serif(_ size: CGFloat, _ weight: CGFloat = 300) -> NSFont { make("Newsreader", size, weight: weight) }
    static func sans(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont { make("Inter", size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont { make("JetBrains Mono", size, weight: weight) }
}

// MARK: - Live readouts

/// The six channel meters in the Spatial Audio recording (window points): L R C LFE Ls Rs.
enum Meters {
    static let columns: [CGFloat] = [1118.75, 1138.75, 1158.75, 1179.75, 1200.75, 1220.75]
    static let top: CGFloat = 642, bottom: CGFloat = 712
    /// The meters and their letters, without the "CHANNELS · SPATIAL AUDIO" caption above them (621–630).
    static let region = CGRect(x: 1108, y: 634, width: 124, height: 98)

    /// How full each meter is (0…1) in this frame, read from the brass fill.
    static func levels(_ frame: CGImage) -> [Double] {
        let s = CGFloat(frame.width) / AppWindow.size.width
        let area = CGRect(x: columns.first! * s - 4, y: top * s, width: (columns.last! - columns.first!) * s + 8, height: (bottom - top) * s).integral
        guard let cut = frame.cropping(to: area) else { return Array(repeating: 0, count: 6) }
        let w = cut.width, h = cut.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return columns.map { cx in
            let x = Int((cx - columns.first!) * s) + 4
            // Row 0 of the bitmap is the top of the meter; the brass fill runs up from the bottom.
            var topmost = h
            for row in 0..<h {
                let i = (row * w + x) * 4
                if Int(p[i]) > 90 && Int(p[i]) > Int(p[i + 2]) + 25 { topmost = row; break }
            }
            return topmost >= h ? 0 : Double(h - topmost) / Double(h)
        }
    }
}
