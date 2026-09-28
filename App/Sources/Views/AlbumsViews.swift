//
// Nocturne — album grid, album detail, artists.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneAudio
import NocturneLibrary
import SwiftUI

// MARK: - Shared header

struct PageHeader<Trailing: View>: View {
    let title: String
    let meta: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typeface.serif(26, weight: .medium)).foregroundStyle(Palette.text)
                Text(meta).font(Typeface.mono(11)).foregroundStyle(Palette.text3)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

// MARK: - Album grid

struct AlbumsGridView: View {
    @Environment(AppModel.self) private var model
    var title = "Albums"
    var forcedSort: AlbumSort? = nil
    var albumsOverride: [Album]? = nil

    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 22, alignment: .top)]

    var body: some View {
        @Bindable var library = model.library
        let albums = albumsOverride ?? source(library)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: title, meta: meta(albums)) {
                    if albumsOverride == nil && forcedSort == nil {
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
                }
                if albumsOverride == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FormatFilter.allCases) { f in
                                Chip(title: f.label, isOn: library.formatFilter == f) { library.formatFilter = f }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 6)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(albums) { album in
                        AlbumCard(album: album)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.window)
    }

    private func source(_ library: LibraryStore) -> [Album] {
        var list = library.filteredAlbums
        if forcedSort == .recentlyAdded {
            list.sort { $0.addedAt > $1.addedAt }
            list = Array(list.prefix(60))
        }
        return list
    }

    private func meta(_ albums: [Album]) -> String {
        let s = model.library.stats
        if albumsOverride != nil || forcedSort != nil { return "\(albums.count) albums" }
        return "\(s.albums.formatted()) albums · \(s.tracks.formatted()) tracks · \(s.bytes.byteString)"
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
                if isPlaying {
                    PlayingBars(active: model.player.isPlaying)
                        .padding(8)
                } else if hovering {
                    Button {
                        model.player.play(model.library.tracks(albumKey: album.key))
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
            Text(album.title)
                .font(Typeface.serif(14))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .padding(.top, 10)
            Text(album.artist)
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
        .contextMenu { AlbumMenu(album: album) }
        .draggable(model.library.tracks(albumKey: album.key).compactMap(\.id).map(String.init).joined(separator: ","))
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
            .tracking(0.3)
    }
}

struct PlayingBars: View {
    var active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !active)) { context in
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
        let tracks = model.library.tracks(albumKey: album.key)
        Button("Play") { model.player.play(tracks) }
        Button("Play Next") { model.player.playNext(tracks) }
        Button("Add to Queue") { model.player.addToQueue(tracks) }
        AddToPlaylistMenu(trackIDs: tracks.compactMap(\.id))
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
            model.analysis.analyzeNow(tracks)
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
                if let p = model.library.createPlaylist(name: "New Playlist", trackIDs: trackIDs), let id = p.id { model.sidebar = .playlist(id) }
            }
            Divider()
            ForEach(model.library.playlists.filter { !$0.isSmart }) { p in
                Button(p.name) { model.library.append(trackIDs, to: p) }
            }
        }
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let albumKey: String
    @State private var tracks: [Track] = []

    var body: some View {
        let album = model.library.album(key: albumKey)
        VStack(spacing: 0) {
            if let album {
                hero(album)
                Hairline()
            }
            TrackTable(tracks: tracks, showAlbum: false, showArtist: tracks.contains { $0.artist != album?.artist && $0.artist != nil })
        }
        .background(Palette.window)
        .navigationTitle(album?.title ?? "Album")
        .task(id: "\(albumKey)#\(model.library.revision)") {
            tracks = model.library.tracks(albumKey: albumKey)
        }
    }

    private func hero(_ album: Album) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(key: album.artworkKey, size: 600, cornerRadius: 7)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.55), radius: 25, y: 18)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text(kicker(album))
                    .font(Typeface.mono(10.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.brass)
                Text(album.title)
                    .font(Typeface.serif(38))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 8)
                Button { model.path.append(.artist(album.artist)) } label: {
                    Text(album.artist).font(Typeface.ui(15)).foregroundStyle(Palette.brassHi)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                Text(subline(album))
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 6)
                HStack(spacing: 10) {
                    Button { model.player.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(BrassButtonStyle())
                    Button { model.player.shuffle = true; model.player.play(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(QuietButtonStyle())
                    Button("Look Up on MusicBrainz") { model.lookupTracks = tracks }
                        .buttonStyle(QuietButtonStyle())
                    Menu {
                        AlbumMenu(album: album)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
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

    private func kicker(_ a: Album) -> String {
        var parts = ["ALBUM"]
        if let y = a.year { parts.append(String(y)) }
        parts.append("\(a.trackCount) TRACK\(a.trackCount == 1 ? "" : "S")")
        parts.append(a.duration.longDuration)
        return parts.joined(separator: " · ")
    }

    private func subline(_ a: Album) -> String {
        var parts: [String] = []
        if let g = a.genre { parts.append(g) }
        // "FLAC · 24/88.2 · 5.1" → "FLAC · 24-bit / 88.2 kHz · 5.1"
        let channelText = a.isMultichannel ? " · " + ChannelLayouts.name(channels: a.maxChannels) : ""
        let base = channelText.isEmpty ? a.formatSummary : String(a.formatSummary.dropLast(channelText.count))
        parts.append(base.replacingOccurrences(of: "/", with: "-bit / ").appending(a.isDSD || !base.contains("/") ? "" : " kHz") + channelText)
        parts.append(a.totalSize.byteString)
        if let p = a.sourcePath { parts.append((p as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Artists", meta: "\(model.library.artists.count) artists") { EmptyView() }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach(model.library.artists) { artist in
                        Button { model.path.append(.artist(artist.name)) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ArtworkView(key: artist.artworkKey, size: 160, cornerRadius: 999)
                                    .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
                                Text(artist.name).font(Typeface.serif(14)).foregroundStyle(Palette.text).lineLimit(1).padding(.top, 10)
                                Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.trackCount) tracks")
                                    .font(Typeface.mono(10)).foregroundStyle(Palette.text3).padding(.top, 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .background(Palette.window)
    }
}

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let albums = model.library.albums(artist: name)
        AlbumsGridView(title: name, albumsOverride: albums)
            .id(model.library.revision)
            .navigationTitle(name)
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
                        Text("\(source.mode == .managed ? "MANAGED · COPIED & ORGANIZED" : "REFERENCED IN PLACE") · \(source.isOnline ? "ONLINE" : "OFFLINE")\(source.lastScannedAt.map { " · SCANNED " + $0.formatted(.relative(presentation: .named)).uppercased() } ?? "")")
                            .font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                        Text(source.path).font(Typeface.ui(12)).foregroundStyle(Palette.text2).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Rescan") { Task { await model.library.scan(source) } }.buttonStyle(QuietButtonStyle())
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }.buttonStyle(QuietButtonStyle())
                }
                .padding(24)
                Hairline()
                AlbumsGridView(title: "Albums in this source", albumsOverride: model.library.albums(underPath: source.path))
                    .id(model.library.revision)
            }
            .background(Palette.window)
        }
    }
}
