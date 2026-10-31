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

/// A small seeded random number generator (SplitMix64), so the particles start the same way every time.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

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
    var g = SIMD4<Float>.zero
    var h = SIMD4<Float>.zero
    var k = SIMD4<Float>.zero
    var stops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var rings: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}

@MainActor
public final class VisualizerRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    public var settings = VisualizerSettings() { didSet { overlayKey = "" } }
    /// Reduce Motion: no strobe, calmer lasers and particles.
    public var reduceMotion = false
    /// Dim Flashing Lights (Accessibility > Display): no strobe.
    public var reduceFlashing = false
    public var labels = VisualizerLabels.english { didSet { overlayKey = "" } }
    /// Called once per drawn frame (on the main thread) for the newest analysis and what's playing.
    public var frameSource: (() -> (VisualizerFrame, VisualizerScene))?

    private let queue: MTLCommandQueue
    private var pipelines: [VisualizerStyle: MTLRenderPipelineState] = [:]
    private let pixelFormat: MTLPixelFormat = .bgra8Unorm

    // Trails (scope and particles): light drawn additively into a texture that fades a little each frame.
    private let trailFormat: MTLPixelFormat = .rgba16Float
    private var fadePipeline: MTLRenderPipelineState?
    private var beamPipeline: MTLRenderPipelineState?
    private var spritePipeline: MTLRenderPipelineState?
    private var particleStep: MTLComputePipelineState?
    private var trail: MTLTexture?
    private var trailStyle: VisualizerStyle?

    // Scope: the trace's points, in a few buffers taken in turn (the GPU may still be reading the last one).
    static let beamPoints = 2 * 1024 + 2
    private var beamBuffers: [MTLBuffer] = []
    private var beamIndex = 0
    private var scopeEnvelope: Float = 0
    private var points: [SIMD4<Float>] = []

    // Particles
    public static let particleCount = 20_000
    private var particles: MTLBuffer?

    // Meters: the printed faces, redrawn when the window's size or the meter changes.
    private var meterFace: MTLTexture?
    private var meterFaceKey = ""
    private var peakLights = SIMD2<Float>(0, 0)

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
    /// Seconds since the last flash.
    private var sinceFlash: Double = 1
    private var signal: Float = 0
    private var rings: [SIMD4<Float>] = []
    private var ringColour: Float = 0.55

    /// GPU time per frame, averaged (from the command buffers' own timestamps).
    public struct GPUStats: Sendable, Equatable {
        public var frames = 0
        public var seconds: Double = 0
        public var averageMilliseconds: Double { frames > 0 ? seconds / Double(frames) * 1000 : 0 }
        public init() {}
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
            let names: [VisualizerStyle: String] = [.bars: "vz_bars", .spectrogram: "vz_spectrogram", .vinyl: "vz_vinyl", .club: "vz_club",
                                                    .scope: "vz_scope", .meters: "vz_meters", .particles: "vz_particles",
                                                    .mirrored: "vz_mirror"]
            for (style, name) in names {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = vertex
                d.fragmentFunction = library.makeFunction(name: name)
                d.colorAttachments[0].pixelFormat = pixelFormat
                pipelines[style] = try device.makeRenderPipelineState(descriptor: d)
            }
            // The fade keeps a set fraction of what's there (the blend colour); beams and sprites add light.
            let fade = MTLRenderPipelineDescriptor()
            fade.vertexFunction = vertex
            fade.fragmentFunction = library.makeFunction(name: "vz_fade")
            fade.colorAttachments[0].pixelFormat = trailFormat
            fade.colorAttachments[0].isBlendingEnabled = true
            fade.colorAttachments[0].sourceRGBBlendFactor = .zero
            fade.colorAttachments[0].sourceAlphaBlendFactor = .zero
            fade.colorAttachments[0].destinationRGBBlendFactor = .blendColor
            fade.colorAttachments[0].destinationAlphaBlendFactor = .blendAlpha
            fadePipeline = try device.makeRenderPipelineState(descriptor: fade)
            func additive(_ vertexName: String, _ fragmentName: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertexName)
                d.fragmentFunction = library.makeFunction(name: fragmentName)
                d.colorAttachments[0].pixelFormat = trailFormat
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .one
                return try device.makeRenderPipelineState(descriptor: d)
            }
            beamPipeline = try additive("vz_beam_vertex", "vz_beam_fragment")
            spritePipeline = try additive("vz_sprite_vertex", "vz_sprite_fragment")
            if let step = library.makeFunction(name: "vz_particles_step") {
                particleStep = try device.makeComputePipelineState(function: step)
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
        beamBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: Self.beamPoints * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        }
        points.reserveCapacity(Self.beamPoints)
    }

    /// The particles' starting state: spread over a disc, still, their lives staggered so they don't all renew at
    /// once. Seeded, so offline renders come out the same every time.
    private func makeParticles() -> MTLBuffer? {
        var rng = SplitMix64(seed: 0x5EED_CAFE)
        var data = [SIMD4<Float>](repeating: .zero, count: Self.particleCount * 2)
        for i in 0..<Self.particleCount {
            let a = Float.random(in: 0..<(2 * .pi), using: &rng), r = 0.9 * Float.random(in: 0..<1, using: &rng).squareRoot()
            let life = Float.random(in: 0.5..<10, using: &rng)
            data[2 * i] = SIMD4(cos(a) * r * 1.6, sin(a) * r * 1.6, 0, 0)
            data[2 * i + 1] = SIMD4(0, life, Float.random(in: 0..<100, using: &rng), life + 1)
        }
        return device.makeBuffer(bytes: data, length: data.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
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
        let style = settings.style

        var u = VisualizerUniforms()
        u.a = SIMD4(Float(size.width), Float(size.height), Float(frame.time), Float(scale))
        u.b = SIMD4(frame.bass, frame.mid, frame.treble, frame.beatPulse)
        let level = max(0, (max(frame.rmsDB.x, frame.rmsDB.y) + 60) / 60)
        u.c = SIMD4(level, Float(recordAngle), Float(armAngle ?? Self.armRest), settings.tonearm ? 1 : 0)
        u.d = SIMD4(Float(frame.bands.count), Float(frame.fine.count), Float(Self.historyWidth),
                    Float(Double(historyHead) + historyFraction))
        u.e = SIMD4(settings.peakCaps ? 1 : 0, artwork != nil ? 1 : 0, strobe, signal)
        u.f = SIMD4(Float(laserAngle), Float(platterSpeed), 0, Float(min(rings.count, 16)))
        let stops = settings.theme.stops.map { SIMD4<Float>($0, 1) }
        u.stops = (stops[0], stops[1], stops[2], stops[3])
        withUnsafeMutableBytes(of: &u.rings) { raw in
            let slots = raw.bindMemory(to: SIMD4<Float>.self)
            for i in 0..<16 { slots[i] = i < rings.count ? rings[i] : .zero }
        }

        // The styles with passes of their own before the picture.
        let px = { (r: CGRect) in SIMD4<Float>(Float(r.minX * scale), Float(r.minY * scale), Float(r.width * scale), Float(r.height * scale)) }
        let points = CGSize(width: size.width / scale, height: size.height / scale)
        switch style {
        case .scope:
            u.g = SIMD4(Float(1.1 * scale), settings.scopeMode == .oscilloscope ? 1 : 0, frame.correlation, 0)
            if settings.scopeMode == .goniometer {
                let g = VisualizerLayout.goniometer(in: points)
                u.h = SIMD4(Float(g.centre.x * scale), Float(g.centre.y * scale), Float(g.radius * scale), 0)
                u.k = SIMD4(Float(g.bar.minX * scale), Float(g.bar.midY * scale), Float(g.bar.maxX * scale), Float(g.bar.height * scale))
            } else {
                let s = VisualizerLayout.oscilloscope(in: points)
                u.h = SIMD4(Float(s.minX * scale), Float(s.minY * scale), Float(s.maxX * scale), Float(s.maxY * scale))
            }
            encodeScope(buffer, frame: frame, uniforms: &u, size: size, scale: scale, dt: dt)
        case .particles:
            u.g = SIMD4(Float(dt), Float(size.width / size.height), reduceMotion ? 1 : 0, Float(Self.particleCount))
            encodeParticles(buffer, uniforms: &u, size: size, dt: dt)
        case .meters:
            let faces = VisualizerLayout.meterFaces(in: points)
            u.g = px(faces[0])
            u.h = px(faces[1])
            let ppm = settings.meterKind == .ppm
            let travel = ppm ? SIMD2(Float(VisualizerMeters.ppmTravel(decibels: Double(frame.ppm.x))),
                                     Float(VisualizerMeters.ppmTravel(decibels: Double(frame.ppm.y)))) : frame.vu
            u.k = SIMD4(travel.x, travel.y, ppm ? 1 : 0, 0)
            u.c = SIMD4(peakLights.x, peakLights.y, 0, 0)
            updateMeterFace(size: size, scale: scale)
        case .mirrored:
            u.g = SIMD4(settings.mirrorLayout == .line ? 1 : 0, frame.bass * frame.beatPulse + 0.5 * frame.bass, 0, 0)
        default:
            break
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
        encoder.setFragmentTexture(trail ?? blank, index: 3)
        encoder.setFragmentTexture(meterFace ?? blank, index: 4)
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
        sinceFlash += dt
        if strobeAllowed && frame.beat && frame.bass > 0.8 && sinceFlash >= Self.flashInterval {
            strobe = 0.6
            sinceFlash = 0
        }
        strobe *= Float(exp(-dt / 0.045))
        if strobe < 0.003 || !strobeAllowed { strobe = 0 }

        // Meters: the peak lights come on near full scale (as the sensitivity control shows it) and stay lit a moment.
        let lightFall = Float(exp(-dt / 0.25))
        let over = Self.peakLit(peakDB: frame.peakDB, sensitivity: settings.sensitivity)
        peakLights = SIMD2(over.x ? 1 : peakLights.x * lightFall, over.y ? 1 : peakLights.y * lightFall)
    }

    /// Whether each meter's peak light is on for a frame's sample peaks (dBFS): above -1 dBFS, or above it once raised
    /// by the sensitivity control's gain, as the other styles show it. Turning the control down never hides a clip.
    static func peakLit(peakDB: SIMD2<Float>, sensitivity: Double) -> (x: Bool, y: Bool) {
        let gain = Float(20 * log10(max(sensitivity, 0.01)))
        let threshold: Float = -1 - max(0, gain)
        return (peakDB.x > threshold, peakDB.y > threshold)
    }

    /// At most one flash every 0.4 s (2.5 a second), under the 3 a second that photosensitivity guidelines (WCAG 2.3.1,
    /// Ofcom/Harding) allow, however fast the beats come.
    static let flashInterval = 0.4

    /// The strobe's brightness this frame, 0…0.6 (tests).
    var strobeLevel: Float { strobe }

    /// The strobe only flashes when it's switched on, its warning was accepted, and neither Reduce Motion nor Dim
    /// Flashing Lights is on.
    public var strobeAllowed: Bool {
        settings.strobe && settings.strobeWarningAccepted && !reduceMotion && !reduceFlashing
    }

    // MARK: Trails

    /// The trail texture at the drawable's size, cleared when it's new or another style used it last.
    private func prepareTrail(size: CGSize, for style: VisualizerStyle, buffer: MTLCommandBuffer) -> MTLTexture? {
        let w = Int(size.width), h = Int(size.height)
        var fresh = trailStyle != style
        if trail?.width != w || trail?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: trailFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            trail = device.makeTexture(descriptor: d)
            fresh = true
        }
        trailStyle = style
        guard let trail else { return nil }
        if fresh {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = trail
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        return trail
    }

    /// A pass into the trail: everything there fades to `keep`, then `draw` adds the new light.
    private func trailPass(_ buffer: MTLCommandBuffer, trail: MTLTexture, keep: Double, draw: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = trail
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass), let fadePipeline else { return }
        encoder.setRenderPipelineState(fadePipeline)
        encoder.setBlendColor(red: Float(keep), green: Float(keep), blue: Float(keep), alpha: Float(keep))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        draw(encoder)
        encoder.endEncoding()
    }

    // MARK: Scope

    /// The trace's points for this frame, in pixels: the goniometer's newest samples (left against right, turned
    /// 45°), or the two channels against time from a rising zero crossing. The gain follows the music's recent peak
    /// (like a scope's automatic gain), so quiet and loud masters fill the screen alike.
    static func scopePoints(frame: VisualizerFrame, mode: VisualizerScopeMode, size points: CGSize, scale: CGFloat,
                            gain: Float, brightness: Float, into out: inout [SIMD4<Float>]) {
        out.removeAll(keepingCapacity: true)
        let samples = frame.stereo
        guard samples.count >= 2 else { return }
        let s = Float(scale)
        switch mode {
        case .goniometer:
            let g = VisualizerLayout.goniometer(in: points)
            let c = SIMD2(Float(g.centre.x) * s, Float(g.centre.y) * s), radius = Float(g.radius) * s
            let k = gain * Float(0.5.squareRoot()) * radius
            for p in samples.suffix(1024) {
                // Mono upright, left to the upper left, right to the upper right, out of phase across.
                out.append(SIMD4(c.x + (p.y - p.x) * k, c.y - (p.x + p.y) * k, brightness, 0))
            }
        case .oscilloscope:
            let screen = VisualizerLayout.oscilloscope(in: points)
            let span = min(1024, samples.count / 2)
            // The newest rising zero crossing that still leaves a full sweep after it; else free-running.
            var start = samples.count - span
            var i = samples.count - span
            while i > 1 {
                let a = samples[i - 1].x + samples[i - 1].y, b = samples[i].x + samples[i].y
                if a < 0 && b >= 0 { start = i; break }
                i -= 1
            }
            let x0 = Float(screen.minX) * s, width = Float(screen.width) * s
            let height = Float(screen.height) * s, top = Float(screen.minY) * s
            let amplitude = gain * height * 0.22
            for channel in 0..<2 {
                let base = top + height * (channel == 0 ? 0.25 : 0.75)
                for j in 0..<span {
                    let p = samples[start + j]
                    out.append(SIMD4(x0 + width * Float(j) / Float(span - 1), base - (channel == 0 ? p.x : p.y) * amplitude,
                                     brightness, Float(channel + 1)))
                }
            }
        }
    }

    private func encodeScope(_ buffer: MTLCommandBuffer, frame: VisualizerFrame, uniforms u: inout VisualizerUniforms,
                             size: CGSize, scale: CGFloat, dt: Double) {
        guard let trail = prepareTrail(size: size, for: .scope, buffer: buffer), let beamPipeline, !beamBuffers.isEmpty else { return }
        // Automatic gain: up at once to the newest peak, back down over a couple of seconds, at most +30 dB.
        var peak: Float = 0
        for p in frame.stereo.suffix(1024) { peak = max(peak, abs(p.x), abs(p.y)) }
        scopeEnvelope = max(peak, scopeEnvelope * Float(exp(-dt / 2)))
        let gain = Float(settings.sensitivity) * 0.8 / max(scopeEnvelope, 0.0316)
        let goniometer = settings.scopeMode == .goniometer
        // Every sample leaves the same light whatever the frame rate: the goniometer redraws the newest 1,024
        // samples each frame, so each is drawn about 1,024 / (new samples per frame) times.
        let perFrame = max(1, dt / max(frame.stereoInterval, 1e-6))
        let brightness = Float(goniometer ? min(1, perFrame / 1024) * 0.22 : dt * 60 * 0.3) * (frame.hasSignal ? 1 : 0.4)
        Self.scopePoints(frame: frame, mode: settings.scopeMode, size: CGSize(width: size.width / scale, height: size.height / scale),
                         scale: scale, gain: gain, brightness: brightness, into: &points)
        beamIndex = (beamIndex + 1) % beamBuffers.count
        let target = beamBuffers[beamIndex]
        let count = min(points.count, Self.beamPoints)
        points.withUnsafeBytes { raw in
            if let base = raw.baseAddress { target.contents().copyMemory(from: base, byteCount: count * MemoryLayout<SIMD4<Float>>.stride) }
        }
        let keep = exp(-dt / (goniometer ? 0.07 : 0.05))
        var uniforms = u
        trailPass(buffer, trail: trail, keep: keep) { encoder in
            guard count >= 2 else { return }
            encoder.setRenderPipelineState(beamPipeline)
            encoder.setVertexBuffer(target, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
            if goniometer {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count - 1)
            } else {
                // Two sweeps, one per channel, not joined.
                let sweep = count / 2
                for channel in 0..<2 {
                    encoder.setVertexBufferOffset(channel * sweep * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sweep - 1)
                }
            }
        }
    }

    // MARK: Particles

    private func encodeParticles(_ buffer: MTLCommandBuffer, uniforms u: inout VisualizerUniforms, size: CGSize, dt: Double) {
        if particles == nil { particles = makeParticles() }
        guard let particles, let particleStep, let spritePipeline,
              let trail = prepareTrail(size: size, for: .particles, buffer: buffer) else { return }
        var uniforms = u
        if let compute = buffer.makeComputeCommandEncoder() {
            compute.setComputePipelineState(particleStep)
            compute.setBuffer(particles, offset: 0, index: 0)
            compute.setBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 1)
            let width = min(256, particleStep.maxTotalThreadsPerThreadgroup)
            compute.dispatchThreadgroups(MTLSize(width: (Self.particleCount + width - 1) / width, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }
        let keep = settings.particleTrails ? exp(-dt / 0.22) : 0
        trailPass(buffer, trail: trail, keep: keep) { encoder in
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBuffer(particles, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.particleCount)
        }
    }

    // MARK: Meters

    private func updateMeterFace(size: CGSize, scale: CGFloat) {
        let w = Int(size.width), h = Int(size.height)
        let key = "\(w)x\(h)@\(scale) \(settings.meterKind)"
        guard key != meterFaceKey else { return }
        meterFaceKey = key
        guard let bytes = VisualizerMeterFace.render(width: w, height: h, scale: scale, kind: settings.meterKind) else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        meterFace = texture
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
