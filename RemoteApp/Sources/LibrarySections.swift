//
// Vespertine Remote: the pages of the library the Mac's sidebar has besides albums, artists and playlists: songs,
// genres, sources, and a song's copies.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

/// A sidebar row with the count the Mac shows beside it.
struct CountedLabel: View {
    let title: String
    let symbol: String
    var count: Int?

    var body: some View {
        Label {
            HStack {
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                if let count, count > 0 {
                    Text(count.formatted()).font(.signal(.caption)).foregroundStyle(Palette.text3).fixedSize()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// A source as the Mac's sidebar lists it: its kind's symbol, its name, and whether it's offline or being scanned.
struct SourceLabel: View {
    let source: SourceSummary

    static func symbol(_ kind: SourceKind) -> String {
        switch kind {
        case .network: "server.rack"
        case .external: "externaldrive"
        case .managed: "tray.full"
        case .folder: "folder"
        }
    }

    var body: some View {
        Label {
            HStack {
                Text(source.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if source.scanning {
                    ProgressView().controlSize(.mini)
                } else if !source.online {
                    Text("OFFLINE")
                        .font(.signal(.caption2).weight(.semibold))
                        .foregroundStyle(Palette.text3)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.hairlineStrong))
                }
            }
        } icon: {
            Image(systemName: Self.symbol(source.kind))
        }
        .opacity(source.online ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}

/// A source's page: what it is and how it stands, as the Mac's page of it says, over the albums in it.
struct SourcePage: View {
    let session: RemoteSession
    let source: SourceSummary

    var body: some View {
        AlbumsGrid(session: session, listing: .source(id: source.id, name: source.name))
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(source.detail)
                    .font(.signal(.caption2)).foregroundStyle(Palette.text3)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(Palette.base)
                    .accessibilityIdentifier("source-status")
            }
    }
}

/// Every song, by title, a page at a time.
struct SongsList: View {
    let session: RemoteSession
    @State private var songs: [TrackSummary] = []
    @State private var total: Int?
    @State private var loading = false

    var body: some View {
        List {
            // A tap plays the songs listed so far from that one, as a double-click in the Mac's Songs page plays from there.
            TrackRows(session: session, tracks: songs, play: { index in .playTracks(ids: songs.compactMap(\.id), startAt: index, shuffled: nil) })
            if let total, songs.count < total {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
                    .onAppear { Task { await loadMore() } }
            }
        }
        .obsidianList()
        .navigationTitle("Songs").screenTitleStyle()
        .accessibilityIdentifier("songs-list")
        .task(id: session.isConnected) { if songs.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading else { return }
        if let total, songs.count >= total { return }
        loading = true
        defer { loading = false }
        if case .songs(let items, let all) = await session.send(.songs(offset: songs.count, limit: 200)) {
            songs += items
            total = all
        }
    }
}

/// A tile per genre, as on the Mac: up to four covers in a square, the genre's name and how many albums it has.
struct GenresGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: RemoteSession
    @State private var genres: [GenreSummary] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
                                         count: RemoteLayout.albumColumns(width: min(geometry.size.width, 1200), accessibilityText: typeSize.isAccessibilitySize)), spacing: 20) {
                    ForEach(genres) { genre in
                        NavigationLink { AlbumsGrid(session: session, listing: .genre(key: genre.key, name: genre.name)) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                GenreMosaic(keys: genre.artworkKeys)
                                Text(genre.name).font(.serif(.subheadline, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                                Text("Albums: \(genre.albumCount)").font(.signal(.caption2)).foregroundStyle(Palette.text3)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                    }
                }
                .padding()
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
                if loaded, genres.isEmpty {
                    Text(problem ?? String(localized: "No genres yet"))
                        .font(problem == nil ? .serif(.title3) : .callout).foregroundStyle(Palette.text2)
                        .multilineTextAlignment(.center).padding(.top, 60).padding(.horizontal, 32)
                }
            }
            .accessibilityIdentifier("genres-grid")
        }
        .obsidianBackground()
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.isConnected) {
            switch await session.send(.genres) {
            case .genres(let items): genres = items; problem = nil; loaded = true
            case .failed(let reason): problem = reason.isEmpty ? nil : reason; loaded = !reason.isEmpty
            default: break
            }
        }
    }
}

/// Up to four covers in a square (fewer than four: the first fills it).
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
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
    }

