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
    /// How surround songs are played on headphones here: folded to stereo (Off) until you choose Spatial Audio (kept as
    /// `.fixed`; a `.headTracked` kept from build 7 means the same). Kept between launches.
    var surround = PlayTarget.surround(stored: UserDefaults.standard.string(forKey: PlayTarget.surroundKey)) {
        didSet {
            UserDefaults.standard.set(surround.rawValue, forKey: Self.surroundKey)
            made?.remote.surroundChoice = surround
        }
    }
    private static let surroundKey = "surroundOnThisDevice"
    /// A song the library has in stereo and in surround plays here as the version for the output (the app's setting).
    var combinesVersions = UserDefaults.standard.object(forKey: "combineVersions") as? Bool ?? true { didSet { made?.remote.combinesVersions = combinesVersions } }

    /// The choice kept from an earlier launch, or Off for someone who never made one: the spatial rendering is asked for,
    /// never the starting point.
    static func surround(stored: String?) -> SpatialModeChoice { stored.flatMap(SpatialModeChoice.init(rawValue:)) ?? .off }
    /// The choices the picker offers: Off and Spatial Audio. Fixed or Head Tracked is chosen in Control Center: iOS renders
    /// Spatial Audio for the app, and no iOS app can choose that for it (the API for it is visionOS-only in the iOS 27 SDK).
    static let surroundChoices: [SpatialModeChoice] = [.off, .fixed]
    /// The picker's value for a kept choice.
    static func pickerValue(_ choice: SpatialModeChoice) -> SpatialModeChoice { choice == .off ? .off : .fixed }
    /// Whether songs played here are levelled with the ReplayGain values in their files, and by which of them. Off until
    /// chosen: with it off no sample is changed. Kept between launches.
    var replayGain = PlayTarget.replayGain(stored: UserDefaults.standard.string(forKey: PlayTarget.replayGainKey)) {
        didSet {
            UserDefaults.standard.set(replayGain.rawValue, forKey: Self.replayGainKey)
            made?.remote.playback.replayGain = replayGain
        }
    }
    private static let replayGainKey = "replayGainOnThisDevice"

    /// The choice kept from an earlier launch, or Off for someone who never made one.
    static func replayGain(stored: String?) -> ReplayGainChoice { stored.flatMap(ReplayGainChoice.init(rawValue:)) ?? .off }
    /// Why songs aren't fetched right now (cellular data with playing over it turned off), or nil.
    @ObservationIgnored var holdReason: String?
    /// How much has been fetched from the Mac for playing here since the app opened.
    var bytesReceived: Int64 { (made?.remote.playback.bytesReceived ?? 0) + KeptShelf.shared.bytesReceived }
    private var made: (session: ObjectIdentifier, remote: PhoneRemote, system: PhoneSystem, keeper: QueueKeeper?)?
    /// Where each Mac's (and each share's) queue is kept between launches.
    static let queues = QueueShelf(directory: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                                               ?? FileManager.default.temporaryDirectory).appendingPathComponent("Queues", isDirectory: true))

    /// The phone's player for `session` when this device is where music plays and the Mac can send songs; nil when the
    /// Mac plays.
    func phone(for session: RemoteSession) -> PhoneRemote? {
        // A share has no Mac to play on: its songs always play here.
        guard onThisDevice || session.isShare else { return nil }
        #if DEBUG
        // App Store captures use the demo and must stay silent on whatever machine takes them.
        if session.isDemo, LaunchOptions.screenshot { return nil }
        #endif
        // Once made it stays, connected or not: a song that is playing doesn't vanish from Now Playing when the Mac does.
        if let made, made.session == ObjectIdentifier(session) { return made.remote }
        guard session.isDemo || session.canStream || KeptShelf.shared.hasKept(session) else { return nil }
        return make(for: session)
    }

    /// Whether `session`'s Mac can send songs to this device (a Mac whose Vespertine speaks the stream channel).
    func canPlayHere(_ session: RemoteSession) -> Bool { session.canStream || session.isDemo }

    func choose(thisDevice: Bool) {
        guard thisDevice != onThisDevice else { return }
        if !thisDevice { made?.remote.playback.stop() }
        onThisDevice = thisDevice
        UserDefaults.standard.set(thisDevice, forKey: Self.key)
    }

    /// The session is over (another Mac was chosen, or none): the phone stops and lets go of its streams.
    func leave() {
        // The queue and the place are written as they are before the stop below puts the song back to its start.
        made?.keeper?.stop()
        made?.system.stop()
        made?.remote.playback.stop()
        made = nil
    }

    /// The app is being put away: iOS may end it without another word, so the queue and the place are written now.
    func saveQueue() { made?.keeper?.saveNow() }

    /// Music is playing on this device right now: the connection to the Mac has to stay up in the background.
    var isBusy: Bool { made.map { $0.remote.playback.isPlaying } ?? false }

    private func make(for session: RemoteSession) -> PhoneRemote {
        leave()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        // The demo has no Mac to send songs: its songs are sound the app makes, through the same player.
        let playback = session.isDemo
            ? PhonePlayback(client: DemoSound.client(), player: PhonePlayer(), cacheDirectory: caches.appendingPathComponent("DemoStreams", isDirectory: true))
            : PhonePlayback(session: session, player: PhonePlayer(), cacheDirectory: caches.appendingPathComponent("Streams", isDirectory: true))
        let remote = PhoneRemote(playback: playback) { [weak session] command in await session?.send(command) ?? .failed(reason: "") }
        remote.words = { signal in (Self.badge(signal), Self.output(signal)) }
        remote.surroundChoice = surround
        remote.combinesVersions = combinesVersions
        // Which DACs passed the DoP test here: kept between launches, by each DAC's own identifier.
        remote.dopDACs = DoPDACs.load()
        remote.onDoPDACsChanged = { $0.save() }
        playback.holdReason = { [weak self] in self?.holdReason }
        let keeper = KeptShelf.shared.keeper(for: session)
        playback.kept = { [weak keeper] song in keeper?.store.kept(song).map { ($0.file, $0.descriptor) } }
        // A kept song's ReplayGain values are kept beside it, so it is levelled the same with the Mac off.
        playback.keptGain = { [weak keeper] song in keeper?.store.kept(song)?.replayGain }
        playback.onGainValues = { [weak keeper] song, values in keeper?.store.noteReplayGain(values, of: song) }
        playback.replayGain = replayGain
        remote.macName = session.server?.name ?? session.pairing.name
        let system = PhoneSystem(remote: remote) { [weak session] key in
            guard let session, case .artwork(_, _, _, let data) = await session.send(.artwork(key: key, size: 600)) else { return nil }
            return data
        }
        system.start()
        // The queue this Mac (or share) was left with comes back paused at its place. The demo starts afresh each time.
        let queueKeeper = session.isDemo ? nil : QueueKeeper(playback: playback, shelf: Self.queues, owner: session.pairing.serverID)
        queueKeeper?.start()
        made = (ObjectIdentifier(session), remote, system, queueKeeper)
        return remote
    }

    // MARK: Words

    /// "This iPhone" or "This iPad".
    static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad") : String(localized: "This iPhone")
    }

    /// The badge: whether the song arrives as the file it is, or as a copy the Mac made in a format this device can open.
    static func badge(_ signal: PhoneSignal) -> String {
        // Only for a DAC that passed the DoP test on this device, and only while the output carries the frames as sent.
        if signal.dsdRate != nil, !signal.dopBroken {
            return String(localized: "NATIVE DSD · DoP", comment: "Status badge (short, uppercase).")
        }
        if let outputs = signal.discreteOutputs {
            return String(localized: "SURROUND ON \(String(outputs)) OUTPUTS", comment: "Signal badge on the iPhone: a surround song played on an audio interface, each channel on an output of its own. %@ is the number of outputs, e.g. 6.")
        }
        // Handed to iOS whole: only what iOS says it does with it.
        switch signal.systemSurround {
        case .spatial?:
            return signal.systemRendering == .dolbyAtmos
                ? String(localized: "SPATIAL AUDIO · DOLBY ATMOS", comment: "Signal badge on the iPhone: iOS says it plays this surround song as Spatial Audio in Dolby Atmos. Dolby Atmos stays as it is.")
                : String(localized: "SPATIAL AUDIO", comment: "Signal badge on the iPhone: iOS says it plays this surround song as Spatial Audio (on AirPods or Beats).")
        case .surround?:
            let channels = signal.systemChannels ?? signal.channels
            return String(localized: "SURROUND · \(String(channels)) CHANNELS TO iOS", comment: "Signal badge on the iPhone: a surround song is handed to iOS with all its channels, but iOS doesn't say it spatializes it. %@ is the number of channels, e.g. 6. iOS stays as it is.")
        case .stereo?:
            return String(localized: "SURROUND · iOS PLAYS STEREO", comment: "Signal badge on the iPhone: a surround song is handed to iOS with all its channels, and iOS says it plays it as stereo. iOS stays as it is.")
        case .pending?:
            return String(localized: "SURROUND TO iOS · SPATIAL AUDIO ON", comment: "Signal badge on the iPhone: a surround song was handed to iOS with all its channels, and iOS says Spatial Audio is on for this output; iOS hasn't said how it renders the song. iOS stays as it is.")
        case nil: break
        }
        switch signal.surround {
        case .headTracked?, .fixed?: return String(localized: "BINAURAL · FIXED", comment: "Signal badge on the iPhone: a surround song rendered for headphones by the app itself (not by iOS), not following the head.")
        case .off?: return String(localized: "SURROUND FOLDED TO STEREO", comment: "Signal badge on the iPhone: a surround song mixed down to two channels.")
        case nil: break
        }
        if signal.cut {
            return String(localized: "CUT ON THE MAC", comment: "Signal badge on the iPhone: the song is one track cut out of a longer lossless file (a CUE sheet album) by the Mac, with its sound unchanged. Same style as CONVERTED ON THE MAC.")
        }
        if signal.convertedHere {
            return String(localized: "CONVERTED ON THIS DEVICE", comment: "Signal badge on the iPhone or iPad (short, uppercase): the song is a DSD file that this device converted to PCM itself, with no Mac involved. Same style as CONVERTED ON THE MAC.")
        }
        if signal.converted {
            return String(localized: "CONVERTED ON THE MAC", comment: "Signal badge: the Mac converted this song to a format the iPhone can play.")
        }
        // The two stronger wordings hold only while nothing is known to change the samples on the way to a DAC
        // (`PhoneSignal.untouched`): a lower volume, another rate, Bluetooth or the speaker, or anything Vespertine does
        // to the sound brings back the plain one.
        if signal.verifiedOnDAC {
            return String(localized: "ORIGINAL FILE · VERIFIED ON THIS DAC", comment: "Signal badge on the iPhone (short, uppercase): the song's own lossless file plays with nothing changing its samples, on a DAC that passed the DoP listening test at this song's sample rate. DAC stays as it is.")
        }
        if signal.untouched {
            return String(localized: "ORIGINAL FILE · NO PROCESSING", comment: "Signal badge on the iPhone (short, uppercase): the song's own lossless file plays on a DAC at the song's own sample rate, with the volume at 100% and nothing in Vespertine changing the sound.")
        }
        return String(localized: "ORIGINAL FILE", comment: "Signal badge: the iPhone plays the song's own file, as it is on the Mac.")
    }

    /// The DoP test's results for a DAC, as rows: the rates it played the chord at, and the rates it didn't.
    static func dopRows(_ dacs: DoPDACs, route: PhoneRoute?) -> [(label: String, value: String)] {
        let results = dacs.results(for: route?.uid)
        func rates(_ passed: Bool) -> String? {
            let list = results.filter { ($0.result == .passed) == passed }.map { PhoneSignal.kilohertz($0.carrier) }
            return list.isEmpty ? nil : String(localized: "\(list.joined(separator: ", ")) kHz", comment: "Signal chip: a sample rate.")
        }
        var rows: [(String, String)] = []
        if let passed = rates(true) {
            rows.append((String(localized: "DoP passed at", comment: "Row label on the iPhone's Output screen: the sample rates at which this DAC passed the DoP listening test. The value is a list of rates, e.g. 176.4, 352.8 kHz. DoP stays as it is."), passed))
        }
        if let failed = rates(false) {
            rows.append((String(localized: "DoP not passed at", comment: "Row label on the iPhone's Output screen: the sample rates at which this DAC did not pass the DoP listening test. The value is a list of rates, e.g. 192, 384 kHz. DoP stays as it is."), failed))
        }
        return rows
    }

    /// What the output runs at, and that iOS changed the rate to get there when it did.
    static func output(_ signal: PhoneSignal) -> String {
        guard let rate = signal.outputRate, rate > 0 else { return "" }
        let kilohertz = PhoneSignal.kilohertz(rate)
        var text = signal.resampled ? String(localized: "\(kilohertz) kHz, resampled by iOS", comment: "Signal chip on the iPhone: the output's sample rate, which differs from the song's.")
                                    : String(localized: "\(kilohertz) kHz", comment: "Signal chip: a sample rate.")
        // On a DAC, a volume below the top means it isn't getting the song's own samples: said, not hidden.
        if signal.onDAC, signal.volumeReduced, let volume = signal.volume {
            text += " · " + String(localized: "volume \(percent(volume))", comment: "Signal chip on the iPhone, after the sample rate: the device's volume when it is not at 100%, lowercase. %@ is a percentage such as 80%.")
        }
        return text
    }

    static func percent(_ level: Double) -> String {
        min(max(level, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The Output screen's read-back: what the song is and what iOS says the output is doing with it. Facts only.
    static func report(_ signal: PhoneSignal, route: PhoneRoute?, dop: DoPDACs = DoPDACs()) -> [(label: String, value: String)] {
        var rows: [(String, String)] = [
            (String(localized: "Song", comment: "Row label on the iPhone's Output screen: the playing song's format, e.g. 24/192."), signal.streamFormat),
            (String(localized: "Song’s channels", comment: "Row label on the iPhone's Output screen: how many channels the playing song has."), String(signal.channels)),
        ]
        if signal.dsdRate != nil {
            // The DSD bits travel in DoP frames at this rate; the output has to run at exactly it (the rows below say).
            rows.append(("DoP", String(localized: "\(PhoneSignal.kilohertz(signal.streamRate)) kHz", comment: "Signal chip: a sample rate.")))
        }
        if let route {
            rows.append((String(localized: "Output"), route.name))
            if route.sampleRate > 0 {
                rows.append((String(localized: "Output runs at", comment: "Row label on the iPhone's Output screen: the sample rate the output device runs at now."),
                             String(localized: "\(PhoneSignal.kilohertz(route.sampleRate)) kHz", comment: "Signal chip: a sample rate.")))
            }
            if route.channels > 0 {
                rows.append((String(localized: "Output’s channels", comment: "Row label on the iPhone's Output screen: how many channels the output device runs with now."), String(route.channels)))
            }
            rows.append((String(localized: "Resampled by iOS", comment: "Row label on the iPhone's Output screen: whether iOS changes the song's sample rate on the way to the output. The value is Yes or No."),
                         signal.resampled ? String(localized: "Yes") : String(localized: "No")))
        }
        if signal.discreteOutputs != nil {
            rows.append((String(localized: "Surround"), String(localized: "A channel to each output", comment: "Value on the iPhone's Output screen, for the row Surround: each channel of a surround song goes to its own output of an audio interface, unmixed.")))
        } else if let sent = signal.systemChannels {
            // Handed to iOS whole. What iOS does with it is iOS's word, read back; Fixed or Head Tracked isn't told to apps.
            rows.append((String(localized: "Channels sent to iOS", comment: "Row label on the iPhone's Output screen: how many channels of a surround song the app hands to iOS, for iOS's Spatial Audio to render. iOS stays as it is."), String(sent)))
            rows.append((String(localized: "Spatial Audio on this output", comment: "Row label on the iPhone's Output screen: whether iOS says the output can play Spatial Audio and it is turned on. The value is On or Off."),
                         signal.routeSpatial ? String(localized: "On") : String(localized: "Off")))
            rows.append((String(localized: "Surround on Headphones"), String(localized: "Spatial Audio by iOS", comment: "Value on the iPhone's Output screen, for the row Surround on Headphones: the surround song is handed to iOS, whose Spatial Audio renders it (Fixed or Head Tracked as chosen in Control Center). iOS stays as it is.")))
        } else if let surround = signal.surround, route?.isHeadphones == true {
            // What is being done to the song right now.
            let value = switch surround {
            case .off: String(localized: "Off")
            case .fixed, .headTracked: String(localized: "Rendered by Vespertine, fixed", comment: "Value on the iPhone's Output screen, for the row Surround on Headphones: the app renders the surround song for headphones itself (iOS doesn't spatialize on these headphones), without following the head.")
            }
            rows.append((String(localized: "Surround on Headphones"), value))
        }
        if signal.channels > 2, let mode = signal.systemRendering, let name = renderingName(mode) {
            rows.append((String(localized: "iOS renders it as", comment: "Row label on the iPhone's Output screen: how iOS says it renders the app's audio (AVAudioSession rendering mode). The value is Stereo, Surround, Spatial Audio, Dolby Audio or Dolby Atmos. iOS stays as it is."), name))
        }
        // Only while ReplayGain is on: what is being done to this song's samples, or that nothing is.
        if let gain = signal.replayGain {
            rows.append((String(localized: "ReplayGain"), String(localized: "\(decibels(gain)) dB")))
        } else if signal.replayGainHasNothing {
            rows.append((String(localized: "ReplayGain"), String(localized: "None for this song", comment: "Value on the iPhone's Output screen, for the row ReplayGain: ReplayGain is turned on, but the playing song has no ReplayGain values (or is DSD sent as DoP), so it plays unchanged.")))
        }
        if let volume = signal.volume { rows.append((String(localized: "Volume"), percent(volume))) }
        if signal.untouched {
            rows.append((String(localized: "Original file", comment: "Row label on the iPhone's Output screen: the song's own lossless file is playing. The value is No processing or Verified on this DAC."),
                         signal.verifiedOnDAC ? String(localized: "Verified on this DAC", comment: "Value on the iPhone's Output screen, for the row Original file: this DAC passed the DoP listening test at this song's sample rate. DAC stays as it is.")
                                              : String(localized: "No processing", comment: "Value on the iPhone's Output screen, for the row Original file: nothing changes the song's samples on the way to the DAC.")))
        }
        rows.append(contentsOf: dopRows(dop, route: route).map { ($0.label, $0.value) })
        return rows
    }

    /// iOS's rendering mode in words; nil while iOS hasn't said.
    static func renderingName(_ mode: SystemRenderingMode) -> String? {
        switch mode {
        case .notApplicable: nil
        case .monoStereo: String(localized: "Stereo", comment: "Value on the iPhone's Output screen, for the row iOS renders it as: iOS plays the audio as plain two-channel stereo.")
        case .surround: String(localized: "Surround")
        case .spatialAudio: String(localized: "Spatial Audio")
        // Brand names, the same in every language.
        case .dolbyAudio: "Dolby Audio"
        case .dolbyAtmos: "Dolby Atmos"
        }
    }

    /// "−6.2", "+1.5": a gain with its sign, to one decimal place.
    static func decibels(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + abs(value).formatted(.number.precision(.fractionLength(1)))
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
