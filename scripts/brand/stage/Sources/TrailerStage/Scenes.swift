// SPDX-License-Identifier: GPL-3.0-or-later
// The trailer's scenes. Times are musical: `s` is the scene's first downbeat, `b` one beat (0.923 s).
import AppKit
import SwiftUI

private let b = Music.beat

// MARK: - Intro: the crescent waxes, the name resolves, a capsule of glass passes over it.

struct IntroScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets

    var body: some View {
        let g = Geo(size: size)
        let type = g.pick(g.W * 0.085, square: g.W * 0.1, tall: g.W * 0.118)
        let exit = easeInOutCubic(progress(t, 2.8, 3.55))
        let phase = progress(t, 0.15, 1.55)
        let glow = smooth(progress(t, 0.2, 1.1)) * (1 - 0.6 * smooth(progress(t, 1.3, 2.6)))
        ZStack {
            lockup(type: type, phase: phase, glow: glow)
                .scaleEffect(1 - 0.12 * exit)
                .blur(radius: 14 * exit)
                .opacity(1 - exit)
            BrandLabel(text: "Surround and hi-res music for Mac", size: type * 0.12)
                .arrive(t, at: 1.75)
                .opacity(1 - smooth(progress(t, 2.6, 3.1)))
                .offset(y: type * 1.02)
        }
        .frame(width: size.width, height: size.height)
    }

    func letters(type: CGFloat, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: -type * 0.012) {
            ForEach(Array("vespertine".enumerated()), id: \.offset) { i, letter in
                let p = spring(t, start: 0.95 + Double(i) * 0.05, response: 0.85, damping: 0.92)
                Text(String(letter)).font(Font(BrandFont.serif(type, 300))).foregroundStyle(color)
                    .opacity(clamp01(p * 1.3))
                    .blur(radius: (1 - CGFloat(clamp01(p))) * type * 0.1)
                    .offset(y: (1 - CGFloat(p)) * type * 0.22)
            }
        }
    }

    func lockup(type: CGFloat, phase: Double, glow: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: type * 0.34) {
            Crescent(diameter: type * 0.92, phase: phase, glow: glow)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - d.height * 0.18 }
            letters(type: type, color: Brand.ivory)
                .overlay {
                    // A band of brass light travels through the letters once they've settled.
                    let sweep = easeInOutCubic(progress(t, 1.75, 2.75))
                    letters(type: type, color: Brand.brass)
                        .shadow(color: Brand.brass.opacity(0.6), radius: type * 0.12)
                        .mask(
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.5), .init(color: .clear, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: type * 2.2)
                                .rotationEffect(.degrees(14))
                                .offset(x: mix(-type * 5, type * 5, sweep))
                        )
                        .opacity(t > 1.7 && t < 2.85 ? 1 : 0)
                }
        }
    }
}

// MARK: - Bit-perfect (two bars)

