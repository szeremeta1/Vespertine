//
// Vespertine: album grid, album detail, artists.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineAudio
import VespertineLibrary
import SwiftUI

// MARK: - Shared header

struct PageHeader<Trailing: View>: View {
    let title: String
    let meta: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Side by side when it fits; in a narrow window the controls drop below the title instead of squeezing
        // words onto two lines ("Albu / ms", "Pl / ay"). Stacked, a long title truncates.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                heading.fixedSize()
                Spacer(minLength: 14)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                heading
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typeface.serif(26, weight: .medium)).foregroundStyle(Palette.text)
            Text(meta).font(Typeface.mono(11)).foregroundStyle(Palette.text3)
        }
        .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 14) { trailing }.fixedSize()
    }
}

// MARK: - Album grid

/// A grid of albums with its filter bar: Albums, Recently Added, a source, an artist, a genre.
struct AlbumsGridView: View {
    @Environment(AppModel.self) private var model
    let scope: FilterScope
    var title = String(localized: "Albums")
    /// The Albums page: a sort order, and the library's size in the subtitle.
    var isLibrary = false

    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 22, alignment: .top)]

    var body: some View {
        @Bindable var library = model.library
        let base = model.baseAlbums(scope)
        let filter = model.filter(scope)
        let albums = model.filtered(base, by: filter)
        let families = AlbumFamilies.visibleGroups(albums, among: model.library.albums)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: title, meta: meta(families, base: base, filter: filter)) {
                    if isLibrary {
                        Picker("Sort", selection: $library.albumSort) {
                            Text("Artist").tag(AlbumSort.artist)
                            Text("Title").tag(AlbumSort.title)
                            Text("Year").tag(AlbumSort.year)
                            Text("Added").tag(AlbumSort.recentlyAdded)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    PlayShuffleButtons(disabled: families.isEmpty) { model.play(scope, shuffled: $0) }
                }
                FilterBar(scope: scope, items: .albums(base, model: model))
                    .padding(.bottom, 6)
                if albums.isEmpty && !base.isEmpty {
                    NoMatchesView(title: "No albums match these filters") { model.setFilter(LibraryFilter(), for: scope) }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(families) { family in
                            if family.editions.count > 1 {
                                AlbumFamilyCard(family: family)
                            } else {
                                AlbumCard(album: family.representative)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.window)
    }

    private func meta(_ families: [AlbumFamily], base: [Album], filter: LibraryFilter) -> String {
        let count = families.count
        if !filter.isEmpty { return String(localized: "\(count) of \(AlbumFamilies.group(base).count) albums") }
        guard isLibrary else { return String(localized: "\(count) albums") }
        let s = model.library.stats
        return [String(localized: "\(count) albums"), String(localized: "\(s.albums) editions"),
                String(localized: "\(s.tracks) tracks"), s.bytes.byteString].joined(separator: " · ")
    }
}

struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var hovering = false

    var isPlaying: Bool { model.player.current?.track.albumKey == album.key && model.player.state != .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(key: album.artworkKey, size: 600, cornerRadius: 6)
                    .shadow(color: .black.opacity(0.45), radius: 13, y: 10)
                    .overlay {
                        if isPlaying {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.brass, lineWidth: 1.5)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        // The library has this album more than once (a download and a vinyl transfer, stereo and 5.1).
                        if let n = model.library.copyCounts[album.key] { CopiesPill(count: n).padding(9) }
                    }
                if isPlaying {
                    PlayingBars(active: model.player.isPlaying)
                        .padding(8)
                } else if hovering {
                    Button {
                        model.player.play(model.playableTracks(albumKey: album.key), shuffled: false)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x1A140A))
                            .frame(width: 32, height: 32)
                            .background(Palette.brassGradient, in: Circle())
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.opacity)
                }
            }
            Text(album.title.libraryDisplayName)
                .font(Typeface.serif(14))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .padding(.top, 10)
            Text(album.artist.libraryDisplayName)
                .font(Typeface.ui(12))
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .padding(.top, 2)
            FormatLabel(summary: album.formatSummary, highlight: album.isHiRes)
                .padding(.top, 5)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture { model.openAlbum(album.key) }
        // Full Keyboard Access: Tab reaches the card, Return or Space opens it (it can't be a Button: it holds one).
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.return, .space]) { _ in model.openAlbum(album.key); return .handled }
        // VoiceOver (and other assistive tech) can open the album and play it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(album.title.libraryDisplayName), \(album.artist.libraryDisplayName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.openAlbum(album.key) }
        .accessibilityAction(named: "Play") { model.player.play(model.playableTracks(albumKey: album.key), shuffled: false) }
        .contextMenu { AlbumMenu(album: album) }
        .draggable(model.playableTracks(albumKey: album.key).compactMap(\.id).map(String.init).joined(separator: ","))
    }

    private var accessibilityValue: String {
        guard let copies = model.library.copyCounts[album.key] else { return album.formatSummary }
        return "\(album.formatSummary), \(String(localized: "\(copies) COPIES"))"
    }
}

