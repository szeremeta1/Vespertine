//
// Nocturne — a bit-perfect audio player for macOS.
// Copyright © 2026 Nocturne contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneLibrary
import SwiftUI

@main
struct NocturneApp: App {
    @State private var startup = LibraryStartup()
    @State private var updater = AppUpdater()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Nocturne", id: "main") {
            LibraryContent(startup: startup) { model in
                MainWindow()
                    .environment(model)
                    .frame(minWidth: 1080, minHeight: 680)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            if let model = startup.model { NocturneCommands(model: model) }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
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

        MenuBarExtra {
            LibraryContent(startup: startup) { model in
                MenuBarView().environment(model).preferredColorScheme(.dark)
            }
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

struct NocturneCommands: Commands {
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
            Button("Rescan Library") { Task { await model.library.rescanAll() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Enrich Metadata…") { model.enrichAlbumKeys = [] }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Controls") {
            // Space is handled by the main window so it never steals spaces from text fields.
            Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Divider()
            Toggle("Shuffle", isOn: Bindable(model.player).shuffle)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Repeat", selection: Bindable(model.player).repeatMode) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Divider()
            Toggle("Exclusive Mode", isOn: Binding(get: { model.settings.exclusiveMode },
                                                   set: { model.settings.exclusiveMode = $0; model.syncEngine() }))
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Mini Player") { openWindow(id: "mini") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}
