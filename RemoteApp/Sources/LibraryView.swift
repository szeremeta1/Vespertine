//
// Vespertine Remote: the Mac's library: albums, artists, playlists, favorites and search.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct LibraryView: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    var section: RemoteDestination? = nil
    @State private var search = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let section {
                    sectionContent(section)
                } else if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    List {
                        NavigationLink(value: "albums") { Label("Albums", systemImage: "square.stack") }
                        NavigationLink(value: "artists") { Label("Artists", systemImage: "music.mic") }
                        NavigationLink { PlaylistsList(session: session) } label: { Label("Playlists", systemImage: "music.note.list") }
                        NavigationLink {
                            TrackListView(session: session, title: Text("Favorites"), load: .favorites, play: nil)
                        } label: { Label("Favorites", systemImage: "heart") }
                    }
                } else {
                    SearchResults(session: session, text: search)
                }
            }
            .obsidianList()
            .navigationTitle(section?.title ?? String(localized: "Library"))
            .searchable(text: $search, prompt: Text("Songs, artists, albums"))
            .navigationDestination(for: String.self) { place in
                switch place {
                case "artists": ArtistsList(session: session)
                case "playlists": PlaylistsList(session: session)
                case "favorites": TrackListView(session: session, title: Text("Favorites"), load: .favorites, play: nil)
                default: AlbumsGrid(session: session)
                }
            }
            .onAppear {
                #if DEBUG
                if model.startScreen == "search" { search = "Harbor"; model.startScreen = nil }
                #endif
                guard section == nil else { return }
                switch model.startScreen {
                case "albums", "coverFlow", "album": path = ["albums"]; if model.startScreen != "album" { model.startScreen = nil }
                case "artists", "playlists", "favorites":
                    if let screen = model.startScreen { path = [screen] }
                    model.startScreen = nil
                default: break
                }
            }
        }
    }

    @ViewBuilder private func sectionContent(_ place: RemoteDestination) -> some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResults(session: session, text: search)
        } else {
            switch place {
            case .artists: ArtistsList(session: session).readablePane()
            case .playlists: PlaylistsList(session: session).readablePane()
            case .favorites: TrackListView(session: session, title: Text("Favorites"), load: .favorites, play: nil).readablePane()
            default: AlbumsGrid(session: session)
            }
        }
    }
}

private struct SearchResults: View {
    let session: RemoteSession
    let text: String
    @State private var tracks: [TrackSummary] = []

    var body: some View {
        List {
            TrackRows(session: session, tracks: tracks, play: { index in .playTracks(ids: tracks.compactMap(\.id), startAt: index, shuffled: nil) })
        }
        .obsidianList()
        .task(id: text) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if case .tracks(let items) = await session.send(.search(text: text, limit: 200)) { tracks = items }
            }
    }
}

struct AlbumsGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    @State private var albums: [AlbumSummary] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var sample: AlbumSummary?
    var artist: String?

    private var coverFlow: Bool { model.settings.albumsLayout == .coverFlow }

    var body: some View {
        Group {
            if coverFlow {
                CoverFlowView(session: session, albums: albums) { Task { await loadMore() } }
            } else {
                grid
            }
        }
        .obsidianBackground()
        .navigationTitle(artist.map { Text($0) } ?? Text("Albums"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { model.settings.albumsLayout = coverFlow ? .grid : .coverFlow }
                } label: {
                    Image(systemName: coverFlow ? "square.grid.2x2" : "rectangle.stack")
                }
                .accessibilityLabel(coverFlow ? Text("Show as a Grid") : Text("Show as Cover Flow"))
            }
        }
        .navigationDestination(isPresented: Binding(get: { sample != nil }, set: { if !$0 { sample = nil } })) {
            if let sample { AlbumView(session: session, album: sample) }
        }
        .task(id: session.isConnected) {
            if albums.isEmpty { await loadMore() }
            if model.startScreen == "album", let first = albums.first { model.startScreen = nil; sample = first }
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: RemoteLayout.albumColumns(width: min(geometry.size.width, 1200), accessibilityText: typeSize.isAccessibilitySize)), spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink { AlbumView(session: session, album: album) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ArtworkView(key: album.artworkKey)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
                                Text(album.title).font(.serif(.subheadline, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(Palette.text2).lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .onAppear { if album.key == albums.last?.key { Task { await loadMore() } } }
                    }
                }
                .padding()
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
                if loading { ProgressView().padding() }
                if !loading, albums.isEmpty, total != nil {
                    Text("No albums yet").font(.serif(.title3)).foregroundStyle(Palette.text2).padding(.top, 60)
                }
            }
            .accessibilityIdentifier("albums-grid")
        }
    }

    private func loadMore() async {
        guard !loading else { return }
        if let artist {
            guard albums.isEmpty else { return }
            loading = true
            defer { loading = false }
            if case .albums(let items, _) = await session.send(.artistAlbums(name: artist)) { albums = items; total = items.count }
            return
        }
        if let total, albums.count >= total { return }
        loading = true
        defer { loading = false }
        if case .albums(let items, let all) = await session.send(.albums(offset: albums.count, limit: 120)) {
            albums += items
            total = all
        }
    }
}

