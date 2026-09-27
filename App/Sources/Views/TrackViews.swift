//
// Nocturne — track tables: album tracklists, songs, playlists, search.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneLibrary
import SwiftUI

struct TrackRow: Identifiable, Hashable {
    let track: Track
    let index: Int
    var id: Int64 { track.id ?? -Int64(index) }
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
                    AnalysisTag(track: row.track)
                }
            }
            .width(min: 120, ideal: 200)

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
            let chosen = tracks.filter { ids.contains($0.id ?? -1) }
            if !chosen.isEmpty { TrackMenu(tracks: chosen, playlist: reorderable, all: tracks) }
        } primaryAction: { ids in
            guard let first = ids.first, let index = rows.firstIndex(where: { $0.id == first }) else { return }
            model.player.play(rows.map(\.track), startAt: index)
        }
        .onAppear { selection = model.selectedTrackIDs.intersection(rows.map(\.id)) }
        .onChange(of: model.selectedTrackIDs) { _, new in
            let visible = new.intersection(rows.map(\.id))
            if visible != selection { selection = visible }
        }
        .onChange(of: selection) { _, new in
            model.selectedTrackIDs = new
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
            tag("UPSAMPLED", color: Palette.copper)
        case "possibleLossyOrigin":
            tag("LOSSY ORIGIN?", color: Palette.copper)
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
                model.library.setPlaylistOrder(all.compactMap(\.id).filter { !remove.contains($0) }, playlist: playlist)
            }
        }
    }
}

// MARK: - Songs / search / playlists

struct SongsView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let tracks: [Track]?
    @State private var loaded: [Track] = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, meta: "\(loaded.count.formatted()) tracks · \(loaded.reduce(0) { $0 + $1.duration }.longDuration)") {
                Button { model.player.play(loaded) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(BrassButtonStyle())
                    .disabled(loaded.isEmpty)
            }
            TrackTable(tracks: loaded)
        }
        .background(Palette.window)
        .task(id: model.library.revision) { loaded = tracks ?? model.library.allTracks() }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var results: [Track] = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "“\(query)”", meta: "\(results.count) matching tracks") { EmptyView() }
            if results.isEmpty {
                Text("No tracks match.").font(Typeface.ui(13)).foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackTable(tracks: results)
            }
        }
        .background(Palette.window)
        .task(id: "\(query)#\(model.library.revision)") {
            try? await Task.sleep(for: .milliseconds(120))
            results = model.library.search(query)
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