struct HeroScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets
    let frame: CGImage?

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.bitPerfect.range.lowerBound
        let pose = self.pose(g, s)
        let cue = Cue.for(.bitPerfect)!
        ZStack(alignment: .topLeading) {
            morphGlass(g, s)
            WindowRig(frame: frame, sidebar: assets.sidebars[cue.recording], sidebarColor: assets.sidebarColor[cue.recording] ?? .gray, pose: pose,
                      inspectorOverlay: AnyView(SignalPulse(t: t, start: s + b * beat(g, 4.4, tall: 2.7))))
            copy(g, s)
        }
        .frame(width: g.W, height: g.H)
    }

    /// When things happen, in beats from the start of the scene. A vertical frame is too narrow for the sidebar
    /// lifting off a whole window to read, so there the camera pushes into Now Playing right after the window appears.
    func beat(_ g: Geo, _ wide: Double, tall: Double) -> Double { g.tall ? tall : wide }

    func startScale(_ g: Geo) -> CGFloat { g.pick(0.74, square: 0.6, tall: 0.345) * g.u }
    func startCenter(_ g: Geo) -> CGPoint { g.at((0.5, 0.5), tall: (0.5, 0.46)) }

    func pose(_ g: Geo, _ s: Double) -> RigPose {
        let appear = smooth(progress(t, s - 0.4, s - 0.12))
        let settle = spring(t, start: s - 0.1, response: 1.2, damping: 0.9)
        let explode = spring(t, start: s + b * 1.0, response: 0.95, damping: 0.8)
        let push = easeInOutQuint(progress(t, s + b * beat(g, 3.6, tall: 0.9), s + b * beat(g, 5.0, tall: 2.4)))
        let dolly = progress(t, s, s + b * 8)

        // Before the push: the whole window, slowly growing. After: the lifted Now Playing panel, big.
        let scale0 = startScale(g) * CGFloat(mix(0.96, 1.02, settle) * (1 + 0.015 * dolly))
        let pushScale = g.pick(0.95, square: 0.87, tall: 0.68) * g.u * CGFloat(1 + 0.02 * dolly)
        let lift = CGSize(width: g.pick(70, square: 50, tall: 0), height: 0)
        let inspectorCenter = CGPoint(x: AppWindow.inspector.midX + lift.width, y: AppWindow.inspector.midY)
        let pushTarget = g.at((0.71, 0.53), square: (0.66, 0.57), tall: (0.5, 0.6))
        let pushCenter = windowCenter(placing: inspectorCenter, at: pushTarget, scale: pushScale)

        return RigPose(
            center: mix(startCenter(g), pushCenter, push),
            scale: mix(scale0, pushScale, push),
            tiltX: 0,
            tiltY: (-5 * explode + 8 * smooth(progress(t, s + b * 1.6, s + b * 3.8))) * (1 - push) - g.pick(8, square: 6, tall: 0) * push,
            opacity: appear,
            explode: explode,
            sidebarLift: CGSize(width: mix(g.pick(-92, square: -80, tall: -60), g.pick(-420, square: -520, tall: -900), push), height: -6),
            inspectorLift: lift,
            contentDim: mix(0.3 * explode, 0.8, push),
            contentBlur: CGFloat(8 * push),
            inspectorScale: 1.07,
            sidebarScale: 1.05,
            shadow: 1,
            sidebarTiltY: g.tall ? 0 : 14,
            inspectorTiltY: g.tall ? 0 : -10 * (1 - push)
        )
    }

    /// The pane of glass that grows out of the intro's lockup into the window's frame.
    @ViewBuilder func morphGlass(_ g: Geo, _ s: Double) -> some View {
        let grow = easeInOutQuint(progress(t, 2.75, 3.6))
        let visible = window(t, 2.65, 3.95, fadeIn: 0.25, fadeOut: 0.4)
        if visible > 0.001 {
            let scale = startScale(g) * 0.96
            let target = CGSize(width: AppWindow.size.width * scale, height: AppWindow.size.height * scale)
            let startSize = CGSize(width: g.pick(g.W * 0.58, square: g.W * 0.8, tall: g.W * 0.9), height: g.pick(g.W * 0.12, square: g.W * 0.16, tall: g.W * 0.2))
            let w = mix(startSize.width, target.width, grow), h = mix(startSize.height, target.height, grow)
            let radius = mix(h / 2, 22 * scale, grow)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape.fill(.clear)
                .frame(width: w, height: h)
                .glassEffect(.clear, in: shape)
                .overlay(shape.strokeBorder(LinearGradient(colors: [Brand.brassHi.opacity(0.55), Color.white.opacity(0.06), Brand.brass.opacity(0.4)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
                .position(startCenter(g))
                .opacity(visible)
        }
    }

    @ViewBuilder func copy(_ g: Geo, _ s: Double) -> some View {
        let at = g.at((0.07, 0.43), square: (0.07, 0.46), tall: (0.5, 0.19))
        VStack(alignment: g.tall ? .center : .leading, spacing: 24 * g.u) {
            Tagline(text: "Every sample,\nuntouched.", size: g.pick(g.W * 0.05, square: g.W * 0.062, tall: g.W * 0.085), t: t, start: s + b * beat(g, 4.1, tall: 2.0),
                    alignment: g.tall ? .center : .leading, width: g.pick(g.W * 0.36, square: g.W * 0.42, tall: g.W * 0.86))
            BrandLabel(text: g.wide ? "Bit-perfect · 24-bit · 192 kHz · exclusive" : "Bit-perfect · 24-bit · 192 kHz",
                       size: g.pick(g.W * 0.0098, square: g.W * 0.014, tall: g.W * 0.022), brass: true, dot: true)
                .arrive(t, at: s + b * beat(g, 5.2, tall: 3.1))
        }
        .frame(width: g.pick(g.W * 0.4, square: g.W * 0.45, tall: g.W * 0.9), alignment: g.tall ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .position(x: g.tall ? g.W / 2 : at.x + g.pick(g.W * 0.2, square: g.W * 0.225), y: at.y)
    }
}

/// A pulse of brass light running down the signal path, lighting each stage; then BIT-PERFECT flares.
/// Coordinates are the inspector's own (window points minus the inspector's origin).
struct SignalPulse: View {
    let t: Double
    let start: Double

    // Measured in the recording (window points): the centres of the signal path's 7.5 pt rings, and the
    // centre line of the BIT-PERFECT badge's 1 pt border, so the light lands exactly on the app's own shapes.
    // Re-measured on the 2026-10-01 recording of Elton John's Regimental Sgt. Zippo: its album line wraps to two lines, so
    // everything below it sits 16 pt lower than in the first recording (rings 538.75 ... 708.75, badge 452.25). Measured the
    // same way on both clips (brass pixels in the ring column): every ring and the badge moved by exactly 16.0 pt, x by 0.
    static let nodeX: CGFloat = 1116.75 - AppWindow.inspector.minX
    static let nodes: [CGFloat] = [554.75, 593.75, 632.75, 685.75, 724.75].map { $0 - AppWindow.inspector.minY }
    static let ring: CGFloat = 7.5
    static let badge = CGRect(x: 1112.25 - AppWindow.inspector.minX, y: 468.25 - AppWindow.inspector.minY, width: 106, height: 22)

    var body: some View {
        let travel = easeInOutCubic(progress(t, start, start + b * 1.9))
        let y = mix(SignalPulse.nodes.first!, SignalPulse.nodes.last!, travel)
        let running = t > start && t < start + b * 2.3
        let lineFade = t < start + b * 2.3 ? 1 : max(0, 1 - (t - start - b * 2.3) * 1.2)
        let flare = t > start + b * 2.0 ? max(0, 1 - (t - (start + b * 2.0)) / 1.1) : 0
        ZStack(alignment: .topLeading) {
            Capsule().fill(Brand.brassGradient)
                .frame(width: 2.4, height: max(0, y - SignalPulse.nodes.first!))
                .offset(x: SignalPulse.nodeX - 1.2, y: SignalPulse.nodes.first!)
                .shadow(color: Brand.brass.opacity(0.9), radius: 5)
                .opacity(t > start ? lineFade * 0.95 : 0)
            ForEach(Array(SignalPulse.nodes.enumerated()), id: \.offset) { _, ny in
                let lit = t > start && y >= ny - 1
                let near = lit ? max(0, 1 - Double(abs(y - ny)) / 50) : 0
                Circle().fill(Brand.brassHi).frame(width: SignalPulse.ring, height: SignalPulse.ring)
                    .shadow(color: Brand.brass, radius: 8 + 16 * CGFloat(near))
                    .scaleEffect(1 + 0.9 * near)
                    .opacity(lit ? 1 : 0)
                    .offset(x: SignalPulse.nodeX - SignalPulse.ring / 2, y: ny - SignalPulse.ring / 2)
            }
            if running {
                Circle().fill(Color.white).frame(width: 11, height: 11)
                    .shadow(color: Brand.brassHi, radius: 12).shadow(color: Brand.brass, radius: 28)
                    .offset(x: SignalPulse.nodeX - 5.5, y: y - 5.5)
            }
            // The badge's own border lights up and fades; it stays on the border rather than rippling outward.
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Brand.brassHi, lineWidth: 1.4)
                .frame(width: SignalPulse.badge.width, height: SignalPulse.badge.height)
                .shadow(color: Brand.brass, radius: 6)
                .shadow(color: Brand.brass.opacity(0.8), radius: 18)
                .opacity(flare)
                .offset(x: SignalPulse.badge.minX, y: SignalPulse.badge.minY)
        }
        .frame(width: AppWindow.inspector.width, height: AppWindow.inspector.height, alignment: .topLeading)
    }
}

// MARK: - Shared layout for the one-bar feature scenes

/// A window that eases in turned toward the copy, drifting slowly for the rest of the bar.
func featurePose(_ g: Geo, t: Double, s: Double, right: Bool, dim: Double = 0) -> RigPose {
    let arrive = spring(t, start: s - 0.45, response: 1.0, damping: 0.88)
    let drift = progress(t, s - 0.45, s + Music.bar + 0.45)
    let x = g.pick(right ? 0.665 : 0.335, square: right ? 0.6 : 0.4, tall: 0.5)
    let y = g.pick(0.53, square: 0.64, tall: 0.47)
    let scale = g.pick(0.6, square: 0.54, tall: 0.345) * g.u * CGFloat(mix(0.93, 1.0, arrive) + 0.03 * drift)
    return RigPose(
        center: CGPoint(x: g.W * x + CGFloat(mix(right ? 24 : -24, right ? -18 : 18, drift)) * g.u, y: g.H * y),
        scale: scale,
        tiltY: g.tall ? 0 : (right ? -1 : 1) * mix(15, 9, drift),
        opacity: 1,
        contentDim: dim,
        contentBlur: CGFloat(dim * 6)
    )
}

struct FeatureCopy: View {
    let g: Geo
    let t: Double
    let start: Double
    let tagline: String
    var label: String? = nil
    var label2: String? = nil
    var brass = false
    var copper = false
    let right: Bool   // the window is on the right, so the copy is on the left

    var body: some View {
        let x = g.pick(right ? 0.07 : 0.63, square: 0.07, tall: 0.5)
        let y = g.pick(0.27, square: 0.15, tall: 0.2)
        let width = g.pick(g.W * 0.34, square: g.W * 0.8, tall: g.W * 0.88)
        VStack(alignment: g.tall ? .center : .leading, spacing: 20 * g.u) {
            Tagline(text: tagline, size: g.pick(g.W * 0.04, square: g.W * 0.056, tall: g.W * 0.078), t: t, start: start,
                    alignment: g.tall ? .center : .leading, width: width)
            if let label {
                BrandLabel(text: label, size: g.pick(g.W * 0.0092, square: g.W * 0.0135, tall: g.W * 0.02), brass: brass, copper: copper, dot: brass || copper)
                    .arrive(t, at: start + b * 0.75)
            }
            if let label2 {
                BrandLabel(text: label2, size: g.pick(g.W * 0.0092, square: g.W * 0.0135, tall: g.W * 0.02))
                    .arrive(t, at: start + b * 0.95)
            }
        }
        .frame(width: width, alignment: g.tall ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .position(x: g.tall ? g.W / 2 : g.W * x + width / 2, y: g.H * y)
    }
}

// MARK: - Native DSD

struct DSDScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets
    let frame: CGImage?

    static let badges = CGRect(x: 1104, y: 404, width: 196, height: 110)
    static let path = CGRect(x: 1104, y: 638, width: 306, height: 48)

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.dsd.range.lowerBound
        let lifted = smooth(progress(t, s + b * 0.4, s + b * 1.4))
        let pose = featurePose(g, t: t, s: s, right: true, dim: 0.55 * lifted)
        let cue = Cue.for(.dsd)!
        ZStack(alignment: .topLeading) {
            WindowRig(frame: frame, sidebar: assets.sidebars[cue.recording], sidebarColor: assets.sidebarColor[cue.recording] ?? .gray, pose: pose)
            FeatureCopy(g: g, t: t, start: s + b * 0.35, tagline: "Native DSD,\nnot a conversion.", right: true)
            Lift(image: frame, region: DSDScene.badges, pose: pose,
                 to: g.at((0.23, 0.6), square: (0.3, 0.44), tall: (0.5, 0.52)),
                 toScale: g.pick(1.75, square: 1.7, tall: 1.45) * g.u,
                 p: spring(t, start: s + b * 0.55, response: 0.8, damping: 0.8))
            Lift(image: frame, region: DSDScene.path, pose: pose,
                 to: g.at((0.25, 0.83), square: (0.36, 0.66), tall: (0.5, 0.7)),
                 toScale: g.pick(1.5, square: 1.35, tall: 1.2) * g.u,
                 p: spring(t, start: s + b * 1.15, response: 0.8, damping: 0.8))
        }
        .frame(width: g.W, height: g.H)
    }
}

// MARK: - Stereo and surround versions

struct VersionsScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets
    let frame: CGImage?

    static let rows = CGRect(x: 292, y: 452, width: 484, height: 70)
    static let source = CGRect(x: 1104, y: 562, width: 306, height: 34)

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.versions.range.lowerBound
        let lifted = smooth(progress(t, s + b * 0.4, s + b * 1.4))
        let pose = featurePose(g, t: t, s: s, right: false, dim: 0.55 * lifted)
        let cue = Cue.for(.versions)!
        ZStack(alignment: .topLeading) {
            WindowRig(frame: frame, sidebar: assets.sidebars[cue.recording], sidebarColor: assets.sidebarColor[cue.recording] ?? .gray, pose: pose)
            FeatureCopy(g: g, t: t, start: s + b * 0.35, tagline: "Stereo or surround,\non its own.",
                        label: "Stereo DAC → stereo", label2: "Spatial Audio → 5.1", right: false)
            Lift(image: frame, region: VersionsScene.rows, pose: pose,
                 to: g.at((0.76, 0.64), square: (0.5, 0.44), tall: (0.5, 0.52)),
                 toScale: g.pick(1.4, square: 1.5, tall: 1.0) * g.u,
                 p: spring(t, start: s + b * 0.55, response: 0.8, damping: 0.8))
            Lift(image: frame, region: VersionsScene.source, pose: pose,
                 to: g.at((0.76, 0.82), square: (0.5, 0.62), tall: (0.5, 0.66)),
                 toScale: g.pick(1.5, square: 1.5, tall: 1.2) * g.u,
                 p: spring(t, start: s + b * 1.15, response: 0.8, damping: 0.8))
        }
        .frame(width: g.W, height: g.H)
    }
}

