//
// Vespertine: where the music plays: on the Mac (the app is its remote) or on this iPhone or iPad (the Mac sends the songs
// and this device plays them). The screens send the same commands either way; this decides who gets them.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Observation
import SwiftUI
import UIKit
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol

@Observable
final class PlayTarget {
    static let shared = PlayTarget()
    private static let key = "playsOnThisDevice"

    /// "This iPhone" is chosen in Output. Kept between launches.
    private(set) var onThisDevice = UserDefaults.standard.bool(forKey: PlayTarget.key)
    /// How surround songs are played on headphones here: Head Tracked unless chosen otherwise. Kept between launches.
    var surround = SpatialModeChoice(rawValue: UserDefaults.standard.string(forKey: PlayTarget.surroundKey) ?? "") ?? .headTracked {
        didSet {
            UserDefaults.standard.set(surround.rawValue, forKey: Self.surroundKey)
            made?.remote.surroundChoice = surround
        }
    }
    private static let surroundKey = "surroundOnThisDevice"
    /// Why songs aren't fetched right now (cellular data with playing over it turned off), or nil.
    @ObservationIgnored var holdReason: String?
    /// How much has been fetched from the Mac for playing here since the app opened.
    var bytesReceived: Int64 { (made?.remote.playback.bytesReceived ?? 0) + KeptShelf.shared.bytesReceived }
    private var made: (session: ObjectIdentifier, remote: PhoneRemote, system: PhoneSystem)?

    /// The phone's player for `session` when this device is where music plays and the Mac can send songs; nil when the
    /// Mac plays.
    func phone(for session: RemoteSession) -> PhoneRemote? {
        guard onThisDevice, !session.isDemo else { return nil }
        // Once made it stays, connected or not: a song that is playing doesn't vanish from Now Playing when the Mac does.
        if let made, made.session == ObjectIdentifier(session) { return made.remote }
        guard session.canStream || KeptShelf.shared.hasKept(session) else { return nil }
        return make(for: session)
    }

    /// Whether `session`'s Mac can send songs to this device (a Mac whose Vespertine speaks the stream channel).
    func canPlayHere(_ session: RemoteSession) -> Bool { session.canStream && !session.isDemo }

    func choose(thisDevice: Bool) {
        guard thisDevice != onThisDevice else { return }
        if !thisDevice { made?.remote.playback.stop() }
        onThisDevice = thisDevice
        UserDefaults.standard.set(thisDevice, forKey: Self.key)
    }

    /// The session is over (another Mac was chosen, or none): the phone stops and lets go of its streams.
    func leave() {
        made?.system.stop()
        made?.remote.playback.stop()
        made = nil
    }

    /// Music is playing on this device right now: the connection to the Mac has to stay up in the background.
    var isBusy: Bool { made.map { $0.remote.playback.isPlaying } ?? false }

    private func make(for session: RemoteSession) -> PhoneRemote {
        leave()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let playback = PhonePlayback(session: session, player: PhonePlayer(), cacheDirectory: caches.appendingPathComponent("Streams", isDirectory: true))
        let remote = PhoneRemote(playback: playback) { [weak session] command in await session?.send(command) ?? .failed(reason: "") }
        remote.words = { signal in (Self.badge(signal), Self.output(signal)) }
        remote.surroundChoice = surround
        playback.holdReason = { [weak self] in self?.holdReason }
        let keeper = KeptShelf.shared.keeper(for: session)
        playback.kept = { [weak keeper] song in keeper?.store.kept(song).map { ($0.file, $0.descriptor) } }
        remote.macName = session.server?.name ?? session.pairing.name
        let system = PhoneSystem(remote: remote) { [weak session] key in
            guard let session, case .artwork(_, _, _, let data) = await session.send(.artwork(key: key, size: 600)) else { return nil }
            return data
        }
        system.start()
        made = (ObjectIdentifier(session), remote, system)
        return remote
    }

    // MARK: Words

    /// "This iPhone" or "This iPad".
    static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad") : String(localized: "This iPhone")
    }

    /// The badge: whether the song arrives as the file it is, or as a copy the Mac made in a format this device can open.
    static func badge(_ signal: PhoneSignal) -> String {
        switch signal.surround {
        case .headTracked?: return String(localized: "SPATIAL AUDIO · HEAD TRACKED", comment: "Signal badge on the iPhone: a surround song rendered for headphones, following the head.")
        case .fixed?: return String(localized: "SPATIAL AUDIO · FIXED", comment: "Signal badge on the iPhone: a surround song rendered for headphones, not following the head.")
        case .off?: return String(localized: "SURROUND FOLDED TO STEREO", comment: "Signal badge on the iPhone: a surround song mixed down to two channels.")
        case nil: break
        }
        return signal.converted ? String(localized: "CONVERTED ON THE MAC", comment: "Signal badge: the Mac converted this song to a format the iPhone can play.")
                         : String(localized: "ORIGINAL FILE", comment: "Signal badge: the iPhone plays the song's own file, as it is on the Mac.")
    }

    /// What the output runs at, and that iOS changed the rate to get there when it did.
    static func output(_ signal: PhoneSignal) -> String {
        guard let rate = signal.outputRate, rate > 0 else { return "" }
        let kilohertz = PhoneSignal.kilohertz(rate)
        return signal.resampled ? String(localized: "\(kilohertz) kHz, resampled by iOS", comment: "Signal chip on the iPhone: the output's sample rate, which differs from the song's.")
                                : String(localized: "\(kilohertz) kHz", comment: "Signal chip: a sample rate.")
    }
}

extension RemoteSession {
    /// The phone's player, when music plays on this device.
    var phone: PhoneRemote? { PlayTarget.shared.phone(for: self) }
    /// What Now Playing shows: this device's player when music plays here, the Mac's otherwise.
    var shownPlayer: PlayerState? { phone?.playerState ?? player }
    var shownQueue: QueueState? { phone?.queueState ?? queue }

    /// Sends a command to whoever plays: this device for transport, queue and "play this", the Mac for everything else.
    func run(_ command: RemoteCommand) async -> RemoteReply {
        if let phone, PhoneRemote.handles(command) { return await phone.run(command) }
        return await send(command)
    }
}
