//
// Vespertine — user preferences (UserDefaults-backed).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary
import Observation

enum ReplayGainMode: String, CaseIterable, Identifiable {
    case off, track, album
    var id: String { rawValue }
    var label: String { switch self { case .off: "Off"; case .track: "Track"; case .album: "Album" } }
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
        case .match: "Match source"
        case .maximum: "Device maximum"
        case .fixed(let r): "Fixed \(SampleRate.format(r)) kHz"
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
    /// Dolby Atmos: rendered by macOS (objects), or its channel bed played through Vespertine.
    var atmosBySystem: Bool { didSet { defaults.set(atmosBySystem, forKey: "atmosBySystem") } }
    /// Songs with a stereo and a multichannel version: which to play.
    var versionPreference: TrackVersions.Preference { didSet { defaults.set(versionPreference.rawValue, forKey: "versionPreference") } }
    var releaseAfterPause: Double { didSet { defaults.set(releaseAfterPause, forKey: "releaseAfterPause") } }
    var selectedDeviceUID: String? { didSet { defaults.set(selectedDeviceUID, forKey: "selectedDeviceUID") } }
    var dopDeviceUIDs: Set<String> { didSet { defaults.set(Array(dopDeviceUIDs), forKey: "dopDeviceUIDs") } }
    /// Outputs with an AV receiver: Dolby and DTS are sent to them untouched.
    var bitstreamDeviceUIDs: Set<String> { didSet { defaults.set(Array(bitstreamDeviceUIDs), forKey: "bitstreamDeviceUIDs") } }
    /// Spatial Audio for multichannel music, per device (unset = head tracked on AirPods/Beats, off elsewhere).
    var spatialModes: [String: String] { didSet { defaults.set(spatialModes, forKey: "spatialModes") } }
    var rateChoices: [String: String] { didSet { defaults.set(rateChoices, forKey: "rateChoices") } }
    var replayGain: ReplayGainMode { didSet { defaults.set(replayGain.rawValue, forKey: "replayGain") } }
    var replayGainPreampDB: Double { didSet { defaults.set(replayGainPreampDB, forKey: "replayGainPreamp") } }
    /// Offer a (dithered) software volume when the device has no hardware control.
    var allowDigitalVolume: Bool { didSet { defaults.set(allowDigitalVolume, forKey: "allowDigitalVolume") } }
    var digitalVolume: Double { didSet { defaults.set(digitalVolume, forKey: "digitalVolume") } }
    var defaultImportMode: ImportMode { didSet { defaults.set(defaultImportMode.rawValue, forKey: "importMode") } }
    var managedFolderPath: String { didSet { defaults.set(managedFolderPath, forKey: "managedFolder") } }
    var watchFolders: Bool { didSet { defaults.set(watchFolders, forKey: "watchFolders") } }
    var fetchArtworkOnline: Bool { didSet { defaults.set(fetchArtworkOnline, forKey: "fetchArtworkOnline") } }
    var scrobble: Bool { didSet { defaults.set(scrobble, forKey: "scrobble") } }
    var miniPlayerFloats: Bool { didSet { defaults.set(miniPlayerFloats, forKey: "miniPlayerFloats") } }
    /// Leave voice recordings, telephony audio and short clips out of the library.
    var skipNonMusic: Bool { didSet { defaults.set(skipNonMusic, forKey: "skipNonMusic") } }
    /// Keep local copies of what plays from network shares (and the next few tracks).
    var networkCache: Bool { didSet { defaults.set(networkCache, forKey: "networkCache") } }
    var networkCacheLimitGB: Double { didSet { defaults.set(networkCacheLimitGB, forKey: "networkCacheLimitGB") } }
    /// While playing, make the Mac's sound output follow Vespertine's device, so volume keys and
    /// headphone controls (e.g. the AirPods Max Digital Crown) adjust what you're listening to.
    var systemOutputFollowsPlayback: Bool { didSet { defaults.set(systemOutputFollowsPlayback, forKey: "systemOutputFollowsPlayback") } }
    /// What happens to devices Vespertine changed when it quits.
    var deviceOnQuit: DeviceOnQuit { didSet { defaults.set(deviceOnQuit.rawValue, forKey: "deviceOnQuit") } }
    /// Analyze new and changed music in the background after it's added.
    var autoAnalyze: Bool { didSet { defaults.set(autoAnalyze, forKey: "autoAnalyze") } }
    /// Include network shares in automatic analysis (reads every file in full over the network).
    var analyzeNetworkShares: Bool { didSet { defaults.set(analyzeNetworkShares, forKey: "analyzeNetworkShares") } }
    /// Upcoming tracks copied ahead of playback when the cache is on.
    var networkPrefetch: Int { didSet { defaults.set(networkPrefetch, forKey: "networkPrefetch") } }

    /// Library location. Overridable with `-VespertineDataDirectory <path>` for testing.
    let dataDirectory: URL

