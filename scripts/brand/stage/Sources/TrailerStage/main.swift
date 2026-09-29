// SPDX-License-Identifier: GPL-3.0-or-later
// trailer-stage: renders the Vespertine launch trailer.
//
// The trailer is a SwiftUI scene in an on-screen window, so Liquid Glass is the real system material,
// not an imitation. The clock is stepped one frame at a time; after each step the window server
// composites the frame and ScreenCaptureKit grabs just this window at 2×. Motion is a pure function
// of time, so renders are repeatable and any range can be re-rendered on its own.
//
//   trailer-stage --repo <repo> --raw <recordings dir> --out <file.mov>
//                 [--aspect wide|square|vertical] [--from s] [--to s] [--fps 60] [--step n]
//
// wide renders 3200×1800, square 2000×2000 and vertical 1080×1920. Keep the screen unlocked and
// don't cover the window while it renders; only this window is captured.
import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct Options {
    var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var raw = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/Vespertine/Trailer/raw")
    var out = URL(fileURLWithPath: "trailer.mov")
    var aspect = Aspect.wide
    var from = 0.0
    var to = Music.duration
    var fps = 60.0
    var step = 1              // render every nth frame (for quick previews)
    var stills: [Double] = [] // render single frames as PNGs instead of a movie

    init(_ args: [String]) {
        var i = 1
        func next() -> String { i += 1; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--repo": repo = URL(fileURLWithPath: next())
            case "--raw": raw = URL(fileURLWithPath: next())
            case "--out": out = URL(fileURLWithPath: next())
            case "--aspect": aspect = Aspect(rawValue: next()) ?? .wide
            case "--from": from = Double(next())!
            case "--to": to = Double(next())!
            case "--fps": fps = Double(next())!
            case "--step": step = Int(next())!
            case "--stills": stills = next().split(separator: ",").map { Double($0)! }
            default: print("unknown argument \(args[i])"); exit(2)
            }
            i += 1
        }
    }
}

enum Aspect: String {
    case wide, square, vertical
    /// Window size in points; captured at the display's 2× scale.
    var size: CGSize {
        switch self {
        case .wide: return CGSize(width: 1600, height: 900)
        case .square: return CGSize(width: 1000, height: 1000)
        case .vertical: return CGSize(width: 540, height: 960)
        }
    }
}

/// Everything the scenes draw at one instant.
final class Frame: ObservableObject {
    @Published var t: Double = 0
    @Published var video: [String: CGImage] = [:]
    /// The Spatial Audio recording's channel meters, with a meter-like release.
    @Published var meters: [Double] = Array(repeating: 0, count: 6)
}

@MainActor
final class Renderer {
    let options: Options
    let frame = Frame()
    let assets: Assets
    var window: NSWindow!
    var sources: [String: VideoSource] = [:]

    init(_ options: Options) {
        self.options = options
        let paths = Paths(repo: options.repo, raw: options.raw)
        BrandFont.register(paths)
        assets = Assets(paths)
    }

    func openWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let size = options.aspect.size
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else { fatalError("needs a Retina display") }
        // Dark appearance, so Liquid Glass renders as it does over the app's own dark interface.
        app.appearance = NSAppearance(named: .darkAqua)
        let stage = StageView(frame: frame, assets: assets, size: size).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: stage)
        let origin = CGPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - size.height - 24)
        window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        // Stay above other apps while rendering, so nothing covers the frames being captured.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }

    /// Feeds each visible scene its recording frame for time `t`.
    func prepare(_ t: Double) {
        var video: [String: CGImage] = [:]
        for cue in Cue.all where cue.isVisible(at: t) {
            let local = cue.sourceStart + (t - cue.scene.range.lowerBound)
            let key = cue.key
            if sources[key] == nil {
                sources[key] = try! VideoSource(assets.paths.recording(cue.recording), from: max(0, local))
                // Anything earlier than this reader's start would need a new reader; renders only move forward.
                sourceStarts[key] = max(0, local)
            }
            if let image = sources[key]!.frame(at: local - sourceStarts[key]!) { video[key] = image }
        }
        var meters = frame.meters
        if let key = Cue.for(.spatial)?.key, let image = video[key] {
            meters = zip(Meters.levels(image), meters).map { max($0, $1 * 0.88) }
        }
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) {
            frame.video = video
            frame.meters = meters
            frame.t = t
        }
    }
    var sourceStarts: [String: Double] = [:]

    func captureFilter() async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { fatalError("stage window not visible") }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let px = CGSize(width: options.aspect.size.width * 2, height: options.aspect.size.height * 2)
        config.width = Int(px.width); config.height = Int(px.height)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.colorSpaceName = CGColorSpace.sRGB
        return (filter, config)
    }

    func settle() async {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        try? await Task.sleep(nanoseconds: 32_000_000)   // two refreshes at 120 Hz, then the window server has composited
    }

    func run() async throws {
        openWindow()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (filter, config) = try await captureFilter()

        if !options.stills.isEmpty {
            for t in options.stills {
                prepare(t); await settle()
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let url = options.out.deletingPathExtension().appendingPathExtension(String(format: "%06.3f.png", t))
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
                print("still \(t) → \(url.lastPathComponent)")
            }
            return
        }

        let writer = try MovieWriter(url: options.out, width: config.width, height: config.height, fps: options.fps / Double(options.step))
        let first = Int((options.from * options.fps).rounded()), last = Int((options.to * options.fps).rounded())
        let started = Date()
        for f in stride(from: first, to: last, by: options.step) {
            let t = Double(f) / options.fps
            prepare(t)
            await settle()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            writer.append(image)
            if (f - first) / options.step % 60 == 0 {
                let done = Double(f - first) / Double(last - first)
                print(String(format: "%5.1f%%  t=%6.3f  %.0f s elapsed", done * 100, t, Date().timeIntervalSince(started)))
            }
        }
        await writer.finish()
        print("wrote \(options.out.path) in \(Int(Date().timeIntervalSince(started))) s")
    }
}

/// ProRes 422 HQ, Rec. 709 tags (the capture is sRGB, which shares Rec. 709 primaries).
final class MovieWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let fps: Double
    var count: Int64 = 0

    init(url: URL, width: Int, height: Int, fps: Double) throws {
        try? FileManager.default.removeItem(at: url)
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage) {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { usleep(500) }
        adaptor.append(buffer, withPresentationTime: CMTime(value: count, timescale: CMTimeScale(fps.rounded())))
        count += 1
    }

    func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }
}

@main
struct TrailerStageMain {
    static func main() {
        let options = Options(CommandLine.arguments)
        Task { @MainActor in
            do {
                try await Renderer(options).run()
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}
