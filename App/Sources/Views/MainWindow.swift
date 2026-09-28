//
// Nocturne — main window layout.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneLibrary
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
            } detail: {
                HStack(spacing: 0) {
                    ContentRouter()
                        .frame(minWidth: 520)
                    if model.showInspector {
                        Hairline(vertical: true)
                        InspectorView()
                            .frame(width: 348)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: model.showInspector)
            }
            TransportBar()
        }
        .background(Palette.window)
        .tint(Palette.brass)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search library")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { _ = model.path.popLast() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.path.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back (⌘[)")
            }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.folder, .audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFolders(urls) }
        }
        .onKeyPress(.space) {
            model.player.togglePlayPause()
            return .handled
        }
        .sheet(item: Binding(get: { model.lookupTracks.map(LookupRequest.init) }, set: { model.lookupTracks = $0?.tracks })) { request in
            MusicBrainzSheet(tracks: request.tracks)
                .environment(model)
        }
        .sheet(isPresented: $model.showFindMusic) {
            FindMusicSheet().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.enrichAlbumKeys != nil }, set: { if !$0 { model.enrichAlbumKeys = nil } })) {
            EnrichSheet(albumKeys: model.enrichAlbumKeys ?? []).environment(model)
        }
        .sheet(item: $model.smartEditorPlaylist) { playlist in
            SmartPlaylistEditor(playlist: playlist)
                .environment(model)
        }
        .overlay(alignment: .top) { ErrorBanner() }
        .task { model.runDeveloperHooks(openWindow: openWindow) }
    }
}

struct LookupRequest: Identifiable {
    let tracks: [Track]
    var id: String { tracks.compactMap(\.id).map(String.init).joined(separator: ",") }
}

/// Picks the content for the current sidebar item or search.
struct ContentRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView(query: model.searchText)
            } else if model.library.stats.tracks == 0 && model.library.scanProgress == nil && model.library.sources.isEmpty {
                EmptyLibraryView()
            } else if let route = model.path.last {
                switch route {
                case .album(let key): AlbumDetailView(albumKey: key).id(key)
                case .artist(let name): ArtistDetailView(name: name).id(name)
                }
            } else {
                switch model.sidebar {
                case .albums: AlbumsGridView()
                case .artists: ArtistsView()
                case .songs: SongsView(title: "Songs", tracks: nil)
                case .recentlyAdded: AlbumsGridView(title: "Recently Added", forcedSort: .recentlyAdded)
                case .playlist(let id): PlaylistView(playlistID: id)
                case .source(let id): SourceView(sourceID: id)
                }
            }
        }
        .background(Palette.window)
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.player.lastError ?? model.library.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.copper)
                Text(message).font(Typeface.ui(12)).foregroundStyle(Palette.text).lineLimit(2)
                Button("Dismiss") { dismiss() }.buttonStyle(QuietButtonStyle(compact: true))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.copper.opacity(0.4)))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(8))
                dismiss()
            }
        }
    }

    private func dismiss() {
        withAnimation { model.player.clearError(); model.library.clearError() }
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Palette.brass)
            Text("Your library is empty")
                .font(Typeface.serif(30))
                .foregroundStyle(Palette.text)
            Text("Nocturne can look through this Mac for music, check each file's real format, and bring in\nyour hi-res and lossless albums. You can also add folders yourself.")
                .font(Typeface.ui(13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.text2)
                .lineSpacing(3)
            HStack(spacing: 12) {
                Button { model.showFindMusic = true } label: { Label("Find Music on This Mac…", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(BrassButtonStyle())
                Button("Add Folder…") { model.presentImporter(.reference) }
                    .buttonStyle(QuietButtonStyle())
                Button("Import & Organize…") { model.presentImporter(.copyAndOrganize) }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, 6)
            Text("FLAC · ALAC · WAV · AIFF · DSD · APE · WavPack · Opus · MP3 · AAC · and more")
                .font(Typeface.mono(10.5))
                .foregroundStyle(Palette.text3)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
