//
// Vespertine — favorite songs: the heart button, its table cell, and the Favorites page.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

/// A quiet heart: an outline in the faintest ink until the song is a favorite, then filled brass.
struct FavoriteButton: View {
    /// Optional on purpose: table rows being torn down lose their environment for a last layout pass,
    /// and a required lookup traps there. Tables pass the model in instead.
    @Environment(AppModel.self) private var environmentModel: AppModel?
    let track: Track?
    var size: CGFloat = 13
    var appModel: AppModel? = nil
    @State private var hovering = false
    @State private var bounce = 0

    var body: some View {
        if let model = appModel ?? environmentModel { button(model) }
    }

    private func button(_ model: AppModel) -> some View {
        let isOn = model.library.isFavorite(track)
        return Button {
            guard let track else { return }
            if !isOn { bounce += 1 }
            model.toggleFavorite([track])
        } label: {
            Image(systemName: isOn ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isOn ? Palette.brass : hovering ? Palette.text2 : Palette.text3)
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.up, options: .nonRepeating, value: bounce)
                .frame(width: size + 9, height: size + 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(track?.id == nil)
        .help(isOn ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(isOn ? "Remove from Favorites" : "Add to Favorites")
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The heart column of track tables: a filled heart on favorites; on other songs the outline appears only
/// where it's wanted (the pointer is over it, the row is selected, or the song is playing).
struct FavoriteCell: View {
    let model: AppModel
    let track: Track
    var emphasized = false
    @State private var hovering = false

    var body: some View {
        let visible = hovering || emphasized || model.library.isFavorite(track)
        FavoriteButton(track: track, size: 11, appModel: model)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Every favorite song, the most recently favorited first.
struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Favorites",
                       meta: "\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(tracks.reduce(0) { $0 + $1.duration }.longDuration)") {
                Button { model.player.shuffle = true; model.player.play(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(QuietButtonStyle()).disabled(tracks.isEmpty)
                Button { model.player.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(BrassButtonStyle()).disabled(tracks.isEmpty)
            }
            if tracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "heart")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(Palette.brass)
                    Text("No favorites yet").font(Typeface.serif(18)).foregroundStyle(Palette.text2)
                    Text("Click \(Image(systemName: "heart")) beside a song while it plays, or choose Add to Favorites from any song’s menu.")
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackTable(tracks: tracks)
            }
        }
        .background(Palette.window)
        .task(id: "\(model.library.favoriteIDs.hashValue)#\(model.library.revision)") { tracks = model.library.favoriteTracks() }
    }
}
