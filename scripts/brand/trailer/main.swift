// Renders the launch trailer's scenes (intro, six app scenes from screen recordings, end card) as ProRes files with
// half-second handles, ready to assemble with the music in an editor. Usage:
//   trailer-scenes <clips dir> <out dir> [wide|square]
// Clips are window recordings of Vespertine at 2880×1800 (see docs/press/README.md).
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit

let args = CommandLine.arguments
let clipsDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let mode = args.count > 3 ? args[3] : "wide"          // wide 1920×1080, square 1080×1080, vertical 1080×1920
let square = mode != "wide", vertical = mode == "vertical"
let W = square ? 1080 : 1920, H = vertical ? 1920 : 1080
/// Vertical cuts keep text clear of Shorts/Reels/TikTok controls: nothing in the top 250 or bottom 400 px.
let safeBottom: CGFloat = vertical ? 420 : 0
let fps: Int32 = 30, handle = 0.5, bar = 60.0 / 64 * 4   // Starlight Lounge, 64 BPM: one scene per bar
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func ease(_ t: CGFloat) -> CGFloat { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { ease(CGFloat((t - a) / (b - a))) }

// MARK: Source frames

/// Sequential frame access to a recording: frame(at:) returns the latest frame at or before the time.
final class Source {
    let reader: AVAssetReader, output: AVAssetReaderTrackOutput
    var current: CGImage?, next: (CMTime, CGImage)?
    init(_ url: URL, from start: Double) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); reader.startReading()
        self.start = CMTime(seconds: start, preferredTimescale: 600)
    }
    let start: CMTime
    private func read() -> (CMTime, CGImage)? {
        guard let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        let image = Source.ctx.createCGImage(ci, from: ci.extent)!
        return (CMTimeSubtract(sb.presentationTimeStamp, start), image)
    }
    static let ctx = CIContext(options: [.cacheIntermediates: false])
    func frame(at t: Double) -> CGImage {
        if next == nil { next = read() }
        while let n = next, n.0.seconds <= t { current = n.1; next = read() }
        if current == nil { current = next?.1 }
        return current!
    }
}

// MARK: Writer

final class Writer {
    let writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    var n: Int64 = 0
    init(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    }
    func append(_ draw: (CGContext) -> Void) {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(ctx)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(pb!, withPresentationTime: CMTime(value: n, timescale: fps)); n += 1
    }
    func finish() async { input.markAsFinished(); await writer.finishWriting() }
}

// MARK: Drawing helpers

func fillText(_ ctx: CGContext, _ s: String, _ font: CTFont, _ color: UInt32, _ alpha: CGFloat, x: CGFloat, baseline: CGFloat, tracking: CGFloat = 0, center: Bool = false) {
    let t = Brand.textPath(s, font: font, tracking: tracking)
    ctx.saveGState(); ctx.translateBy(x: center ? x - t.width / 2 : x, y: baseline)
    ctx.addPath(t.path); ctx.setFillColor(Brand.color(color, alpha)); ctx.fillPath(); ctx.restoreGState()
}

func background(_ ctx: CGContext, glow: CGFloat = 0.12) {
    let w = CGFloat(W), h = CGFloat(H)
    Brand.field(ctx, glowAt: CGPoint(x: w * 0.5, y: h * 0.55), glowRadius: max(w, h) * 0.7, glow: glow)
}

/// macOS draws a capture indicator where a recorded window's buttons are; the sidebar colour covers it.
func maskIndicator(_ image: CGImage) -> CGImage {
    let ctx = Brand.context(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let s = CGFloat(image.width) / 1440
    let sample = CGRect(x: 0, y: CGFloat(image.height) - 60 * s, width: 160 * s, height: 60 * s)
    ctx.setFillColor(Brand.color(0x1C1C1E)); ctx.fill(sample)
    return ctx.makeImage()!
}

/// A horizontal mask: opaque up to `fadeFrom`, fading to clear at `width`.
func scrimMask(width: CGFloat, fadeFrom: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: fadeFrom, y: 0), end: CGPoint(x: width, y: 0), options: [.drawsBeforeStartLocation])
    return ctx.makeImage()!
}