// MARK: - Spatial Audio: the six channel meters become six glass speakers around you.

struct SpatialScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets
    let frame: CGImage?
    let meters: [Double]

    /// Speaker angles (degrees, 0 = in front) and distance (fraction of the ring), in meter order.
    static let layout: [(label: String, angle: Double, r: CGFloat)] = [
        ("L", -32, 1), ("R", 32, 1), ("C", 0, 1), ("LFE", 180, 0.42), ("Ls", -112, 1), ("Rs", 112, 1),
    ]

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.spatial.range.lowerBound
        let away = easeInOutCubic(progress(t, s + b * 0.8, s + b * 1.8))
        var pose = featurePose(g, t: t, s: s, right: true)
        pose.center = mix(pose.center, g.at((0.27, 0.62), square: (0.28, 0.72), tall: (0.5, 0.5)), away)
        pose.scale *= CGFloat(mix(1, 0.8, away))
        pose.opacity = mix(1, 0.4, away)
        pose.contentBlur = CGFloat(6 * away)
        let cue = Cue.for(.spatial)!
        let ringCenter = g.at((0.71, 0.53), square: (0.68, 0.58), tall: (0.5, 0.56))
        let ringR = g.pick(g.H * 0.27, square: g.H * 0.22, tall: g.W * 0.34)
        let lift = spring(t, start: s + b * 0.25, response: 0.75, damping: 0.85)
        let burst = spring(t, start: s + b * 1.05, response: 0.9, damping: 0.72)

        return ZStack(alignment: .topLeading) {
            WindowRig(frame: frame, sidebar: assets.sidebars[cue.recording], sidebarColor: assets.sidebarColor[cue.recording] ?? .gray, pose: pose)
            FeatureCopy(g: g, t: t, start: s + b * 1.1, tagline: "Your 5.1 albums,\nall around you.",
                        label: "Spatial · head tracked · 6 channels", copper: true, right: true)
            // The meters lift out of Now Playing…
            Lift(image: frame, region: Meters.region, pose: pose, to: ringCenter, toScale: 2.0 * g.u, p: lift,
                 fade: 1 - smooth(progress(t, s + b * 1.02, s + b * 1.3)))
            // …and become speakers placed around the listener.
            ring(center: ringCenter, radius: ringR, g: g, appear: burst)
        }
        .frame(width: g.W, height: g.H)
    }

    func ring(center: CGPoint, radius: CGFloat, g: Geo, appear: Double) -> some View {
        let orb = g.pick(66, square: 58, tall: 54) * g.u
        return ZStack {
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(CGFloat(mix(0.6, 1, appear)))
                .opacity(clamp01(appear))
                .position(center)
            // The listener.
            Circle().strokeBorder(Brand.ivory.opacity(0.5), lineWidth: 1.2).frame(width: orb * 0.5, height: orb * 0.5)
                .overlay(Circle().fill(Brand.ivory.opacity(0.8)).frame(width: orb * 0.12, height: orb * 0.12))
                .opacity(clamp01(appear))
                .position(center)
            ForEach(Array(SpatialScene.layout.enumerated()), id: \.offset) { i, spk in
                let level = i < meters.count ? meters[i] : 0
                let a = spk.angle * .pi / 180
                let home = CGPoint(x: center.x + CGFloat(sin(a)) * radius * spk.r, y: center.y - CGFloat(cos(a)) * radius * spk.r)
                let origin = CGPoint(x: center.x + (Meters.columns[i] - Meters.region.midX) * 2 * g.u,
                                     y: center.y + ((Meters.top + Meters.bottom) / 2 - Meters.region.midY) * 2 * g.u)
                let d = orb * (spk.label == "LFE" ? 0.8 : 1)
                // Each speaker leaves its meter as a disc exactly as wide as the bar (14 pt, lifted at 2×),
                // then grows on its way out; its name appears once it has nearly arrived.
                let grow = mix(14 * 2 * g.u / d, 1, clamp01(appear))
                let at = mix(origin, home, appear)
                ZStack {
                    Circle().fill(Brand.brass.opacity(0.18 + 0.5 * level))
                        .frame(width: d * CGFloat(0.3 + 0.55 * level), height: d * CGFloat(0.3 + 0.55 * level))
                        .blur(radius: d * 0.12)
                    Circle().fill(.clear).frame(width: d, height: d)
                        .glassEffect(.regular.tint(Brand.brass.opacity(0.06 + 0.22 * level)), in: Circle())
                    Circle().strokeBorder(Brand.brassHi.opacity(0.25 + 0.5 * level), lineWidth: 1).frame(width: d, height: d)
                }
                .scaleEffect(grow * (1 + 0.12 * CGFloat(level)))
                .position(at)
                .opacity(clamp01(appear * 4))
                Text(spk.label).font(Font(BrandFont.mono(11 * g.u, 500))).kerning(1.2 * g.u).foregroundStyle(Brand.ash)
                    .position(x: at.x, y: at.y + d / 2 + 14.5 * g.u)
                    .opacity(smooth(clamp01((appear - 0.6) / 0.35)))
            }
        }
    }
}

