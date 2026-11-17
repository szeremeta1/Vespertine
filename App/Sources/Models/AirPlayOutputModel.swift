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
import VespertineLibrary
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
    /// A receiver whose password the listener is being asked for (the sheet is up while this is set).
    var passwordRequest: AirPlayPasswordRequest?
    /// Where receivers' passwords are kept.
    @ObservationIgnored var passwords = AirPlayPasswords.keychain
    /// A song's cover file by its library key, for receivers that show one.
    @ObservationIgnored var artwork: (@Sendable (String) -> Data?)? {
        didSet { playback?.artworkProvider = artwork }
    }

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

    /// The listener chose `device` in the output list: it becomes the output (`select`), after its password has been
    /// asked for when it has one and none is saved.
    func choose(_ device: AirPlayDevice, select: @escaping @MainActor (String) -> Void) {
        guard device.needsPassword else { return select(device.uid) }
        let passwords = self.passwords
        Task {
            // The keychain is read off the main thread (it can put up macOS's own prompt).
            let saved = await Task.detached { passwords.read(device.deviceID) != nil }.value
            if saved { select(device.uid) } else { passwordRequest = AirPlayPasswordRequest(device: device, refused: false) }
        }
    }

    /// The listener gave the password asked for: it is saved, and the receiver becomes (or stays) the output.
    func submit(password: String, select: @escaping @MainActor (String) -> Void) async {
        guard let request = passwordRequest else { return }
        let passwords = self.passwords
        await Task.detached { passwords.write(password, request.device.deviceID) }.value
        passwordRequest = nil
        select(request.device.uid)
    }

    func cancelPassword() { passwordRequest = nil }

    func forgetPassword(for device: AirPlayDevice) async {
        let passwords = self.passwords
        await Task.detached { passwords.write(nil, device.deviceID) }.value
    }

    func device(uid: String?) -> AirPlayDevice? {
        guard let uid, AirPlayDevice.isAirPlayUID(uid) else { return nil }
        return devices.first { $0.uid == uid && $0.isSupported }
    }

    /// The playback for `device`, made once per receiver (nil: none chosen, or it isn't on the network now).
    /// `chosenUID`: the receiver chosen as the output, found or not. A Bonjour record that expires or a browser that starts
    /// again (the Wi-Fi roamed, a VPN came up) doesn't end the music: while the session with the receiver is open, it stays.
    func playback(for device: AirPlayDevice?, chosenUID: String? = nil, settings: RendererSettings, receiverVolumeDB: Double) -> AirPlayPlayback? {
        guard let device else {
            if let playback, let chosenUID, playback.device.uid == chosenUID, playback.isEngaged {
                playback.update(settings: settings)
                playback.setReceiverVolume(decibels: receiverVolumeDB)
                return playback
            }
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
        let passwords = self.passwords
        made.passwordProvider = { passwords.read(device.deviceID) }
        // A missing, changed or mistyped password: the listener is asked (again).
        made.passwordRefused = { [weak self] in
            Task { @MainActor in self?.passwordRequest = AirPlayPasswordRequest(device: device, refused: true) }
        }
        made.artworkProvider = artwork
        playback = made
        return made
    }
}

/// The listener is asked for a receiver's password: on choosing it with none saved, or after it refused the one saved.
nonisolated struct AirPlayPasswordRequest: Identifiable, Equatable, Sendable {
    let device: AirPlayDevice
    let refused: Bool
    var id: String { device.uid + (refused ? "!" : "") }
}

/// Receivers' passwords by device id: the keychain in the app, a dictionary in tests. Both calls can block (the keychain
/// may put up macOS's own prompt), so they are made off the main thread.
nonisolated struct AirPlayPasswords: Sendable {
    var read: @Sendable (_ deviceID: String) -> String?
    /// nil or empty removes it.
    var write: @Sendable (_ password: String?, _ deviceID: String) -> Void

    static func account(_ deviceID: String) -> String { "airplay-password-" + deviceID }

    static let keychain = AirPlayPasswords(
        read: { id in Keychain.read(AirPlayPasswords.account(id)).value.flatMap { $0.isEmpty ? nil : $0 } },
        write: { password, id in _ = Keychain.write(password, account: AirPlayPasswords.account(id)) })

    /// Kept in memory only.
    static func memory(_ start: [String: String] = [:]) -> AirPlayPasswords {
        let box = Locked(start)
        return AirPlayPasswords(read: { id in box.withLock { $0[id] } },
                                write: { password, id in box.withLock { $0[id] = (password?.isEmpty == false) ? password : nil } })
    }
}

/// The cover an AirPlay receiver is sent: the library's stored picture near the size a receiver's display uses.
enum AirPlayCover {
    /// The file for `key`, read where it is called (off the main thread, by the playback). Keys are the library's own
    /// (letters, digits, dashes); anything else is refused, so a key can never name a file outside the artwork folder.
    nonisolated static func data(key: String, store: ArtworkStore) -> Data? {
        guard !key.isEmpty, key.count <= 128,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        // The 600-pixel thumbnail (a JPEG) when there is one; the original only if it is one receivers take and not huge.
        guard let data = try? Data(contentsOf: store.url(for: key, minimumSize: 600)), AirPlayArtwork.contentType(of: data) != nil else { return nil }
        return data
    }

    nonisolated static func provider(store: ArtworkStore) -> @Sendable (String) -> Data? {
        { key in data(key: key, store: store) }
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

    /// The level a receiver starts at until the listener sets one. Low on purpose: many receivers and amplifiers take the
    /// AirPlay volume as their master volume, and the first song must never arrive at full level.
    static let firstAirPlayLevel = 0.3

    /// A receiver's level: what the listener set for it, else `firstAirPlayLevel` (never the app's digital volume for
    /// other outputs).
    func airPlayLevel(uid: String) -> Double { appVolumeLevels[uid] ?? Self.firstAirPlayLevel }

    /// Volume Up, Down and Mute for a receiver, from its own level.
    func applyAirPlayVolume(_ action: VolumeControls.Action, uid: String) {
        if appVolumeLevels[uid] == nil { setAppVolumeLevel(Self.firstAirPlayLevel, for: uid) }
        applyVolume(action, for: uid)
    }

    func setAirPlayDigitalVolume(_ digital: Bool, for uid: String) {
        if digital { airPlayDigitalVolume.insert(uid) } else { airPlayDigitalVolume.remove(uid) }
    }
}
