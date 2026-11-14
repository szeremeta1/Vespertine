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

    public init(name: String, portType: String, sampleRate: Double, channels: Int, spatial: Bool) {
        self.name = name
        self.portType = portType
        self.sampleRate = sampleRate
        self.channels = channels
        self.spatial = spatial
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

    public init(stream: StreamDescriptor, route: PhoneRoute?) {
        converted = stream.kind != .original
        lossless = stream.format.lossless
        streamRate = stream.format.sampleRate
        bitDepth = stream.format.bitDepth
        channels = stream.format.channels
        outputRate = route.map(\.sampleRate)
    }

    /// "24/96", "16/44.1", or "48 kHz" for lossy audio.
    public var streamFormat: String {
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
    public var route: PhoneRoute? { didSet { applySurround() } }
    /// The device's own volume, 0…1, when known (the app keeps it current): shown, never changed from here.
    public var outputVolume: Double?
    /// How you want surround songs played; the output decides what it gets (`PhoneRoute.surroundMode`).
    public var surroundChoice: SpatialModeChoice = .headTracked { didSet { applySurround() } }

    private func applySurround() {
        let mode = route.map { $0.surroundMode(wanted: surroundChoice) } ?? surroundChoice
        let wanted: SpatialMode = switch mode {
        case .off: .off
        case .fixed: .fixed
        case .headTracked: .headTracked
        }
        if playback.player.spatialMode != wanted { playback.player.spatialMode = wanted }
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
            return await play(.albumTracks(key: key)) { self.playback.play($0, startAt: startAt, shuffled: shuffled) }
        case .playTracks(let ids, let startAt, let shuffled):
            return await play(.tracks(ids: ids)) { self.playback.play($0, startAt: startAt, shuffled: shuffled) }
        case .playCopy(let ids, let startAt):
            // The songs by their own IDs are the very copies asked for.
            return await play(.tracks(ids: ids)) { self.playback.play($0, startAt: startAt, shuffled: false) }
        case .playPlaylist(let id, let shuffled):
            return await play(.playlistTracks(id: id)) { self.playback.play($0, shuffled: shuffled) }
        case .playNext(let ids):
            return await play(.tracks(ids: ids)) { self.playback.playNext($0) }
        case .addToQueue(let ids):
            return await play(.tracks(ids: ids)) { self.playback.addToQueue($0) }
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
            playback.play(all, shuffled: shuffled)

        case .volume, .setVolume, .setTransitions:
            // The phone's volume is the phone's own (its buttons); transitions are the Mac player's.
            break
        default:
            return await library(command)
        }
        return .ok
    }

    private func play(_ ask: RemoteCommand, then start: ([TrackSummary]) -> Void) async -> RemoteReply {
        switch await library(ask) {
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
            }
            return signal
        }
    }

    public var playerState: PlayerState {
        let entry = playback.nowPlaying
        let state = playback.player.state
        let waiting = state == .loading || playback.preparing != nil || playback.player.isBuffering || (playback.isPlaying && state == .idle)
        let value: PlaybackValue = entry == nil ? .stopped : (playback.isPlaying ? .playing : (state == .idle ? .stopped : .paused))
        let summary = signal.map { signal -> SignalSummary in
            let said = words(signal)
            return SignalSummary(bitPerfect: false, badge: said.badge, deviceFormat: said.output, exclusive: false)
        }
        return PlayerState(playback: value, loading: waiting, nowPlaying: entry.map { NowPlaying(entry: $0.id, track: $0.track) },
                           position: playback.position, positionAt: Date(), duration: playback.duration,
                           shuffle: playback.queue.shuffle, repeatMode: playback.queue.repeatMode, signal: summary, output: route?.name,
                           volume: VolumeState(route: .fixed, level: outputVolume, muted: false), waitingFor: nil, error: playback.notice, transitions: nil)
    }
}
#endif
