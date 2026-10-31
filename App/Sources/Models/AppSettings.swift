//
// Vespertine — user preferences (UserDefaults-backed).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary
import VespertineVisualizer
import Observation

enum ReplayGainMode: String, CaseIterable, Identifiable {
    case off, track, album
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: String(localized: "Off", comment: "ReplayGain mode: no volume adjustment.")
        case .track: String(localized: "Track", comment: "ReplayGain mode: adjust each song by its own gain.")
        case .album: String(localized: "Album", comment: "ReplayGain mode: adjust songs by their album's gain.")
        }
    }
}

/// Stored per device: "match", "max" or "fixed:96000".
enum RateChoice: Hashable, Identifiable {
    case match, maximum, fixed(Double)
    var id: String { code }

    var code: String {
        switch self { case .match: "match"; case .maximum: "max"; case .fixed(let r): "fixed:\(Int(r))" }
    }

    init(code: String) {
        if code == "max" { self = .maximum }
        else if code.hasPrefix("fixed:"), let r = Double(code.dropFirst(6)), r.isFinite, r >= 8000, r <= 3_072_000 { self = .fixed(r) }
        else { self = .match }
    }

    var policy: RatePolicy {
        switch self { case .match: .matchSource; case .maximum: .maximum; case .fixed(let r): .fixed(r) }
    }

