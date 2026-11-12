//
// Vespertine: app-wide state: navigation, selection, devices, and wiring between stores.
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
    case albumFamily(String)
    case artist(String)
    case genre(String)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing", details = "Details", analysis = "Analysis"
    var id: String { rawValue }
    /// The tab's name on screen (the raw value is matched by the `-VespertineInspectorTab` QA hook).
    var label: String {
        switch self {
        case .nowPlaying: String(localized: "Now Playing")
        case .details: String(localized: "Details")
        case .analysis: String(localized: "Analysis")
        }
    }
}

enum QueueTab: String, CaseIterable, Identifiable {
    case upNext, history
    var id: String { rawValue }
    var label: String {
        switch self {
        case .upNext: String(localized: "Up Next")
        case .history: String(localized: "History", comment: "Tab beside Up Next: the songs played before, most recent first")
        }
    }
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
        return devices.first(where: \.isDefault) ?? OutputChoice.best(among: devices)
    }

    func watchVolume(of device: OutputDevice?) {
        let id = device?.id
        guard id != volumeDevice || monitor == nil else { return }
        volumeDevice = id
        hardwareRestore = nil
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
        // A level set by hand ends a mute: what Mute remembered is out of date.
        if value > 0 { hardwareRestore = nil }
        hal.async { DeviceControl.setHardwareVolume(id, value) }
    }

    /// The level Mute brings back while the device is muted from the Controls menu (kept for this run only).
    private var hardwareRestore: Float?

    /// Whether the device's volume is down because Mute did it.
    var isHardwareMuted: Bool { hardwareVolume == 0 && hardwareRestore != nil }

    /// Volume Up, Volume Down or Mute on the device's own volume. False when its level isn't known.
    @discardableResult
    func applyHardwareVolume(_ action: VolumeControls.Action) -> Bool {
        guard volumeDevice != nil, let level = hardwareVolume else { return false }
        let next = VolumeControls.apply(action, to: VolumeControls.State(level: Double(level), restoreLevel: hardwareRestore.map(Double.init)))
        setHardwareVolume(Float(next.level))
        hardwareRestore = next.restoreLevel.map(Float.init)
        return true
    }
}

/// Where the first-time transitions note is up: the window the switch was turned on in. (On the main window while
/// Settings was in use, it raised that window over Settings, which seemed to close.)
struct TransitionsNote: Equatable {
    enum Window { case main, settings }
    private(set) var window: Window?

    func isShown(in other: Window) -> Bool { window == other }
    mutating func show(in window: Window) { self.window = window }
    mutating func dismiss() { window = nil }
}

