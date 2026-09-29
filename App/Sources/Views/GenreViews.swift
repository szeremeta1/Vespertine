//
// Vespertine — browsing by genre: a tile per genre, and each genre's albums.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

struct GenresView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 22, alignment: .top)]

    var body: some View {
        let genres = model.library.genres
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Genres", meta: "\(genres.count) genres") { EmptyView() }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach(genres) { GenreTile(genre: $0) }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.window)
    }
}

struct GenreTile: View {
    @Environment(AppModel.self) private var model
    let genre: GenreSummary

    var body: some View {
        Button { model.path.append(.genre(genre.key)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                GenreMosaic(keys: genre.artworkKeys)
                    .shadow(color: .black.opacity(0.45), radius: 13, y: 10)
                Text(genre.name).font(Typeface.serif(14)).foregroundStyle(Palette.text).lineLimit(1).padding(.top, 10)
                Text("\(genre.albumCount) album\(genre.albumCount == 1 ? "" : "s")")
                    .font(Typeface.mono(10)).foregroundStyle(Palette.text3).padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(genre.name), \(genre.albumCount) albums")
    }
}

/// Up to four covers in a square (one cover fills it).
struct GenreMosaic: View {
    let keys: [String]

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if keys.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { cover(keys[0]); cover(keys[1]) }
                        GridRow { cover(keys[2]); cover(keys[3]) }
                    }
                } else {
                    ArtworkView(key: keys.first, size: 400, cornerRadius: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private func cover(_ key: String) -> some View { ArtworkView(key: key, size: 300, cornerRadius: 0) }
}

struct GenreDetailView: View {
    @Environment(AppModel.self) private var model
    let genreKey: String

    var body: some View {
        let _ = model.library.revision
        let name = model.library.genres.first { $0.key == genreKey }?.name ?? genreKey
        AlbumsGridView(title: name, albumsOverride: model.library.albums(genre: genreKey))
    }
}
