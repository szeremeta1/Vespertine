//
// Nocturne — sidebar: library, playlists, sources.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneLibrary
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Playlist?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { if let v = $0 { model.sidebar = v } })) {
            Section("Library") {
                row(.albums, "Albums", "square.grid.2x2", count: model.library.stats.albums)
                row(.artists, "Artists", "person", count: model.library.stats.artists)
                row(.songs, "Songs", "music.note", count: model.library.stats.tracks)
                row(.recentlyAdded, "Recently Added", "clock", count: nil)
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
                            Button("Play") { model.player.play(model.library.tracks(in: playlist)) }
                            Divider()
                            Button("Delete Playlist", role: .destructive) {
                                if model.sidebar == .playlist(id) { model.sidebar = .albums }
                                model.library.deletePlaylist(playlist)
                            }
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
                                if !source.isOnline {
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
                            Image(systemName: source.path.hasPrefix("/Volumes/") ? "externaldrive" : (source.mode == .managed ? "tray.full" : "folder"))
                        }
                        .opacity(source.isOnline ? 1 : 0.55)
                        .help(source.path)
                        .tag(SidebarItem.source(id))
                        .contextMenu {
                            Button("Rescan") { Task { await model.library.scan(source) } }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                if model.sidebar == .source(id) { model.sidebar = .albums }
                                model.library.removeSource(source)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sources")
                    Spacer()
                    Menu {
                        Button("Find Music on This Mac…") { model.showFindMusic = true }
                        Divider()
                        Button("Add Folder (Reference in Place)…") { model.presentImporter(.reference) }
                        Button("Import & Organize (Copy)…") { model.presentImporter(.copyAndOrganize) }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
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
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let p = renaming { model.library.renamePlaylist(p, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, count: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
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

    private func newPlaylist(smart: Bool) {
        let rules: SmartRules? = smart ? SmartRules(rules: [SmartRule(field: .genre, op: .contains, value: "")]) : nil
        if let p = model.library.createPlaylist(name: smart ? "New Smart Playlist" : "New Playlist", rules: rules), let id = p.id {
            model.sidebar = .playlist(id)
            if smart { model.smartEditorPlaylist = p } else { newName = p.name; renaming = p }
        }
    }
}

struct ScanStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = model.library.scanProgress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Scanning").font(Typeface.ui(11, weight: .medium)).foregroundStyle(Palette.text2)
                    Spacer()
                    Text(p.total > 0 ? "\(p.processed)/\(p.total)" : "…").font(Typeface.mono(10)).foregroundStyle(Palette.text3)
                }
                ProgressView(value: p.total > 0 ? Double(p.processed) / Double(p.total) : 0)
                    .progressViewStyle(.linear)
                    .tint(Palette.brass)
            }
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }
}
