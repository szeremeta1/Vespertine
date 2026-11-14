//
// Vespertine Remote: Now Playing's record: the cover as the label of a disc that turns with the song's position, and a
// tonearm that tracks across it. It shows where playback is, not the sound (the phone hears none of it).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct VinylView: View {
    let session: RemoteSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var player: PlayerState? { session.shownPlayer }
    private var spinning: Bool { player?.playback == .playing && player?.loading != true && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            // Room on the right for the arm's pivot.
            let disc = side * 0.9
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !spinning)) { context in
                let position = player?.expectedPosition(at: context.date) ?? 0
                let duration = max(player?.duration ?? 0, 0)
                let progress = duration > 0 ? position / duration : 0
                ZStack(alignment: .topLeading) {
                    record(diameter: disc, angle: reduceMotion ? 0 : VinylGeometry.rotation(position: position))
                        .frame(width: disc, height: disc)
                        .offset(x: 0, y: side - disc)
                    Tonearm(radius: disc / 2,
                            angle: player?.playback == .stopped || player?.nowPlaying == nil ? 0 : VinylGeometry.tonearmAngle(progress: progress))
                        .frame(width: disc, height: disc)
                        .offset(x: 0, y: side - disc)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: player?.playback == .stopped)
                }
                .frame(width: side, height: side, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Record"))
        .accessibilityValue(spinning ? Text("Turning") : Text("Still"))
    }

    private func record(diameter: CGFloat, angle: Double) -> some View {
        ZStack {
            // The disc and its grooves: the same from every angle, so they needn't turn.
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = size.width / 2
                let whole = Path(ellipseIn: CGRect(origin: .zero, size: size))
                context.fill(whole, with: .radialGradient(Gradient(colors: [Color(hex: 0x1B1B1F), Color(hex: 0x0A0A0B), Color(hex: 0x141417)]),
                                                         center: center, startRadius: radius * 0.3, endRadius: radius))
                var r = radius * VinylGeometry.grooveInner
                var index = 0
                while r < radius * VinylGeometry.grooveOuter {
                    // A few wider gaps between "songs".
                    let gap = index % 23 == 22
                    let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    context.stroke(ring, with: .color(Color(hex: 0xECE6DA, opacity: gap ? 0.015 : (index % 3 == 0 ? 0.075 : 0.04))), lineWidth: gap ? 2 : 0.6)
                    r += gap ? 5 : max(2.2, radius * 0.012)
                    index += 1
                }
                context.stroke(whole.strokedPath(StrokeStyle(lineWidth: 1)), with: .color(Color(hex: 0xECE6DA, opacity: 0.1)))
            }
            // The light on the vinyl: two soft wedges that stay put while the record turns.
            Circle()
                .fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0.0), .init(color: Palette.text.opacity(0.13), location: 0.07), .init(color: .clear, location: 0.15),
                    .init(color: .clear, location: 0.5), .init(color: Palette.text.opacity(0.09), location: 0.57), .init(color: .clear, location: 0.65),
                    .init(color: .clear, location: 1.0),
                ], center: .center, angle: .degrees(-70)))
                .mask(Circle().strokeBorder(lineWidth: diameter * (VinylGeometry.grooveOuter - VinylGeometry.grooveInner) / 2).padding(diameter * (1 - VinylGeometry.grooveOuter) / 2))
                .blendMode(.screen)
            // The label turns: the cover, with a paper ring and the spindle hole.
            ZStack {
                ArtworkView(key: player?.nowPlaying?.track.artworkKey, size: 600, cornerRadius: 0)
                    .clipShape(Circle())
                Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                Circle().fill(Palette.base).frame(width: diameter * 0.035, height: diameter * 0.035)
                Circle().strokeBorder(Palette.text.opacity(0.25), lineWidth: 0.5).frame(width: diameter * 0.035, height: diameter * 0.035)
            }
            .frame(width: diameter * VinylGeometry.labelShare, height: diameter * VinylGeometry.labelShare)
            .rotationEffect(.degrees(angle))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
    }
}

/// The arm, drawn hanging straight down from its pivot and turned to where the needle belongs.
private struct Tonearm: View {
    /// The record's radius in points.
    let radius: CGFloat
    /// Degrees from rest.
    let angle: Double

    var body: some View {
        let pivot = CGPoint(x: radius + radius * VinylGeometry.armPivot.x, y: radius + radius * VinylGeometry.armPivot.y)
        let length = radius * VinylGeometry.armLength
        let direction = VinylGeometry.restAngle(pivot: VinylGeometry.armPivot, length: VinylGeometry.armLength) + angle
        ZStack(alignment: .topLeading) {
            // Arm tube.
            Capsule()
                .fill(LinearGradient(colors: [Color(hex: 0xD9D4CA), Color(hex: 0x8E8980)], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(3, radius * 0.028), height: length * 0.9)
                .offset(x: -max(3, radius * 0.028) / 2, y: 0)
            // Headshell and cartridge at the needle end.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Palette.brassGradient)
                .frame(width: radius * 0.085, height: radius * 0.15)
                .offset(x: -radius * 0.0425, y: length * 0.88)
            // Counterweight behind the pivot.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: 0x55524C))
                .frame(width: radius * 0.1, height: radius * 0.14)
                .offset(x: -radius * 0.05, y: -radius * 0.2)
            // Pivot.
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x3A3A40), Color(hex: 0x1C1C21)], center: .center, startRadius: 0, endRadius: radius * 0.09))
                .overlay(Circle().strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
                .frame(width: radius * 0.17, height: radius * 0.17)
                .offset(x: -radius * 0.085, y: -radius * 0.085)
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
        .rotationEffect(.degrees(direction), anchor: .topLeading)
        .offset(x: pivot.x, y: pivot.y)
        .shadow(color: .black.opacity(0.5), radius: 5, x: 3, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
