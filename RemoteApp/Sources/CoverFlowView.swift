//
// Vespertine Remote: Cover Flow: the albums as a row of covers standing in space, flicked through with a finger. The
// row's perspective shifts a little as the device tilts (motion sensors), unless Reduce Motion is on or it's switched off.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import UIKit
import VespertineRemoteClient
import VespertineRemoteProtocol

struct CoverFlowView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let session: RemoteSession
    let albums: [AlbumSummary]
    /// The library has more albums than are loaded: called as the row nears the end.
    var loadMore: () -> Void = {}

    /// Which cover is in front; fractions while the row moves.
    @State private var position: Double = 0
    @State private var dragStart: Double?
    @State private var opened: AlbumSummary?
    @State private var feedback = CommandFeedback()
    @State private var sensing = false

    private var front: Int { min(max(Int(position.rounded()), 0), max(albums.count - 1, 0)) }
    private var album: AlbumSummary? { albums.indices.contains(front) ? albums[front] : nil }
    private var followsTilt: Bool { model.settings.tiltParallax && !reduceMotion }
    private var tilt: Tilt { followsTilt ? model.tiltSensor.tilt : .zero }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width * 0.62, max(120, geometry.size.height - 250), 420)
            let layout = CoverFlowLayout(coverSide: side, flat: reduceMotion)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                stage(layout)
                    .frame(height: side * 1.42)
                caption
                    .padding(.top, 4)
                Spacer(minLength: 0)
                scrubber
                    .padding(.horizontal, 24).padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
        }
        .background(floor.ignoresSafeArea())
        .feedback(feedback)
        .sensoryFeedback(.selection, trigger: front)
        .sheet(item: $opened) { album in
            NavigationStack {
                AlbumView(session: session, album: album)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { opened = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: front) { _, new in
            if new >= albums.count - 12 { loadMore() }
        }
        .onChange(of: albums.count) { _, count in
            position = min(position, Double(max(count - 1, 0)))
        }
        .onAppear { sense(scenePhase == .active) }
        .onDisappear { sense(false) }
        .onChange(of: scenePhase) { _, phase in sense(phase == .active) }
        .onChange(of: followsTilt) { _, _ in sense(scenePhase == .active) }
    }

    /// Reads the motion sensors only while Cover Flow is on screen and following the tilt.
    private func sense(_ wanted: Bool) {
        let on = wanted && followsTilt
        guard on != sensing else { return }
        sensing = on
        if on {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                model.tiltSensor.orientation = .init(scene.interfaceOrientation)
            }
            model.tiltSensor.start()
        } else {
            model.tiltSensor.stop()
        }
    }

    private var floor: some View {
        ZStack {
            Palette.base
            RadialGradient(colors: [Palette.brass.opacity(0.10), .clear], center: .init(x: 0.5 + tilt.x * 0.04, y: 0.36), startRadius: 0, endRadius: 420)
        }
    }

    private func stage(_ layout: CoverFlowLayout) -> some View {
        let tilt = tilt
        return ZStack {
            ForEach(layout.visible(around: position, count: albums.count), id: \.self) { index in
                let pose = layout.pose(offset: Double(index) - position, tilt: tilt)
                CoverFlowCover(album: albums[index], side: layout.coverSide, dim: pose.depth)
                    .scaleEffect(pose.scale)
                    .rotation3DEffect(.degrees(pose.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                    .offset(x: pose.x)
                    .opacity(pose.opacity)
                    .zIndex(pose.z)
                    .onTapGesture { tapped(index) }
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .rotation3DEffect(.degrees(layout.stagePitch(tilt: tilt)), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
        .contentShape(Rectangle())
        .gesture(drag(layout))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.map { Text("\($0.title), \($0.artist)") } ?? Text("No albums"))
        .accessibilityValue(albums.isEmpty ? Text(verbatim: "") : Text("Album \(front + 1) of \(albums.count)"))
        .accessibilityHint(Text("Swipe up or down for the next or previous album. Double-tap to open it."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(to: front + 1)
            case .decrement: move(to: front - 1)
            @unknown default: break
            }
        }
        .accessibilityAction { opened = album }
    }

    private func drag(_ layout: CoverFlowLayout) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = dragStart ?? position
                dragStart = start
                position = layout.dragged(from: start, translation: value.translation.width, count: albums.count)
            }
            .onEnded { value in
                let start = dragStart ?? position
                dragStart = nil
                move(to: layout.rest(from: start, translation: value.translation.width, predicted: value.predictedEndTranslation.width, count: albums.count))
            }
    }

    private func tapped(_ index: Int) {
        if index == front { opened = albums[index] } else { move(to: index) }
    }

    private func move(to index: Int) {
        let target = Double(min(max(index, 0), max(albums.count - 1, 0)))
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { position = target }
    }

    @ViewBuilder private var caption: some View {
        if let album {
            VStack(spacing: 5) {
                Text(album.title).font(.serif(.title3, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(album.artist).font(.subheadline).foregroundStyle(Palette.text2).lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: album.format, highlighted: album.hiRes || album.dsd)
                    if let year = album.year { Chip(text: String(year)) }
                    Chip(text: String(localized: "\(album.trackCount) songs"))
                }
                .padding(.top, 2)
                HStack(spacing: 12) {
                    Button { feedback.run(session, .playAlbum(key: album.key, startAt: 0, shuffled: false)) } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color(hex: 0x1A140A))
                    Button { feedback.run(session, .playAlbum(key: album.key, startAt: 0, shuffled: true)) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(minWidth: 96)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 10)
                .disabled(!session.isConnected)
            }
            .padding(.horizontal, 24)
            .id(album.key)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: album.key)
        } else {
            Text("No albums yet").font(.serif(.title3)).foregroundStyle(Palette.text2)
        }
    }

    /// A thin bar to cross a long library quickly.
    @ViewBuilder private var scrubber: some View {
        if albums.count > 1 {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { min(max(position, 0), Double(albums.count - 1)) }, set: { position = $0.rounded() }),
                       in: 0...Double(albums.count - 1), step: 1)
                    .tint(Palette.brassLo)
                    .accessibilityHidden(true)
                Text(verbatim: "\(front + 1) / \(albums.count)")
                    .font(.signal(.caption2)).foregroundStyle(Palette.text3)
                    .frame(minWidth: 52, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// One cover with its reflection on the floor.
private struct CoverFlowCover: View {
    let album: AlbumSummary
    let side: CGFloat
    /// 0 in front, 1 in the stacks (a little darker).
    let dim: Double

    var body: some View {
        VStack(spacing: 2) {
            ArtworkView(key: album.artworkKey, size: 600, cornerRadius: 3)
                .overlay(Rectangle().strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
                .frame(width: side, height: side)
            ArtworkView(key: album.artworkKey, size: 600, cornerRadius: 3)
                .frame(width: side, height: side)
                .scaleEffect(x: 1, y: -1)
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.32), location: 0), .init(color: .clear, location: 0.42)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: side * 0.4, alignment: .top)
                .clipped()
        }
        .overlay(Color.black.opacity(0.38 * dim).allowsHitTesting(false))
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }
}