    init(defaults: UserDefaults = .standard, dataDirectory: URL? = nil) {
        self.defaults = defaults
        defaults.register(defaults: [
            "exclusiveMode": false, "atmosBySystem": true, "integerMode": true, "releaseAfterPause": 30.0, "replayGain": "off", "replayGainPreamp": 0.0,
            "allowDigitalVolume": false, "digitalVolume": 1.0, "importMode": ImportMode.copyAndOrganize.rawValue,
            "watchFolders": true, "fetchArtworkOnline": true, "scrobble": false, "miniPlayerFloats": true, "skipNonMusic": true,
            "networkCache": true, "networkCacheLimitGB": 20.0, "networkPrefetch": 3,
            "autoAnalyze": false, "analyzeNetworkShares": false, "systemOutputFollowsPlayback": true, "deviceOnQuit": "restore",
        ])
        exclusiveMode = defaults.bool(forKey: "exclusiveMode")
        atmosBySystem = defaults.bool(forKey: "atmosBySystem")
        versionPreference = TrackVersions.Preference(rawValue: defaults.string(forKey: "versionPreference") ?? "") ?? .matchOutput
        integerMode = defaults.bool(forKey: "integerMode")
        releaseAfterPause = defaults.double(forKey: "releaseAfterPause")
        selectedDeviceUID = defaults.string(forKey: "selectedDeviceUID")
        dopDeviceUIDs = Set(defaults.stringArray(forKey: "dopDeviceUIDs") ?? [])
        bitstreamDeviceUIDs = Set(defaults.stringArray(forKey: "bitstreamDeviceUIDs") ?? [])
        spatialModes = defaults.dictionary(forKey: "spatialModes") as? [String: String] ?? [:]
        rateChoices = defaults.dictionary(forKey: "rateChoices") as? [String: String] ?? [:]
        replayGain = ReplayGainMode(rawValue: defaults.string(forKey: "replayGain") ?? "off") ?? .off
        replayGainPreampDB = defaults.double(forKey: "replayGainPreamp")
        allowDigitalVolume = defaults.bool(forKey: "allowDigitalVolume")
        digitalVolume = defaults.double(forKey: "digitalVolume")
        defaultImportMode = ImportMode(rawValue: defaults.string(forKey: "importMode") ?? "") ?? .copyAndOrganize
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        managedFolderPath = defaults.string(forKey: "managedFolder") ?? music.appendingPathComponent("Vespertine").path
        watchFolders = defaults.bool(forKey: "watchFolders")
        fetchArtworkOnline = defaults.bool(forKey: "fetchArtworkOnline")
        scrobble = defaults.bool(forKey: "scrobble")
        miniPlayerFloats = defaults.bool(forKey: "miniPlayerFloats")
        skipNonMusic = defaults.bool(forKey: "skipNonMusic")
        systemOutputFollowsPlayback = defaults.bool(forKey: "systemOutputFollowsPlayback")
        deviceOnQuit = DeviceOnQuit(rawValue: defaults.string(forKey: "deviceOnQuit") ?? "") ?? .restore
        autoAnalyze = defaults.bool(forKey: "autoAnalyze")
        analyzeNetworkShares = defaults.bool(forKey: "analyzeNetworkShares")
        networkCache = defaults.bool(forKey: "networkCache")
        networkCacheLimitGB = defaults.double(forKey: "networkCacheLimitGB")
        networkPrefetch = defaults.integer(forKey: "networkPrefetch")

        if let dataDirectory {
            self.dataDirectory = dataDirectory
        } else if let override = LaunchArguments().string(forKey: "VespertineDataDirectory") ?? defaults.string(forKey: "LibraryDataDirectory") {
            self.dataDirectory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let standard = LibraryDatabase.defaultURL.deletingLastPathComponent()
            // Development builds keep their own library beside the real one.
            self.dataDirectory = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
                ? standard.deletingLastPathComponent().appendingPathComponent("Vespertine Dev", isDirectory: true) : standard
        }
    }

    var networkCacheLimitBytes: Int64 { Int64(networkCacheLimitGB * 1_000_000_000) }

    func rateChoice(for uid: String) -> RateChoice { RateChoice(code: rateChoices[uid] ?? "match") }
    func setRateChoice(_ choice: RateChoice, for uid: String) { rateChoices[uid] = choice.code }

    /// Digital volume slider (0…1) → dB, with a musical taper and a hard mute at 0.
    var digitalVolumeDB: Double? {
        guard allowDigitalVolume else { return nil }
        if digitalVolume >= 0.999 { return 0 }
        if digitalVolume <= 0.001 { return -120 }
        return 60 * (pow(digitalVolume, 0.5) - 1)
    }

    /// Digital volume is passed as set: the engine skips it on whichever output it plays to that has hardware volume.
    func engineSettings() -> EngineSettings {
        var s = EngineSettings()
        s.exclusive = exclusiveMode
        s.deviceUID = selectedDeviceUID
        s.dopDeviceUIDs = dopDeviceUIDs
        s.bitstreamDeviceUIDs = bitstreamDeviceUIDs
        s.spatialModes = spatialModes.compactMapValues(SpatialMode.init(rawValue:))
        s.ratePolicies = rateChoices.mapValues { RateChoice(code: $0).policy }
        s.releaseExclusiveAfterPause = releaseAfterPause
        s.digitalVolumeDB = digitalVolumeDB
        s.preferHardwareVolume = true
        s.atmosBySystem = atmosBySystem
        s.integerMode = integerMode
        return s
    }
}
