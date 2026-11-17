//
// Vespertine: "This iPhone" as a place to play, behind the same commands the screens send to the Mac. Transport, queue and
// "play this" commands act on the phone's own queue and player (the Mac is only asked which songs an album or a playlist
// holds); what the screens read back has the Mac's shape, so Now Playing and the queue draw either with the same code.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

/// Where the phone's sound goes right now, as iOS reports it.
public struct PhoneRoute: Equatable, Sendable {
    public var name: String
    /// `AVAudioSession.Port` raw value ("BluetoothA2DPOutput", "USBAudio", "Speaker", "Headphones"…).
    public var portType: String
    /// The rate iOS runs the route at.
    public var sampleRate: Double
    public var channels: Int
    /// iOS can spatialize on this route (AirPods with Spatial Audio).
    public var spatial: Bool
    /// The most output channels iOS says this route can run with (a 5.1 interface says 6 while it runs with 2).
    public var maximumChannels: Int
    /// The speaker each output channel is, when the output says (`AudioChannelLabel` values). Most interfaces don't.
    public var channelLabels: [UInt32]?
    /// iOS's own identifier for the output (`AVAudioSessionPortDescription.uid`): what a DAC's DoP test answer is kept by.
    public var uid: String?

    public init(name: String, portType: String, sampleRate: Double, channels: Int, spatial: Bool, maximumChannels: Int? = nil, channelLabels: [UInt32]? = nil,
                uid: String? = nil) {
        self.uid = uid
        self.name = name
        self.portType = portType
        self.sampleRate = sampleRate
        self.channels = channels
        self.spatial = spatial
        self.maximumChannels = max(maximumChannels ?? channels, channels)
        self.channelLabels = channelLabels
    }

    public var isBluetooth: Bool { portType.hasPrefix("Bluetooth") }
    public var isUSB: Bool { portType == "USBAudio" }
    public var isBuiltIn: Bool { portType == "Speaker" || portType == "Receiver" }
    /// A route whose rate iOS fixes: asking it for another one is pointless (and on Bluetooth, harmful).
    public var hasFixedRate: Bool { isBluetooth || isBuiltIn || portType == "AirPlay" || portType == "CarAudio" }

    /// The most a conversion on the Mac should deliver for this route: the route's own rate where iOS fixes it (so a DSD
    /// album isn't sent at 176.4 kHz to be resampled to 48), no cap for a DAC.
    public var conversionCap: Double? { hasFixedRate && sampleRate > 0 ? sampleRate : nil }
}

/// What reaches the output, in facts the app puts into words: nothing here ever says "bit-perfect".
public struct PhoneSignal: Equatable, Sendable {
    /// The Mac made a FLAC of the song (a format the phone can't open), rather than sending the file as it is.
    public var converted: Bool
    /// The conversion was made on this device, from a file it read itself (a DSD file on a share), not by a Mac.
    public var convertedHere: Bool
    /// The Mac only cut the song out of a longer lossless file (a CUE track): its samples are the file's own.
    public var cut: Bool
    public var lossless: Bool
    /// The rate of what the phone decodes.
    public var streamRate: Double
    public var bitDepth: Int?
    public var channels: Int
    /// The rate the output runs at, when known.
    public var outputRate: Double?
    /// iOS changes the rate between the two.
    public var resampled: Bool { outputRate.map { $0 > 0 && abs($0 - streamRate) > 0.5 } ?? false }
    /// For a surround song: how it is being played (`.off` is the fold to stereo). nil for stereo and mono.
    public var surround: SpatialModeChoice?
    /// For a surround song on an interface with more than two outputs: how many outputs it plays on, a channel each.
    public var discreteOutputs: Int?
    /// For a surround song handed to iOS whole (`SurroundPath.system`): how many channels iOS is given. nil otherwise.
    public var systemChannels: Int?
    /// What iOS says it renders the app's audio as, read back while it plays. nil: not read.
    public var systemRendering: SystemRenderingMode?
    /// The route can spatialize and Spatial Audio is on for it, as iOS says (`isSpatialAudioEnabled`).
    public var routeSpatial = false

