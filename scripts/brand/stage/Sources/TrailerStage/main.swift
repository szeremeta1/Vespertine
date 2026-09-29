// SPDX-License-Identifier: GPL-3.0-or-later
// trailer-stage: renders the Vespertine launch trailer.
//
// The trailer is a SwiftUI scene in an on-screen window, so Liquid Glass is the real system material,
// not an imitation. The clock is stepped one frame at a time; the window server composites each frame
// and a ScreenCaptureKit stream of just this window hands it over at 2× (see Capture.swift). Motion is a
// pure function of time, so renders are repeatable and any range can be re-rendered on its own.
//
//   trailer-stage --repo <repo> --raw <recordings dir> --out <file.mov>
//                 [--aspect wide|square|vertical] [--from s] [--to s] [--fps 60] [--step n] [--behind]
//                 [--stills t1,t2,…]
//
// wide renders 3200×1800, square 2000×2000 and vertical 1080×1920. Keep the screen unlocked. With
// --behind the window sits behind every other window and never takes focus; being covered doesn't
// change what is captured. Run one render at a time: concurrent captures stall each other in replayd.
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
    var behind = false        // keep the stage window behind other windows and never take focus

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
            case "--behind": behind = true
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
    /// The frame number shown under the stage for the streamed capture (see Capture.swift).
    @Published var stamp: Int = Stamp.none
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
        // In the background the stage never appears in the Dock or takes focus from whatever the user is doing.
        app.setActivationPolicy(options.behind ? .accessory : .regular)
        let size = options.aspect.size
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else { fatalError("needs a Retina display") }
        // Dark appearance, so Liquid Glass renders as it does over the app's own dark interface.
        app.appearance = NSAppearance(named: .darkAqua)
        let stage = VStack(spacing: 0) {
            StageView(frame: frame, assets: assets, size: size)
            FrameStamp(frame: frame, width: size.width)
        }
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: stage)
        let windowSize = CGSize(width: size.width, height: size.height + Stamp.height)
        let origin = CGPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - windowSize.height - 24)
        window = NSWindow(contentRect: CGRect(origin: origin, size: windowSize), styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        // On every Space, full-screen ones included, so switching Spaces never takes it off screen (the window
        // server stops compositing windows that aren't on the active Space).
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if options.behind {
            // Behind every other window: the capture is of this window alone, so being covered doesn't matter.
            window.level = .normal
            window.orderBack(nil)
        } else {
            // Stay above other apps while rendering, so nothing covers the frames being captured.
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
    }

    /// Feeds each visible scene its recording frame for time `t`, and stamps the frame number under the stage.
    func prepare(_ t: Double, stamp: Int = Stamp.none) {
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
            frame.stamp = stamp
        }
    }
    var sourceStarts: [String: Double] = [:]

    func captureFilter() async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { fatalError("stage window not visible") }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(options.aspect.size.width * 2)
        config.height = Int((options.aspect.size.height + Stamp.height) * 2)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        config.queueDepth = 6
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.colorSpaceName = CGColorSpace.sRGB
        return (filter, config)
    }

    /// Pushes the new frame to the window server now rather than at the end of this run-loop turn.
    func commit() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// For single stills: commit, then give the window server time to composite before a screenshot.
    func settle() async {
        commit()
        try? await Task.sleep(nanoseconds: 32_000_000)   // two refreshes at 120 Hz
    }

    var stageRows: Int { Int(options.aspect.size.height * 2) }

    /// The captured image of frame `n`. If the window server pauses the window (a Space switch, say) and no
    /// image arrives, the frame is shown again by toggling only its stamp (the scene isn't prepared twice, so
    /// state such as the meters' release stays exact), up to three times.
    func image(of n: Int, from capture: StreamCapture) async throws -> CVPixelBuffer {
        for attempt in 0... {
            do { return try await capture.image() } catch let error as StreamCapture.TimedOut where attempt < 3 {
                print("no image of frame \(error.frame); showing it again")
                frame.stamp = Stamp.none; commit()
                capture.expect(n)
                frame.stamp = n; commit()
            }
        }
        fatalError("unreachable")
    }

    func run() async throws {
        openWindow()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (filter, config) = try await captureFilter()

        if !options.stills.isEmpty {
            for t in options.stills {
                prepare(t); await settle()
                let window = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let image = window.cropping(to: CGRect(x: 0, y: 0, width: window.width, height: stageRows))!
                let url = options.out.deletingPathExtension().appendingPathExtension(String(format: "%06.3f.png", t))
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
                print("still \(t) → \(url.lastPathComponent)")
            }
            return
        }

        let writer = try MovieWriter(url: options.out, width: config.width, height: stageRows, fps: options.fps / Double(options.step))
        let capture = try StreamCapture(filter: filter, configuration: config, stageRows: stageRows)
        try await capture.start()
        let first = Int((options.from * options.fps).rounded()), last = Int((options.to * options.fps).rounded())
        let started = Date()
        var spent = [0.0, 0.0, 0.0, 0.0]   // prepare, commit, capture, write
        func lap(_ i: Int, _ since: inout Date) { let now = Date(); spent[i] += now.timeIntervalSince(since); since = now }
        for f in stride(from: first, to: last, by: options.step) {
            let t = Double(f) / options.fps
            var mark = Date()
            capture.expect(f)
            prepare(t, stamp: f); lap(0, &mark)
            commit(); lap(1, &mark)
            let buffer = try await image(of: f, from: capture); lap(2, &mark)
            writer.append(buffer, rows: stageRows); lap(3, &mark)
            if (f - first) / options.step % 60 == 0 {
                let done = Double(f - first) / Double(last - first)
                print(String(format: "%5.1f%%  t=%6.3f  %.0f s elapsed", done * 100, t, Date().timeIntervalSince(started)))
            }
        }
        await capture.stop()
        await writer.finish()
        let n = Double(max(1, (last - first) / options.step))
        print(String(format: "per frame: prepare %.0f ms, commit %.0f ms, capture %.0f ms, write %.0f ms",
                     spent[0] / n * 1000, spent[1] / n * 1000, spent[2] / n * 1000, spent[3] / n * 1000))
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

    /// Copies the top `rows` of a captured window image (the stage, without the frame stamp) into the movie.
    func append(_ source: CVPixelBuffer, rows: Int) {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(buffer, [])
        let from = CVPixelBufferGetBaseAddress(source)!, to = CVPixelBufferGetBaseAddress(buffer)!
        let fromRow = CVPixelBufferGetBytesPerRow(source), toRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = min(fromRow, toRow, CVPixelBufferGetWidth(buffer) * 4)
        for y in 0..<min(rows, CVPixelBufferGetHeight(buffer)) { memcpy(to + y * toRow, from + y * fromRow, bytes) }
        CVPixelBufferUnlockBaseAddress(buffer, []); CVPixelBufferUnlockBaseAddress(source, .readOnly)
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
        setvbuf(stdout, nil, _IOLBF, 0)   // progress lines show up even when output goes to a log file
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