struct AlbumView: View {
    let session: RemoteSession
    let album: AlbumSummary
    @State private var tracks: [TrackSummary] = []
    @State private var feedback = CommandFeedback()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    if sizeClass == .regular && !typeSize.isAccessibilitySize {
                        HStack(spacing: 28) {
                            ArtworkView(key: album.artworkKey, size: 800, cornerRadius: 10).frame(width: 240, height: 240)
                            albumInfo.frame(minWidth: 260, maxWidth: 520)
                        }
                    }
                    VStack(spacing: 16) {
                        ArtworkView(key: album.artworkKey, size: 800, cornerRadius: 10).frame(maxWidth: 280)
                        albumInfo
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            TrackRows(session: session, tracks: tracks, play: { .playAlbum(key: album.key, startAt: $0, shuffled: false) }, numbered: true)
        }
        .obsidianList()
        .navigationBarTitleDisplayMode(.inline)
        .feedback(feedback)
        .task(id: session.isConnected) { if tracks.isEmpty, case .tracks(let items) = await session.send(.albumTracks(key: album.key)) { tracks = items } }
    }

    private var albumInfo: some View {
        VStack(spacing: 10) {
            Text(album.title).font(.serif(.title3, weight: .semibold)).multilineTextAlignment(.center)
            Text(album.artist).foregroundStyle(Palette.text2)
            HStack(spacing: 6) {
                Chip(text: album.format, highlighted: album.hiRes || album.dsd)
                if let year = album.year { Chip(text: String(year)) }
            }
            HStack {
                Button { feedback.run(session, .playAlbum(key: album.key, startAt: 0, shuffled: false)) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { feedback.run(session, .playAlbum(key: album.key, startAt: 0, shuffled: true)) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!session.isConnected)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ArtistsList: View {
    let session: RemoteSession
    @State private var artists: [ArtistSummary] = []
    @State private var filter = ""

    var body: some View {
        List(artists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { artist in
            NavigationLink { AlbumsGrid(session: session, artist: artist.name) } label: {
                HStack {
                    ArtworkView(key: artist.artworkKey, size: 120, cornerRadius: 22).frame(width: 44)
                    VStack(alignment: .leading) {
                        Text(artist.name)
                        Text("Albums: \(artist.albumCount)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .obsidianList()
        .searchable(text: $filter)
        .navigationTitle("Artists")
        .task(id: session.isConnected) { if case .artists(let items) = await session.send(.artists) { artists = items } }
    }
}

struct PlaylistsList: View {
    let session: RemoteSession
    @State private var playlists: [PlaylistSummary] = []

    var body: some View {
        List(playlists) { playlist in
            NavigationLink {
                TrackListView(session: session, title: Text(playlist.name), load: .playlistTracks(id: playlist.id),
                              play: { _ in .playPlaylist(id: playlist.id, shuffled: false) })
            } label: {
                Label(playlist.name, systemImage: playlist.smart ? "gearshape" : "music.note.list")
            }
        }
        .obsidianList()
        .navigationTitle("Playlists")
        .task(id: session.isConnected) { if case .playlists(let items) = await session.send(.playlists) { playlists = items } }
    }
}

/// A list of songs loaded with one command.
struct TrackListView: View {
    let session: RemoteSession
    let title: Text
    let load: RemoteCommand
    /// How to play from a row (nil: play these songs from that row).
    let play: ((Int) -> RemoteCommand)?
    @State private var tracks: [TrackSummary] = []

    var body: some View {
        List {
            TrackRows(session: session, tracks: tracks, play: play ?? { index in .playTracks(ids: tracks.compactMap(\.id), startAt: index, shuffled: nil) })
        }
        .obsidianList()
        .navigationTitle(title)
        .task(id: session.isConnected) { if case .tracks(let items) = await session.send(load) { tracks = items } }
    }
}

/// Song rows: tap plays from that song; the menu adds to the queue or favorites.
struct TrackRows: View {
    let session: RemoteSession
    let tracks: [TrackSummary]
    let play: (Int) -> RemoteCommand
    var numbered = false
    @State private var feedback = CommandFeedback()

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
            Button { feedback.run(session, play(index)) } label: {
                HStack(spacing: 12) {
                    if numbered {
                        Text(track.trackNumber.map(String.init) ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    } else {
                        ArtworkView(key: track.artworkKey, size: 120, cornerRadius: 4).frame(width: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text(numbered ? track.format : "\(track.artist) — \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if track.favorite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.secondary) }
                    Text(formatTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let id = track.id {
                    Button { feedback.run(session, .playNext(ids: [id])) } label: { Label("Play Next", systemImage: "text.insert") }
                    Button { feedback.run(session, .addToQueue(ids: [id])) } label: { Label("Add to Queue", systemImage: "text.append") }
                    Button { feedback.run(session, .setFavorite(ids: [id], on: !track.favorite)) } label: {
                        Label(track.favorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"), systemImage: track.favorite ? "heart.slash" : "heart")
                    }
                }
            }
        }
        .feedback(feedback)
    }
}