    /// What iOS does with a surround song handed to it whole, in iOS's own words; nil when none was handed over.
    public enum SystemSurround: Equatable, Sendable {
        /// iOS says it renders it as Spatial Audio (or Dolby Atmos / Dolby Audio) on a route where Spatial Audio is on.
        case spatial
        /// iOS has the channels but doesn't say it spatializes them.
        case surround
        /// iOS says it plays it as stereo.
        case stereo
        /// Handed over to an output iOS says has Spatial Audio on, and iOS's rendering mode doesn't say more. Measured on
        /// an iPhone 15 Pro Max (iOS 26.3.1, speaker): the rendering mode stays "not applicable" for a sample buffer
        /// renderer's six channels, so this is what the badge usually shows; it says what iOS reported, nothing more.
        case pending
    }

    /// Spatial only when iOS says so twice: the route has Spatial Audio on, and the rendering mode it resolved is a
    /// spatial one. Never from what the app asked for.
    public var systemSurround: SystemSurround? {
        guard let sent = systemChannels, sent > 2 else { return nil }
        switch systemRendering {
        case nil, .notApplicable?: return routeSpatial ? .pending : .surround
        case .monoStereo?: return .stereo
        case .surround?: return .surround
        case .spatialAudio?, .dolbyAudio?, .dolbyAtmos?: return routeSpatial ? .spatial : .surround
        }
    }
    /// The channels the output runs with, when known.
    public var outputChannels: Int?
    /// The device's own volume, 0…1, when known.
    public var volume: Double?
    /// The volume isn't at its top: what reaches a DAC is not the song's own samples.
    public var volumeReduced: Bool { volume.map { $0 < 0.995 } ?? false }
    /// The output is one that can run at a song's own rate (a DAC, the headphone adapter), where the volume and the rate
    /// decide whether it gets the song's samples as they are.
    public var onDAC = false
    /// The song is DSD and its own bits are being sent to the DAC as DoP frames: the DSD rate (2822400 for DSD64). Only
    /// ever set for a DAC that passed the DoP test here. nil: PCM.
    public var dsdRate: Double?
    /// Sent as DoP, but the output isn't at the carrier rate or the volume isn't at its top: the DAC isn't getting DSD.
    public var dopBroken: Bool { dsdRate != nil && (resampled || volumeReduced) }
    /// The phone holds the file itself, as it is on the Mac or the share: nothing was converted or cut out for it.
    public var original: Bool
    /// Vespertine is changing the samples on purpose (a gain, an equalizer, anything of the kind). Whatever does so sets
    /// this, and the "no processing" wording goes while it is set.
    public var processed = false
    /// This DAC played the DoP test's chord at exactly the rate this song plays at (`DoPDACs.passed(at:for:)`): frames at
    /// this rate were shown to reach it as sent.
    public var dacPassedAtRate = false
    /// The ReplayGain being applied to the song, in decibels (after its peak has had its say). nil: none is.
    public var replayGain: Double?
    /// ReplayGain is on and this song has nothing done to it: its file has no values, or it is DSD sent as DoP.
    public var replayGainHasNothing = false

    /// Nothing between the file and the DAC is known to change the song's samples: it is the lossless file itself,
    /// Vespertine does nothing to it, and iOS reports a DAC running at the song's own rate and channel count with the
    /// volume at its top. Everything here is read back or true of how the song is played; none of it is a measurement
    /// at the DAC. Anything unknown (the rate, the volume) counts against it, and so does Bluetooth, AirPlay or the
    /// speaker, where iOS always converts.
    public var untouched: Bool {
        guard original, lossless, dsdRate == nil, !processed, surround == nil, discreteOutputs == nil, systemChannels == nil, onDAC else { return false }
        guard let outputRate, outputRate > 0, !resampled, outputChannels == channels else { return false }
        guard let volume, volume >= 0.995 else { return false }
        return true
    }

    /// `untouched`, on a DAC that passed the DoP test at this song's rate: the one case where something other than
    /// iOS's word says frames at this rate arrive as sent. The test carries 24 bits, so it says nothing for a song
    /// with more.
    public var verifiedOnDAC: Bool { untouched && dacPassedAtRate && (bitDepth ?? .max) <= 24 }

    public init(stream: StreamDescriptor, route: PhoneRoute?) {
        dsdRate = stream.dsdRate
        // A file this device decoded itself is the song's own file, as one iOS decodes is.
        original = stream.kind == .original || stream.kind == .decoded
        converted = !original
        convertedHere = stream.kind == .pcm
        cut = stream.kind == .flac && stream.cut == true
        lossless = stream.format.lossless
        streamRate = stream.format.sampleRate
        bitDepth = stream.format.bitDepth
        channels = stream.format.channels
        outputRate = route.map(\.sampleRate)
        outputChannels = route.map(\.channels)
        routeSpatial = route?.spatial ?? false
        onDAC = route.map { !$0.hasFixedRate } ?? false
    }

