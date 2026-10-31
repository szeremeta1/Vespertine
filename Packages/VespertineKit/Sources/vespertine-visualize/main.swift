//
// Vespertine — renders the visualizer offline from decoded audio, with the same analysis and renderer as the window.
//
//   ffmpeg -i song.flac -f f32le -ac 2 -ar 48000 song.f32
//   vespertine-visualize song.f32 --rate 48000 --style vinyl --art cover.jpg --title T --artist A \
//       --start 30 --seconds 8 --fps 60 --size 1920x1080 --raw | ffmpeg -f rawvideo -pix_fmt bgra -s 1920x1080 -r 60 -i - …
//   vespertine-visualize song.f32 --rate 48000 --style bars --still 42 --png bars.png
//
// Prints the analysis and GPU time per frame to stderr.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import VespertineVisualizer

struct Options {
    var input = ""
    var rate = 48_000.0
    var settings = VisualizerSettings()
    var art: String?
    var title: String?
    var artist: String?
    var start = 0.0
    var seconds = 5.0
    var fps = 60.0
    var size = CGSize(width: 1920, height: 1080)
    var scale: CGFloat = 2
    var raw = false
    var still: Double?
    var png: String?
    var duration: Double?
    var paused = false
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next() -> String { args.isEmpty ? "" : args.removeFirst() }
    while !args.isEmpty {
        let a = next()
        switch a {
        case "--rate": o.rate = Double(next()) ?? o.rate
        case "--style": o.settings.style = VisualizerStyle(rawValue: next()) ?? .vinyl
        case "--theme": o.settings.theme = VisualizerTheme(rawValue: next()) ?? .vespertine
        case "--sensitivity": o.settings.sensitivity = Double(next()) ?? 1
        case "--bands": o.settings.bandCount = Int(next()) ?? 64
        case "--linear": o.settings.decibelScale = false
        case "--no-peaks": o.settings.peakCaps = false
        case "--no-tonearm": o.settings.tonearm = false
        case "--strobe": o.settings.strobe = true; o.settings.strobeWarningAccepted = true
        case "--scope": o.settings.scopeMode = VisualizerScopeMode(rawValue: next()) ?? .goniometer
        case "--meter": o.settings.meterKind = VisualizerMeterKind(rawValue: next()) ?? .vu
        case "--reference": o.settings.meterReference = Double(next())
        case "--layout": o.settings.mirrorLayout = VisualizerMirrorLayout(rawValue: next()) ?? .circle
        case "--no-trails": o.settings.particleTrails = false
        case "--no-info": o.settings.showsTrackInfo = false
        case "--history": o.settings.spectrogramSeconds = Double(next()) ?? 12
        case "--art": o.art = next()
        case "--title": o.title = next()
        case "--artist": o.artist = next()
        case "--start": o.start = Double(next()) ?? 0
        case "--seconds": o.seconds = Double(next()) ?? 5
        case "--fps": o.fps = Double(next()) ?? 60
        case "--size":
            let p = next().split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { o.size = CGSize(width: p[0], height: p[1]) }
        case "--scale": o.scale = CGFloat(Double(next()) ?? 2)
        case "--raw": o.raw = true
        case "--still": o.still = Double(next())
        case "--png": o.png = next()
        case "--duration": o.duration = Double(next())
        case "--paused": o.paused = true
        default: o.input = a
        }
    }
    o.settings = o.settings.normalized
    return o
}

func writePNG(_ bytes: [UInt8], size: CGSize, to path: String) {
    let w = Int(size.width), h = Int(size.height)
    var data = bytes
    let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

@MainActor
func run() -> Int32 {
    let o = parse()
    guard let data = FileManager.default.contents(atPath: o.input) else {
        FileHandle.standardError.write("usage: vespertine-visualize <stereo f32le file> [options]\n".data(using: .utf8)!)
        return 2
    }
    let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let frames = samples.count / 2
    var left = [Float](repeating: 0, count: frames), right = left
    for i in 0..<frames { left[i] = samples[2 * i]; right[i] = samples[2 * i + 1] }
    let total = o.duration ?? Double(frames) / o.rate

    guard let renderer = VisualizerRenderer() else {
        FileHandle.standardError.write("Metal isn't available\n".data(using: .utf8)!)
        return 1
    }
    renderer.settings = o.settings
    if let art = o.art, let image = NSImage(contentsOfFile: art)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        renderer.setArtwork(image)
    }
    var configuration = VisualizerAnalyzer.Configuration()
    configuration.bandCount = o.settings.bandCount
    configuration.sensitivity = Float(o.settings.sensitivity)
    configuration.linear = !o.settings.decibelScale
    configuration.meterReferenceDB = o.settings.meterReference.map(Float.init)
    let analyzer = VisualizerAnalyzer(configuration: configuration)
    let n = VisualizerAnalyzer.fftSize(for: o.rate)
    let dt = 1 / o.fps

    // Warm up from a few seconds before, so smoothing, peaks, the spinning record and the spectrogram's history are
    // where they'd be in a window that had been open a while.
    let warm = o.still != nil ? max(o.settings.spectrogramSeconds, 3) : max(2, o.settings.style == .spectrogram ? o.settings.spectrogramSeconds : 2)
    let from = (o.still ?? o.start) - warm
    let until = o.still ?? (o.start + o.seconds)
    let stdout = FileHandle.standardOutput
    var analysisTime = 0.0, rendered = 0
    var t = from
    var last: [UInt8]?
    renderer.resetStats()
    while t <= until + dt / 2 {
        let end = Int(t * o.rate)
        let fresh = end >= n && end <= frames && !o.paused
        let lo = max(0, min(end, frames) - n)
        let clock = Date()
        let frame = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                analyzer.process(left: UnsafeBufferPointer(rebasing: l[lo..<max(lo, min(end, frames))]),
                                 right: UnsafeBufferPointer(rebasing: r[lo..<max(lo, min(end, frames))]),
                                 sampleRate: o.rate, fresh: fresh, dt: dt)
            }
        }
        analysisTime += Date().timeIntervalSince(clock)
        let scene = VisualizerScene(title: o.title, artist: o.artist, progress: min(1, max(0, t / total)), isPlaying: !o.paused)
        let visible = t >= (o.still ?? o.start) - dt / 2
        guard let bytes = renderer.renderOffscreen(frame: frame, scene: scene, size: o.size, scale: o.scale, dt: dt) else { return 1 }
        rendered += 1
        if visible {
            last = bytes
            if o.raw { bytes.withUnsafeBytes { stdout.write(Data($0)) } }
        }
        t += dt
    }
    if let png = o.png, let last { writePNG(last, size: o.size, to: png) }
    let stats = renderer.gpuStats
    FileHandle.standardError.write(String(format: "frames %d, analysis %.1f µs/frame, GPU %.2f ms/frame at %dx%d\n",
                                          rendered, analysisTime / Double(max(rendered, 1)) * 1e6, stats.averageMilliseconds,
                                          Int(o.size.width), Int(o.size.height)).data(using: .utf8)!)
    return 0
}

exit(MainActor.assumeIsolated { run() })
