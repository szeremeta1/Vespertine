//
// Vespertine: AirPlay receivers as outputs (AirPlay 1 / RAOP, ALAC 16/44.1), behind Settings › Playback › AirPlay Players
// (beta), off by default. The model exists only while the switch is on; until then nothing is browsed on Bonjour and no
// socket is opened. macOS's own AirPlay devices (Core Audio) are listed with the other devices as before.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAirPlay
import VespertineAudio
import VespertineUPnP

@Observable
@MainActor
final class AirPlayOutputModel {
    @ObservationIgnored let service: AirPlayService
    private(set) var devices: [AirPlayDevice] = []
    /// Bonjour hasn't answered yet.
    private(set) var searching = true
    @ObservationIgnored private(set) var playback: AirPlayPlayback?
    /// Called when the list of receivers changes.
    @ObservationIgnored var onChange: (() -> Void)?

    init(service: AirPlayService = AirPlayService()) {
        self.service = service
        service.discovery.onChange = { [weak self] list in
            Task { @MainActor in
                guard let self else { return }
                let changed = self.devices != list
                self.devices = list
                if !list.isEmpty { self.searching = false }
                if changed { self.onChange?() }
            }
        }
    }

    func start() {
        service.want(true)
        Task {
            // Bonjour answers within a moment; after a few seconds "Searching…" gives way to the list, even an empty one.
            try? await Task.sleep(for: .seconds(4))
            searching = false
        }
    }

    func stop() {
        playback?.shutdown()
        playback = nil
        service.want(false)
        devices = []
    }

    func device(uid: String?) -> AirPlayDevice? {
        guard let uid, AirPlayDevice.isAirPlayUID(uid) else { return nil }
        return devices.first { $0.uid == uid && $0.isSupported }
    }

    /// The playback for `device`, made once per receiver (nil: none chosen, or it isn't on the network now).
    func playback(for device: AirPlayDevice?, settings: RendererSettings, receiverVolumeDB: Double) -> AirPlayPlayback? {
        guard let device else {
            playback?.shutdown()
            playback = nil
            return nil
        }
        if let playback, playback.device.uid == device.uid {
            playback.update(settings: settings)
            playback.setReceiverVolume(decibels: receiverVolumeDB)
            return playback
        }
        playback?.shutdown()
        guard let made = AirPlayPlayback(device: device) else { playback = nil; return nil }
        made.update(settings: settings)
        made.setReceiverVolume(decibels: receiverVolumeDB)
        playback = made
        return made
    }
}

/// The Settings › Playback switch for AirPlay receivers: its words, and what turning it on or off does.
@MainActor
enum AirPlaySwitch {
    static var title: String {
        String(localized: "AirPlay Players (beta)", comment: "Settings › Playback: the switch that brings AirPlay receivers (AirPlay 1) into the app as outputs Vespertine streams to itself. “AirPlay” and “beta” stay as they are in your language.")
    }

    static var explanation: String {
        String(localized: "Sends ALAC 16-bit / 44.1 kHz to AirPlay receivers (AirPlay 1), CD-quality files exactly as they are. Off, Vespertine doesn't look for them, opens no port for them, and plays as before; macOS's own AirPlay outputs stay as they are.", comment: "Settings › Playback: the caption under the AirPlay Players (beta) switch.")
    }

    /// Turns the feature on or off and answers the model that should exist now: `current` or a new, started one while on; nil off.
    static func apply(_ on: Bool, to settings: AppSettings, current: AirPlayOutputModel?, onChange: @escaping () -> Void = {},
                      make: () -> AirPlayOutputModel = { AirPlayOutputModel() }) -> AirPlayOutputModel? {
        settings.airPlayPlayersFeature = on
        guard on else {
            current?.stop()
            return nil
        }
        if let current { return current }
        let model = make()
        model.onChange = onChange
        model.start()
        return model
    }

    /// Whether the chosen output survives the switch going to `on`: an AirPlay receiver chosen as the output doesn't, once off.
    static func keepsOutput(_ uid: String?, turningOnTo on: Bool) -> Bool {
        on || !AirPlayDevice.isAirPlayUID(uid)
    }
}

extension AppSettings {
    /// What Vespertine applies for the AirPlay receiver `uid`: its equalizer, room correction and, when Vespertine sets the
    /// volume, digital volume.
    func airPlaySettings(uid: String) -> RendererSettings {
        let engine = engineSettings()
        let digital = airPlayDigitalVolume.contains(uid) ? Self.decibels(airPlayLevel(uid: uid)) : nil
        return RendererSettings(equalizer: engine.equalizers[uid], roomCorrection: engine.roomCorrections[uid], digitalVolumeDB: digital)
    }

    /// The receiver's own volume: the level while the receiver sets it, 0 dB while Vespertine does.
    func airPlayReceiverVolumeDB(uid: String) -> Double {
        airPlayDigitalVolume.contains(uid) ? 0 : RAOPVolume.decibels(level: airPlayLevel(uid: uid))
    }

    /// A receiver's level: what the listener set for it, else full (its own volume left at 100%, not the app's digital
    /// volume for other outputs).
    func airPlayLevel(uid: String) -> Double { appVolumeLevels[uid] ?? 1 }

    /// Volume Up, Down and Mute for a receiver, from its own level.
    func applyAirPlayVolume(_ action: VolumeControls.Action, uid: String) {
        if appVolumeLevels[uid] == nil { setAppVolumeLevel(1, for: uid) }
        applyVolume(action, for: uid)
    }

    func setAirPlayDigitalVolume(_ digital: Bool, for uid: String) {
        if digital { airPlayDigitalVolume.insert(uid) } else { airPlayDigitalVolume.remove(uid) }
    }
}