    /// "24/96", "16/44.1", or "48 kHz" for lossy audio.
    public var streamFormat: String {
        // DoP frames are 24-bit samples at the carrier rate only as packaging: the song is DSD.
        if let dsdRate { return DoPGate.name(dsdRate: dsdRate) }
        let rate = Self.kilohertz(streamRate)
        return bitDepth.map { "\($0)/\(rate)" } ?? "\(rate) kHz"
    }

    public static func kilohertz(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
    }
}

#if canImport(Network) && canImport(AVFAudio)
import Observation
import VespertineChannels

@MainActor
@Observable
public final class PhoneRemote {
    public let playback: PhonePlayback
    /// Where the sound goes (the app keeps it current from the audio session).
    public var route: PhoneRoute? { didSet { applySurround(); if route != oldValue { playback.outputChanged(); followOutput() } } }
    /// The Mac's name, for "Waiting for … to connect" while a song waits for it.
    public var macName: String?
    /// The device's own volume, 0…1, when known (the app keeps it current): shown, never changed from here.
    public var outputVolume: Double? { didSet { if outputVolume != oldValue { playback.outputChanged() } } }
    /// The DACs whose DoP test you answered (the app keeps them between launches).
    public var dopDACs = DoPDACs() { didSet { if dopDACs != oldValue { onDoPDACsChanged?(dopDACs); playback.outputChanged() } } }
    @ObservationIgnored public var onDoPDACsChanged: ((DoPDACs) -> Void)?
    /// The highest carrier rate the output takes DoP at right now, or nil (`DoPGate.ceiling`).
    public var dopCeiling: Double? { DoPGate.ceiling(route: route, volume: outputVolume, dacs: dopDACs) }
    /// How you want surround songs played: folded to stereo until you choose a rendering for headphones. The output
    /// decides what it gets (`PhoneRoute.surroundMode`).
    public var surroundChoice: SpatialModeChoice = .off { didSet { applySurround(); if surroundChoice != oldValue { followOutput() } } }
    /// A song the library has in stereo and in surround plays as the version for this phone's output (`PhoneVersions`).
    /// Off, every song plays as the version asked for.
    public var combinesVersions = true { didSet { if combinesVersions != oldValue { followOutput() } } }
    /// Whether the output gets a song's surround version (`PhoneRoute.wantsSurround`): stereo while nothing is known of it.
    public var wantsSurround: Bool {
        route?.wantsSurround(wanted: surroundChoice, canTrackHead: playback.player.canTrackHead) ?? false
    }
    /// The songs of the queue that play as picked by hand (the copies sheet): the output leaves them alone.
    @ObservationIgnored private var pinned = Set<Int64>()
    /// The album the queue was started as (`PhoneVersions.album`), while everything added since is of it too.
    @ObservationIgnored private var queueAlbum: String?

    /// `tracks` as the versions that play on this output.
    private func versions(_ tracks: [TrackSummary], startAt index: Int? = nil) -> (tracks: [TrackSummary], startAt: Int?) {
        guard combinesVersions else { return (tracks, index) }
        return PhoneVersions.resolve(tracks, surround: wantsSurround, startAt: index)
    }

    /// The output changed: the songs still to come become the versions for it. The song playing stays as it is.
    private func followOutput() {
        guard combinesVersions else { return }
        let surround = wantsSurround, pinned = pinned
        let oneAlbum = queueAlbum
        playback.retrackUpcoming { entry in
            guard let id = entry.track.id, !pinned.contains(id) else { return nil }
            return PhoneVersions.changed(entry.track, surround: surround, oneAlbum: oneAlbum)
        }
    }

    /// What iOS says it renders the app's audio as (the app keeps it current from the audio session).
    public var systemRendering: SystemRenderingMode?

