//
// Vespertine Remote: the Mac's library as its sidebar lists it: albums, artists, songs, genres, recently added,
// favorites, playlists and sources, and search.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol

struct LibraryView: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    var section: RemoteDestination? = nil
    @State private var search = ""
    @State private var path: [String] = []
    /// The library's counts and sources (nil until the Mac answers, and from a Mac too old to say).
    @State private var overview: LibraryOverview?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let section {
                    sectionContent(section)
                } else if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    root
                } else {
                    SearchPage(session: session, text: search)
                }
            }
            .obsidianList()
            .navigationTitle(section?.title ?? String(localized: "Library"))
            .searchable(text: $search, prompt: Text("Songs, artists, albums"))
            .navigationDestination(for: String.self) { place in
                switch place {
                case "artists": ArtistsList(session: session)
                case "songs": SongsList(session: session)
                case "genres": GenresGrid(session: session)
                case "recentlyAdded": AlbumsGrid(session: session, listing: .recentlyAdded)
                case "playlists": PlaylistsList(session: session)
                case "kept": KeptListsView(session: session)
                case "favorites": TrackListView(session: session, title: Text("Favorites"), load: .favorites, play: nil)
                default: AlbumsGrid(session: session)
                }
            }
            .navigationDestination(for: SourceSummary.self) { SourcePage(session: session, source: $0) }
            .task(id: session.isConnected) {
                if case .library(let loaded) = await session.send(.library) { overview = loaded }
            }
            .onAppear {
                #if DEBUG
                if model.startScreen == "search" { search = "Harbor"; model.startScreen = nil }
                #endif
                guard section == nil else { return }
                switch model.startScreen {
                case "albums", "coverFlow", "album": path = ["albums"]; if model.startScreen != "album" { model.startScreen = nil }
                case "artists", "songs", "genres", "recentlyAdded", "playlists", "favorites", "kept":
                    if let screen = model.startScreen { path = [screen] }
                    model.startScreen = nil
                default: break
                }
            }
        }
    }

    /// The Mac's sidebar as a list: its Library pages in its order, with its counts, then the playlists and the sources.
    private var root: some View {
        List {
            Section {
                rootLink("albums", .library, count: overview?.albums)
                rootLink("artists", .artists, count: overview?.artists)
                rootLink("songs", .songs, count: overview?.songs)
                rootLink("genres", .genres, count: overview?.genres)
                rootLink("recentlyAdded", .recentlyAdded)
                rootLink("favorites", .favorites, count: overview?.favorites)
                rootLink("playlists", .playlists, count: overview?.playlists)
            }
            if !session.isDemo {
                Section { rootLink("kept", .kept, count: KeptShelf.shared.keeper(for: session)?.store.lists.count) }
            }
            if let sources = overview?.sources, !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources) { source in
                        NavigationLink(value: source) { SourceLabel(source: source) }
                    }
                }
            }
        }
        .accessibilityIdentifier("library-root")
    }

    private func rootLink(_ place: String, _ destination: RemoteDestination, count: Int? = nil) -> some View {
        NavigationLink(value: place) { CountedLabel(title: destination.title, symbol: destination.symbol, count: count) }
            .accessibilityIdentifier("library-" + destination.id)
    }

    @ViewBuilder private func sectionContent(_ place: RemoteDestination) -> some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchPage(session: session, text: search)
        } else {
            switch place {
            case .artists: ArtistsList(session: session).readablePane()
            case .songs: SongsList(session: session).readablePane()
            case .genres: GenresGrid(session: session)
            case .recentlyAdded: AlbumsGrid(session: session, listing: .recentlyAdded)
            case .playlists: PlaylistsList(session: session).readablePane()
            case .kept: KeptListsView(session: session).readablePane()
            case .favorites: TrackListView(session: session, title: Text("Favorites"), load: .favorites, play: nil).readablePane()
            case .source(let id):
                if let source = overview?.sources.first(where: { $0.id == id }) {
                    SourcePage(session: session, source: source)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            default: AlbumsGrid(session: session)
            }
        }
    }
}

/// What the Mac found, in the groups its own search shows: artists, albums, playlists, then songs.
private struct SearchPage: View {
    let session: RemoteSession
    let text: String
    @State private var found = SearchResults(tracks: [], albums: [], artists: [], playlists: [])
    @State private var searched = false

