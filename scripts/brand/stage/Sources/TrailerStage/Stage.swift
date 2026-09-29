// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// The whole trailer at the frame's time: every visible scene, masked by the transition into it.
struct StageView: View {
    @ObservedObject var frame: Frame
    let assets: Assets
    let size: CGSize

    var body: some View {
        let t = frame.t
        ZStack(alignment: .topLeading) {
            Backdrop(size: size, glow: CGPoint(x: size.width * 0.72, y: size.height * 0.42))
            ForEach(Array(Scene.allCases.enumerated()), id: \.offset) { _, scene in
                if visible(scene, t) {
                    ZStack {
                        // A scene entered through a transition covers what it replaces.
                        if Transition.into(scene) != nil { Backdrop(size: size, glow: glow(for: scene)) }
                        sceneView(scene, t)
                    }
                    .frame(width: size.width, height: size.height)
                    .mask(alignment: .topLeading) { mask(for: scene, t) }
                }
            }
            ForEach(Array(Transition.all.enumerated()), id: \.offset) { _, transition in
                if transition.isActive(t) { transition.glass(t, size) }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// Where each scene's brass glow sits: behind the thing it's about.
    func glow(for scene: Scene) -> CGPoint {
        let g = Geo(size: size)
        switch scene {
        case .dsd, .analysis: return g.at((0.3, 0.6), square: (0.35, 0.45), tall: (0.5, 0.55))
        case .versions: return g.at((0.72, 0.62), square: (0.5, 0.5), tall: (0.5, 0.55))
        case .spatial: return g.at((0.71, 0.53), square: (0.68, 0.58), tall: (0.5, 0.56))
        case .end: return g.at((0.5, 0.42))
        default: return g.at((0.72, 0.42))
        }
    }

    func visible(_ scene: Scene, _ t: Double) -> Bool {
        t >= scene.range.lowerBound - Cue.overlap && t <= scene.range.upperBound + Cue.overlap
    }

    @ViewBuilder func sceneView(_ scene: Scene, _ t: Double) -> some View {
        switch scene {
        case .intro: IntroScene(t: t, size: size, assets: assets)
        case .bitPerfect: HeroScene(t: t, size: size, assets: assets, frame: video(.bitPerfect))
        case .dsd: DSDScene(t: t, size: size, assets: assets, frame: video(.dsd))
        case .versions: VersionsScene(t: t, size: size, assets: assets, frame: video(.versions))
        case .spatial: SpatialScene(t: t, size: size, assets: assets, frame: video(.spatial), meters: frame.meters)
        case .analysis: AnalysisScene(t: t, size: size, assets: assets, frame: video(.analysis))
        case .library: LibraryScene(t: t, size: size, assets: assets, frame: video(.library))
        case .end: EndScene(t: t, size: size, assets: assets)
        }
    }

    func video(_ scene: Scene) -> CGImage? {
        guard let cue = Cue.for(scene) else { return nil }
        return frame.video[cue.key] ?? assets.poster[cue.recording]
    }

    /// A scene entered through a transition shows only inside its growing shape.
    func mask(for scene: Scene, _ t: Double) -> some View {
        Canvas { ctx, sz in
            var path = Path(CGRect(origin: .zero, size: sz))
            if let incoming = Transition.into(scene), t < incoming.end { path = incoming.revealed(t, sz) }
            ctx.fill(path, with: .color(.white))
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Transitions: a shape of Liquid Glass grows over each cut, with the next scene inside it

struct Transition {
    enum Shape {
        case circle
        case capsule(aspect: CGFloat)   // width ÷ height of the pill
    }
    let into: Scene
    let center: UnitPoint
    var shape: Shape = .circle
    var duration = 0.95

    var at: Double { into.range.lowerBound }
    var start: Double { at - duration / 2 }
    var end: Double { at + duration / 2 }
    func isActive(_ t: Double) -> Bool { t > start - 0.02 && t < end + 0.02 }
    func p(_ t: Double) -> Double { easeInOutCubic(progress(t, start, end)) }

    static let all: [Transition] = [
        Transition(into: .dsd, center: UnitPoint(x: 0.72, y: 0.5)),
        Transition(into: .versions, center: UnitPoint(x: 0.3, y: 0.62), shape: .capsule(aspect: 2.4)),
        Transition(into: .spatial, center: UnitPoint(x: 0.71, y: 0.53)),
        Transition(into: .analysis, center: UnitPoint(x: 0.64, y: 0.56), shape: .capsule(aspect: 1.9)),
        Transition(into: .library, center: UnitPoint(x: 0.62, y: 0.5)),
        Transition(into: .end, center: UnitPoint(x: 0.5, y: 0.45), duration: 1.15),
    ]
    static func into(_ scene: Scene) -> Transition? { all.first { $0.into == scene } }

    static let band: CGFloat = 78

    /// The shape's half-height grows until the whole frame, band included, is inside it.
    func radius(_ t: Double, _ size: CGSize) -> CGFloat {
        mix(0, coverRadius(size) + Transition.band, p(t))
    }

    /// The smallest half-height at which the shape contains all four corners of the frame.
    func coverRadius(_ size: CGSize) -> CGFloat {
        let corners = [CGPoint(x: -2, y: -2), CGPoint(x: size.width + 2, y: -2), CGPoint(x: -2, y: size.height + 2), CGPoint(x: size.width + 2, y: size.height + 2)]
        var lo: CGFloat = 0, hi: CGFloat = hypot(size.width, size.height) * 1.5
        for _ in 0..<22 {
            let mid = (lo + hi) / 2
            let shape = path(radius: mid, size)
            if corners.allSatisfy({ shape.contains($0) }) { hi = mid } else { lo = mid }
        }
        return hi
    }
    func centerPoint(_ size: CGSize) -> CGPoint { CGPoint(x: center.x * size.width, y: center.y * size.height) }

    func rect(radius r: CGFloat, _ size: CGSize) -> CGRect {
        let c = centerPoint(size)
        switch shape {
        case .circle: return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .capsule(let aspect): return CGRect(x: c.x - r * aspect, y: c.y - r, width: 2 * r * aspect, height: 2 * r)
        }
    }
    func path(radius r: CGFloat, _ size: CGSize) -> Path {
        guard r > 0 else { return Path() }
        return Path(roundedRect: rect(radius: r, size), cornerRadius: r, style: .continuous)
    }

    /// The part of the frame showing the incoming scene.
    func revealed(_ t: Double, _ size: CGSize) -> Path { path(radius: radius(t, size), size) }

    @ViewBuilder func glass(_ t: Double, _ size: CGSize) -> some View {
        let r = radius(t, size)
        if r > 2 {
            let band = Band(outer: path(radius: r, size), inner: path(radius: max(0, r - min(Transition.band, r)), size))
            Color.clear
                .frame(width: size.width, height: size.height)
                .glassEffect(.regular, in: band)
                .overlay(path(radius: r, size).stroke(LinearGradient(colors: [Brand.brassHi.opacity(0.7), Color.white.opacity(0.1), Brand.brass.opacity(0.5)],
                                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.4))
                .overlay(path(radius: max(0, r - Transition.band), size).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// The ring of glass between two nested paths.
struct Band: Shape {
    let outer: Path
    let inner: Path
    func path(in rect: CGRect) -> Path { outer.subtracting(inner) }
}