    private func cover(_ key: String) -> some View { ArtworkView(key: key, size: 300, cornerRadius: 0) }
}

// MARK: - A song's copies

/// Beside a song the library has in several copies: "2 COPIES", opening the list of them (as on the Mac).
struct SongCopiesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("\(count) COPIES").font(.signal(.caption2).weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.hairlineStrong))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel(Text("\(count) COPIES"))
        .accessibilityHint(Text("Shows this song’s copies"))
    }
}

/// Every copy of a song: its format, what its folder calls it, where it is and its length; play it or favorite it.
struct SongCopiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession
    /// The row's song (the copy the list shows).
    let track: TrackSummary
    /// The list the row is in: playing another copy from here plays it in the row's place, then goes on with the list.
    let list: [TrackSummary]
    let index: Int
    @State private var feedback = CommandFeedback()
    /// Hearts changed here, until the list is loaded again.
    @State private var hearts: [Int64: Bool] = [:]

    private var copies: [TrackCopy] { track.copies ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(copies) { copy in row(copy) }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.serif(.title3, weight: .medium)).foregroundStyle(Palette.text).textCase(nil)
                        (Text("\(copies.count) COPIES") + Text(verbatim: " · ") + Text("IN YOUR LIBRARY"))
                            .font(.signal(.caption2).weight(.semibold)).foregroundStyle(Palette.brass)
                    }
                    .padding(.bottom, 6)
                } footer: {
                    Text("Play plays that copy here, then the list goes on. A heart is for that copy; where an album’s copies are bundled on the Mac, it is for all of them.")
                }
            }
            .obsidianList()
            .navigationTitle("Copies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .feedback(feedback)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ copy: TrackCopy) -> some View {
        let favorite = hearts[copy.id] ?? copy.favorite
        return HStack(spacing: 10) {
            Button { play(copy) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.caption)
                        .foregroundStyle(Palette.text)
                        .frame(width: 30, height: 30)
                        .background(Palette.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.hairlineStrong))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Chip(text: copy.format, highlighted: copy.hiRes)
                            if copy.id == track.id {
                                Text("IN THIS LIST").font(.signal(.caption2).weight(.semibold)).foregroundStyle(Palette.text3)
                            }
                            if copy.preferred {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.brass)
                                    .accessibilityLabel(Text("Preferred copy"))
                            }
                        }
                        if let edition = copy.edition {
                            Text(edition).font(.caption.weight(.medium)).foregroundStyle(Palette.text2).lineLimit(1)
                        }
                        Text(copy.location).font(.caption2).foregroundStyle(Palette.text3).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Text(formatTime(copy.duration)).font(.caption.monospacedDigit()).foregroundStyle(Palette.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Play This Copy"))
            Button {
                hearts[copy.id] = !favorite
                feedback.run(session, .setFavorite(ids: [copy.id], on: !favorite))
            } label: {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .foregroundStyle(favorite ? Palette.brass : Palette.text3)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(favorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
        }
        .disabled(!session.isConnected)
    }

    /// Plays this copy in the row's place, then the rest of the list as it is.
    private func play(_ copy: TrackCopy) {
        var ids = list.map(\.id)
        if ids.indices.contains(index) { ids[index] = copy.id }
        let before = ids[..<min(index, ids.count)].compactMap { $0 }.count
        feedback.run(session, .playCopy(ids: ids.compactMap { $0 }, startAt: before))
        dismiss()
    }
}