    var body: some View {
        List {
            if !found.artists.isEmpty {
                Section("Artists") {
                    ForEach(found.artists) { artist in
                        NavigationLink { AlbumsGrid(session: session, listing: .artist(artist.name)) } label: {
                            HStack {
                                ArtworkView(key: artist.artworkKey, size: 120, cornerRadius: 22).frame(width: 44)
                                Text(artist.name)
                            }
                        }
                    }
                }
            }
            if !found.albums.isEmpty {
                Section("Albums") {
                    ForEach(found.albums) { album in
                        NavigationLink { AlbumView(session: session, album: album) } label: {
                            HStack {
                                ArtworkView(key: album.artworkKey, size: 120, cornerRadius: 4).frame(width: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).lineLimit(1)
                                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            if !found.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(found.playlists) { playlist in
                        NavigationLink {
                            TrackListView(session: session, title: Text(playlist.name), load: .playlistTracks(id: playlist.id),
                                          play: { _ in .playPlaylist(id: playlist.id, shuffled: false) })
                        } label: {
                            Label(playlist.name, systemImage: playlist.smart ? "gearshape" : "music.note.list")
                        }
                    }
                }
            }
            if !found.tracks.isEmpty {
                Section("Songs") {
                    TrackRows(session: session, tracks: found.tracks, play: { index in .playTracks(ids: found.tracks.compactMap(\.id), startAt: index, shuffled: nil) })
                }
            }
            if searched, found.tracks.isEmpty, found.albums.isEmpty, found.artists.isEmpty, found.playlists.isEmpty {
                Text("Nothing found for “\(text)”").foregroundStyle(Palette.text2)
            }
        }
        .obsidianList()
        .accessibilityIdentifier("search-results")
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            switch await session.send(.find(text: text, limit: 50)) {
            case .found(let results): found = results
            default:
                // An older Mac only knows the search for songs.
                if case .tracks(let items) = await session.send(.search(text: text, limit: 200)) {
                    found = SearchResults(tracks: items, albums: [], artists: [], playlists: [])
                }
            }
            searched = true
        }
    }
}

struct AlbumsGrid: View {
    /// What the grid lists.
    enum Listing: Hashable {
        /// Every album, a page at a time.
        case all
        case artist(String)
        case genre(key: String, name: String)
        /// The newest albums first, as many as the Mac's own page shows.
        case recentlyAdded
        case source(id: Int64, name: String)

        var title: Text {
            switch self {
            case .all: Text("Albums")
            case .artist(let name), .genre(_, let name), .source(_, let name): Text(name)
            case .recentlyAdded: Text("Recently Added")
            }
        }

        /// The command that lists it whole (nil for the paged list of every album).
        var command: RemoteCommand? {
            switch self {
            case .all: nil
            case .artist(let name): .artistAlbums(name: name)
            case .genre(let key, _): .genreAlbums(key: key)
            case .recentlyAdded: .recentlyAdded(limit: 150)
            case .source(let id, _): .sourceAlbums(id: id)
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    @State private var albums: [AlbumSummary] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var sample: AlbumSummary?
    /// Why the list couldn't be loaded, in the Mac's words (an older Mac doesn't know the newer pages).
    @State private var problem: String?
    @State private var feedback = CommandFeedback()
    var listing: Listing = .all
    /// How the page of every album is ordered and narrowed. The Mac does it; kept between launches.
    @AppStorage("albumSort") private var sortName = AlbumSort.library.rawValue
    @AppStorage("albumFilter") private var filterName = AlbumFilter.all.rawValue
    private var sort: AlbumSort { AlbumSort(rawValue: sortName) ?? .library }
    private var filter: AlbumFilter { AlbumFilter(rawValue: filterName) ?? .all }
    /// Only a Mac that knows how (the version that streams) is asked to sort and narrow.
    private var arranges: Bool { listing == .all && session.canStream }

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
        .navigationTitle(listing.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // A page of chosen albums plays as the Mac's Play and Shuffle buttons on that page do.
                if listing != .all {
                    Menu {
                        Button { feedback.run(session, .playAlbums(keys: albums.map(\.key), shuffled: false)) } label: { Label("Play", systemImage: "play.fill") }
                        Button { feedback.run(session, .playAlbums(keys: albums.map(\.key), shuffled: true)) } label: { Label("Shuffle", systemImage: "shuffle") }
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .accessibilityLabel(Text("Play These Albums"))
                    .disabled(albums.isEmpty || !session.isConnected)
                }
                if arranges {
                    Menu {
                        Picker("Sort By", selection: $sortName) {
                            Text("The Mac’s Order").tag(AlbumSort.library.rawValue)
                            Text("Title").tag(AlbumSort.title.rawValue)
                            Text("Artist").tag(AlbumSort.artist.rawValue)
                            Text("Newest First").tag(AlbumSort.newest.rawValue)
                            Text("Oldest First").tag(AlbumSort.oldest.rawValue)
                        }
                        Picker("Show", selection: $filterName) {
                            Text("All Albums").tag(AlbumFilter.all.rawValue)
                            Text("Hi-Res").tag(AlbumFilter.hiRes.rawValue)
                            Text("DSD").tag(AlbumFilter.dsd.rawValue)
                            Text("Surround").tag(AlbumFilter.surround.rawValue)
                        }
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel(Text("Sort and Filter"))
                }
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
        .feedback(feedback)
        .onChange(of: sortName + "/" + filterName) {
            albums = []
            total = nil
            Task { await loadMore() }
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
                    Text(arranges && filter != .all ? "No albums match" : "No albums yet").font(.serif(.title3)).foregroundStyle(Palette.text2).padding(.top, 60)
                }
                if !loading, albums.isEmpty, let problem {
                    Text(problem).font(.callout).foregroundStyle(Palette.text2).multilineTextAlignment(.center).padding(.top, 60).padding(.horizontal, 32)
                }
            }
            .accessibilityIdentifier("albums-grid")
        }
    }

    private func loadMore() async {
        guard !loading else { return }
        if let command = listing.command {
            guard albums.isEmpty else { return }
            loading = true
            defer { loading = false }
            switch await session.send(command) {
            case .albums(let items, _): albums = items; total = items.count; problem = nil
            case .failed(let reason): problem = reason.isEmpty ? nil : reason
            default: break
            }
            return
        }
        if let total, albums.count >= total { return }
        loading = true
        defer { loading = false }
        let asked = (sortName, filterName)
        let command: RemoteCommand = arranges ? .albums(offset: albums.count, limit: 120, sort: sort, filter: filter) : .albums(offset: albums.count, limit: 120)
        if case .albums(let items, let all) = await session.send(command), asked == (sortName, filterName) {
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
                        HStack(alignment: .bottom, spacing: 28) {
                            ArtworkView(key: album.artworkKey, size: 800, cornerRadius: 10).frame(width: 240, height: 240)
                            albumInfo(leading: true).frame(minWidth: 260, maxWidth: 420)
                            Spacer(minLength: 0)
                        }
                    }
                    VStack(spacing: 16) {
                        ArtworkView(key: album.artworkKey, size: 800, cornerRadius: 10).frame(maxWidth: 280)
                        albumInfo(leading: false)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            TrackRows(session: session, tracks: tracks, play: { .playAlbum(key: album.key, startAt: $0, shuffled: false) }, numbered: true)
        }
        .obsidianList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                KeepButton(session: session, id: KeptList.albumID(album.key)) {
                    tracks.isEmpty ? nil : KeptList(id: KeptList.albumID(album.key), kind: .album, reference: album.key, title: album.title, subtitle: album.artist,
                                                    artworkKey: album.artworkKey, tracks: tracks, smaller: KeptShelf.shared.smaller)
                }
            }
        }
        .feedback(feedback)
        .task(id: session.isConnected) { if tracks.isEmpty, case .tracks(let items) = await session.send(.albumTracks(key: album.key)) { tracks = items } }
    }

    private func albumInfo(leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .center, spacing: 10) {
            Text(album.title).font(.serif(leading ? .title2 : .title3, weight: .semibold)).multilineTextAlignment(leading ? .leading : .center)
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
            NavigationLink { AlbumsGrid(session: session, listing: .artist(artist.name)) } label: {
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
        .navigationTitle("Artists").screenTitleStyle()
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
                              play: { _ in .playPlaylist(id: playlist.id, shuffled: false) },
                              keep: { tracks in
                                  KeptList(id: KeptList.playlistID(playlist.id), kind: .playlist, reference: String(playlist.id), title: playlist.name, subtitle: "",
                                           artworkKey: tracks.first?.artworkKey, tracks: tracks, smaller: KeptShelf.shared.smaller)
                              }, keepID: KeptList.playlistID(playlist.id))
            } label: {
                Label(playlist.name, systemImage: playlist.smart ? "gearshape" : "music.note.list")
            }
        }
        .obsidianList()
        .navigationTitle("Playlists").screenTitleStyle()
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
    /// For a list that can be kept on this device (a playlist): makes the kept list from its songs.
    var keep: (([TrackSummary]) -> KeptList)? = nil
    var keepID: String? = nil
    @State private var tracks: [TrackSummary] = []

    var body: some View {
        List {
            TrackRows(session: session, tracks: tracks, play: play ?? { index in .playTracks(ids: tracks.compactMap(\.id), startAt: index, shuffled: nil) })
        }
        .obsidianList()
        .navigationTitle(title).screenTitleStyle()
        .toolbar {
            if let keep, let keepID {
                ToolbarItem(placement: .topBarTrailing) { KeepButton(session: session, id: keepID) { tracks.isEmpty ? nil : keep(tracks) } }
            }
        }
        .task(id: session.isConnected) { if case .tracks(let items) = await session.send(load) { tracks = items } }
    }
}

/// Song rows: tap plays from that song; the menu adds to the queue or favorites. A song the library has in several
/// copies says how many, as on the Mac, and opens the list of them.
struct TrackRows: View {
    let session: RemoteSession
    let tracks: [TrackSummary]
    let play: (Int) -> RemoteCommand
    var numbered = false
    @State private var feedback = CommandFeedback()
    /// The song being added to a playlist.
    @State private var adding: PlaylistAddition?

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
            HStack(spacing: 10) {
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
                if let copies = track.copies, copies.count > 1 {
                    SongCopiesButton(session: session, track: track, list: tracks, index: index)
                }
            }
            .contextMenu {
                if let id = track.id {
                    Button { feedback.run(session, .playNext(ids: [id])) } label: { Label("Play Next", systemImage: "text.insert") }
                    Button { feedback.run(session, .addToQueue(ids: [id])) } label: { Label("Add to Queue", systemImage: "text.append") }
                    Button { feedback.run(session, .setFavorite(ids: [id], on: !track.favorite)) } label: {
                        Label(track.favorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"), systemImage: track.favorite ? "heart.slash" : "heart")
                    }
                    Button { adding = PlaylistAddition(id: id, title: track.title) } label: { Label("Add to a Playlist…", systemImage: "text.badge.plus") }
                }
            }
        }
        .feedback(feedback)
        .sheet(item: $adding) { AddToPlaylistSheet(session: session, addition: $0) }
    }
}

/// A song on its way into a playlist.
struct PlaylistAddition: Identifiable {
    let id: Int64
    let title: String
}

/// Adds a song to one of the Mac's playlists, or to a new one.
struct AddToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession
    let addition: PlaylistAddition
    @State private var playlists: [PlaylistSummary] = []
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("New Playlist", text: $name)
                    Button("Create and Add") {
                        answer(.createPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines), ids: [addition.id]))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                // A smart playlist chooses its own songs.
                let own = playlists.filter { !$0.smart }
                if !own.isEmpty {
                    Section("Playlists") {
                        ForEach(own) { playlist in
                            Button { answer(.addToPlaylist(id: playlist.id, ids: [addition.id])) } label: {
                                Label(playlist.name, systemImage: "music.note.list").foregroundStyle(Palette.text)
                            }
                        }
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .obsidianList()
            .navigationTitle(Text("Add “\(addition.title)”"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { if case .playlists(let items) = await session.send(.playlists) { playlists = items } }
        }
        .presentationDetents([.medium, .large])
    }

    private func answer(_ command: RemoteCommand) {
        Task {
            switch await session.send(command) {
            case .failed(let reason): problem = reason.isEmpty ? String(localized: "The Mac didn’t answer.") : reason
            default: dismiss()
            }
        }
    }
}
