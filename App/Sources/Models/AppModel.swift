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
    case albums, artists, songs, genres, recentlyAdded
    case playlist(Int64)
    case source(Int64)
}

enum DetailRoute: Hashable {
    case album(String)
    case artist(String)
    case genre(String)
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
    let shares: NetworkShareManager
    let analysis: AnalysisQueue

    var sidebar: SidebarItem = .albums { didSet { if oldValue != sidebar { path = []; searchText = "" } } }
    var path: [DetailRoute] = []
    var searchText = ""
    var selectedTrackIDs: Set<Int64> = [] { didSet { if selectedTrackIDs != oldValue { selectionChangedAt = .now } } }
    /// When the selection last changed; the Analysis tab shows whichever changed last, selection or playback.
    private(set) var selectionChangedAt: Date = .distantPast
    var inspectorTab: InspectorTab = .nowPlaying
    var showInspector = true
    var showImporter = false
    var pendingImportMode: ImportMode = .reference
    var lookupTracks: [Track]?     // MusicBrainz sheet
    var smartEditorPlaylist: Playlist?
    var showFindMusic = false
    var showConnectServer = false
    /// Tracks to export for Spatial Audio (sheet shown while non-nil).
    var spatialExportTracks: [Track]?
    /// nil = not shown; [] = whole library; otherwise these albums.
    var enrichAlbumKeys: [String]?

    init(dataDirectory: URL? = nil) throws {
        let settings = AppSettings(dataDirectory: dataDirectory)
        self.settings = settings
        library = try LibraryStore(dataDirectory: settings.dataDirectory)
        devices = DeviceStore()
        shares = NetworkShareManager(library: library, settings: settings)
        player = PlayerController(library: library, settings: settings, shares: shares)
        analysis = AnalysisQueue(library: library, settings: settings, shares: shares)
        analysis.isStreamingPlayback = { [weak player = self.player, weak shares = self.shares] in
            // Playing from a share, or just asked to (still loading): the network belongs to playback.
            guard let player, let shares, let track = player.current?.track, shares.isNetwork(track) else { return false }
            return player.state == .playing || (player.state != .paused && Date().timeIntervalSince(player.trackStartedAt) < 20)
        }
        devices.dopUIDs = settings.dopDeviceUIDs
        library.setSkipsNonMusic(settings.skipNonMusic)
        devices.onDevicesChanged = { [weak self] in
            self?.player.engine.devicesChanged()
            self?.syncEngine()
        }
        syncEngine()
        shares.start()
        analysis.start()
        // Hand the DAC back when Nocturne quits: stop, release exclusive access, then restore or
        // standardize its format as chosen in Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.engine.stopAndWait()
                DeviceRestore.finish(self.settings.deviceOnQuit)
            }
        }
        library.onScanFinished = { [weak self] in
            guard let self, self.settings.autoAnalyze else { return }
            self.analysis.analyzeLibrary()
        }
        if settings.autoAnalyze {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                // Server results first, so nothing the server already analyzed is read over the network.
                await self?.analysis.syncServerResults()
                self?.analysis.analyzeLibrary()
            }
        }

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

    /// The Spatial Audio mode multichannel music gets on `device` (its setting, or the default).
    func engineSpatialMode(for device: OutputDevice) -> SpatialMode {
        settings.engineSettings(deviceHasHardwareVolume: device.hasHardwareVolume).spatialMode(for: device)
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

    func openAudio(_ url: URL) {
        guard url.isFileURL else { return }
        Task {
            await library.addFolders([url], mode: .reference, managedRoot: url.deletingLastPathComponent())
            let path = url.resolvingSymlinksInPath().path
            let tracks = library.allTracks().filter { $0.filePath == path }
            if !tracks.isEmpty { player.play(tracks) }
        }
    }

    func importFolders(_ urls: [URL]) {
        let mode = pendingImportMode
        let root = URL(fileURLWithPath: settings.managedFolderPath, isDirectory: true)
        Task { await library.addFolders(urls, mode: mode, managedRoot: root) }
    }
}
