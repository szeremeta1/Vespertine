//
// Vespertine: the sidebar's TIDAL pages (Search, My Mixes, New Releases, Downloads), the catalog's albums and lists, and the one
// banner that says TIDAL is offline. Built from the library's own pieces: page headers, shelves, album cards, the songs table.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import VespertineLibrary
import VespertineTidal

// MARK: - Search

/// TIDAL › Search: the main window's search field searches TIDAL here (UX amendment 4).
struct TidalSearchView: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var result: TidalSearchResult?
    @State private var failure: String?
    @State private var opened: TidalCollection?

    var body: some View {
        ZStack {
            content.opacity(opened == nil ? 1 : 0).allowsHitTesting(opened == nil)
            if let opened { TidalCollectionPage(collection: opened) { self.opened = nil } }
        }
        .background(Palette.window)
        .task(id: query) {
            opened = nil
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { result = nil; failure = nil; return }
            try? await Task.sleep(for: .milliseconds(400))   // typing on cancels this: only the last text is sent
            guard !Task.isCancelled, let catalog = model.tidal.catalog else { return }
            do {
                result = try await catalog.search(text)
                failure = nil
            } catch is CancellationError {
            } catch {
                model.tidal.note(error)
                failure = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 0) {
            if trimmed.isEmpty {
                PageHeader(title: String(localized: "Search TIDAL"), meta: String(localized: "Type in the search field")) { EmptyView() }
                Spacer(minLength: 0)
            } else if let result {
                let songs = model.tracks(forCatalog: result.tracks)
                PageHeader(title: String(localized: "\u{201C}\(trimmed)\u{201D}", comment: "TIDAL search results title: the search text in quotation marks"),
                           meta: TidalShelves.meta(result)) {
                    PlayShuffleButtons(disabled: songs.isEmpty) { shuffled in model.player.play(songs, shuffled: shuffled) }
                }
                if result.tracks.isEmpty && result.albums.isEmpty && result.artists.isEmpty && result.playlists.isEmpty {
                    TidalEmptyText(String(localized: "Nothing on TIDAL matches."))
                } else {
                    TidalShelves(albums: result.albums, playlists: result.playlists, artists: result.artists, open: { opened = $0 })
                    if !songs.isEmpty {
                        TidalSectionTitle(title: String(localized: "Songs"), count: songs.count).padding(.top, 6)
                        TrackTable(tracks: songs)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            } else {
                PageHeader(title: String(localized: "\u{201C}\(trimmed)\u{201D}"), meta: failure ?? String(localized: "Searching TIDAL…")) { EmptyView() }
                Spacer(minLength: 0)
            }
        }
    }
}

/// An album, playlist, mix or artist of the catalog, opened over the page it was found on.
enum TidalCollection: Hashable, Identifiable {
    case album(TidalAlbum)
    case playlist(TidalPlaylist)
    case mix(TidalMix)
    case artist(TidalArtist)

    var id: String {
        switch self {
        case .album(let album): "album:\(album.id)"
        case .playlist(let playlist): "playlist:\(playlist.uuid)"
        case .mix(let mix): "mix:\(mix.id)"
        case .artist(let artist): "artist:\(artist.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let album): album.title
        case .playlist(let playlist): playlist.title
        case .mix(let mix): mix.title
        case .artist(let artist): artist.name
        }
    }
}

/// The shelves of catalog albums, playlists and artists, as the library's search shows its own.
struct TidalShelves: View {
    let albums: [TidalAlbum]
    var playlists: [TidalPlaylist] = []
    var artists: [TidalArtist] = []
    let open: (TidalCollection) -> Void

    static func meta(_ result: TidalSearchResult) -> String {
        let parts: [String] = (result.artists.isEmpty ? [] : [String(localized: "\(result.artists.count) artists")])
            + (result.albums.isEmpty ? [] : [String(localized: "\(result.albums.count) albums")])
            + (result.playlists.isEmpty ? [] : [String(localized: "\(result.playlists.count) playlists")])
            + (result.tracks.isEmpty ? [] : [String(localized: "\(result.tracks.count) songs")])
        return parts.isEmpty ? String(localized: "\(0) songs") : parts.joined(separator: " · ")
    }

    var body: some View {
        if !artists.isEmpty {
            shelf(String(localized: "Artists"), count: artists.count) {
                ForEach(artists) { artist in
                    TidalCoverCard(title: artist.name, subtitle: nil, cover: artist.picture, round: true) { open(.artist(artist)) }
                        .frame(width: 136)
                }
            }
        }
        if !albums.isEmpty {
            shelf(String(localized: "Albums"), count: albums.count) {
                ForEach(albums) { album in TidalAlbumCard(album: album) { open(.album(album)) }.frame(width: 150) }
            }
        }
        if !playlists.isEmpty {
            shelf(String(localized: "Playlists"), count: playlists.count) {
                ForEach(playlists) { playlist in
                    TidalCoverCard(title: playlist.title, subtitle: String(localized: "\(playlist.numberOfTracks) songs"),
                                   cover: playlist.squareImage) { open(.playlist(playlist)) }
                        .frame(width: 150)
                        .contextMenu { TidalCollectionMenu(collection: .playlist(playlist)) }
                }
            }
        }
    }

    private func shelf<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TidalSectionTitle(title: title, count: count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) { content() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct TidalSectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Typeface.serif(18)).foregroundStyle(Palette.text)
            Text("\(count)").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }
}

struct TidalEmptyText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(Typeface.ui(13)).foregroundStyle(Palette.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A catalog album, drawn as the library's album card is.
struct TidalAlbumCard: View {
    @Environment(AppModel.self) private var model
    let album: TidalAlbum
    let open: () -> Void

    var body: some View {
        TidalCoverCard(title: album.title, subtitle: album.artist?.name ?? album.artists.first?.name, cover: album.cover,
                       format: Self.format(album), open: open)
            .contextMenu { TidalCollectionMenu(collection: .album(album)) }
    }

    /// What TIDAL lists for the album, as the library's format line reads ("HI-RES ≈").
    static func format(_ album: TidalAlbum) -> String? {
        let tags = album.mediaMetadata?.tags ?? []
        if tags.contains("HIRES_LOSSLESS") { return String(localized: "HI-RES ≈", comment: "A TIDAL album listed as hi-res, not confirmed by playing it") }
        if tags.contains("LOSSLESS") || album.audioQuality == "LOSSLESS" { return String(localized: "CD ≈", comment: "A TIDAL album listed as lossless 16/44.1") }
        return nil
    }
}

/// A cover with its title and subtitle under it, as the album grid shows the library's albums.
struct TidalCoverCard: View {
    let title: String
    let subtitle: String?
    let cover: String?
    var round = false
    var format: String? = nil
    let open: () -> Void

    var body: some View {
        VStack(alignment: round ? .center : .leading, spacing: 0) {
            ArtworkView(key: cover.map { "tidal:\($0)" }, size: 320, cornerRadius: round ? 68 : 6)
                .shadow(color: .black.opacity(0.45), radius: 13, y: 10)
            Text(verbatim: title)
                .font(Typeface.serif(14)).foregroundStyle(Palette.text).lineLimit(1)
                .padding(.top, 10)
            if let subtitle {
                Text(verbatim: subtitle).font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1).padding(.top, 2)
            }
            if let format {
                Text(verbatim: format).font(Typeface.mono(10)).foregroundStyle(Palette.text3).padding(.top, 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.return, .space]) { _ in open(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }
}

/// A catalog album, playlist, mix or artist: its songs in the songs table, under a header with Play, Add to Library and Download.
struct TidalCollectionPage: View {
    @Environment(AppModel.self) private var model
    let collection: TidalCollection
    let close: () -> Void
    @State private var tracks: [TidalTrack]?
    @State private var albums: [TidalAlbum] = []
    @State private var failure: String?
    @State private var opened: TidalCollection?

    var body: some View {
        ZStack {
            page.opacity(opened == nil ? 1 : 0).allowsHitTesting(opened == nil)
            if let opened { TidalCollectionPage(collection: opened) { self.opened = nil } }
        }
        .background(Palette.window)
        .task(id: collection) { await load() }
    }

    @ViewBuilder private var page: some View {
        let songs = model.tracks(forCatalog: tracks ?? [])
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: close) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(QuietButtonStyle(compact: true))
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 14)
            PageHeader(title: collection.title, meta: failure ?? (tracks == nil ? String(localized: "Loading…") : String(localized: "\(songs.count) songs"))) {
                HStack(spacing: 8) {
                    if case .artist = collection {} else {
                        TidalCollectionButtons(collection: collection, tracks: tracks ?? [])
                    }
                    PlayShuffleButtons(disabled: songs.isEmpty) { shuffled in model.player.play(songs, shuffled: shuffled) }
                }
            }
            if !albums.isEmpty { TidalShelves(albums: albums, open: { opened = $0 }) }
            if !songs.isEmpty {
                TrackTable(tracks: songs, showAlbum: !isAlbum)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var isAlbum: Bool { if case .album = collection { true } else { false } }

    private func load() async {
        guard let catalog = model.tidal.catalog else { return }
        do {
            switch collection {
            case .album(let album): tracks = try await catalog.albumTracks(album.id)
            case .playlist(let playlist): tracks = try await catalog.playlistTracks(playlist.uuid)
            case .mix(let mix): tracks = try await catalog.mixTracks(mix.id)
            case .artist(let artist):
                albums = try await catalog.artistAlbums(artist.id)
                tracks = []
            }
            failure = nil
        } catch is CancellationError {
        } catch {
            model.tidal.note(error)
            failure = error.localizedDescription
        }
    }
}

/// "Add to Library" and "Download" for a whole album or playlist.
struct TidalCollectionButtons: View {
    @Environment(AppModel.self) private var model
    let collection: TidalCollection
    let tracks: [TidalTrack]

    var body: some View {
        Button("Add to Library") { add() }
            .buttonStyle(QuietButtonStyle(compact: true))
            .disabled(tracks.isEmpty || !model.tidal.state.isSignedIn)
        Button("Download") { download() }
            .buttonStyle(QuietButtonStyle(compact: true))
            .disabled(!model.tidal.state.isSignedIn)
    }

    private func add() {
        if case .album(let album) = collection { try? model.tidal.addToLibrary(tracks, album: album) } else { try? model.tidal.addToLibrary(tracks) }
    }

    private func download() {
        switch collection {
        case .album(let album): model.download(album: album.id)
        case .playlist(let playlist): model.download(playlist: playlist.uuid)
        default: model.download(tracks)
        }
    }
}

/// The context menu of a catalog album or playlist.
struct TidalCollectionMenu: View {
    @Environment(AppModel.self) private var model
    let collection: TidalCollection

    var body: some View {
        switch collection {
        case .album(let album):
            Button("Add to Library") { Task { await model.tidal.addToLibrary(album: album) } }
            Button("Download") { model.download(album: album.id) }
            Button("Show on TIDAL") { NSWorkspace.shared.open(URL(string: "https://tidal.com/browse/album/\(album.id)")!) }
        case .playlist(let playlist):
            Button("Download") { model.download(playlist: playlist.uuid) }
            Button("Show on TIDAL") { NSWorkspace.shared.open(URL(string: "https://tidal.com/browse/playlist/\(playlist.uuid)")!) }
        default:
            EmptyView()
        }
    }
}

/// The context menu of catalog songs that have no library row.
struct TidalCatalogTrackMenu: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let catalog = tracks.compactMap(model.catalogTrack(of:))
        let canPlay = tracks.contains { model.playability(of: $0).isPlayable }
        Button("Play") { model.player.play(tracks, shuffled: false) }.disabled(!canPlay)
        Button("Play Next") { model.player.playNext(tracks) }.disabled(!canPlay)
        Button("Add to Queue") { model.player.addToQueue(tracks) }.disabled(!canPlay)
        Divider()
        Button("Add to Library") { try? model.tidal.addToLibrary(catalog) }.disabled(catalog.isEmpty || !model.tidal.state.isSignedIn)
        Button("Download") { model.download(catalog) }.disabled(catalog.isEmpty || !model.tidal.state.isSignedIn)
        if let first = catalog.first {
            Button("Show on TIDAL") { NSWorkspace.shared.open(URL(string: "https://tidal.com/browse/track/\(first.id)")!) }
        }
    }
}

// MARK: - Mixes and new releases

struct TidalMixesView: View {
    @Environment(AppModel.self) private var model
    @State private var mixes: [TidalMix]?
    @State private var failure: String?
    @State private var opened: TidalCollection?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: String(localized: "My Mixes"), meta: failure ?? mixes.map { String(localized: "\($0.count) mixes") } ?? String(localized: "Loading…")) { EmptyView() }
                if let mixes, !mixes.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)], spacing: 28) {
                            ForEach(mixes) { mix in
                                TidalCoverCard(title: mix.title, subtitle: mix.subTitle, cover: nil) { opened = .mix(mix) }
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 24)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .opacity(opened == nil ? 1 : 0).allowsHitTesting(opened == nil)
            if let opened { TidalCollectionPage(collection: opened) { self.opened = nil } }
        }
        .background(Palette.window)
        .task {
            guard let catalog = model.tidal.catalog, let userId = model.tidal.userId else { return }
            do { mixes = try await catalog.mixes(userId: userId) } catch { model.tidal.note(error); failure = error.localizedDescription }
        }
    }
}