func wrapLines(_ s: String, _ font: CTFont, width: CGFloat, tracking: CGFloat = 0) -> [String] {
    var lines: [String] = [], line = ""
    for word in s.split(separator: " ") {
        let c = line.isEmpty ? String(word) : line + " " + word
        if Brand.textPath(c, font: font, tracking: tracking).width > width, !line.isEmpty { lines.append(line); line = String(word) } else { line = c }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

// MARK: Scenes

struct AppScene {
    var name: String, clip: String, from: Double, duration: Double
    var focus: CGRect           // region of the recording (px, top-left origin) the camera moves in on
    var zoom: CGFloat           // how far: 0 = stay on the whole window, 1 = focus fills the frame
    var headline: String, detail: String
}

let scenes: [AppScene] = [
    AppScene(name: "02-bit-perfect", clip: "bitperfect", from: 2.0, duration: bar, focus: CGRect(x: 2110, y: 560, width: 770, height: 1000), zoom: 0.75,
             headline: "Every sample, untouched.", detail: "BIT-PERFECT · 24-BIT · 192 kHz · EXCLUSIVE"),
    AppScene(name: "03-native-dsd", clip: "dsd", from: 2.0, duration: bar, focus: CGRect(x: 2110, y: 420, width: 770, height: 820), zoom: 0.75,
             headline: "Native DSD, not a conversion.", detail: "DSD64 · 2.8 MHz · DoP · 176.4 kHz"),
    AppScene(name: "04-stereo-and-surround", clip: "versions", from: 2.0, duration: bar, focus: CGRect(x: 440, y: 560, width: 1700, height: 900), zoom: 0.55,
             headline: "Stereo or surround, on its own.", detail: "5.1 FOR SURROUND AND SPATIAL AUDIO · STEREO FOR A STEREO DAC"),
    AppScene(name: "05-spatial-audio", clip: "spatial", from: 2.0, duration: bar, focus: CGRect(x: 2110, y: 260, width: 770, height: 1280), zoom: 0.75,
             headline: "Your 5.1 albums, all around you.", detail: "HEAD-TRACKED SPATIAL AUDIO · 6 CHANNELS"),
    AppScene(name: "06-fake-hi-res", clip: "analysis", from: 2.0, duration: bar, focus: CGRect(x: 2110, y: 120, width: 770, height: 1120), zoom: 0.75,
             headline: "Know when hi-res isn’t.", detail: "SPECTRAL ANALYSIS · UPSAMPLED · PADDED · LOSSY ORIGIN"),
    AppScene(name: "07a-albums", clip: "albums", from: 1.0, duration: bar / 2, focus: CGRect(x: 400, y: 200, width: 2480, height: 1500), zoom: 0.25,
             headline: "Your whole library.", detail: "FLAC · ALAC · WAV · AIFF · DSD · DOLBY · DTS"),
    AppScene(name: "07b-genres", clip: "genres", from: 1.0, duration: bar / 2, focus: CGRect(x: 400, y: 200, width: 2480, height: 1500), zoom: 0.25,
             headline: "Your whole library.", detail: "FLAC · ALAC · WAV · AIFF · DSD · DOLBY · DTS"),
    AppScene(name: "07c-search", clip: "search", from: 1.0, duration: bar / 2, focus: CGRect(x: 400, y: 150, width: 2480, height: 1500), zoom: 0.25,
             headline: "Your whole library.", detail: "FLAC · ALAC · WAV · AIFF · DSD · DOLBY · DTS"),
]

func renderApp(_ s: AppScene) async throws {
    let source = try await Source(clipsDir.appendingPathComponent("\(s.clip).mov"), from: max(0, s.from - handle))
    let writer = try Writer(outDir.appendingPathComponent("\(s.name).mov"))
    let total = s.duration + 2 * handle, frames = Int(total * Double(fps))
    let w = CGFloat(W), h = CGFloat(H)
    let montage = s.name.hasPrefix("07")
    for i in 0..<frames {
        let t = Double(i) / Double(fps), local = t - handle         // local: 0 at the scene's cut point
        let img = maskIndicator(source.frame(at: t))
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        // Camera: from the whole window (with a margin) towards the focus region, eased over the whole take.
        // Vertical: start on a taller window (sides cropped) and finish centred on the readout, which a narrow frame
        // would otherwise cut off.
        let fitAll = vertical ? h * 0.5 / ih : min(w / iw, h / ih) * (square ? 0.98 : 0.9)
        let fitFocus = min(w / s.focus.width, h / s.focus.height) * 0.92
        let p = ease(CGFloat(t / (vertical ? total * 0.65 : total))) * (vertical && s.zoom >= 0.5 ? 1 : s.zoom)
        let scale = fitAll + (fitFocus - fitAll) * p
        let center = CGPoint(x: iw / 2 + (s.focus.midX - iw / 2) * p, y: ih / 2 + (s.focus.midY - ih / 2) * p)
        writer.append { ctx in
            background(ctx)
            ctx.saveGState()
            ctx.translateBy(x: w / 2, y: h / 2); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -center.x, y: -(ih - center.y))
            let frame = CGRect(x: 0, y: 0, width: iw, height: ih)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 90, color: Brand.color(0x000000, 0.75))
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.setFillColor(Brand.color(Brand.window)); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.clip()
            ctx.interpolationQuality = .high; ctx.draw(img, in: frame)
            ctx.restoreGState()
            // Caption over a soft scrim.
            let captionIn = montage ? (s.name == "07a-albums" ? 0.2 : -10) : 0.25
            let a = min(ramp(local, captionIn, captionIn + 0.6), 1 - ramp(local, s.duration - 0.35, s.duration + 0.15))
            guard a > 0 else { return }
            // Scrim only behind the caption: dark at the bottom left, fading upwards and to the right, so readouts stay visible.
            let hs0: CGFloat = square ? 60 : 72
            let capW = max(Brand.textPath(s.headline, font: Brand.serif(hs0, weight: 300), tracking: -0.015).width,
                           Brand.textPath(s.detail, font: Brand.mono(square ? 17 : 19, weight: 500), tracking: 0.14).width) + (square ? 64 : 96)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: scrimMask(width: vertical ? w * 2 : capW + 180, fadeFrom: vertical ? w * 2 : capW))
            let scrim = CGGradient(colorsSpace: nil, colors: [Brand.color(Brand.base, 0.96 * a), Brand.color(Brand.base, 0.8 * a), Brand.color(Brand.base, 0)] as CFArray,
                                   locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(scrim, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: safeBottom + (vertical ? 420 : 250)), options: [])
            ctx.restoreGState()
            let rise = (1 - ramp(local, captionIn, captionIn + 0.7)) * 14
            let hs: CGFloat = vertical ? 66 : square ? 60 : 72, x: CGFloat = square ? 64 : 96
            let hf = Brand.serif(hs, weight: 300), df = Brand.mono(square ? 17 : 19, weight: 500)
            let lines = vertical ? wrapLines(s.headline, hf, width: w - 2 * x) : [s.headline]
            let details = vertical ? wrapLines(s.detail, df, width: w - 2 * x, tracking: 0.14) : [s.detail]
            // Stack from the bottom: detail lines, then the headline above them (wide and square keep one line each).
            let detailBase = safeBottom + 80, headBase = detailBase + CGFloat(details.count - 1) * 30 + 48
            for (k, d) in details.enumerated() {
                fillText(ctx, d, df, Brand.brass, a, x: x + 3, baseline: detailBase + CGFloat(details.count - 1 - k) * 30 - rise, tracking: 0.14)
            }
            for (k, l) in lines.enumerated() {
                fillText(ctx, l, hf, Brand.text, a, x: x, baseline: headBase + CGFloat(lines.count - 1 - k) * hs * 1.12 - rise, tracking: -0.015)
            }
        }
    }
    await writer.finish()
    print("scene \(s.name): \(frames) frames")
}

