//
// Vespertine — a bit-perfect audio player for macOS.
// Copyright © 2026 Vespertine contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

@main
struct VespertineApp: App {
    @State private var startup = LibraryStartup()
    @State private var updater = AppUpdater()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Vespertine", id: "main") {
            LibraryContent(startup: startup) { model in
                MainRoot()
                    .environment(model)
                    .environment(updater)
                    .frame(minWidth: 1080, minHeight: 680)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            if let model = startup.model { VespertineCommands(model: model) }
            CommandGroup(replacing: .appInfo) {
                Button("About Vespertine") { AboutPanel.show() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                if let model = startup.model {
                    Button("Setup Assistant…") { openWindow(id: "main"); model.showSetup = true }
                        .disabled(model.showSetup)
                }
            }
        }

        Window("Mini Player", id: "mini") {
            LibraryContent(startup: startup) { model in
                MiniPlayerView().environment(model).preferredColorScheme(.dark)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.bottomLeading)

        Window("Equalizer", id: "equalizer") {
            LibraryContent(startup: startup) { model in
                EqualizerWindow().environment(model).preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 860, height: 600)

        MenuBarExtra {
            LibraryContent(startup: startup) { model in
                MenuBarView().environment(model)
            }
            .environment(\.colorScheme, .dark)
            .background(DarkWindowAppearance())
        } label: {
            if let model = startup.model { MenuBarLabel().environment(model) }
            else { Image(systemName: "exclamationmark.triangle") }
        }
        .menuBarExtraStyle(.window)

        Settings {
            LibraryContent(startup: startup) { model in
                SettingsView().environment(model).environment(updater).preferredColorScheme(.dark)
            }
        }
    }
}

struct VespertineCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Find Music on This Mac…") { model.showFindMusic = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Add Folder to Library…") { model.presentImporter(.reference) }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Import & Organize…") { model.presentImporter(.copyAndOrganize) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Connect to Server…") { model.showConnectServer = true }
                .keyboardShortcut("k", modifiers: [.command])
            Divider()
            Button("Import Playlist…") { model.importPlaylistFiles() }
            Button("Import Apple Music Library…") { model.importAppleMusicLibrary() }
            Divider()
            Button("Rescan Library") { Task { await model.library.rescanAll() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Enrich Metadata…") { model.enrichAlbumKeys = [] }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button(model.analysis.isRunning ? String(localized: "Stop Analyzing") : String(localized: "Analyze Library")) {
                if model.analysis.isRunning { model.analysis.cancel() } else { model.analysis.analyzeLibrary(includeNetwork: true) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }
        CommandMenu("Controls") {
            // Space is handled by the main window so it never steals spaces from text fields.
            Button(model.player.isPlaying ? String(localized: "Pause") : String(localized: "Play", comment: "Verb: start playback")) { model.player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button("Skip Forward 10 Seconds") { model.player.seek(to: min(model.player.duration, model.player.position + 10)) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model.player.current == nil)
            Button("Skip Back 10 Seconds") { model.player.seek(to: max(0, model.player.position - 10)) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(model.player.current == nil)
            Button("Go to Current Album") {
                if let key = model.player.current?.track.albumKey {
                    model.sidebar = .albums
                    model.path = []
                    model.openAlbum(key)
                }
            }
            .keyboardShortcut("j", modifiers: [.command])
            .disabled(model.player.current == nil)
            Divider()
            let current = model.player.current?.track
            Button(model.library.isFavorite(current) ? String(localized: "Remove Current Song from Favorites") : String(localized: "Add Current Song to Favorites")) {
                if let current { model.toggleFavorite([current]) }
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(current == nil)
            Divider()
            Toggle("Shuffle", isOn: Bindable(model.player).shuffle)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Repeat", selection: Bindable(model.player).repeatMode) {
                Text("Off", comment: "Repeat mode").tag(RepeatMode.off)
                Text("All", comment: "Repeat mode").tag(RepeatMode.all)
                Text("One", comment: "Repeat mode").tag(RepeatMode.one)
            }
            Divider()
            Toggle("Exclusive Mode", isOn: Binding(get: { model.settings.exclusiveMode },
                                                   set: { model.settings.exclusiveMode = $0; model.syncEngine() }))
            Divider()
            Button("Loopback Test…") { openWindow(id: "main"); model.showLoopbackTest = true }
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")) { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(model.showQueue && model.queueTab == .upNext ? String(localized: "Hide Up Next") : String(localized: "Show Up Next")) { model.toggleQueue(.upNext) }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Button(model.showQueue && model.queueTab == .history ? String(localized: "Hide History") : String(localized: "Show History")) { model.toggleQueue(.history) }
            Button("Mini Player") { openWindow(id: "mini") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Equalizer") { openWindow(id: "equalizer") }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}