struct TidalNewReleasesView: View {
    @Environment(AppModel.self) private var model
    @State private var albums: [TidalAlbum]?
    @State private var failure: String?
    @State private var opened: TidalCollection?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: String(localized: "New Releases"),
                           meta: failure ?? albums.map { String(localized: "\($0.count) albums by artists you follow") } ?? String(localized: "Loading…")) { EmptyView() }
                if let albums, !albums.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)], spacing: 28) {
                            ForEach(albums) { album in TidalAlbumCard(album: album) { opened = .album(album) } }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 24)
                    }
                } else if albums != nil {
                    TidalEmptyText(String(localized: "Nothing new from the artists you follow on TIDAL in the last six months."))
                } else {
                    Spacer(minLength: 0)
                }
            }
            .opacity(opened == nil ? 1 : 0).allowsHitTesting(opened == nil)
            if let opened { TidalCollectionPage(collection: opened) { self.opened = nil } }
        }
        .background(Palette.window)
        .task {
            guard let catalog = model.tidal.catalog, let userId = model.tidal.userId else { return }
            do { albums = try await catalog.newReleases(userId: userId) } catch { model.tidal.note(error); failure = error.localizedDescription }
        }
    }
}

// MARK: - Downloads

struct TidalDownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.tidal.downloader?.items ?? []
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: String(localized: "Downloads"), meta: TidalDownloadProgress(items: items).summary) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.settings.tidalDownloadsFolder)])
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }
            if items.isEmpty {
                TidalEmptyText(String(localized: "Downloaded songs are kept in your downloads folder and play offline. Choose Download on a TIDAL song, album or playlist."))
            } else {
                List {
                    ForEach(items) { item in TidalDownloadRow(item: item) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.window)
    }
}