func renderIntro() async throws {
    let writer = try Writer(outDir.appendingPathComponent("01-intro.mov"))
    let total = bar + 2 * handle, frames = Int(total * Double(fps)), w = CGFloat(W), h = CGFloat(H)
    let size: CGFloat = square ? 118 : 132
    let word = Brand.textPath("vespertine", font: Brand.serif(size, weight: 300), tracking: -0.01)
    let m = size * 0.92, gap = size * 0.34, x0 = (w - (m + gap + word.width)) / 2, baseline = h * 0.5 - size * 0.28
    for i in 0..<frames {
        let t = Double(i) / Double(fps) - handle
        writer.append { ctx in
            ctx.setFillColor(Brand.color(0x000000)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setAlpha(ramp(t, 0, 1.6)); background(ctx, glow: 0.05 + 0.1 * ramp(t, 0.4, 2.6)); ctx.setAlpha(1)
            let mA = ramp(t, 0.35, 1.7), rise = (1 - ramp(t, 0.35, 2.0)) * 60
            ctx.saveGState(); ctx.setAlpha(mA); ctx.translateBy(x: x0, y: baseline - m * 0.18 - rise)
            Brand.fillBrass(ctx, Brand.crescent(size: m)); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: x0 + m + gap, y: baseline); ctx.addPath(word.path)
            ctx.setFillColor(Brand.color(Brand.text, ramp(t, 1.2, 2.5))); ctx.fillPath(); ctx.restoreGState()
            fillText(ctx, "A BIT-PERFECT MUSIC PLAYER FOR MACOS", Brand.mono(square ? 17 : 19, weight: 500), Brand.brass, ramp(t, 2.1, 3.0),
                     x: w / 2, baseline: baseline - size * 0.78, tracking: 0.22, center: true)
        }
    }
    await writer.finish(); print("scene intro: \(frames) frames")
}