    private func applySurround() {
        let path = route.map { $0.surroundPath(wanted: surroundChoice, canTrackHead: playback.player.canTrackHead) }
            ?? (surroundChoice == .off ? .fold : .binaural)
        // Vespertine's own rendering is only ever Fixed: head tracking needs AirPods or Beats, and on those iOS renders.
        let wanted: SpatialMode = path == .binaural ? .fixed : .off
        let system = path == .system
        // Both at once, so the song is connected once for the new path.
        if playback.player.spatialMode != wanted || playback.player.systemSpatial != system {
            playback.player.setSurround(spatialMode: wanted, systemSpatial: system)
        }
        // An interface with more than two outputs gets a surround song's channels on outputs of their own.
        let speakers = route.flatMap { $0.isMultichannel ? ChannelLayouts.outputSpeakers(channels: $0.channels, described: $0.channelLabels) : nil }
        if playback.player.outputSpeakers != speakers { playback.player.outputSpeakers = speakers }
    }
    /// A signal in the app's language: the badge ("ORIGINAL FILE", "CONVERTED ON THE MAC"…) and what the output runs at
    /// ("48 kHz", or that iOS resampled to it).
    @ObservationIgnored public var words: (PhoneSignal) -> (badge: String, output: String) = { signal in
        ("", signal.outputRate.map { PhoneSignal.kilohertz($0) + " kHz" } ?? "")
    }
    @ObservationIgnored private let library: @MainActor (RemoteCommand) async -> RemoteReply
    /// Called with each transport command you give (play, pause, stop…), before it acts: the system glue listens.
    @ObservationIgnored public var onTransport: ((RemoteCommand) -> Void)?

    /// `library`: asks the Mac (which songs an album holds, songs by ID).
    public init(playback: PhonePlayback, library: @escaping @MainActor (RemoteCommand) async -> RemoteReply) {
        self.playback = playback
        self.library = library
        playback.maxSampleRate = { [weak self] in self?.route?.conversionCap }
        playback.dop.ceiling = { [weak self] in self?.dopCeiling }
        playback.dop.rate = { [weak self] in self?.route?.sampleRate }
        playback.dop.declined = { [weak self] carrier in
            guard let self, let uid = route?.uid else { return }
            dopDACs.declined(carrier, uid: uid)
        }
        applySurround()
    }

    /// Whether a command is about playing (the phone takes it) or about the Mac's library and outputs (the Mac does).
    public nonisolated static func handles(_ command: RemoteCommand) -> Bool {
        switch command {
        case .playPause, .play, .pause, .next, .previous, .stop, .seek, .setShuffle, .setRepeat,
             .jump, .removeFromQueue, .moveInQueue, .clearUpcoming,
             .playAlbum, .playTracks, .playPlaylist, .playNext, .addToQueue, .playAlbums, .playCopy,
             .volume, .setVolume, .setTransitions:
            true
        default:
            false
        }
    }

    public func run(_ command: RemoteCommand) async -> RemoteReply {
        switch command {
        case .playPause, .play, .pause, .stop: onTransport?(command)
        default: break
        }
        switch command {
        case .playPause: playback.playPause()
        case .play: playback.resume()
        case .pause: playback.pause()
        case .next: playback.next()
        case .previous: playback.previous()
        case .stop: playback.stop()
        case .seek(let seconds): playback.seek(to: seconds)
        case .setShuffle(let on): playback.setShuffle(on)
        case .setRepeat(let mode): playback.setRepeat(mode)
        case .jump(let entry): playback.jump(to: entry)
        case .removeFromQueue(let entries): playback.remove(entries)
        case .moveInQueue(let entries, let before): playback.moveUpcoming(entries, before: before)
        case .clearUpcoming: playback.clearUpcoming()

        case .playAlbum(let key, let startAt, let shuffled):
            return await play(.albumTracks(key: key)) { self.start($0, startAt: startAt, shuffled: shuffled) }
        case .playTracks(let ids, let startAt, let shuffled):
            return await play(.tracks(ids: ids)) { self.start($0, startAt: startAt, shuffled: shuffled) }
        case .playCopy(let ids, let startAt):
            // The songs by their own IDs are the very copies asked for, whatever the output: they stay those copies.
            return await play(.tracks(ids: ids)) {
                self.pinned = Set($0.compactMap(\.id))
                self.queueAlbum = nil
                self.playback.play($0, startAt: startAt, shuffled: false)
            }
        case .playPlaylist(let id, let startAt, let shuffled):
            // A page at a time: a long playlist in one reply would be more than a message holds.
            let songs = await PlaylistPages.load(id: id, ask: library)
            return await play(songs) { self.start($0, startAt: startAt ?? 0, shuffled: shuffled) }
        case .playNext(let ids):
            return await play(.tracks(ids: ids)) { self.playback.playNext(self.adding($0)) }
        case .addToQueue(let ids):
            return await play(.tracks(ids: ids)) { self.playback.addToQueue(self.adding($0)) }
        case .playAlbums(let keys, let shuffled):
            var all: [TrackSummary] = []
            for key in keys {
                switch await library(.albumTracks(key: key)) {
                case .tracks(let items): all += items
                case .failed(let reason) where keys.count == 1: return .failed(reason: reason)
                default: continue
                }
            }
            guard !all.isEmpty else { return .failed(reason: "") }
            start(all, shuffled: shuffled)

        case .volume, .setVolume, .setTransitions:
            // The phone's volume is the phone's own (its buttons); transitions are the Mac player's.
            break
        default:
            return await library(command)
        }
        return .ok
    }

