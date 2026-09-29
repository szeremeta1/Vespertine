// SPDX-License-Identifier: GPL-3.0-or-later
// Pieces of the real interface lifted out of the window onto Liquid Glass, and the brand crescent.
import AppKit
import SwiftUI

/// Stage geometry helpers. `u` scales designs made for the 1600×900 pt wide stage to the others.
struct Geo {
    let size: CGSize
    var W: CGFloat { size.width }
    var H: CGFloat { size.height }
    var wide: Bool { W / H > 1.4 }
    var tall: Bool { H / W > 1.4 }
    var square: Bool { !wide && !tall }
    /// Design unit: 1 on the wide stage.
    var u: CGFloat { wide ? W / 1600 : (square ? W / 1000 : W / 540) }

    /// A point given as fractions of the stage, chosen per aspect.
    func at(_ wide: (CGFloat, CGFloat), square sq: (CGFloat, CGFloat)? = nil, tall tl: (CGFloat, CGFloat)? = nil) -> CGPoint {
        let f = self.wide ? wide : (self.tall ? (tl ?? sq ?? wide) : (sq ?? wide))
        return CGPoint(x: f.0 * W, y: f.1 * H)
    }
    func pick<T>(_ wide: T, square: T? = nil, tall: T? = nil) -> T { self.wide ? wide : (self.tall ? (tall ?? square ?? wide) : (square ?? wide)) }
}

/// Where a window point lands on stage for a pose (tilt ignored; lifts start from flat windows).
func stagePoint(_ p: CGPoint, _ pose: RigPose) -> CGPoint {
    CGPoint(x: pose.center.x + (p.x - AppWindow.size.width / 2) * pose.scale, y: pose.center.y + (p.y - AppWindow.size.height / 2) * pose.scale)
}

/// The window centre that puts window point `p` at stage point `target` for a given scale.
func windowCenter(placing p: CGPoint, at target: CGPoint, scale: CGFloat) -> CGPoint {
    CGPoint(x: target.x - (p.x - AppWindow.size.width / 2) * scale, y: target.y - (p.y - AppWindow.size.height / 2) * scale)
}

extension CGRect { var mid: CGPoint { CGPoint(x: midX, y: midY) } }

/// A region of the recording lifted off the window: it rises from where it sits in the window onto a
/// plate of Liquid Glass, grows, and settles where the story needs it.
struct Lift: View {
    let image: CGImage?
    let region: CGRect           // window points
    let pose: RigPose            // the window it comes out of
    let to: CGPoint              // stage point for the lifted region's centre
    let toScale: CGFloat         // stage points per window point once lifted
    let p: Double                // spring progress (may overshoot)
    var fade: Double = 1         // for leaving
    var plate: CGFloat = 14
    var corner: CGFloat = 12
    var overlay: AnyView? = nil  // drawn in the region's own coordinates

    var body: some View {
        let from = stagePoint(region.mid, pose)
        let s = mix(pose.scale, toScale, p)
        let rise = clamp01(p)
        let shape = RoundedRectangle(cornerRadius: corner + plate, style: .continuous)
        return ZStack {
            shape.fill(Color.black.opacity(0.35 * rise))
                .frame(width: region.width + plate * 2, height: region.height + plate * 2)
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.05), Brand.brass.opacity(0.25)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .opacity(smooth(rise * 1.6))
            if let image {
                Image(decorative: crop(image, region), scale: 2).resizable()
                    .frame(width: region.width, height: region.height)
                    .overlay(alignment: .topLeading) { overlay }
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
        }
        .scaleEffect(s)
        .shadow(color: .black.opacity(0.55 * rise), radius: 36 * rise, y: 24 * rise)
        .position(mix(from, to, p))
        .opacity(clamp01(p * 5) * fade)
    }
}

/// The brand crescent as vectors (docs/brand/logo.svg): a brass disc with an offset disc taken away.
/// `phase` 0 hides it completely (the dark disc covers the brass one); 1 is the logo's crescent.
struct Crescent: View {
    var diameter: CGFloat
    var phase: Double = 1
    var glow: Double = 0

    // From the logo's viewBox: outer disc r 92 at (189.69, 189.69); cut-out r 79.12 at (228.33, 169.45).
    static let outerR: CGFloat = 92, innerR: CGFloat = 79.12
    static let innerOffset = CGSize(width: 38.64, height: -20.24)

    var body: some View {
        let k = diameter / (2 * Crescent.outerR)
        let p = CGFloat(easeInOutCubic(phase))
        let innerR = mix(Crescent.outerR * 1.04, Crescent.innerR, Double(p)) * k
        let offset = CGSize(width: Crescent.innerOffset.width * k * p, height: Crescent.innerOffset.height * k * p)
        return Circle()
            .fill(LinearGradient(stops: [.init(color: Color(hex: 0xF0DAAA), location: 0), .init(color: Brand.brass, location: 0.55), .init(color: Brand.brassLo, location: 1)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: diameter, height: diameter)
            .mask(
                Rectangle().overlay(Circle().frame(width: innerR * 2, height: innerR * 2).offset(offset).blendMode(.destinationOut))
                    .compositingGroup()
            )
            .shadow(color: Brand.brass.opacity(0.55 * glow), radius: diameter * 0.35)
    }
}

/// A soft diagonal glint sweeping across whatever it overlays.
struct Glint: View {
    let p: Double
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Color.white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.35)
                .rotationEffect(.degrees(18))
                .offset(x: mix(-g.size.width * 0.5, g.size.width * 1.2, easeInOutCubic(p)))
                .blendMode(.plusLighter)
        }
        .opacity(p > 0 && p < 1 ? 1 : 0)
        .allowsHitTesting(false)
    }
}