func renderEnd() async throws {
    let writer = try Writer(outDir.appendingPathComponent("08-end.mov"))
    let dur = bar * 2, total = dur + 2 * handle, frames = Int(total * Double(fps)), w = CGFloat(W), h = CGFloat(H)
    let size: CGFloat = square ? 104 : 118
    let word = Brand.textPath("vespertine", font: Brand.serif(size, weight: 300), tracking: -0.01)
    let m = size * 0.92, gap = size * 0.34, x0 = (w - (m + gap + word.width)) / 2, baseline = h * 0.56
    for i in 0..<frames {
        let t = Double(i) / Double(fps) - handle
        writer.append { ctx in
            background(ctx, glow: 0.15)
            let a = ramp(t, 0, 1.0)
            ctx.saveGState(); ctx.setAlpha(a); ctx.translateBy(x: x0, y: baseline - m * 0.18); Brand.fillBrass(ctx, Brand.crescent(size: m)); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: x0 + m + gap, y: baseline); ctx.addPath(word.path); ctx.setFillColor(Brand.color(Brand.text, a)); ctx.fillPath(); ctx.restoreGState()
            fillText(ctx, "Free and open source for macOS.", Brand.sans(square ? 30 : 34), Brand.text2, ramp(t, 0.8, 1.7), x: w / 2, baseline: baseline - size * 0.95, center: true)
            fillText(ctx, "SZEREMETA1.GITHUB.IO/VESPERTINE", Brand.mono(square ? 21 : 24, weight: 500), Brand.brass, ramp(t, 1.3, 2.2),
                     x: w / 2, baseline: baseline - size * 1.5, tracking: 0.16, center: true)
            let tm = square ? ["AirPods is a trademark of Apple Inc. Dolby is a trademark of Dolby Laboratories. DTS is a trademark of DTS, Inc.",
                               "Vespertine is not affiliated with them. Music shown is from the maker’s own library."]
                            : ["AirPods is a trademark of Apple Inc. Dolby is a trademark of Dolby Laboratories. DTS is a trademark of DTS, Inc. Vespertine is not affiliated with them.",
                               "Albums shown are from the maker’s own library and belong to their owners."]
            for (k, line) in tm.enumerated() {
                fillText(ctx, line, Brand.sans(square ? 13 : 15), Brand.text3, ramp(t, 1.6, 2.4), x: w / 2, baseline: safeBottom + 70 - CGFloat(k) * 24, center: true)
            }
        }
    }
    await writer.finish(); print("scene end: \(frames) frames")
}

try await renderIntro()
for s in scenes { try await renderApp(s) }
try await renderEnd()
