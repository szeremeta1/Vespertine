//
// Vespertine — app-wide state: navigation, selection, devices, and wiring between stores.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import CoreAudio
import VespertineAudio
import VespertineLibrary
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case albums, artists, songs, genres, recentlyAdded, favorites
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

/// Output devices and the chosen one's hardware volume.
///
/// Core Audio calls never run on the main thread (after the first read at launch): while a device switches rate or
/// is taken exclusively, and whenever coreaudiod is slow, HAL property reads wait on its locks for seconds. Reading
/// every device's formats on the main thread at each change (macOS reports one every time exclusive access moves
/// the Mac's default output) froze the window at the start of a song. Reads go to a serial queue, bursts of change
/// notices collapse into one read, and the result is published on the main thread.
@Observable
@MainActor
final class DeviceStore {
    private(set) var devices: [OutputDevice] = []
    private(set) var hardwareVolume: Float?
    private var monitor: DeviceMonitor?
    /// Called on the main thread once a changed device list has been read.
    var onDevicesChanged: (() -> Void)?

    /// All HAL work of this store, in order.
    nonisolated private let hal = DispatchQueue(label: "org.szeremeta.vespertine.device-store", qos: .userInitiated)
    private var refreshQueued = false
    private var refreshAgain = false
    private var volumeDevice: AudioObjectID?

    init() {
        devices = OutputDevices.list() // at launch, before anything plays: the HAL is idle
        monitor = DeviceMonitor { [weak self] change in
            Task { @MainActor in
                switch change {
                case .devices: self?.refresh(notify: true)
                case .volume: self?.readVolume()
                }
            }
        }
    }

    var dopUIDs: Set<String> = [] { didSet { if dopUIDs != oldValue { refresh() } } }

    /// Reads the device list off the main thread. Requests that arrive while a read is under way cause exactly one
    /// more read, so a burst of change notices costs at most two.
    func refresh(notify: Bool = false) {
        pendingNotify = pendingNotify || notify
        guard !refreshQueued else { refreshAgain = true; return }
        refreshQueued = true
        let dop = dopUIDs
        hal.async { [weak self] in
            let list = OutputDevices.list(dopEnabledUIDs: dop)
            Task { @MainActor in self?.finishRefresh(list) }
        }
    }

    private var pendingNotify = false

    private func finishRefresh(_ list: [OutputDevice]) {
        refreshQueued = false
        if devices != list { devices = list }
        if refreshAgain {
            refreshAgain = false
            refresh()
            return
        }
        if pendingNotify {
            pendingNotify = false
            onDevicesChanged?()
        }
    }

    func device(uid: String?) -> OutputDevice? {
        if let uid, let d = devices.first(where: { $0.uid == uid }) { return d }
        return devices.first(where: \.isDefault) ?? devices.first
    }

    func watchVolume(of device: OutputDevice?) {
        let id = device?.id
        guard id != volumeDevice || monitor == nil else { return }
        volumeDevice = id
        let monitor = self.monitor
        hal.async { monitor?.watchVolume(of: id) }
        readVolume()
    }

    private func readVolume() {
        guard let id = volumeDevice else { hardwareVolume = nil; return }
        hal.async { [weak self] in
            let value = DeviceControl.hardwareVolume(id)
            Task { @MainActor in
                guard let self, self.volumeDevice == id else { return }
                self.hardwareVolume = value
            }
        }
    }

    /// Shows the new value at once; the device is set in order on the HAL queue.
    func setHardwareVolume(_ value: Float) {
        guard let id = volumeDevice else { return }
        hardwareVolume = value
        hal.async { DeviceControl.setHardwareVolume(id, value) }
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
    var path: [DetailRoute] = [] { didSet { carryFilter(from: oldValue) } }
    var searchText = ""
    /// Each page's filter (see Browsing.swift). The sidebar's pages keep theirs across launches.
    var filters: [FilterScope: LibraryFilter] = [:] { didSet { if filters != oldValue { saveFilters() } } }
    /// Where filters are saved; nil for QA runs on a test library (`-VespertineDataDirectory`), so screenshots
    /// always start from the filters their launch arguments set (`-VespertinePersistFilters YES` keeps them).
    @ObservationIgnored private let filtersURL: URL?
    @ObservationIgnored private var filterSave: Task<Void, Never>?

    private func saveFilters() {
        guard let filtersURL else { return }
        filterSave?.cancel()
        filterSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            FilterStore.save(self.filters, to: filtersURL)
        }
    }
    /// Asks the filter bar of a page to open its panel (on a facet, when given).
    var filterPanelRequest: FilterPanelRequest?
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
    /// Address to pre-fill in Connect to Server (e.g. to enter a password for an existing share).
    var connectPrefill: String?
    /// Tracks to export for Spatial Audio (sheet shown while non-nil).
    var spatialExportTracks: [Track]?
    /// nil = not shown; [] = whole library; otherwise these albums.
    var enrichAlbumKeys: [String]?