/// "3 COPIES" on an album's artwork: the library has the album in that many folders, formats or layouts.
struct CopiesPill: View {
    let count: Int
    var body: some View {
        Text("\(count) COPIES")
            .font(Typeface.mono(9, weight: .semibold))
            .letterSpacing(0.5)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Palette.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.hairlineStrong))
            .accessibilityLabel(Text("\(count) COPIES"))
    }
}

/// One card for an album with several tagged releases. The artwork is from the edition that
/// matched this page (for example a DSD filter), and every edition is available inside.
struct AlbumFamilyCard: View {
    @Environment(AppModel.self) private var model
    let family: AlbumFamily

    private var isPlaying: Bool {
        guard let key = model.player.current?.track.albumKey, model.player.state != .stopped else { return false }
        return family.contains(key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(key: family.representative.artworkKey, size: 600, cornerRadius: 6)
                    .shadow(color: .black.opacity(0.45), radius: 13, y: 10)
                    .overlay {
                        if isPlaying { RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.brass, lineWidth: 1.5) }
                    }
                Text("\(family.editions.count) EDITIONS")
                    .font(Typeface.mono(9, weight: .semibold))
                    .letterSpacing(0.5)
                    .foregroundStyle(Palette.brassHi)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
                    .padding(9)
            }
            Text(family.title.libraryDisplayName).font(Typeface.serif(14)).foregroundStyle(Palette.text)
                .lineLimit(1).padding(.top, 10)
            Text(family.artist.libraryDisplayName).font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                .lineLimit(1).padding(.top, 2)
            FormatLabel(summary: String(localized: "\(family.editions.count) editions") + " · " + family.representative.formatSummary, highlight: true)
                .padding(.top, 5)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openAlbumFamily(family.representative.key) }
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.return, .space]) { _ in model.openAlbumFamily(family.representative.key); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(family.title.libraryDisplayName), \(family.artist.libraryDisplayName), \(family.editions.count) editions")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.openAlbumFamily(family.representative.key) }
        .contextMenu {
            ForEach(family.editions) { edition in
                Button(edition.title) { model.openAlbum(edition.key) }
            }
        }
    }
}

struct AlbumFamilyDetailView: View {
    @Environment(AppModel.self) private var model
    let memberKey: String
    @State private var selectedKey: String?