// MARK: - Fake hi-res detection

struct AnalysisScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets
    let frame: CGImage?

    static let badges = CGRect(x: 1106, y: 176, width: 202, height: 35)
    static let spectrum = CGRect(x: 1106, y: 476, width: 318, height: 172)

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.analysis.range.lowerBound
        let lifted = smooth(progress(t, s + b * 0.4, s + b * 1.4))
        let pose = featurePose(g, t: t, s: s, right: true, dim: 0.6 * lifted)
        let cue = Cue.for(.analysis)!
        ZStack(alignment: .topLeading) {
            WindowRig(frame: frame, sidebar: assets.sidebars[cue.recording], sidebarColor: assets.sidebarColor[cue.recording] ?? .gray, pose: pose)
            FeatureCopy(g: g, t: t, start: s + b * 0.35, tagline: "Know when\nhi-res isn't.", right: true)
            Lift(image: frame, region: AnalysisScene.spectrum, pose: pose,
                 to: g.at((0.64, 0.56), square: (0.6, 0.62), tall: (0.5, 0.62)),
                 toScale: g.pick(2.05, square: 2.1, tall: 1.5) * g.u,
                 p: spring(t, start: s + b * 0.5, response: 0.85, damping: 0.8),
                 overlay: AnyView(CutoffSweep(t: t, start: s + b * 1.3)))
            Lift(image: frame, region: AnalysisScene.badges, pose: pose,
                 to: g.at((0.22, 0.56), square: (0.3, 0.3), tall: (0.5, 0.35)),
                 toScale: g.pick(1.55, square: 1.5, tall: 1.4) * g.u,
                 p: spring(t, start: s + b * 1.0, response: 0.8, damping: 0.8))
        }
        .frame(width: g.W, height: g.H)
    }
}

