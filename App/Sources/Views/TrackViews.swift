//
// Nocturne — track tables: album tracklists, songs, playlists, search.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneLibrary
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

    @State private var selection = Set<Int64>()
    @State private var sortOrder: [KeyPathComparator<TrackRow>] = []

    private var rows: [TrackRow] {
        let base = tracks.enumerated().map { TrackRow(track: $1, index: $0) }
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.index) { row in
                if model.player.current?.track.id == row.track.id, model.player.state != .stopped {
                    Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.brass)
                } else {
                    Text(showAlbum ? "\(row.index + 1)" : (row.track.trackNumber.map(String.init) ?? "–"))
                        .font(Typeface.mono(11.5))
                        .foregroundStyle(Palette.text3)
                }
            }
            .width(36)

            TableColumn("Title", value: \.track.title) { row in
                Text(row.track.title)
                    .font(Typeface.ui(13))
                    .foregroundStyle(model.player.current?.track.id == row.track.id ? Palette.brassHi : Palette.text)
                    .opacity(row.track.isMissing ? 0.45 : 1)
            }
            .width(min: 160, ideal: 280)

            if showArtist {
                TableColumn("Artist", value: \.track.displayArtist) { row in
                    Text(row.track.displayArtist).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
                .width(min: 100, ideal: 170)
            }
            if showAlbum {
                TableColumn("Album", value: \.track.displayAlbum) { row in
                    Text(row.track.displayAlbum).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
                .width(min: 100, ideal: 190)
            }

            TableColumn("Format", value: \.track.sampleRate) { row in
                HStack(spacing: 8) {
                    Text(row.track.formatSummary).font(Typeface.mono(11)).foregroundStyle(Palette.text2)
                        .lineLimit(1).fixedSize()
                    AnalysisTag(track: row.track).fixedSize()
                }
            }
            .width(min: 150, ideal: 250)

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
            if !chosen.isEmpty { TrackMenu(tracks: chosen, playlist: reorderable, all: tracks, positions: Set(chosenRows.map(\.index))) }
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
            tag("UPSAMPLED", color: Palette.copper).help("A 44.1/48 kHz master upsampled to a hi-res rate")
        case "possibleLossyOrigin":
            tag("LOSSY ORIGIN", color: Palette.copper).help("Made from an MP3, AAC or Opus file")
        case "bandwidthExtended":
            tag("SYNTHETIC HF", color: Palette.copper).help("Made from a lossy file; its high frequencies were generated afterwards (SBR or AI “enhancement”)")
        case "genuine" where (track.bitDepth ?? 0) >= 24:
            tag("TRUE \(track.bitDepth ?? 24)", color: Palette.brass)
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

/// Filters tracks by what analysis found.
enum AnalysisFilter: String, CaseIterable, Identifiable {
    case all, genuine, anyIssue, lossy, synthetic, upsampled, padded, notAnalyzed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All tracks"
        case .genuine: "Genuine"
        case .anyIssue: "Any issue"
        case .lossy: "Lossy origin"
        case .synthetic: "Synthetic high frequencies"
        case .upsampled: "Upsampled"
        case .padded: "Padded bit depth"
        case .notAnalyzed: "Not analyzed"
        }
    }
    func matches(_ t: Track) -> Bool {
        let v = t.analysisVerdict
        switch self {
        case .all: return true
        case .genuine: return v == "genuine"
        case .anyIssue: return ["possibleLossyOrigin", "bandwidthExtended", "upsampled", "paddedBitDepth"].contains(v ?? "")
        case .lossy: return v == "possibleLossyOrigin"
        case .synthetic: return v == "bandwidthExtended"
        case .upsampled: return v == "upsampled"
        case .padded: return v == "paddedBitDepth"
        case .notAnalyzed: return v == nil && t.isLossless && !t.isDSD
        }
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let tracks: [Track]?
    @State private var loaded: [Track] = []
    @State private var filter: AnalysisFilter = .all

    var body: some View {
        let shown = filter == .all ? loaded : loaded.filter(filter.matches)
        VStack(spacing: 0) {
            PageHeader(title: title, meta: "\(shown.count.formatted()) tracks · \(shown.reduce(0) { $0 + $1.duration }.longDuration)") {
                Menu {
                    Picker("Analysis", selection: $filter) {
                        ForEach(AnalysisFilter.allCases) { f in
                            Text(f == .all ? f.label : "\(f.label) (\(loaded.filter(f.matches).count))").tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Analyze Tracks Without Results") { model.analysis.analyzeNow(loaded.filter(AnalysisFilter.notAnalyzed.matches)) }
                } label: {
                    Label(filter == .all ? "Analysis" : filter.label, systemImage: filter == .all ? "waveform.badge.magnifyingglass" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.button)
                .buttonStyle(QuietButtonStyle())
                .fixedSize()
                Button { model.player.play(shown) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(BrassButtonStyle())
                    .disabled(shown.isEmpty)
            }
            TrackTable(tracks: shown)
        }
        .background(Palette.window)
        .task(id: model.library.revision) { loaded = tracks ?? model.library.allTracks() }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var results: [Track] = []
    @State private var albums: [Album] = []
    @State private var artists: [LibraryDatabase.ArtistSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "\u{201C}\(query)\u{201D}", meta: meta) { EmptyView() }
            if results.isEmpty && albums.isEmpty && artists.isEmpty {
                Text("Nothing matches.").font(Typeface.ui(13)).foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !artists.isEmpty {
                    shelf("Artists", count: artists.count) {
                        ForEach(artists) { ArtistTile(artist: $0).frame(width: 136) }
                    }
                }
                if !albums.isEmpty {
                    shelf("Albums", count: albums.count) {
                        ForEach(albums) { AlbumCard(album: $0).frame(width: 150) }
                    }
                }
                if !results.isEmpty {
                    sectionTitle("Songs", count: results.count).padding(.top, 6)
                    TrackTable(tracks: results)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .background(Palette.window)
        .task(id: "\(query)#\(model.library.revision)") {
            try? await Task.sleep(for: .milliseconds(120))
            results = model.library.search(query)
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            func matches(_ text: String) -> Bool { words.allSatisfy { text.localizedStandardContains($0) } }
            func startsWith(_ text: String) -> Int { text.localizedStandardRange(of: query)?.lowerBound == text.startIndex ? 0 : 1 }
            albums = model.library.albums
                .filter { matches("\($0.title) \($0.artist)") }
                .sorted { (startsWith($0.title), $0.title) < (startsWith($1.title), $1.title) }
            artists = model.library.artists
                .filter { matches($0.name) }
                .sorted { (startsWith($0.name), -$0.trackCount) < (startsWith($1.name), -$1.trackCount) }
        }
    }

    private var meta: String {
        func n(_ c: Int, _ word: String) -> String { "\(c) \(word)\(c == 1 ? "" : "s")" }
        return [n(artists.count, "artist"), n(albums.count, "album"), n(results.count, "song")].joined(separator: " · ")
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
    @State private var tracks: [Track] = []

    var body: some View {
        let playlist = model.library.playlists.first { $0.id == playlistID }
        VStack(spacing: 0) {
            if let playlist {
                PageHeader(title: playlist.name,
                           meta: "\(playlist.isSmart ? "SMART · " : "")\(tracks.count) tracks · \(tracks.reduce(0) { $0 + $1.duration }.longDuration)") {
                    if playlist.isSmart {
                        Button("Edit Rules…") { model.smartEditorPlaylist = playlist }.buttonStyle(QuietButtonStyle())
                    }
                    Button { model.player.shuffle = true; model.player.play(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(QuietButtonStyle()).disabled(tracks.isEmpty)
                    Button { model.player.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(BrassButtonStyle()).disabled(tracks.isEmpty)
                }
                if tracks.isEmpty {
                    VStack(spacing: 8) {
                        Text(playlist.isSmart ? "No tracks match these rules yet." : "Drag albums or tracks here.")
                            .font(Typeface.serif(18)).foregroundStyle(Palette.text2)
                        Text(playlist.isSmart ? "Run an analysis or adjust the rules." : "You can also use “Add to Playlist” in any context menu.")
                            .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TrackTable(tracks: tracks, reorderable: playlist)
                }
            }
        }
        .background(Palette.window)
        .task(id: "\(playlistID)#\(model.library.revision)#\(playlist?.smartRules.hashValue ?? 0)") {
            if let playlist { tracks = model.library.tracks(in: playlist) }
        }
    }
}
