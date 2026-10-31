//
// Vespertine — draws the visualizer with Metal: one full-window fragment shader per style, fed each frame with the
// newest analysis. Also renders offscreen (screenshots, recordings, timing).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Metal
import MetalKit
import QuartzCore
import os

/// What's playing, as the visualizer shows it.
public struct VisualizerScene: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    /// How far through the song, 0…1 (the tonearm follows it); nil when nothing is loaded.
    public var progress: Double?
    public var isPlaying: Bool

    public init(title: String? = nil, artist: String? = nil, progress: Double? = nil, isPlaying: Bool = false) {
        self.title = title
        self.artist = artist
        self.progress = progress
        self.isPlaying = isPlaying
    }
}

/// The few words the visualizer draws itself (axis units), localized by the app.
public struct VisualizerLabels: Sendable, Equatable {
    public var hertz: @Sendable (Int) -> String
    public var kilohertz: @Sendable (Double) -> String
    public var decibels: @Sendable (Int) -> String
    public var secondsAgo: @Sendable (Int) -> String

    public init(hertz: @escaping @Sendable (Int) -> String, kilohertz: @escaping @Sendable (Double) -> String,
                decibels: @escaping @Sendable (Int) -> String, secondsAgo: @escaping @Sendable (Int) -> String) {
        self.hertz = hertz
        self.kilohertz = kilohertz
        self.decibels = decibels
        self.secondsAgo = secondsAgo
    }

    public static let english = VisualizerLabels(
        hertz: { "\($0) Hz" },
        kilohertz: { abs($0 - $0.rounded()) < 0.05 ? "\(Int($0.rounded())) kHz" : String(format: "%.1f kHz", $0) },
        decibels: { "\($0) dB" },
        secondsAgo: { $0 == 0 ? "0 s" : "-\($0) s" })

    public static func == (a: VisualizerLabels, b: VisualizerLabels) -> Bool {
        a.hertz(1000) == b.hertz(1000) && a.kilohertz(1) == b.kilohertz(1) && a.decibels(-6) == b.decibels(-6)
            && a.secondsAgo(5) == b.secondsAgo(5)
    }
}

/// The uniforms every shader reads; mirrors `struct U` in the shader source (float4s only).
struct VisualizerUniforms {
    var a = SIMD4<Float>.zero
    var b = SIMD4<Float>.zero
    var c = SIMD4<Float>.zero
    var d = SIMD4<Float>.zero
    var e = SIMD4<Float>.zero
    var f = SIMD4<Float>.zero
    var stops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var rings: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}