    init(dataDirectory: URL? = nil) throws {
        let settings = AppSettings(dataDirectory: dataDirectory)
        self.settings = settings
        let defaults = UserDefaults.standard
        let isolated = defaults.string(forKey: "VespertineDataDirectory") != nil && !defaults.bool(forKey: "VespertinePersistFilters")
        filtersURL = isolated ? nil : FilterStore.url(in: settings.dataDirectory)
        if let filtersURL { filters = FilterStore.load(from: filtersURL) }
        library = try LibraryStore(dataDirectory: settings.dataDirectory)
        devices = DeviceStore()
        shares = NetworkShareManager(library: library, settings: settings)
        player = PlayerController(library: library, settings: settings, shares: shares)
        analysis = AnalysisQueue(library: library, settings: settings, shares: shares)
        let streaming: @MainActor () -> Bool = { [weak player = self.player, weak shares = self.shares] in
            // Playing from a share, or just asked to (still loading): the network belongs to playback.
            guard let player, let shares, let track = player.current?.track, shares.isNetwork(track) else { return false }
            return player.state == .playing || (player.state != .paused && Date().timeIntervalSince(player.trackStartedAt) < 20)
        }
        analysis.isStreamingPlayback = streaming
        shares.isStreamingPlayback = streaming
        analysis.onServerStatus = { [weak shares = self.shares] id, status in
            Task { await shares?.serverReported(status, for: id) }
        }
        devices.dopUIDs = settings.dopDeviceUIDs
        library.setSkipsNonMusic(settings.skipNonMusic)
        devices.onDevicesChanged = { [weak self] in
            self?.player.engine.devicesChanged()
            self?.syncEngine()
        }
        player.wantsMultichannel = { [weak self] in self?.outputWantsMultichannel() }
        syncEngine()
        shares.start()
        analysis.start()
        // Hand the DAC back when Vespertine quits: stop, release exclusive access, then restore or
        // standardize its format as chosen in Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.volumeRelay.stop()
                self.player.engine.stopAndWait()
                DeviceRestore.finish(self.settings.deviceOnQuit)
            }
        }
        library.onTracksMoved = { [weak self] moves in self?.player.tracksMoved(moves) }
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

        // Developer aid: `-VespertineAddSource <folder>` adds and scans a reference source on launch.
        if let path = UserDefaults.standard.string(forKey: "VespertineAddSource") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if !library.sources.contains(where: { $0.path == url.path }) {
                let library = self.library
                Task { await library.addFolders([url], mode: .reference, managedRoot: url) }
            }
        }
        if !UserDefaults.standard.bool(forKey: "VespertineOpenMini") {
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
        player.engine.update(settings: settings.engineSettings())
        devices.watchVolume(of: device)
        player.resolveVersions()
    }

    /// Whether songs with a stereo and a multichannel version should play the multichannel one: on an output
    /// with more than two channels (an interface, a receiver's speaker layout) or with Spatial Audio on
    /// (AirPods, Beats). nil while the chosen output is missing (reconnecting AirPods): keep what's queued.
    func outputWantsMultichannel() -> Bool? {
        switch settings.versionPreference {
        case .stereo: return false
        case .multichannel: return true
        case .matchOutput: break
        }
        let device: OutputDevice? = if let uid = settings.selectedDeviceUID { devices.devices.first { $0.uid == uid } }
                                    else { devices.device(uid: nil) }
        guard let device else { return nil }
        let caps = device.capabilities
        return caps.outputChannels > 2 || (caps.speakerLayoutChannels ?? 0) >= 3 || engineSpatialMode(for: device) != .off
    }

    /// The Spatial Audio mode multichannel music gets on `device` (its setting, or the default).
    func engineSpatialMode(for device: OutputDevice) -> SpatialMode {
        settings.engineSettings().spatialMode(for: device)
    }

    func selectDevice(_ uid: String?) {
        settings.selectedDeviceUID = uid
        syncEngine()
    }

    var selectedTracks: [Track] { library.tracks(ids: Array(selectedTrackIDs)) }

    /// Adds songs to Favorites, or removes them when every one already is a favorite. Undoable in the
    /// window you're in (⌘Z brings back a heart clicked by mistake); SwiftUI's own undo manager is nil in
    /// these windows, so it's the AppKit window's.
    func toggleFavorite(_ tracks: [Track]) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let favorite = !ids.allSatisfy(library.favoriteIDs.contains)
        // Only the songs that change, so undo restores exactly what was there.
        let changed = ids.filter { library.favoriteIDs.contains($0) != favorite }
        setFavorite(favorite, trackIDs: changed, undoManager: NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager)
    }

    private func setFavorite(_ favorite: Bool, trackIDs: [Int64], undoManager: UndoManager?) {
        library.setFavorite(favorite, trackIDs: trackIDs)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setFavorite(!favorite, trackIDs: trackIDs, undoManager: undoManager) }
        }
        undoManager.setActionName(favorite ? "Add to Favorites" : "Remove from Favorites")
    }

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