    var body: some View {
        if let family = AlbumFamilies.group(model.library.albums).first(where: { $0.contains(memberKey) }) {
            let selected = selectedKey.flatMap { key in family.editions.first { $0.key == key } } ?? family.editions.first { $0.key == memberKey } ?? family.representative
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(family.title.libraryDisplayName).font(Typeface.serif(26, weight: .medium)).foregroundStyle(Palette.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("\(family.artist.libraryDisplayName) · \(family.editions.count) EDITIONS")
                            .font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(family.editions) { edition in
                            Button {
                                selectedKey = edition.key
                            } label: {
                                if edition.key == selected.key {
                                    Label(edition.title, systemImage: "checkmark")
                                } else {
                                    Text(edition.title.libraryDisplayName)
                                }
                            }
                        }
                    } label: {
                        Text("Choose Edition")
                            .lineLimit(1)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(family.editions) { edition in
                            Button { selectedKey = edition.key } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(key: edition.artworkKey, size: 120, cornerRadius: 3)
                                        .frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(edition.title.libraryDisplayName).font(Typeface.ui(12, weight: .medium))
                                            .foregroundStyle(Palette.text).lineLimit(2)
                                        FormatLabel(summary: edition.formatSummary, highlight: edition.isHiRes)
                                        // What kind of edition it is, and how many copies of it the library has.
                                        let copies: [String] = model.library.copyCounts[edition.key].map { [String(localized: "\($0) COPIES")] } ?? []
                                        let kinds: [String] = EditionKind.of(edition).map(\.name) + copies
                                        if !kinds.isEmpty {
                                            Text(kinds.joined(separator: " · ")).font(Typeface.mono(8.5, weight: .semibold)).letterSpacing(0.5)
                                                .foregroundStyle(Palette.text3).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(width: 280, height: 66)
                                .padding(7)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(edition.key == selected.key ? Palette.brass : Palette.hairlineStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(edition.title), \(edition.formatSummary)")
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 14)
                }
                Hairline()
                AlbumDetailView(albumKey: selected.key).id(selected.key)
            }
            .background(Palette.window)
            .navigationTitle(family.title)
        } else {
            AlbumDetailView(albumKey: memberKey)
        }
    }
}

/// "FLAC · 24/192" with the codec in brass for hi-res material.
struct FormatLabel: View {
    let summary: String
    var highlight = false

    var body: some View {
        let parts = summary.components(separatedBy: " · ")
        Text("\(Text(parts.first ?? "").foregroundStyle(highlight ? Palette.brass : Palette.text3))\(Text(parts.count > 1 ? " · " + parts.dropFirst().joined(separator: " · ") : "").foregroundStyle(Palette.text3))")
            .font(Typeface.mono(10))
            .letterSpacing(0.3)
    }
}

struct PlayingBars: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // With Reduce Motion the bars hold still (at their staggered rest heights) instead of dancing.
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.brassHi)
                        .frame(width: 2.5, height: active ? 4 + 10 * abs(sin(t * (2.1 + Double(i) * 0.7) + Double(i))) : 4)
                }
            }
            .frame(height: 14, alignment: .bottom)
            .padding(5)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct AlbumMenu: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        // Playing, queueing and playlists take the copy that plays; the rest acts on every copy.
        let tracks = model.library.tracks(albumKey: album.key)
        let playable = model.playableTracks(albumKey: album.key)
        Button("Play") { model.player.play(playable, shuffled: false) }
        Button("Shuffle") { model.player.play(playable, shuffled: true) }
        Button("Play Next") { model.player.playNext(playable) }
        Button("Add to Queue") { model.player.addToQueue(playable) }
        AddToPlaylistMenu(trackIDs: playable.compactMap(\.id))
        Divider()
        Button("Get Info") {
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
            model.inspectorTab = .details
            model.showInspector = true
        }
        Button("Enrich Metadata…") { model.enrichAlbumKeys = [album.key] }
        if tracks.contains(where: \.isMultichannel) {
            Button("Export for Spatial Audio…") { model.spatialExportTracks = tracks }
        }
        Button("Analyze") {
            model.analysis.analyze(tracks)
            model.selectedTrackIDs = Set(tracks.prefix(1).compactMap(\.id))
            model.inspectorTab = .analysis
            model.showInspector = true
        }
        Button("Look Up on MusicBrainz…") { model.lookupTracks = tracks }
        Button("Show in Finder") { model.showInFinder(Array(tracks.prefix(1))) }
        let network = tracks.filter(model.shares.isNetwork)
        if !network.isEmpty {
            Divider()
            if network.allSatisfy(model.shares.cache.isOffline) {
                Button("Remove Offline Copy") { model.shares.setOffline(false, tracks: network) }
            } else {
                Button("Keep Offline") { model.shares.setOffline(true, tracks: network) }
                    .disabled(!network.contains(where: model.shares.isReachable))
            }
        }
    }
}

struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let trackIDs: [Int64]

    var body: some View {
        Menu("Add to Playlist") {
            Button("New Playlist from Selection") {
                if let p = model.library.createPlaylist(name: String(localized: "New Playlist (name)", defaultValue: "New Playlist", comment: "Name given to a newly created playlist (a noun, not the command)"), trackIDs: trackIDs), let id = p.id { model.sidebar = .playlist(id) }
            }
            Divider()
            ForEach(model.library.playlists.filter { !$0.isSmart }) { p in
                Button(p.name.libraryDisplayName) { model.library.append(trackIDs, to: p) }
            }
        }
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let albumKey: String
    @State private var tracks: [Track] = []
    @State private var copies = AlbumCopies.empty

    var body: some View {
        let album = model.library.album(key: albumKey)
        // An album in several copies (a 24/192 download, a vinyl transfer, an Atmos mix; an SACD's stereo and 5.1 areas)
        // lists one of them, the one chosen or else the best for the output, with every copy named above the list; or,
        // bundled, each song once in the copy that suits the output. A song's other copies are a click away on its row.
        let wanted = model.outputWantsMultichannel() ?? true
        let shares = model.shares
        let choice = model.library.copyChoice(albumKey: albumKey)
        let selected = copies.copies.isEmpty ? nil : copies.selected(choice, multichannel: wanted, isLocal: { !$0.tracks.contains(where: shares.isNetwork) })
        let shown: [Track] = copies.copies.isEmpty ? tracks : selected?.tracks ?? copies.songs.map {
            TrackVersions.choose($0.tracks, multichannel: wanted, isLocal: { !shares.isNetwork($0) }, isPreferred: model.library.isPreferredCopy) ?? $0.lead
        }
        let songCopies = Self.copies(of: shown, in: copies)
        VStack(spacing: 0) {
            if let album {
                hero(album, shown: shown, copy: copies.copies.count > 1 ? selected : nil, bundled: copies.copies.count > 1 && selected == nil)
                if copies.copies.count > 1 {
                    AlbumCopiesStrip(albumKey: albumKey, copies: copies, selected: selected, choice: choice)
                }
                Hairline()
            }
            TrackTable(tracks: shown, showAlbum: false, showArtist: shown.contains { $0.artist != album?.artist && $0.artist != nil },
                       copies: songCopies)
        }
        .background(Palette.window)
        .navigationTitle(album?.title ?? String(localized: "Album"))
        .task(id: "\(albumKey)#\(model.library.revision)") {
            let found = model.library.tracks(albumKey: albumKey)
            // Editing the album's title or Album Artist gives it a new key: follow its songs there instead of going blank.
            if found.isEmpty, let moved = model.library.tracks(ids: tracks.compactMap(\.id)).first?.albumKey, moved != albumKey,
               let i = model.path.lastIndex(of: .album(albumKey)) {
                model.path[i] = .album(moved)
                return
            }
            tracks = found
            copies = LibraryCopies.analyze(found)
        }
    }

    /// For each song shown that the album has in several copies: track ID → every copy of it.
    static func copies(of shown: [Track], in copies: AlbumCopies) -> [Int64: [Track]] {
        Dictionary(shown.compactMap { t in
            guard let id = t.id, let song = copies.song(of: t), song.tracks.count > 1 else { return nil }
            return (id, song.tracks)
        }, uniquingKeysWith: { a, _ in a })
    }

    private func hero(_ album: Album, shown: [Track], copy: AlbumCopy?, bundled: Bool) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(key: album.artworkKey, size: 600, cornerRadius: 7)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.55), radius: 25, y: 18)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text(kicker(album, shown: shown))
                    .font(Typeface.mono(10.5, weight: .semibold))
                    .letterSpacing(1.4)
                    .foregroundStyle(Palette.brass)
                Text(album.title.libraryDisplayName)
                    .font(Typeface.serif(38))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 8)
                Button { model.path.append(.artist(album.artist)) } label: {
                    Text(album.artist.libraryDisplayName).font(Typeface.ui(15)).foregroundStyle(Palette.brassHi)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                Text(subline(album, copy: copy, bundled: bundled))
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 6)
                if let mark = album.formatMark, mark.family != .lossless {
                    FormatMarkView(mark: mark, size: 9.5, showsCarrier: false).padding(.top, 10)
                }
                HStack(spacing: 10) {
                    Button { model.player.play(shown, shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(BrassButtonStyle())
                        .fixedSize()
                    Button { model.player.play(shown, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(QuietButtonStyle())
                        .fixedSize()
                    Menu {
                        AlbumMenu(album: album)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                    .menuStyle(.button)
                    .buttonStyle(QuietButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.top, 16)
            }
            .frame(height: 220)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private func kicker(_ a: Album, shown: [Track]) -> String {
        var parts = [String(localized: "ALBUM", comment: "Kicker above an album's title on its page")]
        if let y = a.year { parts.append(String(y)) }
        // Counted once per song, however many versions it has.
        let count = shown.isEmpty ? a.trackCount : shown.count
        parts.append(String(localized: "\(count) TRACKS"))
        parts.append((shown.isEmpty ? a.duration : shown.reduce(0) { $0 + $1.duration }).longDuration)
        return parts.joined(separator: " · ")
    }

    private func subline(_ a: Album, copy: AlbumCopy?, bundled: Bool) -> String {
        var parts: [String] = []
        let genres = Genres.split(a.genre)
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        // One copy of several listed: its own format, size and place, not the whole album's.
        if let copy {
            parts.append(copy.format.replacingOccurrences(of: "/", with: "-bit / ").appending(copy.isDSD || !copy.format.contains("/") ? "" : " kHz")
                         + (copy.layout == .stereo || copy.layout == .atmos ? "" : " · " + copy.layout.name))
            parts.append(copy.size.byteString)
            parts.append(model.library.albumLocation(copy.folder))
            return parts.joined(separator: " · ")
        }
        // "FLAC · 24/88.2 · 5.1" → "FLAC · 24-bit / 88.2 kHz · 5.1"
        let channelText = a.isMultichannel ? " · " + ChannelLayouts.name(channels: a.maxChannels) : ""
        let base = channelText.isEmpty ? a.formatSummary : String(a.formatSummary.dropLast(channelText.count))
        parts.append(base.replacingOccurrences(of: "/", with: "-bit / ").appending(a.isDSD || !base.contains("/") ? "" : " kHz") + channelText)
        parts.append(a.totalSize.byteString)
        if bundled { parts.append(String(localized: "Copies bundled", comment: "Album page: its copies play as one, each song in the copy the output supports best.")) }
        else if let p = a.sourcePath { parts.append(model.library.albumLocation(p)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    private let scope = FilterScope.sidebar(.artists)
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

    var body: some View {
        let filter = model.filter(scope)
        let artists = model.artists(filter)
        let total = model.library.artists.count
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: String(localized: "Artists"),
                           meta: filter.isEmpty ? String(localized: "\(total) artists") : String(localized: "\(artists.count) of \(total) artists")) {
                    PlayShuffleButtons(showsPlay: false, disabled: artists.isEmpty) { model.play(scope, shuffled: $0) }
                }
                FilterBar(scope: scope, items: .albums(model.baseAlbums(scope), model: model))
                    .padding(.bottom, 6)
                if artists.isEmpty && total > 0 {
                    NoMatchesView(title: "No artists match these filters") { model.setFilter(LibraryFilter(), for: scope) }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(artists) { artist in
                            ArtistTile(artist: artist, filter: filter)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
        .background(Palette.window)
    }
}

struct ArtistTile: View {
    @Environment(AppModel.self) private var model
    let artist: LibraryDatabase.ArtistSummary
    /// The filter of the page it's on: its counts, and what its menu plays.
    var filter = LibraryFilter()

    var body: some View {
        Button { model.path.append(.artist(artist.name)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(key: artist.artworkKey, size: 160, cornerRadius: 999)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
                Text(artist.name.libraryDisplayName).font(Typeface.serif(14)).foregroundStyle(Palette.text).lineLimit(1).padding(.top, 10)
                Text("\(artist.albumCount) albums · \(artist.trackCount) tracks")
                    .font(Typeface.mono(10)).foregroundStyle(Palette.text3).padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            AlbumsPlayMenu(scope: .route(.artist(artist.name)), filter: filter.removing([.artist]))
        }
    }
}

/// Play, Shuffle, Play Next and Add to Queue for the albums of an artist or a genre, through a filter.
struct AlbumsPlayMenu: View {
    @Environment(AppModel.self) private var model
    let scope: FilterScope
    let filter: LibraryFilter

    var body: some View {
        Button("Play") { model.play(albums: albums, filter: filter, shuffled: false) }
        Button("Shuffle") { model.play(albums: albums, filter: filter, shuffled: true) }
        Button("Play Next") { model.enqueue(albums: albums, filter: filter, next: true) }
        Button("Add to Queue") { model.enqueue(albums: albums, filter: filter, next: false) }
    }

    private var albums: [Album] { model.filtered(model.baseAlbums(scope), by: filter) }
}

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        AlbumsGridView(scope: .route(.artist(name)), title: name.libraryDisplayName)
            .navigationTitle(name.libraryDisplayName)
    }
}

// MARK: - Sources

struct SourceView: View {
    @Environment(AppModel.self) private var model
    let sourceID: Int64

    var body: some View {
        if let source = model.library.sources.first(where: { $0.id == sourceID }) {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.url.lastPathComponent).font(Typeface.serif(26, weight: .medium)).foregroundStyle(Palette.text)
                        Text(source.statusLine)
                            .font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                        Text(source.path).font(Typeface.ui(12)).foregroundStyle(Palette.text2).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Rescan") { Task { await model.library.scan(source, restart: true) } }.buttonStyle(QuietButtonStyle())
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }.buttonStyle(QuietButtonStyle())
                }
                .padding(24)
                Hairline()
                AlbumsGridView(scope: .sidebar(.source(sourceID)), title: String(localized: "Albums in this source"))
            }
            .background(Palette.window)
        }
    }
}

extension LibrarySource {
    /// "MANAGED · COPIED & ORGANIZED · ONLINE · SCANNED 2 HOURS AGO": the line under a source's name on its page (and
    /// on a remote's list of sources).
    var statusLine: String {
        var parts = [mode == .managed ? String(localized: "MANAGED · COPIED & ORGANIZED") : String(localized: "REFERENCED IN PLACE"),
                     isOnline ? String(localized: "ONLINE") : String(localized: "OFFLINE")]
        if let scanned = lastScannedAt {
            parts.append(String(localized: "SCANNED \(scanned.formatted(.relative(presentation: .named)).localizedUppercase)",
                                comment: "Followed by when the source was last scanned, e.g. 2 HOURS AGO"))
        }
        return parts.joined(separator: " · ")
    }
}