/// A copper scan line runs across the spectrum and stops at the cutoff; the synthetic band above it glows.
struct CutoffSweep: View {
    let t: Double
    let start: Double
    // Measured in the recording (window points): the spectrum's plot panel and the app's dashed cutoff line.
    // Everything here stays inside the panel and is clipped to its rounded corners.
    static let plot = CGRect(x: 1112 - AnalysisScene.spectrum.minX, y: 503 - AnalysisScene.spectrum.minY, width: 308, height: 139.5)
    static let cutoffX: CGFloat = 1361.25 - 1112
    static let corner: CGFloat = 6

    var body: some View {
        let scan = easeInOutCubic(progress(t, start, start + b * 1.3))
        let x = mix(0, CutoffSweep.cutoffX, scan)
        let settled = smooth(progress(t, start + b * 1.3, start + b * 1.8))
        let plot = CutoffSweep.plot
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Brand.copper.opacity(0), Brand.copper.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(0, x), height: plot.height)
                .opacity(t > start ? 0.55 * (1 - settled) : 0)
            Rectangle().fill(Brand.copper.opacity(0.28))
                .frame(width: plot.width - CutoffSweep.cutoffX, height: plot.height)
                .offset(x: CutoffSweep.cutoffX)
                .opacity(settled)
            Rectangle().fill(Brand.copper)
                .frame(width: 1.6, height: plot.height)
                .shadow(color: Brand.copper, radius: 6)
                .offset(x: x - 0.8)
                .opacity(t > start ? 1 : 0)
        }
        .frame(width: plot.width, height: plot.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: CutoffSweep.corner, style: .continuous))
        .offset(x: plot.minX, y: plot.minY)
        .frame(width: AnalysisScene.spectrum.width, height: AnalysisScene.spectrum.height, alignment: .topLeading)
    }
}