    var label: String {
        switch self {
        case .match: String(localized: "Match source", comment: "Output sample rate choice: the song's own rate.")
        case .maximum: String(localized: "Device maximum", comment: "Output sample rate choice: the highest rate the device takes.")
        case .fixed(let r):
            String(localized: "Fixed \((r / 1000).formatted(.number.grouping(.never).precision(.fractionLength(0...1)))) kHz",
                   comment: "Output sample rate choice: always this rate, e.g. Fixed 96 kHz.")
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    private let defaults: UserDefaults

    var exclusiveMode: Bool { didSet { defaults.set(exclusiveMode, forKey: "exclusiveMode") } }
    /// Integer mode (exclusive access only): PCM needing no processing goes to the DAC as 32-bit integers.
    var integerMode: Bool { didSet { defaults.set(integerMode, forKey: "integerMode") } }
    /// "Match 16-bit sources" (exclusive access only): 16-bit files go to a DAC's own 16-bit mode where it has one.
    var matchSixteenBit: Bool { didSet { defaults.set(matchSixteenBit, forKey: "matchSixteenBit") } }
    /// Dolby Atmos: rendered by macOS (objects), or its channel bed played through Vespertine.
    var atmosBySystem: Bool { didSet { defaults.set(atmosBySystem, forKey: "atmosBySystem") } }
    /// Songs with a stereo and a multichannel version: which to play.
    var versionPreference: TrackVersions.Preference { didSet { defaults.set(versionPreference.rawValue, forKey: "versionPreference") } }
    var releaseAfterPause: Double { didSet { defaults.set(releaseAfterPause, forKey: "releaseAfterPause") } }
    var selectedDeviceUID: String? { didSet { defaults.set(selectedDeviceUID, forKey: "selectedDeviceUID") } }
    /// The chosen output as last seen, to name it while it's unplugged and find it again under a new UID.
    var selectedDevice: OutputIdentity? { didSet { defaults.set(try? JSONEncoder().encode(selectedDevice), forKey: "selectedDevice") } }
    /// What plays while the chosen output isn't connected.
    var outputFallback: OutputFallback { didSet { defaults.set(outputFallback.rawValue, forKey: "outputFallback") } }
    /// Explicit ons plus connected known DACs not turned off: what the engine and device list use.
    var effectiveDoPUIDs: Set<String> {
        DoPDefaults.resolve(on: dopDeviceUIDs, off: dopOffDeviceUIDs, connected: OutputDevices.connectedUIDs())
    }
    var dopDeviceUIDs: Set<String> { didSet { defaults.set(Array(dopDeviceUIDs), forKey: "dopDeviceUIDs") } }
    /// DACs known to take DoP (`DoPDefaults`) start with it on; a device turned off here stays off.
    var dopOffDeviceUIDs: Set<String> { didSet { defaults.set(Array(dopOffDeviceUIDs), forKey: "dopOffDeviceUIDs") } }
    /// Outputs with an AV receiver: Dolby and DTS are sent to them untouched.
    var bitstreamDeviceUIDs: Set<String> { didSet { defaults.set(Array(bitstreamDeviceUIDs), forKey: "bitstreamDeviceUIDs") } }
    /// Spatial Audio for multichannel music, per device (unset = head tracked on AirPods/Beats, off elsewhere).
    var spatialModes: [String: String] { didSet { defaults.set(spatialModes, forKey: "spatialModes") } }
    var rateChoices: [String: String] { didSet { defaults.set(rateChoices, forKey: "rateChoices") } }
    var replayGain: ReplayGainMode { didSet { defaults.set(replayGain.rawValue, forKey: "replayGain") } }
    var replayGainPreampDB: Double { didSet { defaults.set(replayGainPreampDB, forKey: "replayGainPreamp") } }
    /// Offer a (dithered) software volume when the device has no hardware control: the default for every such output.
    var allowDigitalVolume: Bool { didSet { defaults.set(allowDigitalVolume, forKey: "allowDigitalVolume") } }
    var digitalVolume: Double { didSet { defaults.set(digitalVolume, forKey: "digitalVolume") } }
    /// "Volume control in Vespertine", chosen for one output (device UID → on), overriding `allowDigitalVolume` there.
    var appVolumeChoices: [String: Bool] { didSet { defaults.set(appVolumeChoices, forKey: "appVolumeChoices") } }
    /// Vespertine's volume level per output (0…1). Outputs that aren't listed use `digitalVolume`.
    var appVolumeLevels: [String: Double] { didSet { defaults.set(appVolumeLevels, forKey: "appVolumeLevels") } }
    var defaultImportMode: ImportMode { didSet { defaults.set(defaultImportMode.rawValue, forKey: "importMode") } }
    var managedFolderPath: String { didSet { defaults.set(managedFolderPath, forKey: "managedFolder") } }
    var watchFolders: Bool { didSet { defaults.set(watchFolders, forKey: "watchFolders") } }
    var fetchArtworkOnline: Bool { didSet { defaults.set(fetchArtworkOnline, forKey: "fetchArtworkOnline") } }
    var scrobble: Bool { didSet { defaults.set(scrobble, forKey: "scrobble") } }
    /// Show the song that's playing as the Discord status (through the Discord app on this Mac).
    var discordPresence: Bool { didSet { defaults.set(discordPresence, forKey: "discordPresence") } }
    /// Look the album up online for a cover the Discord status can show (Discord can only show public images).
    var discordArtwork: Bool { didSet { defaults.set(discordArtwork, forKey: "discordArtwork") } }
    var miniPlayerFloats: Bool { didSet { defaults.set(miniPlayerFloats, forKey: "miniPlayerFloats") } }
    /// Leave voice recordings, telephony audio and short clips out of the library.
    var skipNonMusic: Bool { didSet { defaults.set(skipNonMusic, forKey: "skipNonMusic") } }
    /// Keep local copies of what plays from network shares (and the next few tracks).
    var networkCache: Bool { didSet { defaults.set(networkCache, forKey: "networkCache") } }
    var networkCacheLimitGB: Double { didSet { defaults.set(networkCacheLimitGB, forKey: "networkCacheLimitGB") } }
    /// While playing, make the Mac's sound output follow Vespertine's device, so volume keys and
    /// headphone controls (e.g. the AirPods Max Digital Crown) adjust what you're listening to.
    var systemOutputFollowsPlayback: Bool { didSet { defaults.set(systemOutputFollowsPlayback, forKey: "systemOutputFollowsPlayback") } }
    /// "Volume keys control the device held exclusively": with exclusive access, macOS moves the Mac's sound output to
    /// another device, and the volume relay ties that device's level to the DAC's. Off by default, so no other output's
    /// level is ever touched.
    var relayVolumeKeys: Bool { didSet { defaults.set(relayVolumeKeys, forKey: "relayVolumeKeys") } }
    /// What happens to devices Vespertine changed when it quits.
    var deviceOnQuit: DeviceOnQuit { didSet { defaults.set(deviceOnQuit.rawValue, forKey: "deviceOnQuit") } }
    /// Analyze new and changed music in the background after it's added.
    var autoAnalyze: Bool { didSet { defaults.set(autoAnalyze, forKey: "autoAnalyze") } }
    /// Include network shares in automatic analysis (reads every file in full over the network).
    var analyzeNetworkShares: Bool { didSet { defaults.set(analyzeNetworkShares, forKey: "analyzeNetworkShares") } }
    /// Upcoming tracks copied ahead of playback when the cache is on.
    var networkPrefetch: Int { didSet { defaults.set(networkPrefetch, forKey: "networkPrefetch") } }
    /// Equalizer presets, imported or made here.
    var eqPresets: [EQPreset] { didSet { defaults.set(try? JSONEncoder().encode(eqPresets), forKey: "eqPresets") } }
    /// The preset each output plays with (device UID → preset ID, or Off). Outputs that aren't listed play without one.
    var eqAssignments: [String: String] { didSet { defaults.set(eqAssignments, forKey: "eqAssignments") } }
    /// Room correction profiles, measured here or imported. Each belongs to the output it was measured on (or imported for).
    var roomProfiles: [RoomProfile] { didSet { defaults.set(try? RoomCorrectionCoding.encodeProfiles(roomProfiles), forKey: "roomProfiles") } }
    /// The profile each output plays with while room correction is on for it (device UID → profile ID). Off unless
    /// switched on: outputs that aren't listed play without it.
    var roomAssignments: [String: String] { didSet { defaults.set(roomAssignments, forKey: "roomAssignments") } }
    /// Outputs that keep native DSD (DoP) while room correction is on, playing DSD uncorrected. Elsewhere DSD is
    /// converted to PCM while correction is on, so it's corrected too.
    var roomNativeDSDDeviceUIDs: Set<String> { didSet { defaults.set(roomNativeDSDDeviceUIDs.sorted(), forKey: "roomNativeDSD") } }
    /// The visualizer window (Window > Visualizer): off unless switched on in Settings.
    var visualizerEnabled: Bool { didSet { defaults.set(visualizerEnabled, forKey: "visualizerEnabled") } }
    /// How the visualizer draws: style, colours and options.
    var visualizer: VisualizerSettings { didSet { if visualizer != oldValue { visualizer.save(to: defaults) } } }
    /// Where the visualizer window was (display, frame, full screen).
    var visualizerWindow: VisualizerWindowState? { didSet { if visualizerWindow != oldValue { visualizerWindow?.save(to: defaults) } } }
    /// First-run setup has been finished (or skipped) once.
    var setupCompleted: Bool { didSet { defaults.set(setupCompleted, forKey: "setupCompleted") } }

    /// Library location. Overridable with `-VespertineDataDirectory <path>` for testing.
    let dataDirectory: URL

    init(defaults: UserDefaults = .standard, dataDirectory: URL? = nil) {
        self.defaults = defaults
        defaults.register(defaults: [
            "exclusiveMode": false, "atmosBySystem": true, "integerMode": true, "matchSixteenBit": false, "releaseAfterPause": 30.0, "replayGain": "off", "replayGainPreamp": 0.0,
            "allowDigitalVolume": false, "digitalVolume": 1.0, "importMode": ImportMode.copyAndOrganize.rawValue,
            "watchFolders": true, "fetchArtworkOnline": true, "scrobble": false, "discordPresence": false, "discordArtwork": true, "miniPlayerFloats": true, "skipNonMusic": true,
            "networkCache": true, "networkCacheLimitGB": 20.0, "networkPrefetch": 3,
            "autoAnalyze": false, "analyzeNetworkShares": false, "systemOutputFollowsPlayback": true, "relayVolumeKeys": false,
            "deviceOnQuit": "restore", "visualizerEnabled": false,
        ])
        exclusiveMode = defaults.bool(forKey: "exclusiveMode")
        atmosBySystem = defaults.bool(forKey: "atmosBySystem")
        versionPreference = TrackVersions.Preference(rawValue: defaults.string(forKey: "versionPreference") ?? "") ?? .matchOutput
        integerMode = defaults.bool(forKey: "integerMode")
        matchSixteenBit = defaults.bool(forKey: "matchSixteenBit")
        releaseAfterPause = defaults.double(forKey: "releaseAfterPause")
        selectedDeviceUID = defaults.string(forKey: "selectedDeviceUID")
        selectedDevice = defaults.data(forKey: "selectedDevice").flatMap { try? JSONDecoder().decode(OutputIdentity.self, from: $0) }
        outputFallback = OutputFallback(rawValue: defaults.string(forKey: "outputFallback") ?? "") ?? .bestAvailable
        dopDeviceUIDs = Set(defaults.stringArray(forKey: "dopDeviceUIDs") ?? [])
        dopOffDeviceUIDs = Set(defaults.stringArray(forKey: "dopOffDeviceUIDs") ?? [])
        bitstreamDeviceUIDs = Set(defaults.stringArray(forKey: "bitstreamDeviceUIDs") ?? [])
        spatialModes = defaults.dictionary(forKey: "spatialModes") as? [String: String] ?? [:]
        rateChoices = defaults.dictionary(forKey: "rateChoices") as? [String: String] ?? [:]
        replayGain = ReplayGainMode(rawValue: defaults.string(forKey: "replayGain") ?? "off") ?? .off
        replayGainPreampDB = defaults.double(forKey: "replayGainPreamp")
        allowDigitalVolume = defaults.bool(forKey: "allowDigitalVolume")
        digitalVolume = defaults.double(forKey: "digitalVolume")
        appVolumeChoices = defaults.dictionary(forKey: "appVolumeChoices") as? [String: Bool] ?? [:]
        appVolumeLevels = defaults.dictionary(forKey: "appVolumeLevels") as? [String: Double] ?? [:]
        defaultImportMode = ImportMode(rawValue: defaults.string(forKey: "importMode") ?? "") ?? .copyAndOrganize
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        managedFolderPath = defaults.string(forKey: "managedFolder") ?? music.appendingPathComponent("Vespertine").path
        watchFolders = defaults.bool(forKey: "watchFolders")
        fetchArtworkOnline = defaults.bool(forKey: "fetchArtworkOnline")
        scrobble = defaults.bool(forKey: "scrobble")
        discordPresence = defaults.bool(forKey: "discordPresence")
        discordArtwork = defaults.bool(forKey: "discordArtwork")
        miniPlayerFloats = defaults.bool(forKey: "miniPlayerFloats")
        skipNonMusic = defaults.bool(forKey: "skipNonMusic")
        systemOutputFollowsPlayback = defaults.bool(forKey: "systemOutputFollowsPlayback")
        relayVolumeKeys = defaults.bool(forKey: "relayVolumeKeys")
        deviceOnQuit = DeviceOnQuit(rawValue: defaults.string(forKey: "deviceOnQuit") ?? "") ?? .restore
        autoAnalyze = defaults.bool(forKey: "autoAnalyze")
        analyzeNetworkShares = defaults.bool(forKey: "analyzeNetworkShares")
        networkCache = defaults.bool(forKey: "networkCache")
        networkCacheLimitGB = defaults.double(forKey: "networkCacheLimitGB")
        networkPrefetch = defaults.integer(forKey: "networkPrefetch")
        let storedPresets = defaults.data(forKey: "eqPresets")
        let savedPresets = storedPresets.flatMap { try? JSONDecoder().decode([EQPreset].self, from: $0) }
        // The AirPods Max reference presets are added once each, so one that's deleted stays deleted. They are only
        // offered: an output plays one only after it's chosen for it.
        let offered = Set(defaults.stringArray(forKey: "eqOfferedPresets") ?? [])
        let savedIDs = Set(savedPresets?.map(\.id) ?? [])
        let added = AirPodsMaxEQProfiles.all.filter { !savedIDs.contains($0.id) && !offered.contains($0.id.uuidString) }
        let presets = (savedPresets ?? []) + added
        eqPresets = presets
        // Saved presets that can't be read are left as they are, rather than replaced by the reference ones alone.
        if storedPresets == nil || savedPresets != nil {
            if !added.isEmpty { defaults.set(try? JSONEncoder().encode(presets), forKey: "eqPresets") }
            let allOffered = offered.union(AirPodsMaxEQProfiles.all.map(\.id.uuidString))
            if allOffered != offered { defaults.set(allOffered.sorted(), forKey: "eqOfferedPresets") }
        }
        eqAssignments = defaults.dictionary(forKey: "eqAssignments") as? [String: String] ?? [:]
        roomProfiles = defaults.data(forKey: "roomProfiles").flatMap { try? RoomCorrectionCoding.decodeProfiles($0) } ?? []
        roomAssignments = defaults.dictionary(forKey: "roomAssignments") as? [String: String] ?? [:]
        roomNativeDSDDeviceUIDs = Set(defaults.stringArray(forKey: "roomNativeDSD") ?? [])
        setupCompleted = defaults.bool(forKey: "setupCompleted")
        visualizerEnabled = defaults.bool(forKey: "visualizerEnabled")
        visualizer = VisualizerSettings.load(from: defaults)
        visualizerWindow = VisualizerWindowState.load(from: defaults)
        if let dataDirectory {
            self.dataDirectory = dataDirectory
        } else if let override = LaunchArguments().string(forKey: "VespertineDataDirectory") ?? defaults.string(forKey: "LibraryDataDirectory") {
            self.dataDirectory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let standard = LibraryDatabase.defaultURL.deletingLastPathComponent()
            // Development builds keep their own library beside the real one.
            // The room measurement test build has its own, too.
            let side = Bundle.main.bundleIdentifier.flatMap { $0.hasSuffix(".dev") ? "Vespertine Dev" : $0.hasSuffix(".roomtest") ? "Vespertine Room Test" : nil }
            self.dataDirectory = side.map { standard.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true) } ?? standard
        }
    }

    var networkCacheLimitBytes: Int64 { Int64(networkCacheLimitGB * 1_000_000_000) }

    /// The equalizer preset `uid` plays with: only one chosen for it. Off, and never chosen, play without one.
    func eqPreset(for uid: String) -> EQPreset? {
        guard let id = eqAssignments[uid], id != Self.equalizerOff else { return nil }
        return eqPresets.first { $0.id.uuidString == id }
    }

    /// The preset `device` plays with. Nothing is chosen for an output automatically, AirPods Max included.
    func eqPreset(for device: OutputDevice) -> EQPreset? { eqPreset(for: device.uid) }

    func setEQPreset(_ id: UUID?, for uid: String) { eqAssignments[uid] = id?.uuidString ?? Self.equalizerOff }

    private static let equalizerOff = "__off__"

    /// The profiles measured on `uid`, newest first.
    func roomProfiles(for uid: String) -> [RoomProfile] {
        roomProfiles.filter { $0.deviceUID == uid }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The room correction `uid` plays with: only while it's switched on, and only a profile measured on that output.
    func roomProfile(for uid: String) -> RoomProfile? {
        guard let id = roomAssignments[uid] else { return nil }
        return roomProfiles.first { $0.id.uuidString == id && $0.deviceUID == uid }
    }

    /// Switches room correction on for `uid` with `profile`, or off (nil).
    func setRoomProfile(_ profile: UUID?, for uid: String) { roomAssignments[uid] = profile?.uuidString }

    /// Replaces a stored profile (a redesign) or adds a new one.
    func saveRoomProfile(_ profile: RoomProfile) {
        if let i = roomProfiles.firstIndex(where: { $0.id == profile.id }) { roomProfiles[i] = profile } else { roomProfiles.append(profile) }
    }

    func deleteRoomProfile(_ id: UUID) {
        let removed = roomProfiles.first { $0.id == id }
        roomProfiles.removeAll { $0.id == id }
        roomAssignments = roomAssignments.filter { $0.value != id.uuidString }
        // Its measured filters go too, unless another profile still uses them.
        let kept = Set(roomProfiles.flatMap { ($0.impulses ?? [:]).values.map(\.file) })
        for impulse in Set((removed?.impulses ?? [:]).values) where !kept.contains(impulse.file) { impulse.delete() }
    }

    /// Carries an output's own settings (rate, DoP, receiver, Spatial Audio, equalizer) over to its new UID.
    func moveDeviceSettings(from old: String, to new: String) {
        if dopDeviceUIDs.contains(old) { dopDeviceUIDs.insert(new) }
        if dopOffDeviceUIDs.contains(old) { dopOffDeviceUIDs.insert(new) }
        if bitstreamDeviceUIDs.contains(old) { bitstreamDeviceUIDs.insert(new) }
        if spatialModes[new] == nil, let mode = spatialModes[old] { spatialModes[new] = mode }
        if rateChoices[new] == nil, let choice = rateChoices[old] { rateChoices[new] = choice }
        if eqAssignments[new] == nil, let preset = eqAssignments[old] { eqAssignments[new] = preset }
        // Room profiles belong to the output, not to a USB port: the same DAC under a new UID keeps them.
        if roomProfiles.contains(where: { $0.deviceUID == old }) {
            roomProfiles = roomProfiles.map { var p = $0; if p.deviceUID == old { p.deviceUID = new }; return p }
        }
        if roomAssignments[new] == nil, let profile = roomAssignments[old] { roomAssignments[new] = profile }
        if roomNativeDSDDeviceUIDs.contains(old) { roomNativeDSDDeviceUIDs.insert(new) }
        if appVolumeChoices[new] == nil, let choice = appVolumeChoices[old] { appVolumeChoices[new] = choice }
        if appVolumeLevels[new] == nil, let level = appVolumeLevels[old] { appVolumeLevels[new] = level }
    }

    func rateChoice(for uid: String) -> RateChoice { RateChoice(code: rateChoices[uid] ?? "match") }
    func setRateChoice(_ choice: RateChoice, for uid: String) { rateChoices[uid] = choice.code }

    /// Digital volume slider (0…1) → dB, with a musical taper and a hard mute at 0.
    var digitalVolumeDB: Double? {
        guard allowDigitalVolume else { return nil }
        return Self.decibels(digitalVolume)
    }

    static func decibels(_ level: Double) -> Double {
        if level >= 0.999 { return 0 }
        if level <= 0.001 { return -120 }
        return 60 * (pow(level, 0.5) - 1)
    }

    /// Whether Vespertine sets the volume on `uid` (when it has no hardware volume): its own choice, else the default.
    func usesAppVolume(_ uid: String) -> Bool { appVolumeChoices[uid] ?? allowDigitalVolume }
    func setUsesAppVolume(_ on: Bool, for uid: String) { appVolumeChoices[uid] = on }
    func appVolumeLevel(for uid: String) -> Double { appVolumeLevels[uid] ?? digitalVolume }
    func setAppVolumeLevel(_ level: Double, for uid: String) { appVolumeLevels[uid] = min(max(level, 0), 1) }

    /// Each output with a volume choice or level of its own: its digital volume in dB, or nil where it stays fixed.
    var deviceDigitalVolumes: [String: Double?] {
        var result: [String: Double?] = [:]
        for uid in Set(appVolumeChoices.keys).union(appVolumeLevels.keys) {
            result.updateValue(usesAppVolume(uid) ? Self.decibels(appVolumeLevel(for: uid)) : nil, forKey: uid)
        }
        return result
    }

    /// Digital volume is passed as set: the engine skips it on whichever output it plays to that has hardware volume.
    func engineSettings() -> EngineSettings {
        var s = EngineSettings()
        s.exclusive = exclusiveMode
        s.deviceUID = selectedDeviceUID
        s.deviceName = selectedDevice.flatMap { $0.uid == selectedDeviceUID ? $0.name : nil }
        s.outputFallback = outputFallback
        s.dopDeviceUIDs = effectiveDoPUIDs
        s.bitstreamDeviceUIDs = bitstreamDeviceUIDs
        s.spatialModes = spatialModes.compactMapValues(SpatialMode.init(rawValue:))
        s.ratePolicies = rateChoices.mapValues { RateChoice(code: $0).policy }
        s.releaseExclusiveAfterPause = releaseAfterPause
        s.digitalVolumeDB = digitalVolumeDB
        s.deviceDigitalVolumes = deviceDigitalVolumes
        s.preferHardwareVolume = true
        s.atmosBySystem = atmosBySystem
        s.integerMode = integerMode
        s.matchSixteenBit = matchSixteenBit
        s.equalizers = eqAssignments.compactMapValues { id in eqPresets.first { $0.id.uuidString == id } }
        s.roomCorrections = Dictionary(uniqueKeysWithValues: roomAssignments.keys.compactMap { uid in
            roomProfile(for: uid).map { (uid, RoomCorrectionPlayback(profile: $0)) }
        })
        s.roomNativeDSDDeviceUIDs = roomNativeDSDDeviceUIDs
        return s
    }
}