    /// Starts `tracks` in place of the queue, each song as the version for this output.
    private func start(_ tracks: [TrackSummary], startAt index: Int = 0, shuffled: Bool? = nil) {
        pinned = []
        queueAlbum = PhoneVersions.album(of: tracks)
        let playing = versions(tracks, startAt: index)
        playback.play(playing.tracks, startAt: playing.startAt ?? 0, shuffled: shuffled)
    }

    /// Songs added to the queue, each as the version for this output.
    private func adding(_ tracks: [TrackSummary]) -> [TrackSummary] {
        if playback.queue.entries.isEmpty { queueAlbum = PhoneVersions.album(of: tracks) }
        else if let album = queueAlbum, tracks.contains(where: { $0.albumKey != album }) { queueAlbum = nil }
        let playing = versions(tracks).tracks
        // A song that went to another edition takes the queue off the one album.
        if let album = queueAlbum, playing.contains(where: { $0.albumKey != album }) { queueAlbum = nil }
        return playing
    }

    private func play(_ ask: RemoteCommand, then start: ([TrackSummary]) -> Void) async -> RemoteReply {
        await play(await library(ask), then: start)
    }

    private func play(_ answer: RemoteReply, then start: ([TrackSummary]) -> Void) async -> RemoteReply {
        switch answer {
        case .tracks(let items) where !items.isEmpty:
            start(items)
            return .ok
        case .failed(let reason):
            return .failed(reason: reason)
        default:
            return .failed(reason: "")
        }
    }

    // MARK: What the screens read

    public var queueState: QueueState { playback.queue.state }

    public var signal: PhoneSignal? {
        playback.stream.map { stream in
            var signal = PhoneSignal(stream: stream, route: route)
            switch playback.player.rendering {
            case .untouched: signal.surround = nil
            case .downmix: signal.surround = .off
            case .spatial(let tracked): signal.surround = tracked ? .headTracked : .fixed
            case .system(let channels):
                signal.surround = nil
                signal.systemChannels = channels
            case .discrete(let outputs):
                signal.surround = nil
                signal.discreteOutputs = outputs
            }
            // What iOS says it renders the app's audio as, for every song: the fold's "Stereo" is as much a fact as Spatial Audio.
            signal.systemRendering = systemRendering
            signal.volume = outputVolume
            signal.dacPassedAtRate = dopDACs.passed(at: stream.format.sampleRate, for: route?.uid)
            // ReplayGain multiplies every sample: the song is no longer the file's own samples while it does.
            signal.replayGain = playback.appliedGain?.decibels
            signal.replayGainHasNothing = playback.replayGainHasNothing
            signal.processed = playback.appliedGain != nil
            return signal
        }
    }

    public var playerState: PlayerState {
        let entry = playback.nowPlaying
        let state = playback.player.state
        let waiting = playback.waitingForMac || state == .loading || playback.preparing != nil || playback.player.isBuffering || (playback.isPlaying && state == .idle)
        // A song waiting at a place of its own (a queue put back from an earlier launch) is paused there, not stopped.
        let value: PlaybackValue = entry == nil ? .stopped : (playback.isPlaying ? .playing : (state == .idle && playback.resumeAt == nil ? .stopped : .paused))
        let summary = signal.map { signal -> SignalSummary in
            let said = words(signal)
            return SignalSummary(bitPerfect: false, badge: said.badge, deviceFormat: said.output, exclusive: false)
        }
        return PlayerState(playback: value, loading: waiting, nowPlaying: entry.map { NowPlaying(entry: $0.id, track: $0.track) },
                           position: playback.position, positionAt: playback.positionAt, duration: playback.duration,
                           shuffle: playback.queue.shuffle, repeatMode: playback.queue.repeatMode, signal: summary, output: route?.name,
                           volume: VolumeState(route: .fixed, level: outputVolume, muted: false), waitingFor: playback.waitingForMac ? macName : nil, error: playback.notice, transitions: nil)
    }
}
#endif
