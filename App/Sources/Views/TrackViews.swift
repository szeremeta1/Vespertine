//
// Vespertine — track tables: album tracklists, songs, playlists, search.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

struct TrackRow: Identifiable, Hashable {
    let track: Track
    let index: Int
    var id: Int64 { Int64(index) }
}

struct TrackTable: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var showAlbum = true
    var showArtist = true
    var reorderable: Playlist? = nil
    /// Songs that also exist in another version on the album: track ID → "+ STEREO", "+ 5.1".
    var otherVersions: [Int64: String] = [:]
    /// A filtered playlist: each row's place in the whole playlist, and the whole (so edits keep what's hidden).
    var positions: [Int]? = nil
    var allTracks: [Track]? = nil

    @State private var selection = Set<Int64>()
    @State private var sortOrder: [KeyPathComparator<TrackRow>] = []

    private var rows: [TrackRow] {
        let base = tracks.enumerated().map { TrackRow(track: $1, index: positions?[$0] ?? $0) }
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    /// Album pages of multi-disc albums number tracks "2·1", "2·2"…, so disc 2 doesn't look like the list restarting.
    private var numbersDiscs: Bool { !showAlbum && Set(tracks.compactMap(\.discNumber)).count > 1 }

    private func number(_ track: Track, discs: Bool) -> String {
        guard let n = track.trackNumber else { return "–" }
        return discs ? "\(track.discNumber ?? 1)·\(n)" : "\(n)"
    }

    var body: some View {
        let rows = self.rows
        let discs = numbersDiscs
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            // Ideal widths add up to about 810 pt: what's left beside the sidebar and inspector in a 1440 pt window.
            TableColumn("#", value: \.index) { row in
                if model.player.current?.track.id == row.track.id, model.player.state != .stopped {
                    Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.brass)
                } else {
                    Text(showAlbum ? "\(row.index + 1)" : number(row.track, discs: discs))
                        .font(Typeface.mono(11.5))
                        .foregroundStyle(Palette.text3)
                }
            }
            .width(discs ? 44 : 36)

            TableColumn("Title", value: \.track.title) { row in
                Text(row.track.title)
                    .font(Typeface.ui(13))
                    .foregroundStyle(model.player.current?.track.id == row.track.id ? Palette.brassHi : Palette.text)
                    .opacity(row.track.isMissing ? 0.45 : 1)
            }
            .width(min: 160, ideal: 240)

            if showArtist {
                TableColumn("Artist", value: \.track.displayArtist) { row in
                    Text(row.track.displayArtist).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
                .width(min: 100, ideal: 140)
            }
            if showAlbum {
                TableColumn("Album", value: \.track.displayAlbum) { row in
                    Text(row.track.displayAlbum).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
                .width(min: 100, ideal: 150)
            }

            TableColumn("Format", value: \.track.sampleRate) { row in
                HStack(spacing: 8) {
                    Text(row.track.formatSummary).font(Typeface.mono(11)).foregroundStyle(Palette.text2)
                        .lineLimit(1).fixedSize()
                    AnalysisTag(track: row.track).fixedSize()
                    if let other = row.track.id.flatMap({ otherVersions[$0] }) {
                        Text(other).font(Typeface.mono(8.5, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.text2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.hairlineStrong))
                            .fixedSize()
                            .help("This song is also on the album in another version; Vespertine plays the one that suits your output")
                    }
                }
            }
            .width(min: 150, ideal: 190)

            TableColumn(Text(Image(systemName: "heart")).foregroundStyle(Palette.text3)) { row in
                FavoriteCell(model: model, track: row.track,
                             emphasized: selection.contains(row.id) || model.player.current?.track.id == row.track.id)
            }
            .width(22)

            TableColumn("Time", value: \.track.duration) { row in
                Text(row.track.duration.clock).font(Typeface.mono(11.5)).foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Palette.window)
        .contextMenu(forSelectionType: Int64.self) { ids in
            let chosenRows = rows.filter { ids.contains($0.id) }
            let chosen = chosenRows.map(\.track)
            if !chosen.isEmpty { TrackMenu(tracks: chosen, playlist: reorderable, all: allTracks ?? tracks, positions: Set(chosenRows.map(\.index))) }
        } primaryAction: { ids in
            guard let first = ids.first, let index = rows.firstIndex(where: { $0.id == first }) else { return }
            model.player.play(rows.map(\.track), startAt: index)
        }
        .onAppear { selection = Set(rows.filter { model.selectedTrackIDs.contains($0.track.id ?? -1) }.map(\.id)) }
        .onChange(of: model.selectedTrackIDs) { _, new in
            let selectedTracks = Set(rows.filter { selection.contains($0.id) }.compactMap { $0.track.id })
            guard selectedTracks != new else { return }
            let visible = Set(rows.filter { new.contains($0.track.id ?? -1) }.map(\.id))
            if visible != selection { selection = visible }
        }
        .onChange(of: selection) { _, new in
            model.selectedTrackIDs = Set(rows.filter { new.contains($0.id) }.compactMap { $0.track.id })
            if !new.isEmpty, model.inspectorTab == .nowPlaying, model.player.current == nil { model.inspectorTab = .details }
        }
        .onKeyPress(.return) {
            guard let first = selection.first, let index = rows.firstIndex(where: { $0.id == first }) else { return .ignored }
            model.player.play(rows.map(\.track), startAt: index)
            return .handled
        }
    }
}

/// Shows the result of a file analysis inline, only when it's worth attention.
struct AnalysisTag: View {
    let track: Track
    var body: some View {
        switch track.analysisVerdict {
        case "paddedBitDepth":
            tag("\(track.effectiveBitDepth ?? 16)-BIT", color: Palette.copper).help("Only \(track.effectiveBitDepth ?? 16) of \(track.bitDepth ?? 24) bits carry audio (zero-padded)")
        case "upsampled":
            tag("UPSAMPLED?", color: Palette.copper).help("A steep cutoff far below this file’s limit, as a 44.1/48 kHz master upsampled to a hi-res rate shows. A steep mastering low-pass or a DSD conversion filter can look the same.")
        case "possibleLossyOrigin":
            tag("LOSSY ORIGIN?", color: Palette.copper).help("A steep, consistent cutoff, as MP3, AAC and Opus encodes show. Steep mastering or anti-alias filters, FM broadcast sources and historical remasters can look the same.")
        case "bandwidthExtended":
            tag("SYNTHETIC HF?", color: Palette.copper).help("A step at a lossy-looking cutoff with a flat shelf above it that follows the music, as SBR or AI “enhancement” leaves. An exciter or noise reduction on a band-limited recording can look similar.")
        case "genuine" where (track.bitDepth ?? 0) >= 24 && track.effectiveBitDepth == track.bitDepth:
            // Only when the word length was checked (float and 32-bit files aren't).
            tag("TRUE \(track.bitDepth ?? 24)", color: Palette.brass).help("No zero padding: all \(track.bitDepth ?? 24) bits are in use")
        default:
            EmptyView()
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typeface.mono(8.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.5)))
    }
}