struct TidalDownloadRow: View {
    @Environment(AppModel.self) private var model
    let item: TidalDownloader.Item

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(Typeface.ui(13)).foregroundStyle(Palette.text).lineLimit(1)
                Text(verbatim: subtitle).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).lineLimit(1)
            }
            Spacer()
            switch item.state {
            case .queued:
                Text("WAITING").font(Typeface.mono(9, weight: .semibold)).foregroundStyle(Palette.text3)
            case .downloading(let fraction):
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Palette.brass).frame(width: 120)
            case .paused(let reason):
                Image(systemName: "clock").foregroundStyle(Palette.text3).help(reason)
                Text(verbatim: reason).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).lineLimit(1)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.copper)
                Text(verbatim: reason).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).lineLimit(1).help(reason)
            case .done(let url):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
            switch item.state {
            case .queued, .downloading, .paused, .failed:
                Button { model.tidal.downloader?.cancel(item: item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.text3)
                    .help("Remove from Downloads")
            case .done:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    private var title: String {
        switch item.kind {
        case .track(let track): track.title
        case .album(let id): item.album?.title ?? String(localized: "Album \(id)")
        case .playlist: String(localized: "Playlist")
        }
    }

    private var subtitle: String {
        switch item.kind {
        case .track(let track): [track.artists.first?.name, item.album?.title ?? track.album.title].compactMap { $0 }.joined(separator: " · ")
        case .album: String(localized: "Reading the album’s songs")
        case .playlist: String(localized: "Reading the playlist’s songs")
        }
    }
}

/// What the downloads queue is doing, for its page and the sidebar's ring.
struct TidalDownloadProgress {
    let items: [TidalDownloader.Item]

    /// Songs still to download (waiting, downloading or paused).
    var remaining: Int {
        items.filter { switch $0.state { case .queued, .downloading, .paused: true; default: false } }.count
    }

    /// How far the run is: finished songs, plus the part of the one downloading, over all that aren't failed.
    var fraction: Double {
        let counted = items.filter { if case .failed = $0.state { false } else { true } }
        guard !counted.isEmpty else { return 0 }
        let done = counted.reduce(0.0) { sum, item in
            switch item.state {
            case .done: sum + 1
            case .downloading(let part): sum + part
            default: sum
            }
        }
        return done / Double(counted.count)
    }

    /// The backoff reason when the queue waits on one.
    var pausedReason: String? {
        items.lazy.compactMap { if case .paused(let reason) = $0.state { reason } else { nil } }.first
    }

    var summary: String {
        let failed = items.filter { if case .failed = $0.state { true } else { false } }.count
        let parts = [remaining > 0 ? String(localized: "\(remaining) to download") : nil,
                     failed > 0 ? String(localized: "\(failed) failed") : nil].compactMap { $0 }
        if items.isEmpty { return String(localized: "Nothing downloaded in this session", comment: "TIDAL Downloads page with an empty queue") }
        return parts.isEmpty ? String(localized: "\(items.count) downloaded") : parts.joined(separator: " · ")
    }
}

/// The sidebar's Downloads row: a ring and the songs left while the queue runs, a clock while it waits on TIDAL (UX amendment 6).
struct TidalDownloadsBadge: View {
    let progress: TidalDownloadProgress

    var body: some View {
        if let reason = progress.pausedReason {
            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Palette.text3).help(reason)
        } else if progress.remaining > 0 {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Palette.hairlineStrong, lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.02, progress.fraction)).stroke(Palette.brass, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                Text(progress.remaining.formatted()).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(progress.remaining) to download"))
        }
    }
}

// MARK: - Offline banner

/// One slim line over lists that hold TIDAL songs while TIDAL can't stream (UX amendment 3): what still works, why, and what to do.
struct TidalOfflineBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.settings.tidalEnabled, model.library.tidalSource != nil, let reason = model.tidalAvailability.accountReason {
            HStack(spacing: 10) {
                TidalGlyph().foregroundStyle(Palette.text3)
                Text("TIDAL is offline. Downloaded tracks still play.").font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                Text(verbatim: reason).font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                Spacer(minLength: 8)
                if !model.tidal.state.isSignedIn {
                    Button("Sign In…") {
                        model.settingsTab = .tidal
                        model.tidal.wantsLoginSheet = true
                        openSettings()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                } else if model.tidal.backoff == nil {
                    Button("Retry") { Task { await model.tidal.refresh() } }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 7)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }
}
