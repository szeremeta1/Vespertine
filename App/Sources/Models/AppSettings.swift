//
// Nocturne — user preferences (UserDefaults-backed).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneAudio
import NocturneLibrary
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
        else if code.hasPrefix("fixed:"), let r = Double(code.dropFirst(6)) { self = .fixed(r) }
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
    private let defaults = UserDefaults.standard

    var exclusiveMode: Bool { didSet { defaults.set(exclusiveMode, forKey: "exclusiveMode") } }
    var releaseAfterPause: Double { didSet { defaults.set(releaseAfterPause, forKey: "releaseAfterPause") } }
    var selectedDeviceUID: String? { didSet { defaults.set(selectedDeviceUID, forKey: "selectedDeviceUID") } }
    var dopDeviceUIDs: Set<String> { didSet { defaults.set(Array(dopDeviceUIDs), forKey: "dopDeviceUIDs") } }
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

    /// Library location. Overridable with `-NocturneDataDirectory <path>` for testing.
    let dataDirectory: URL

    init() {
        defaults.register(defaults: [
            "exclusiveMode": true, "releaseAfterPause": 30.0, "replayGain": "off", "replayGainPreamp": 0.0,
            "allowDigitalVolume": false, "digitalVolume": 1.0, "importMode": ImportMode.reference.rawValue,
            "watchFolders": true, "fetchArtworkOnline": true, "scrobble": false, "miniPlayerFloats": true,
        ])
        exclusiveMode = defaults.bool(forKey: "exclusiveMode")
        releaseAfterPause = defaults.double(forKey: "releaseAfterPause")
        selectedDeviceUID = defaults.string(forKey: "selectedDeviceUID")
        dopDeviceUIDs = Set(defaults.stringArray(forKey: "dopDeviceUIDs") ?? [])
        rateChoices = defaults.dictionary(forKey: "rateChoices") as? [String: String] ?? [:]
        replayGain = ReplayGainMode(rawValue: defaults.string(forKey: "replayGain") ?? "off") ?? .off
        replayGainPreampDB = defaults.double(forKey: "replayGainPreamp")
        allowDigitalVolume = defaults.bool(forKey: "allowDigitalVolume")
        digitalVolume = defaults.double(forKey: "digitalVolume")
        defaultImportMode = ImportMode(rawValue: defaults.string(forKey: "importMode") ?? "") ?? .reference
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        managedFolderPath = defaults.string(forKey: "managedFolder") ?? music.appendingPathComponent("Nocturne").path
        watchFolders = defaults.bool(forKey: "watchFolders")
        fetchArtworkOnline = defaults.bool(forKey: "fetchArtworkOnline")
        scrobble = defaults.bool(forKey: "scrobble")
        miniPlayerFloats = defaults.bool(forKey: "miniPlayerFloats")

        if let override = defaults.string(forKey: "NocturneDataDirectory") {
            dataDirectory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dataDirectory = LibraryDatabase.defaultURL.deletingLastPathComponent()
        }
    }

    func rateChoice(for uid: String) -> RateChoice { RateChoice(code: rateChoices[uid] ?? "match") }
    func setRateChoice(_ choice: RateChoice, for uid: String) { rateChoices[uid] = choice.code }

    /// Digital volume slider (0…1) → dB, with a musical taper and a hard mute at 0.
    var digitalVolumeDB: Double? {
        guard allowDigitalVolume else { return nil }
        if digitalVolume >= 0.999 { return 0 }
        if digitalVolume <= 0.001 { return -120 }
        return 60 * (pow(digitalVolume, 0.5) - 1)
    }

    func engineSettings(deviceHasHardwareVolume: Bool) -> EngineSettings {
        var s = EngineSettings()
        s.exclusive = exclusiveMode
        s.deviceUID = selectedDeviceUID
        s.dopDeviceUIDs = dopDeviceUIDs
        s.ratePolicies = rateChoices.mapValues { RateChoice(code: $0).policy }
        s.releaseExclusiveAfterPause = releaseAfterPause
        s.digitalVolumeDB = deviceHasHardwareVolume ? nil : digitalVolumeDB
        return s
    }
}
