//
// Nocturne — app-wide state: navigation, selection, devices, and wiring between stores.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import CoreAudio
import NocturneAudio
import NocturneLibrary
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case albums, artists, songs, recentlyAdded
    case playlist(Int64)
    case source(Int64)
}

enum DetailRoute: Hashable {
    case album(String)
    case artist(String)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing", details = "Details", analysis = "Analysis"
    var id: String { rawValue }
}

@Observable
@MainActor
final class DeviceStore {
    private(set) var devices: [OutputDevice] = []
    private(set) var hardwareVolume: Float?
    private var monitor: DeviceMonitor?
    var onDevicesChanged: (() -> Void)?

    init() {
        refresh()
        monitor = DeviceMonitor { [weak self] change in
            Task { @MainActor in
                switch change {
                case .devices: self?.refresh(); self?.onDevicesChanged?()
                case .volume: self?.readVolume()
                }
            }
        }
    }

    var dopUIDs: Set<String> = [] { didSet { refresh() } }

    func refresh() {
        devices = OutputDevices.list(dopEnabledUIDs: dopUIDs)
    }

    func device(uid: String?) -> OutputDevice? {
        if let uid, let d = devices.first(where: { $0.uid == uid }) { return d }
        return devices.first(where: \.isDefault) ?? devices.first
    }

    func watchVolume(of device: OutputDevice?) {
        monitor?.watchVolume(of: device?.id)
        volumeDevice = device?.id
        readVolume()
    }

    private var volumeDevice: AudioObjectID?

    private func readVolume() {
        hardwareVolume = volumeDevice.flatMap { DeviceControl.hardwareVolume($0) }
    }

    func setHardwareVolume(_ value: Float) {
        guard let volumeDevice else { return }
        DeviceControl.setHardwareVolume(volumeDevice, value)
        hardwareVolume = value
    }
}

@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    let library: LibraryStore
    let player: PlayerController
    let devices: DeviceStore

    var sidebar: SidebarItem = .albums { didSet { if oldValue != sidebar { path = [] } } }
    var path: [DetailRoute] = []
    var searchText = ""
    var selectedTrackIDs: Set<Int64> = []
    var inspectorTab: InspectorTab = .nowPlaying
    var showInspector = true
    var showImporter = false
    var pendingImportMode: ImportMode = .reference
    var lookupTracks: [Track]?     // MusicBrainz sheet
    var smartEditorPlaylist: Playlist?
    var showFindMusic = false
    /// nil = not shown; [] = whole library; otherwise these albums.
    var enrichAlbumKeys: [String]?

    init() {
        let settings = AppSettings()
        self.settings = settings
        do {
            library = try LibraryStore(dataDirectory: settings.dataDirectory)
        } catch {
            fatalError("Could not open the library at \(settings.dataDirectory.path): \(error)")
        }
        devices = DeviceStore()
        player = PlayerController(library: library, settings: settings)
        devices.dopUIDs = settings.dopDeviceUIDs
        library.setSkipsNonMusic(settings.skipNonMusic)
        devices.onDevicesChanged = { [weak self] in
            self?.player.engine.devicesChanged()
            self?.syncEngine()
        }
        syncEngine()

        // Developer aid: `-NocturneAddSource <folder>` adds and scans a reference source on launch.
        if let path = UserDefaults.standard.string(forKey: "NocturneAddSource") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if !library.sources.contains(where: { $0.path == url.path }) {
                let library = self.library
                Task { await library.addFolders([url], mode: .reference, managedRoot: url) }
            }
        }
        if !UserDefaults.standard.bool(forKey: "NocturneOpenMini") {
            Task { @MainActor [weak self] in self?.runDeveloperHooks(openWindow: nil) }
        }
    }

    private var hooksStarted = false

    /// Launch-argument QA hooks; runs once, from whichever comes first (app start or main window).
    func runDeveloperHooks(openWindow: OpenWindowAction?) {
        guard !hooksStarted else { return }
        hooksStarted = true
        Task { await DeveloperHooks.run(self, openWindow: openWindow) }
    }

    /// The device playback is (or would be) routed to.
    var activeDevice: OutputDevice? {
        player.outputDevice.flatMap { d in devices.devices.first { $0.id == d.id } } ?? devices.device(uid: settings.selectedDeviceUID)
    }

    /// Push preference changes into the engine and device watchers.
    func syncEngine() {
        devices.dopUIDs = settings.dopDeviceUIDs
        let device = devices.device(uid: settings.selectedDeviceUID)
        player.engine.update(settings: settings.engineSettings(deviceHasHardwareVolume: device?.hasHardwareVolume ?? false))
        devices.watchVolume(of: device)
    }

    func selectDevice(_ uid: String?) {
        settings.selectedDeviceUID = uid
        syncEngine()
    }

    var selectedTracks: [Track] { library.tracks(ids: Array(selectedTrackIDs)) }

    func openAlbum(_ key: String) {
        path.append(.album(key))
    }

    func showInFinder(_ tracks: [Track]) {
        NSWorkspace.shared.activateFileViewerSelecting(tracks.map(\.fileURL))
    }

    func presentImporter(_ mode: ImportMode) {
        pendingImportMode = mode
        showImporter = true
    }

    func importFolders(_ urls: [URL]) {
        let mode = pendingImportMode
        let root = URL(fileURLWithPath: settings.managedFolderPath, isDirectory: true)
        Task { await library.addFolders(urls, mode: mode, managedRoot: root) }
    }
}