struct TrackMenu: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var playlist: Playlist? = nil
    var all: [Track] = []
    var positions: Set<Int>? = nil

    var body: some View {
        Button("Play") { model.player.play(tracks, shuffled: false) }
        Button("Play Next") { model.player.playNext(tracks) }
        Button("Add to Queue") { model.player.addToQueue(tracks) }
        AddToPlaylistMenu(trackIDs: tracks.compactMap(\.id))
        Button(tracks.allSatisfy(model.library.isFavorite) ? "Remove from Favorites" : "Add to Favorites") {
            model.toggleFavorite(tracks)
        }
        Divider()
        Button("Get Info") {
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
            model.inspectorTab = .details
            model.showInspector = true
        }
        Button("Analyze Bit Depth & Spectrum") {
            model.selectedTrackIDs = Set(tracks.prefix(1).compactMap(\.id))
            model.inspectorTab = .analysis
            model.showInspector = true
        }
        Button("Look Up on MusicBrainz…") { model.lookupTracks = tracks }
        Button("Show in Finder") { model.showInFinder(tracks) }
        if let playlist, !playlist.isSmart {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                let remove = Set(tracks.compactMap(\.id))
                let remaining = all.enumerated().filter { index, track in
                    if let positions { return !positions.contains(index) }
                    return !remove.contains(track.id ?? -1)
                }.compactMap { $0.element.id }
                model.library.setPlaylistOrder(remaining, playlist: playlist)
            }
        }
    }
}

// MARK: - Songs / search / playlists

/// Songs with their filter facts, loaded together.
struct SongList {
    var tracks: [Track] = []
    var facts: [FilterFacts] = []

