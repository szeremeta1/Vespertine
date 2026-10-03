//
// Vespertine — sidebar: library, playlists, sources.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Playlist?
    @State private var renamingSource: LibrarySource?
    @State private var removingSource: LibrarySource?
    @State private var deletingPlaylist: Playlist?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { if let v = $0 { model.sidebar = v } })) {
            Section("Library") {
                row(.albums, "Albums", "square.grid.2x2", count: model.library.stats.albums)
                    .contextMenu { playMenu(.albums) }
                row(.artists, "Artists", "person", count: model.library.stats.artists)
                    .contextMenu { playMenu(.artists, play: false) }
                row(.songs, "Songs", "music.note", count: model.library.stats.tracks)
                    .contextMenu { playMenu(.songs) }
                row(.genres, "Genres", "guitars", count: model.library.genres.count)
                    .contextMenu { playMenu(.genres, play: false) }
                row(.recentlyAdded, "Recently Added", "clock", count: nil)
                    .contextMenu { playMenu(.recentlyAdded) }
                row(.favorites, "Favorites", "heart", count: model.library.favoriteCount)
                    .contextMenu { playMenu(.favorites) }
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.flatMap { $0.split(separator: ",") }.compactMap { Int64($0) }
                        model.library.setFavorite(true, trackIDs: ids)
                        return !ids.isEmpty
                    }
            }

            Section {
                ForEach(model.library.playlists) { playlist in
                    if let id = playlist.id {
                        Label {
                            Text(playlist.name).lineLimit(1)
                        } icon: {
                            Image(systemName: playlist.isSmart ? "gearshape" : "music.note.list")
                        }
                        .tag(SidebarItem.playlist(id))
                        .dropDestination(for: String.self) { items, _ in
                            let ids = items.flatMap { $0.split(separator: ",") }.compactMap { Int64($0) }
                            model.library.append(ids, to: playlist)
                            return !ids.isEmpty && !playlist.isSmart
                        }
                        .contextMenu {
                            if playlist.isSmart { Button("Edit Rules…") { model.smartEditorPlaylist = playlist } }
                            Button("Rename…") { newName = playlist.name; renaming = playlist }
                            playMenu(.playlist(id))
                            Divider()
                            Button("Delete Playlist", role: .destructive) { deletingPlaylist = playlist }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Menu {
                        Button("New Playlist") { newPlaylist(smart: false) }
                        Button("New Smart Playlist…") { newPlaylist(smart: true) }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .accessibilityLabel("Add Playlist")
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New playlist")
                }
            }

            Section {
                ForEach(model.library.sources) { source in
                    if let id = source.id {
                        Label {
                            HStack {
                                Text(source.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if source.isNetwork, model.shares.status(of: source) == .connecting {
                                    ProgressView().controlSize(.mini)
                                } else if !source.isOnline {
                                    Text("OFFLINE")
                                        .font(Typeface.mono(8.5, weight: .semibold))
                                        .foregroundStyle(Palette.text3)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.hairlineStrong))
                                } else if model.library.scanProgress?.sourcePath == source.path {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                        } icon: {
                            Image(systemName: source.isNetwork ? "server.rack"
                                  : source.path.hasPrefix("/Volumes/") ? "externaldrive" : (source.mode == .managed ? "tray.full" : "folder"))
                        }
                        .opacity(source.isOnline ? 1 : 0.55)
                        .help(sourceHelp(source))
                        .tag(SidebarItem.source(id))
                        .contextMenu {
                            if source.isNetwork {
                                Button("Reconnect") { Task { await model.shares.connect(source) } }
                                Button("Enter Password…") {
                                    model.connectPrefill = source.remoteURL
                                    model.showConnectServer = true
                                }
                            }
                            Button("Rename…") { newName = source.displayName; renamingSource = source }
                            Button("Rescan") { Task { await model.library.scan(source) } }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }
                                .disabled(!source.isOnline)
                            Divider()
                            Button("Remove from Library", role: .destructive) { removingSource = source }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sources")
                    Spacer()
                    Menu {
                        Button("Find Music on This Mac…") { model.showFindMusic = true }
                        Button("Connect to Server…") { model.showConnectServer = true }
                        Divider()
                        Button("Add Folder (Reference in Place)…") { model.presentImporter(.reference) }
                        Button("Import & Organize (Copy)…") { model.presentImporter(.copyAndOrganize) }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .accessibilityLabel("Add Music")
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add music")
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Palette.brass)
        .safeAreaInset(edge: .bottom) { ScanStatusView() }
        .alert("Rename Source", isPresented: Binding(get: { renamingSource != nil }, set: { if !$0 { renamingSource = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let s = renamingSource { model.library.renameSource(s, to: newName) }; renamingSource = nil }
            Button("Cancel", role: .cancel) { renamingSource = nil }
        } message: {
            Text("Only the name in the sidebar changes; the folder stays as it is. Leave it empty for the default name.")
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let p = renaming { model.library.renamePlaylist(p, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert(deleteTitle, isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }),
               presenting: deletingPlaylist) { playlist in
            Button("Delete", role: .destructive) { delete(playlist) }
            Button("Cancel", role: .cancel) {}
        } message: { playlist in
            Text(playlist.isSmart ? "Its rules are deleted. The songs stay in your library, and no files are deleted."
                                  : "Its list of songs and their order are deleted. The songs stay in your library, and no files are deleted.")
        }
        .modifier(RemoveSourceAlert(source: $removingSource))
    }

    private var deleteTitle: String { deletingPlaylist.map { "Delete the playlist “\($0.name)”?" } ?? "" }

    private func delete(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        if model.sidebar == .playlist(id) { model.sidebar = .albums }
        model.setFilter(LibraryFilter(), for: .sidebar(.playlist(id)))
        model.library.deletePlaylist(playlist)
    }

    /// Plays what the page lists, through its filter (a filtered page plays what it shows).
    @ViewBuilder private func playMenu(_ item: SidebarItem, play: Bool = true) -> some View {
        let scope = FilterScope.sidebar(item)
        if play { Button("Play") { model.play(scope, shuffled: false) } }
        Button("Shuffle") { model.play(scope, shuffled: true) }
        if !model.filter(scope).isEmpty {
            Button("Clear Filters") { model.setFilter(LibraryFilter(), for: scope) }
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, count: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if !model.filter(.sidebar(item)).isEmpty {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.brass)
                        .help("Filtered")
                }
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(Typeface.mono(10.5))
                        .foregroundStyle(Palette.text3)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(item)
    }

    private func sourceHelp(_ source: LibrarySource) -> String {
        guard let share = source.networkShare else { return source.path }
        if case .offline(let reason) = model.shares.status(of: source), !reason.isEmpty {
            return "\(share.displayString)\n\(reason)"
        }
        return share.displayString
    }

    private func newPlaylist(smart: Bool) {
        let rules: SmartRules? = smart ? SmartRules(rules: [SmartRule(field: .genre, op: .contains, value: "")]) : nil
        if let p = model.library.createPlaylist(name: smart ? "New Smart Playlist" : "New Playlist", rules: rules), let id = p.id {
            model.sidebar = .playlist(id)
            if smart { model.smartEditorPlaylist = p } else { newName = p.name; renaming = p }
        }
    }
}

/// Asks before a source leaves the library (from the sidebar or Settings). Its songs' library state goes with
/// them, for good: adding the folder or share again starts them afresh. The files themselves stay where they are.
struct RemoveSourceAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var source: LibrarySource?

    private var title: String { source.map { "Remove “\($0.displayName)” from the library?" } ?? "" }

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
                      presenting: source) { source in
            Button("Remove", role: .destructive) { remove(source) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text("Its songs leave the library, and with them their play counts, favorites, places in playlists, analyses and tag-edit history. Adding it again doesn’t bring these back. \(source.isNetwork ? "Nothing on the server is changed." : "The music files themselves aren’t deleted.")")
        }
    }

    private func remove(_ source: LibrarySource) {
        guard let id = source.id else { return }
        if model.sidebar == .source(id) { model.sidebar = .albums }
        model.setFilter(LibraryFilter(), for: .sidebar(.source(id)))
        if source.isNetwork { Task { await model.shares.remove(source) } } else { model.library.removeSource(source) }
    }
}

struct ScanStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = model.library.scanProgress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.phase == .listing ? "Finding files" : "Reading tags")
                        .font(Typeface.ui(11, weight: .medium)).foregroundStyle(Palette.text2)
                    Spacer()
                    Text(p.phase == .listing ? "\(p.processed) found" : p.total > 0 ? "\(p.processed)/\(p.total)" : "…")
                        .font(Typeface.mono(10)).foregroundStyle(Palette.text3)
                }
                if p.phase == .listing {
                    ProgressView().progressViewStyle(.linear).tint(Palette.brass)
                } else {
                    ProgressView(value: p.total > 0 ? Double(p.processed) / Double(p.total) : 0)
                        .progressViewStyle(.linear)
                        .tint(Palette.brass)
                }
            }
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }
}