@MainActor
public final class VisualizerRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    public var settings = VisualizerSettings() { didSet { overlayKey = "" } }
    /// Reduce Motion: no strobe, and calmer lasers.
    public var reduceMotion = false
    public var labels = VisualizerLabels.english { didSet { overlayKey = "" } }
    /// Called once per drawn frame (on the main thread) for the newest analysis and what's playing.
    public var frameSource: (() -> (VisualizerFrame, VisualizerScene))?

    private let queue: MTLCommandQueue
    private var pipelines: [VisualizerStyle: MTLRenderPipelineState] = [:]
    private let pixelFormat: MTLPixelFormat = .bgra8Unorm

    // Spectrogram history: one column of fine bins per step, written in place (a ring across the texture's width).
    static let historyWidth = 1024
    private var history: MTLTexture?
    private var historyHead = 0
    private var historyFraction: Double = 0
    private var column: [UInt8] = []

    private var artwork: MTLTexture?
    private var blank: MTLTexture?
    private var overlay: MTLTexture?
    private var overlayKey = ""

    // Motion
    private var lastDraw: CFTimeInterval = 0
    private var recordAngle: Double = 0
    private var platterSpeed: Double = 0
    private var armAngle: Double?
    private var laserAngle: Double = 0
    private var strobe: Float = 0
    private var signal: Float = 0
    private var rings: [SIMD4<Float>] = []
    private var ringColour: Float = 0.55

    /// GPU time per frame, averaged (from the command buffers' own timestamps).
    public struct GPUStats: Sendable, Equatable {
        public var frames = 0
        public var seconds: Double = 0
        public var averageMilliseconds: Double { frames > 0 ? seconds / Double(frames) * 1000 : 0 }
    }
    private let gpu = OSAllocatedUnfairLock(initialState: GPUStats())
    public var gpuStats: GPUStats { gpu.withLock { $0 } }
    public func resetStats() { gpu.withLock { $0 = GPUStats() } }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        do {
            let library = try device.makeLibrary(source: VisualizerShaders.source, options: nil)
            guard let vertex = library.makeFunction(name: "vz_vertex") else { return nil }
            let names: [VisualizerStyle: String] = [.bars: "vz_bars", .spectrogram: "vz_spectrogram", .vinyl: "vz_vinyl", .club: "vz_club"]
            for (style, name) in names {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = vertex
                d.fragmentFunction = library.makeFunction(name: name)
                d.colorAttachments[0].pixelFormat = pixelFormat
                pipelines[style] = try device.makeRenderPipelineState(descriptor: d)
            }
        } catch {
            Logger(subsystem: "org.szeremeta.Vespertine", category: "Visualizer").error("Shaders didn't compile: \(error)")
            return nil
        }
        let h = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.historyWidth, height: 512, mipmapped: false)
        h.usage = .shaderRead
        history = device.makeTexture(descriptor: h)
        let b = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        blank = device.makeTexture(descriptor: b)
        var clear: UInt32 = 0
        blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 4)
    }

    /// Sets the album cover the record's label shows (nil: a plain label in the theme's colours).
    public func setArtwork(_ image: CGImage?) {
        guard let image else { artwork = nil; return }
        let loader = MTKTextureLoader(device: device)
        artwork = try? loader.newTexture(cgImage: image, options: [
            .SRGB: false, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
    }

    // MARK: MTKViewDelegate

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawOnMain(in: view) }
    }

    private func drawOnMain(in view: MTKView) {
        guard let (frame, scene) = frameSource?(), let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        let dt = lastDraw > 0 ? min(0.1, now - lastDraw) : 1.0 / 60
        lastDraw = now
        let scale = view.window?.backingScaleFactor ?? 2
        guard let buffer = encode(frame: frame, scene: scene, size: view.drawableSize, scale: scale, dt: dt, pass: pass) else { return }
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: Offscreen

    /// Renders one frame offscreen and returns it as BGRA bytes (premultiplied, top row first). The motion state
    /// advances by `dt`, as in a window.
    public func renderOffscreen(frame: VisualizerFrame, scene: VisualizerScene, size: CGSize, scale: CGFloat, dt: Double) -> [UInt8]? {
        let w = Int(size.width), h = Int(size.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = encode(frame: frame, scene: scene, size: size, scale: scale, dt: dt, pass: pass) else { return nil }
        if target.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return bytes
    }

    // MARK: Frame

    private func encode(frame: VisualizerFrame, scene: VisualizerScene, size: CGSize, scale: CGFloat, dt: Double,
                        pass: MTLRenderPassDescriptor) -> MTLCommandBuffer? {
        guard size.width >= 1, size.height >= 1, let pipeline = pipelines[settings.style],
              let buffer = queue.makeCommandBuffer() else { return nil }
        advance(frame: frame, scene: scene, dt: dt)
        updateOverlay(size: size, scale: scale, scene: scene)

        var u = VisualizerUniforms()
        u.a = SIMD4(Float(size.width), Float(size.height), Float(frame.time), Float(scale))
        u.b = SIMD4(frame.bass, frame.mid, frame.treble, frame.beatPulse)
        let level = max(0, (max(frame.rmsDB.x, frame.rmsDB.y) + 60) / 60)
        u.c = SIMD4(level, Float(recordAngle), Float(armAngle ?? Self.armRest), settings.tonearm ? 1 : 0)
        u.d = SIMD4(Float(frame.bands.count), Float(frame.fine.count), Float(Self.historyWidth),
                    Float(Double(historyHead) + historyFraction))
        u.e = SIMD4(settings.peakCaps ? 1 : 0, artwork != nil ? 1 : 0, strobe, signal)
        u.f = SIMD4(Float(laserAngle), Float(platterSpeed), 0, 0)
        let stops = settings.theme.stops.map { SIMD4<Float>($0, 1) }
        u.stops = (stops[0], stops[1], stops[2], stops[3])
        withUnsafeMutableBytes(of: &u.rings) { raw in
            let slots = raw.bindMemory(to: SIMD4<Float>.self)
            for i in 0..<16 { slots[i] = i < rings.count ? rings[i] : .zero }
        }

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        var bands = frame.bands.isEmpty ? [0] : frame.bands
        var peaks = frame.peaks.isEmpty ? [0] : frame.peaks
        var fine = frame.fine.isEmpty ? [0] : frame.fine
        encoder.setFragmentBytes(&bands, length: bands.count * 4, index: 1)
        encoder.setFragmentBytes(&peaks, length: peaks.count * 4, index: 2)
        encoder.setFragmentBytes(&fine, length: fine.count * 4, index: 3)
        encoder.setFragmentTexture(overlay ?? blank, index: 0)
        encoder.setFragmentTexture(history, index: 1)
        encoder.setFragmentTexture(artwork ?? blank, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let gpu = self.gpu
        buffer.addCompletedHandler { b in
            let t = b.gpuEndTime - b.gpuStartTime
            if t > 0, t < 1 { gpu.withLock { $0.frames += 1; $0.seconds += t } }
        }
        return buffer
    }

    /// Where the tonearm rests, off the record (radians from its pivot).
    static let armRest = atan2(-1.0, -0.04)
    static let armPivot = SIMD2<Double>(1.08, 0.72)
    static let armLength = 1.02

    /// The tonearm's angle that puts the stylus on the record at radius `r` (the outer of the two solutions).
    static func armAngle(stylusRadius r: Double) -> Double {
        let p = armPivot, l = armLength
        let d = (p.x * p.x + p.y * p.y).squareRoot()
        let a = (r * r - l * l + d * d) / (2 * d)
        let h = max(0, r * r - a * a).squareRoot()
        let base = p / d * a
        let perpendicular = SIMD2(-p.y, p.x) / d
        let s = base - perpendicular * h
        return atan2(s.y - p.y, s.x - p.x)
    }

    private func advance(frame: VisualizerFrame, scene: VisualizerScene, dt: Double) {
        signal += ((frame.hasSignal ? 1 : 0) - signal) * VisualizerAnalyzer.coefficient(dt, 0.25)

        // Spectrogram: columns at the chosen speed.
        historyFraction += dt * Double(Self.historyWidth) / settings.spectrogramSeconds
        if historyFraction >= 1, let history {
            let steps = min(Int(historyFraction), 8)
            historyFraction -= Double(Int(historyFraction))
            let rows = history.height
            if column.count != rows { column = .init(repeating: 0, count: rows) }
            for y in 0..<rows {
                let i = y * frame.fine.count / rows
                column[y] = UInt8(min(255, max(0, (frame.fine.indices.contains(i) ? frame.fine[i] : 0) * 255)))
            }
            for _ in 0..<steps {
                historyHead = (historyHead + 1) % Self.historyWidth
                history.replace(region: MTLRegionMake2D(historyHead, 0, 1, rows), mipmapLevel: 0, withBytes: column, bytesPerRow: 1)
            }
        }

        // Vinyl: spins up in about a second, down in two, as a platter would.
        let target: Double = scene.isPlaying ? 1 : 0
        platterSpeed += (target - platterSpeed) * Double(VisualizerAnalyzer.coefficient(dt, target > platterSpeed ? 0.35 : 0.8))
        if platterSpeed < 0.002 && target == 0 { platterSpeed = 0 }
        recordAngle = (recordAngle + platterSpeed * settings.rpm / 60 * 2 * .pi * dt).truncatingRemainder(dividingBy: 2 * .pi)
        let armTarget = scene.progress.map { Self.armAngle(stylusRadius: 0.83 - min(max($0, 0), 1) * (0.83 - 0.40)) } ?? Self.armRest
        let arm = armAngle ?? Self.armRest
        armAngle = arm + (armTarget - arm) * Double(VisualizerAnalyzer.coefficient(dt, 0.45))

        // Club: rings out on every beat, lasers turning with the mids.
        for i in rings.indices {
            rings[i].x += Float(dt) * (0.9 + 0.5 * rings[i].y)
            rings[i].y *= Float(exp(-dt / 0.7))
        }
        rings.removeAll { $0.y < 0.01 || $0.x > 2.4 }
        if frame.beat {
            ringColour = ringColour >= 0.95 ? 0.55 : ringColour + 0.15
            rings.insert(SIMD4(0.16 + 0.1 * frame.bass, 0.35 + 0.65 * frame.bass, 0.010 + 0.018 * frame.bass, ringColour), at: 0)
            if rings.count > 16 { rings.removeLast() }
        }
        let spin = reduceMotion ? 0.08 : 0.22 + 0.9 * Double(frame.mid)
        laserAngle = (laserAngle + dt * spin + (frame.beat && !reduceMotion ? 0.12 : 0)).truncatingRemainder(dividingBy: 2 * .pi)
        if settings.strobe && !reduceMotion && frame.beat && frame.bass > 0.8 { strobe = 0.6 }
        strobe *= Float(exp(-dt / 0.045))
        if strobe < 0.003 || reduceMotion || !settings.strobe { strobe = 0 }
    }

    // MARK: Labels

    /// The axes and the song's title, drawn once with Core Graphics whenever they change, and laid over the picture.
    private func updateOverlay(size: CGSize, scale: CGFloat, scene: VisualizerScene) {
        let info = settings.showsTrackInfo ? "\(scene.title ?? "")\u{1F}\(scene.artist ?? "")" : ""
        let key = "\(Int(size.width))x\(Int(size.height))@\(scale) \(settings.style) \(settings.decibelScale) \(info)"
        guard key != overlayKey else { return }
        overlayKey = key
        let w = Int(size.width), h = Int(size.height)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Points, with y down, as the shaders lay out their margins.
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        VisualizerOverlay.draw(in: CGSize(width: size.width / scale, height: size.height / scale), settings: settings,
                               scene: scene, labels: labels)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        overlay = texture
    }
}