@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    /// The saved speaker groups; nil unless the Settings switch (Speaker Groups (beta)) is on.
    private(set) var speakerGroups: SpeakerGroupsModel?
    /// Mac Sound Output (beta): speaker groups published as outputs of the Mac.
    let systemOutput: SystemOutputModel
    let library: LibraryStore
    let player: PlayerController
    let devices: DeviceStore
    let shares: NetworkShareManager
    let analysis: AnalysisQueue
    let loopback: LoopbackTest
    let visualizer: VisualizerModel

    var sidebar: SidebarItem = .albums { didSet { if oldValue != sidebar { path = []; searchText = "" } } }
    var path: [DetailRoute] = [] { didSet { carryFilter(from: oldValue) } }
    /// Typing a search shows its results (on top of any album or artist page you were on). Cleared here rather than by the
    /// window watching the text, which ran after the change and so also threw away a page opened in the same step.
    var searchText = "" { didSet { if searchText != oldValue { path = [] } } }
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
    /// The Inspector and Up Next share the right side of the window, as lyrics and the queue do in Apple Music:
    /// showing one hides the other, and hiding Up Next brings back the Inspector if it was open before.
    var showInspector = true { didSet { if showInspector, showQueue { showQueue = false } } }
    var showQueue = false {
        didSet {
            guard showQueue != oldValue else { return }
            if showQueue {
                inspectorBeforeQueue = showInspector
                if showInspector { showInspector = false }
            } else if inspectorBeforeQueue, !showInspector {
                inspectorBeforeQueue = false
                showInspector = true
            }
        }
    }
    @ObservationIgnored private var inspectorBeforeQueue = false
    var queueTab: QueueTab = .upNext
    /// Shows Up Next on `tab`, or hides it when it's already showing that tab.
    func toggleQueue(_ tab: QueueTab) {
        if showQueue, queueTab == tab { showQueue = false } else { queueTab = tab; showQueue = true }
    }
    var showImporter = false
    var pendingImportMode: ImportMode = .reference
    var lookupTracks: [Track]?     // MusicBrainz sheet
    var smartEditorPlaylist: Playlist?
    var showFindMusic = false
    var showConnectServer = false
    /// The Remove Missing Songs… confirmation (an alert on the main window while non-nil): what removing would take.
    var missingSongsPrompt: MissingSongsPrompt?
    var showLoopbackTest = false
    /// The note shown the first time transitions are turned on, and the window it's shown in.
    var transitionsNote = TransitionsNote()
    /// What a playlist import did, shown in an alert until dismissed.
    var playlistReport: String?
    /// Address to pre-fill in Connect to Server (e.g. to enter a password for an existing share).
    var connectPrefill: String?
    /// Tracks to export for Spatial Audio (sheet shown while non-nil).
    var spatialExportTracks: [Track]?
    /// nil = not shown; [] = whole library; otherwise these albums.
    var enrichAlbumKeys: [String]?
    /// First-run setup, in the main window in place of the library.
    var showSetup = false

    init(dataDirectory: URL? = nil) throws {
        let settings = AppSettings(dataDirectory: dataDirectory)
        self.settings = settings
        let arguments = LaunchArguments()
        let isolated = arguments.string(forKey: "VespertineDataDirectory") != nil && !arguments.bool(forKey: "VespertinePersistFilters")
        filtersURL = isolated ? nil : FilterStore.url(in: settings.dataDirectory)
        systemOutput = SystemOutputModel(isolated: arguments.string(forKey: "VespertineDataDirectory") != nil)
        if let filtersURL { filters = FilterStore.load(from: filtersURL) }
        library = try LibraryStore(dataDirectory: settings.dataDirectory, automaticScanning: { [weak settings] in settings?.watchFolders ?? false })
        showSetup = Self.needsSetup(settings: settings, library: library, arguments: arguments)
        devices = DeviceStore()
        loopback = LoopbackTest(dataDirectory: settings.dataDirectory)
        shares = NetworkShareManager(library: library, settings: settings)
        // If Vespertine last ended while relaying the volume keys, put the sound output and alert volume back before
        // the relay can take them as they are.
        DeviceRestore.afterCrash()
        player = PlayerController(library: library, settings: settings, shares: shares)
        visualizer = VisualizerModel(engine: player.engine)
        analysis = AnalysisQueue(library: library, settings: settings, shares: shares)
        let streaming: @MainActor () -> Bool = { [weak player = self.player, weak shares = self.shares] in
            // Playing from a share, or just asked to (still loading): the network belongs to playback.
            guard let player, let shares, let track = player.current?.track, shares.isNetwork(track) else { return false }
            return player.state == .playing || (player.state != .paused && Date().timeIntervalSince(player.trackStartedAt) < 20)
        }
        shares.isStreamingPlayback = streaming
        analysis.playbackShareClaim = { [weak player = self.player, weak shares = self.shares] in
            // A song with a complete local copy reads from disk: the network is free for analysis.
            guard let player, let shares, let track = player.current?.track, shares.isNetwork(track),
                  !shares.cache.isAvailable(track) else { return .idle }
            let starting = Date().timeIntervalSince(player.trackStartedAt) < 15
            if player.state == .playing {
                // The buffer's own signal, shared with the network cache: under a third full (or holding for more)
                // until it's back over two thirds.
                return starting || shares.cache.yieldsToPlayback ? .all : .streaming
            }
            return player.state != .paused && starting ? .all : .idle
        }
        analysis.onServerStatus = { [weak shares = self.shares] id, status in
            Task { await shares?.serverReported(status, for: id) }
        }
        devices.dopUIDs = settings.effectiveDoPUIDs
        library.setSkipsNonMusic(settings.skipNonMusic)
        devices.onDevicesChanged = { [weak self] in
            self?.speakerGroups?.followUSBPorts(amongUIDs: self?.devices.devices.map(\.uid) ?? [])
            self?.followChosenOutput()
            self?.player.engine.devicesChanged()
            self?.syncEngine()
        }
        followChosenOutput()
        player.wantsMultichannel = { [weak self] in self?.outputWantsMultichannel() }
        // Which groups are published decides how long a pause keeps one from the other apps.
        systemOutput.onPublishedChanged = { [weak self] in self?.syncEngine() }
        library.bundlesCopiesByDefault = settings.bundleCopies
        if settings.speakerGroupsFeature {
            speakerGroups = SpeakerGroupsSwitch.apply(true, to: settings, current: nil, onChange: groupsChanged)
            speakerGroups?.followUSBPorts(amongUIDs: devices.devices.map(\.uid))
        }
        syncEngine()
        shares.start()
        analysis.start()
        // Hand the DAC back when Vespertine quits: stop, release exclusive access, then restore or
        // standardize its format as chosen in Settings. Core Audio decides how long that takes (a device that won't
        // switch rate can hold it for many seconds), so it runs off the main thread and quitting waits for it only
        // within QuitSequence's budget.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let relay = self.player.volumeRelay, engine = self.player.engine
                let discord = self.player.discord.shutdownStep()
                let onQuit = self.settings.deviceOnQuit
                QuitSequence.run(steps: [
                    { relay.stop() },
                    discord,
                    { engine.stopAndWait() },
                    { DeviceRestore.finish(onQuit) },
                ])
            }
        }
        library.onTracksMoved = { [weak self] moves in self?.player.tracksMoved(moves) }
        shares.onSourceRelinked = { [weak self] id in self?.player.sourceRelinked(id) }
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
        if let path = LaunchArguments().string(forKey: "VespertineAddSource") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if !library.sources.contains(where: { $0.path == url.path }) {
                let library = self.library
                Task { await library.addFolders([url], mode: .reference, managedRoot: url) }
            }
        }
        // Hooks that open another window wait for the main window, which can open it.
        if !LaunchArguments().bool(forKey: "VespertineOpenMini") && LaunchArguments().string(forKey: "VespertineOpenWindow") == nil {
            Task { @MainActor [weak self] in self?.runDeveloperHooks(openWindow: nil) }
        }
    }

    /// Setup shows until it's been finished once. A library that already has music (from before setup existed) counts
    /// as set up. Test libraries (`-VespertineDataDirectory`) skip it, so screenshots open on the library, unless
    /// `-VespertineSetup auto` (first-run rules) or `-VespertineSetup show` (always) asks for it.
    private static func needsSetup(settings: AppSettings, library: LibraryStore, arguments: LaunchArguments) -> Bool {
        switch arguments.string(forKey: "VespertineSetup") {
        case "show": return true
        case "auto": break
        default: if arguments.string(forKey: "VespertineDataDirectory") != nil { return false }
        }
        guard !settings.setupCompleted else { return false }
        if !((try? library.database.sources()) ?? []).isEmpty {
            settings.setupCompleted = true
            return false
        }
        return true
    }

    func completeSetup() {
        settings.setupCompleted = true
        showSetup = false
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
        player.outputDevice.flatMap { d in devices.devices.first { $0.id == d.id } } ?? plannedDevice
    }

    /// Whether the equalizer is in the signal for what is playing: bypassed (with the reason) on native DSD over DoP,
    /// bitstreams and macOS-rendered Atmos, active otherwise. The Equalizer window and the signal path read this.
    var equalizerStatus: EqualizerStatus {
        EqualizerStatus(path: player.signalPath, systemRendering: player.systemRendering)
    }

    /// Where the next song would play: the chosen output, or while it isn't connected, the one that stands in for it
    /// (Settings → Playback; nil when set to wait for it, and while playback waits for one that dropped out mid-song).
    var plannedDevice: OutputDevice? {
        guard let uid = settings.selectedDeviceUID else {
            // Following the Mac's sound output while it is a group published with Mac Sound Output: that group plays.
            if !devices.devices.contains(where: \.isDefault), let groups = speakerGroups?.groups,
               let group = SystemOutput.defaultOutputGroup(among: groups) { return groupOutput(group) }
            return devices.device(uid: nil)
        }
        // A speaker group is chosen like an output: it is ready when all of its outputs are connected.
        if let group = chosenGroup { return groupOutput(group) }
        if let chosen = devices.devices.first(where: { $0.uid == uid }) { return chosen }
        guard player.waitingForDevice == nil else { return nil }
        return OutputChoice.substitute(among: devices.devices, fallback: settings.outputFallback)
    }

    /// The chosen output's name while it isn't connected.
    var missingChosenOutput: String? {
        if let group = chosenGroup { return groupOutput(group) == nil ? group.name : nil }
        guard let uid = settings.selectedDeviceUID, !devices.devices.contains(where: { $0.uid == uid }) else { return nil }
        return settings.selectedDevice.flatMap { $0.uid == uid ? $0.name : nil } ?? String(localized: "The selected output", comment: "Stands in for a device's name at the start of a sentence, e.g. “… didn’t come back.”")
    }

    /// The speaker group chosen as the output, when the feature is on and one is.
    var chosenGroup: SpeakerGroup? {
        guard let uid = settings.selectedDeviceUID else { return nil }
        return speakerGroups?.groups.first { $0.outputUID == uid }
    }

    /// The speaker group whose output is `device`, when the feature is on.
    func group(for device: OutputDevice) -> SpeakerGroup? {
        speakerGroups?.groups.first { $0.outputUID == device.uid }
    }

    /// Keeps every group's drawn room profile (once one has been made) up to date with the drawing, so a speaker moved in the editor is
    /// heard and checked with the next play. Writes the library only when a profile changed.
    private func followDrawings() {
        guard let groups = speakerGroups?.groups else { return }
        var book = settings.roomBook
        var changed = false
        for group in groups where GroupRoomProfile.syncDrawing(of: group, in: &book) { changed = true }
        if changed { settings.roomBook = book }
    }

    /// "Use the drawing" for `group`: its room profile is made (or brought up to date), the group bound to it and the output switched
    /// to play with it. False when the group has no drawing to make a profile of.
    @discardableResult
    func useDrawing(of group: SpeakerGroup) -> Bool {
        var book = settings.roomBook
        guard let bound = GroupRoomProfile.useDrawing(for: group, in: &book) else { return false }
        settings.roomBook = book
        speakerGroups?.upsert(bound)
        return true
    }

    /// The output a group presents while all of its members are connected.
    private func groupOutput(_ group: SpeakerGroup) -> OutputDevice? {
        if case .ready(let output, _) = GroupOutput.resolve(group, among: devices.devices) { return output }
        return nil
    }

    /// Keeps the chosen output chosen: remembers what it is while it's connected, and when it comes back under
    /// another UID (some USB DACs get a new one in another port), picks it again with its settings.
    private func followChosenOutput() {
        guard let uid = settings.selectedDeviceUID else { return }
        if let device = devices.devices.first(where: { $0.uid == uid }) {
            let identity = OutputIdentity(device)
            if settings.selectedDevice != identity { settings.selectedDevice = identity }
        } else if let remembered = settings.selectedDevice, remembered.uid == uid,
                  let device = OutputChoice.sameOutput(as: remembered, among: devices.devices) {
            settings.moveDeviceSettings(from: uid, to: device.uid)
            settings.selectedDeviceUID = device.uid
            settings.selectedDevice = OutputIdentity(device)
        }
    }

    /// A change to the saved speaker groups: the drawings are followed and the engine hears of them.
    private var groupsChanged: () -> Void {
        { [weak self] in
            self?.followDrawings()
            self?.syncEngine()
        }
    }

    /// The Settings switch that brings speaker groups into the app (or removes them), without a restart. Turning it off while a
    /// group is the chosen output lets go of that output (the system's default plays) before the groups go; the saved groups stay in
    /// their file for the next time it is on.
    func setSpeakerGroupsFeature(_ on: Bool) {
        if !SpeakerGroupsSwitch.keepsOutput(settings.selectedDeviceUID, turningOnTo: on, groups: speakerGroups?.groups ?? []) {
            settings.selectedDeviceUID = nil
            settings.selectedDevice = nil
        }
        speakerGroups = SpeakerGroupsSwitch.apply(on, to: settings, current: speakerGroups, onChange: groupsChanged)
        if on { speakerGroups?.followUSBPorts(amongUIDs: devices.devices.map(\.uid)) }
        syncEngine()
    }

    /// The transitions master switch (Controls › Transitions, ⌥⌘X, the transport bar, Up Next). It applies from the next
    /// boundary (one already mixed is taken back while it can be). The first time it's turned on, a note says what it changes.
    func setTransitions(_ on: Bool) {
        guard settings.transitionsFeature else { return }
        if settings.transitions.setEnabled(on) { transitionsNote.show(in: .main) }
        syncEngine()
    }

    func toggleTransitions() { setTransitions(!settings.transitions.enabled) }

    /// The Settings switch that brings transitions into the app (or removes them). Turning it on starts them on, with
    /// the note; turning it off puts the playback switch away too and the engine gets today's settings.
    func setTransitionsFeature(_ on: Bool) {
        settings.transitionsFeature = on
        if on {
            if settings.transitions.setEnabled(true) { transitionsNote.show(in: .settings) }
        } else {
            _ = settings.transitions.setEnabled(false)
            transitionsNote.dismiss()
        }
        syncEngine()
    }

    /// Counts the times a volume command found an output with no volume to move; the volume control in the transport bar opens
    /// its note on each one.
    private(set) var volumeNoteRequests = 0

    /// What Volume Up, Volume Down and Mute move for the output that is playing (or would): its own volume when Core Audio exposes
    /// one, else Vespertine's volume for it when it uses that, else nothing.
    var volumeRoute: VolumeControls.Route {
        guard let device = activeDevice else { return .fixed }
        return VolumeControls.route(for: device, usesAppVolume: settings.usesAppVolume(device.uid), hardwareLevelKnown: devices.hardwareVolume != nil)
    }

    /// Whether the volume is down because Mute did it, for the menu's wording.
    var isVolumeMuted: Bool {
        switch volumeRoute {
        case .software: activeDevice.map { settings.isMuted($0.uid) } ?? false
        case .hardware: devices.isHardwareMuted
        case .fixed: false
        }
    }

    /// Controls › Volume Up, Volume Down, Mute. Only the output Vespertine plays to: never the Mac's sound output.
    func adjustVolume(_ action: VolumeControls.Action) {
        guard let device = activeDevice else { return }
        switch volumeRoute {
        case .software:
            settings.applyVolume(action, for: device.uid)
            syncEngine()
        case .hardware:
            devices.applyHardwareVolume(action)
        case .fixed:
            volumeNoteRequests += 1
        }
    }

    /// Push preference changes into the engine and device watchers.
    func syncEngine() {
        devices.dopUIDs = settings.effectiveDoPUIDs
        let device = plannedDevice
        var engineSettings = settings.engineSettings(groups: speakerGroups?.groups ?? [])
        engineSettings.systemOutputGroupIDs = Set(engineSettings.speakerGroups.map(\.id).filter { systemOutput.choice(for: $0).published })
        player.engine.update(settings: engineSettings)
        systemOutput.sync(groups: engineSettings.speakerGroups, settings: engineSettings)
        devices.watchVolume(of: device)
        player.resolveVersions()
    }

    /// What an album plays: its chosen copy, else the best copy for the output; with its copies bundled, each song once
    /// (the player picks each song's copy for the output as it queues it).
    func playableTracks(albumKey: String) -> [Track] {
        let copies = library.albumCopies(albumKey: albumKey)
        guard copies.copies.count > 1 else { return copies.copies.first?.tracks ?? library.tracks(albumKey: albumKey) }
        let wanted = outputWantsMultichannel() ?? true
        if let copy = copies.selected(library.copyChoice(albumKey: albumKey), multichannel: wanted, isLocal: { [shares] in !$0.tracks.contains(where: shares.isNetwork) }) {
            return copy.tracks
        }
        return copies.songs.map { song in
            TrackVersions.choose(song.tracks, multichannel: wanted, isLocal: { [shares] in !shares.isNetwork($0) },
                                 isPreferred: library.isPreferredCopy) ?? song.lead
        }
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
        guard let device = plannedDevice else { return nil }
        let caps = device.capabilities
        return caps.outputChannels > 2 || (caps.speakerLayoutChannels ?? 0) >= 3 || engineSpatialMode(for: device) != .off
    }

    /// The Spatial Audio mode multichannel music gets on `device` (its setting, or the default).
    func engineSpatialMode(for device: OutputDevice) -> SpatialMode {
        settings.engineSettings().spatialMode(for: device)
    }

    struct MissingSongsPrompt: Identifiable {
        let id = UUID()
        let summary: MissingSongsSummary
    }

    /// Remove Missing Songs…: counts the songs whose files are gone and asks before removing them.
    func askToRemoveMissingSongs() {
        Task { missingSongsPrompt = MissingSongsPrompt(summary: await library.missingSongsSummary()) }
    }

    func selectDevice(_ uid: String?) {
        settings.selectedDeviceUID = uid
        settings.selectedDevice = uid.flatMap { uid in devices.devices.first { $0.uid == uid } }.map { OutputIdentity($0) }
            ?? (uid == settings.selectedDevice?.uid ? settings.selectedDevice : nil)
        syncEngine()
    }

    var selectedTracks: [Track] { library.tracks(ids: Array(selectedTrackIDs)) }

    /// Adds songs to Favorites, or removes them when every one already is a favorite. A favorite is the copy hearted
    /// (the 24/96 vinyl transfer, not the 24/192 download beside it); where an album's copies are bundled, a song is
    /// all its copies: favoriting its stereo copy on headphones favorites its 5.1 one too. Undoable in the
    /// window you're in (⌘Z brings back a heart clicked by mistake); SwiftUI's own undo manager is nil in
    /// these windows, so it's the AppKit window's.
    func toggleFavorite(_ tracks: [Track]) {
        guard tracks.contains(where: { $0.id != nil }) else { return }
        let favorite = !tracks.filter { $0.id != nil }.allSatisfy(library.isFavorite)
        let ids = Array(Set(library.playbackVersions(of: tracks).flatMap { $0 }.compactMap(\.id) + tracks.compactMap(\.id)))
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
        undoManager.setActionName(favorite ? String(localized: "Add to Favorites") : String(localized: "Remove from Favorites"))
    }

    /// A song's cover, or its album's when the song carries none of its own (an album where only some files have
    /// embedded art, or art from a folder image), so Now Playing matches the album page.
    func artworkKey(_ track: Track?) -> String? {
        guard let track else { return nil }
        return track.artworkKey ?? library.album(key: track.albumKey)?.artworkKey
    }

    func openAlbum(_ key: String) {
        if let family = AlbumFamilies.group(library.albums).first(where: { $0.contains(key) }), family.editions.count > 1 {
            openAlbumFamily(key)
        } else {
            path.append(.album(key))
        }
    }

    /// Shows a song's album from anywhere (Up Next, History, the transport).
    func goToAlbum(of track: Track) {
        sidebar = .albums
        path = []
        openAlbum(track.albumKey)
    }

    func openAlbumFamily(_ memberKey: String) {
        path.append(.albumFamily(memberKey))
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
        let path = url.resolvingSymlinksInPath().path
        // Already in the library: play it now. Adding it would rescan the whole source it sits in first.
        let known = library.tracks(filePath: path)
        if !known.isEmpty { player.play(known); return }
        Task {
            await library.addFolders([url], mode: .reference, managedRoot: url.deletingLastPathComponent())
            let tracks = library.tracks(filePath: path)
            if !tracks.isEmpty { player.play(tracks) }
        }
    }

    func importFolders(_ urls: [URL]) {
        let mode = pendingImportMode
        let root = URL(fileURLWithPath: settings.managedFolderPath, isDirectory: true)
        Task { await library.addFolders(urls, mode: mode, managedRoot: root) }
    }
}