// MARK: - The library

struct LibraryScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets
    let frame: CGImage?

    static let columns: [CGFloat] = [256, 450, 644, 838, 1032, 1227]
    static let rows: [CGFloat] = [176, 438]   // 0.6.4: the filter bar sits 2 pt lower
    static let card = CGSize(width: 172, height: 236)   // cover, title, artist and format

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.library.range.lowerBound
        var pose = featurePose(g, t: t, s: s, right: true)
        if g.tall {
            pose.scale = 0.62 * g.u * CGFloat(1 + 0.03 * progress(t, s - 0.45, s + Music.bar))
            pose.center = windowCenter(placing: CGPoint(x: 827, y: 420), at: g.at((0.5, 0.55)), scale: pose.scale)
        }
        pose.tiltX = mix(0, g.tall ? 0 : 11, smooth(progress(t, s, s + b * 2)))
        let wave = smooth(progress(t, s + b * 0.4, s + b * 1.2)) * (1 - smooth(progress(t, s + b * 2.5, s + b * 3.3)))
        pose.contentDim = 0.7 * wave
        let cue = Cue.for(.library)!
        return ZStack(alignment: .topLeading) {
            WindowRig(frame: frame, sidebar: assets.sidebars[cue.recording], sidebarColor: assets.sidebarColor[cue.recording] ?? .gray, pose: pose,
                      windowOverlay: AnyView(covers(s, dim: pose.contentDim)))
            FeatureCopy(g: g, t: t, start: s + b * 0.35, tagline: "Your whole\nlibrary.",
                        label: "FLAC · ALAC · WAV · AIFF", label2: "DSD · Dolby · DTS", right: true)
        }
        .frame(width: g.W, height: g.H)
    }

    /// Each album card rises out of the grid in a wave, catches the light, and settles back. The card leaves a
    /// recess where it was, so the grid's own title and format lines don't show twice under the lifted card.
    func covers(_ s: Double, dim: Double) -> some View {
        let cards = (0..<(LibraryScene.rows.count * LibraryScene.columns.count)).map { i -> (rect: CGRect, start: Double, lift: CGFloat) in
            let r = i / LibraryScene.columns.count, c = i % LibraryScene.columns.count
            let rect = CGRect(x: LibraryScene.columns[c], y: LibraryScene.rows[r], width: LibraryScene.card.width, height: LibraryScene.card.height)
            let start = s + b * 0.5 + Double(c) * 0.07 + Double(r) * 0.14
            let up = spring(t, start: start, response: 0.7, damping: 0.62)
            let down = spring(t, start: start + b * 1.9, response: 0.9, damping: 0.9)
            return (rect, start, CGFloat(max(0, up - down)))
        }
        // The overlay sits above the window's dimming, so the recess is darkened by the same amount.
        let shade = 1 - 0.45 * dim
        return ZStack(alignment: .topLeading) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 6 / 255 * shade, green: 6 / 255 * shade, blue: 7 / 255 * shade))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.05 * shade), lineWidth: 1))
                    .frame(width: card.rect.width + 6, height: card.rect.height + 6)
                    .offset(x: card.rect.minX - 3, y: card.rect.minY - 3)
                    .opacity(smooth(Double(card.lift) * 4))
            }
            if let frame {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    Image(decorative: crop(frame, card.rect), scale: 2).resizable()
                        .frame(width: card.rect.width, height: card.rect.height)
                        .overlay(Glint(p: progress(t, card.start + b * 0.6, card.start + b * 1.4)).clipped())
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.7 * Double(card.lift)), radius: 30 * card.lift, y: 20 * card.lift)
                        // At most 1.11× (1.13 at the spring's overshoot) so a card never covers its neighbours:
                        // the grid's gutters are 22 pt wide.
                        .scaleEffect(1 + 0.11 * card.lift)
                        .offset(x: card.rect.minX, y: card.rect.minY - 38 * card.lift)
                        .opacity(card.lift > 0.01 ? 1 : 0)
                }
            }
        }
        .frame(width: AppWindow.size.width, height: AppWindow.size.height, alignment: .topLeading)
    }
}