    init() {}
    @MainActor init(_ tracks: [Track], model: AppModel) {
        self.tracks = tracks
        facts = model.trackFacts(tracks)
    }
}

/// A page of songs with its filter bar: Songs, Favorites, a playlist.
struct SongsPage<Extra: View, Empty: View>: View {
    @Environment(AppModel.self) private var model
    let scope: FilterScope
    let title: String
    let list: SongList
    /// What the subtitle calls them ("tracks", "songs").
    var word = "track"
    var kicker = ""
    var playlist: Playlist? = nil
    @ViewBuilder var extra: Extra
    @ViewBuilder var empty: Empty

    var body: some View {
        let filter = model.filter(scope)
        let favorites = model.library.favoriteIDs
        let indices = filter.isEmpty || list.facts.count != list.tracks.count ? Array(list.tracks.indices)
            : list.tracks.indices.filter { filter.matches(list.facts[$0], favorite: favorites.contains(list.tracks[$0].id ?? -1)) }
        let shown = indices.map { list.tracks[$0] }
        VStack(spacing: 0) {
            PageHeader(title: title, meta: meta(shown, filtered: !filter.isEmpty)) {
                extra
                PlayShuffleButtons(disabled: shown.isEmpty) { shuffled in
                    model.player.play(shown, shuffled: shuffled, allowing: model.allowing(filter, perAlbum: false))
                }
            }
            if list.tracks.isEmpty {
                empty
            } else {
                FilterBar(scope: scope, items: .songs(list.tracks, facts: list.facts, model: model))
                    .padding(.bottom, 10)
                if shown.isEmpty {
                    NoMatchesView(unit: "song") { model.setFilter(LibraryFilter(), for: scope) }
                    Spacer(minLength: 0)
                } else {
                    // A filtered playlist keeps its own numbers, and edits through it keep the songs out of view.
                    let partial = !filter.isEmpty && playlist?.isSmart == false
                    TrackTable(tracks: shown, reorderable: playlist,
                               positions: partial ? indices : nil, allTracks: partial ? list.tracks : nil)
                }
            }
        }
        .background(Palette.window)
    }