// MARK: - End card

struct EndScene: View {
    let t: Double
    let size: CGSize
    let assets: Assets

    var body: some View {
        let g = Geo(size: size)
        let s = Scene.end.range.lowerBound
        let logoIn = spring(t, start: s + 0.1, response: 1.1, damping: 0.9)
        let fadeOut = smooth(progress(t, Music.duration - 1.5, Music.duration - 0.15))
        let logoW = g.pick(g.W * 0.46, square: g.W * 0.64, tall: g.W * 0.8)
        let small = g.pick(g.W * 0.0165, square: g.W * 0.026, tall: g.W * 0.038)
        ZStack {
            // The glow sits behind the logo; its centre moves up, not the view, which would leave its bottom edge in frame.
            RadialGradient(colors: [Brand.brass.opacity(0.1 + 0.05 * sin((t - s) * 1.3)), .clear], center: UnitPoint(x: 0.5, y: 0.43), startRadius: 0, endRadius: g.W * 0.45)
            Image(decorative: assets.logo, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .frame(width: logoW)
                .scaleEffect(CGFloat(mix(0.94, 1, logoIn)))
                .blur(radius: CGFloat(1 - clamp01(logoIn)) * 16)
                .opacity(clamp01(logoIn * 1.4))
                .offset(y: -g.H * g.pick(0.07, square: 0.07, tall: 0.1))
            Text("Free and open source for macOS.").font(Font(BrandFont.sans(small, 400))).foregroundStyle(Brand.ash)
                .arrive(t, at: s + 0.9)
                .offset(y: g.H * g.pick(0.1, square: 0.08, tall: 0.03))
            Text("vespertineapp.com").font(Font(BrandFont.mono(small * 0.72, 500))).kerning(small * 0.07)
                .foregroundStyle(Brand.brass)
                .padding(.horizontal, small * 1.35).padding(.vertical, small * 0.68)
                .glassEffect(.regular.tint(Brand.brass.opacity(0.08)), in: Capsule())
                .arrive(t, at: s + 1.35)
                .offset(y: g.H * g.pick(0.19, square: 0.16, tall: 0.1))
            Text("Dolby and Dolby Atmos are trademarks of Dolby Laboratories. DTS is a trademark of DTS, Inc. AirPods and Spatial Audio are trademarks of Apple Inc. Vespertine isn't affiliated with them. Albums shown belong to their owners.")
                .font(Font(BrandFont.sans(g.pick(g.W * 0.0068, square: g.W * 0.0105, tall: g.W * 0.016), 400))).foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .frame(width: g.W * 0.72)
                .arrive(t, at: s + 2.2, rise: 0, blur: 0)
                .offset(y: g.H * g.pick(0.43, square: 0.42, tall: 0.24))
        }
        .frame(width: g.W, height: g.H)
        .scaleEffect(CGFloat(1 + 0.035 * easeInOutCubic(progress(t, s, Music.duration))))
        .opacity(1 - fadeOut)
    }
}