    private func meta(_ shown: [Track], filtered: Bool) -> String {
        let n = shown.count
        let count = filtered ? "\(n.formatted()) of \(list.tracks.count.formatted()) \(word)s" : "\(n.formatted()) \(word)\(n == 1 ? "" : "s")"
        return "\(kicker)\(count) · \(shown.reduce(0) { $0 + $1.duration }.longDuration)"
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var model
    @State private var list = SongList()

    var body: some View {
        SongsPage(scope: .sidebar(.songs), title: "Songs", list: list) { EmptyView() } empty: { Spacer() }
            .task(id: model.library.revision) { list = SongList(model.library.allTracks(), model: model) }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var results = SongList()
    @State private var albums: [Album] = []
    @State private var artists: [LibraryDatabase.ArtistSummary] = []
    @State private var genres: [GenreSummary] = []
    private let scope = FilterScope.search

    var body: some View {
        let filter = model.filter(scope)
        let favorites = model.library.favoriteIDs
        let songs = filter.isEmpty || results.facts.count != results.tracks.count ? results.tracks
            : results.tracks.indices.filter { filter.matches(results.facts[$0], favorite: favorites.contains(results.tracks[$0].id ?? -1)) }.map { results.tracks[$0] }
        // Albums by their own facts; artists and genres when one of their albums passes.
        let albums = model.filtered(self.albums, by: filter)
        let artists = filter.isEmpty ? self.artists : {
            let keep = Set(model.artists(filter).map { $0.name.lowercased() })
            return self.artists.filter { keep.contains($0.name.lowercased()) }
        }()
        let genres = filter.isEmpty ? self.genres : {
            let keep = Set(model.genres(filter).map(\.key))
            return self.genres.filter { keep.contains($0.key) }
        }()
        let found = !(results.tracks.isEmpty && self.albums.isEmpty && self.artists.isEmpty && self.genres.isEmpty)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "\u{201C}\(query)\u{201D}", meta: meta(genres: genres.count, artists: artists.count, albums: albums.count, songs: songs.count)) {
                PlayShuffleButtons(disabled: songs.isEmpty) { shuffled in
                    model.player.play(songs, shuffled: shuffled, allowing: model.allowing(filter, perAlbum: false))
                }
            }
            if !found {
                Text("Nothing matches.").font(Typeface.ui(13)).foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FilterBar(scope: scope, items: .songs(results.tracks, facts: results.facts, model: model, alsoOffering: self.albums.map(\.facts)))
                    .padding(.bottom, 12)
                if songs.isEmpty && albums.isEmpty && artists.isEmpty && genres.isEmpty {
                    NoMatchesView(unit: "result") { model.setFilter(LibraryFilter(), for: scope) }
                    Spacer(minLength: 0)
                }
                if !genres.isEmpty {
                    shelf("Genres", count: genres.count) {
                        ForEach(genres) { GenreTile(genre: $0, filter: filter).frame(width: 120) }
                    }
                }
                if !artists.isEmpty {
                    shelf("Artists", count: artists.count) {
                        ForEach(artists) { ArtistTile(artist: $0, filter: filter).frame(width: 136) }
                    }
                }
                if !albums.isEmpty {
                    shelf("Albums", count: albums.count) {
                        ForEach(albums) { AlbumCard(album: $0).frame(width: 150) }
                    }
                }
                if !songs.isEmpty {
                    sectionTitle("Songs", count: songs.count).padding(.top, 6)
                    TrackTable(tracks: songs)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .background(Palette.window)
        .task(id: "\(query)#\(model.library.revision)") {
            try? await Task.sleep(for: .milliseconds(120))
            results = SongList(model.library.search(query), model: model)
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            func matches(_ text: String) -> Bool { words.allSatisfy { text.localizedStandardContains($0) } }
            func startsWith(_ text: String) -> Int { text.localizedStandardRange(of: query)?.lowerBound == text.startIndex ? 0 : 1 }
            // Albums match on title, artist, genre and year ("jazz", "1977", "miles 1959").
            self.albums = model.library.albums
                .filter { matches("\($0.title) \($0.artist) \(Genres.split($0.genre).joined(separator: " ")) \($0.year.map(String.init) ?? "")") }
                .sorted { (startsWith($0.title), $0.title) < (startsWith($1.title), $1.title) }
            self.genres = model.library.genres.filter { matches($0.name) || Genres.key($0.name).contains(Genres.key(query)) }
            self.artists = model.library.artists
                .filter { matches($0.name) }
                .sorted { (startsWith($0.name), -$0.trackCount) < (startsWith($1.name), -$1.trackCount) }
        }
    }

    private func meta(genres: Int, artists: Int, albums: Int, songs: Int) -> String {
        func n(_ c: Int, _ word: String) -> String { "\(c) \(word)\(c == 1 ? "" : "s")" }
        let parts: [String] = (genres == 0 ? [] : [n(genres, "genre")])
            + [n(artists, "artist"), n(albums, "album"), n(songs, "song")]
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Typeface.serif(18)).foregroundStyle(Palette.text)
            Text("\(count)").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private func shelf<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(title, count: count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) { content() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistID: Int64
    @State private var list = SongList()

    var body: some View {
        let playlist = model.library.playlists.first { $0.id == playlistID }
        Group {
            if let playlist {
                SongsPage(scope: .sidebar(.playlist(playlistID)), title: playlist.name, list: list,
                          kicker: playlist.isSmart ? "SMART · " : "", playlist: playlist) {
                    if playlist.isSmart {
                        Button("Edit Rules…") { model.smartEditorPlaylist = playlist }.buttonStyle(QuietButtonStyle())
                    }
                } empty: {
                    VStack(spacing: 8) {
                        Text(playlist.isSmart ? "No tracks match these rules yet." : "Drag albums or tracks here.")
                            .font(Typeface.serif(18)).foregroundStyle(Palette.text2)
                        Text(playlist.isSmart ? "Run an analysis or adjust the rules." : "You can also use “Add to Playlist” in any context menu.")
                            .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Palette.window)
        .task(id: "\(playlistID)#\(model.library.revision)#\(playlist?.smartRules.hashValue ?? 0)#\(favoritesKey(playlist))") {
            if let playlist { list = SongList(model.library.tracks(in: playlist), model: model) }
        }
    }

    /// Smart playlists with an "Is Favorite" rule follow favorites as they change.
    private func favoritesKey(_ playlist: Playlist?) -> Int {
        playlist?.smartRules?.rules.contains { $0.field == .isFavorite } == true ? model.library.favoriteIDs.hashValue : 0
    }
}
