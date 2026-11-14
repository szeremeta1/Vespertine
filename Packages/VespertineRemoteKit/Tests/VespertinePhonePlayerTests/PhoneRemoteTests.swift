//
// Vespertine: with "This iPhone" chosen, the screens send the same commands as for the Mac, and they act on the phone's own
// queue and player. What the screens read back has the Mac's shape.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func song(_ id: Int64, album: String = "a") -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: album, duration: 200, trackNumber: Int(id), discNumber: 1,
                 format: "FLAC · 16/44.1", artworkKey: "art-\(album)", favorite: false)
}

/// A Mac's library in memory, counting what it is asked.
@MainActor private final class FakeLibrary {
    var asked: [RemoteCommand] = []
    let albums: [String: [TrackSummary]] = ["a": (1...4).map { song($0) }, "b": (10...11).map { song($0, album: "b") }]
    let playlist: [TrackSummary] = [song(11, album: "b"), song(2)]

    func answer(_ command: RemoteCommand) async -> RemoteReply {
        asked.append(command)
        switch command {
        case .albumTracks(let key): return albums[key].map { .tracks(items: $0) } ?? .failed(reason: "That isn't in the library any more.")
        case .playlistTracks: return .tracks(items: playlist)
        case .tracks(let ids):
            let all = Dictionary(albums.values.flatMap { $0 }.map { ($0.id!, $0) }, uniquingKeysWith: { a, _ in a })
            return .tracks(items: ids.compactMap { all[$0] })
        default: return .failed(reason: "unexpected")
        }
    }
}

@Suite(.serialized) @MainActor struct PhoneRemoteTests {
    /// A phone whose Mac never opens a stream: the queue and its rules are what is under test here.
    private func made() throws -> (PhoneRemote, FakeLibrary) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let client = PhoneStreamClient(open: { _, _ in .streamPreparing(progress: 0.25) }, read: { _, _, _ in throw RemoteLinkError.closed },
                                       close: { _ in }, isConnected: { true })
        let playback = PhonePlayback(client: client, player: PhonePlayer(engine: engine),
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("phone-remote-\(UUID())"))
        playback.pollInterval = .milliseconds(10)
        let library = FakeLibrary()
        return (PhoneRemote(playback: playback, library: { await library.answer($0) }), library)
    }

    @Test func whichCommandsThePhoneTakesAndWhichStayWithTheMac() {
        for command: RemoteCommand in [.playPause, .next, .seek(seconds: 3), .playAlbum(key: "a", startAt: 0, shuffled: nil), .playNext(ids: [1]),
                                       .jump(entry: "x"), .clearUpcoming, .setShuffle(on: true), .volume(action: .up), .stop] {
            #expect(PhoneRemote.handles(command), "\(command)")
        }
        for command: RemoteCommand in [.albums(offset: 0, limit: 10), .setFavorite(ids: [1], on: true), .selectOutput(uid: nil), .library,
                                       .artwork(key: "k", size: 160), .createPlaylist(name: "n", ids: []), .favorites] {
            #expect(!PhoneRemote.handles(command), "\(command)")
        }
    }

    @Test func playingAnAlbumAsksTheMacForItsSongsAndQueuesThemOnThePhone() async throws {
        let (remote, library) = try made()
        #expect(await remote.run(.playAlbum(key: "a", startAt: 1, shuffled: nil)) == .ok)
        #expect(library.asked == [.albumTracks(key: "a")])
        let queue = remote.queueState
        #expect(queue.current?.track.id == 2)
        #expect(queue.continuing.map(\.track.id) == [3, 4])
        let player = remote.playerState
        #expect(player.nowPlaying?.track.id == 2 && player.playback == .playing && player.loading)
        remote.playback.stop()
    }

    @Test func pausingWhileTheStreamIsStillOpeningHoldsAndNextStaysPaused() async throws {
        let (remote, _) = try made()
        _ = await remote.run(.playAlbum(key: "a", startAt: 0, shuffled: nil))
        #expect(remote.playerState.playback == .playing)
        _ = await remote.run(.playPause)
        #expect(remote.playerState.playback != .playing)
        #expect(remote.queueState.current?.track.id == 1)
        _ = await remote.run(.next)
        #expect(remote.queueState.current?.track.id == 2)
        #expect(remote.playerState.playback != .playing)
        _ = await remote.run(.playPause)
        #expect(remote.playerState.playback == .playing)
        remote.playback.stop()
    }

    @Test func songsByIDKeepTheOrderAskedFor() async throws {
        let (remote, library) = try made()
        #expect(await remote.run(.playTracks(ids: [3, 1], startAt: 0, shuffled: false)) == .ok)
        #expect(await remote.run(.playNext(ids: [10])) == .ok)
        #expect(await remote.run(.addToQueue(ids: [11, 2])) == .ok)
        #expect(library.asked == [.tracks(ids: [3, 1]), .tracks(ids: [10]), .tracks(ids: [11, 2])])
        #expect(remote.queueState.current?.track.id == 3)
        #expect(remote.queueState.playingNext.map(\.track.id) == [10, 11, 2])
        #expect(remote.queueState.continuing.map(\.track.id) == [1])
        remote.playback.stop()
    }

    @Test func severalAlbumsAndAPlaylistPlayInOrder() async throws {
        let (remote, _) = try made()
        #expect(await remote.run(.playAlbums(keys: ["b", "a"], shuffled: false)) == .ok)
        #expect(([remote.queueState.current].compactMap { $0 } + remote.queueState.continuing).map(\.track.id) == [10, 11, 1, 2, 3, 4])
        #expect(await remote.run(.playPlaylist(id: 5, shuffled: false)) == .ok)
        #expect(remote.queueState.current?.track.id == 11 && remote.queueState.continuing.map(\.track.id) == [2])
        remote.playback.stop()
    }

    @Test func theMacsOwnWordsComeBackWhenItCannotListTheSongs() async throws {
        let (remote, _) = try made()
        #expect(await remote.run(.playAlbum(key: "gone", startAt: 0, shuffled: nil)) == .failed(reason: "That isn't in the library any more."))
        #expect(remote.queueState.current == nil)
        #expect(remote.playerState.playback == .stopped)
    }

    @Test func theQueueCommandsEditThePhonesQueue() async throws {
        let (remote, _) = try made()
        _ = await remote.run(.playAlbum(key: "a", startAt: 0, shuffled: nil))
        let entries = remote.queueState.continuing.map(\.entry)
        #expect(await remote.run(.removeFromQueue(entries: [entries[0]])) == .ok)
        #expect(remote.queueState.continuing.map(\.track.id) == [3, 4])
        #expect(await remote.run(.moveInQueue(entries: [entries[2]], before: entries[1])) == .ok)
        #expect(remote.queueState.continuing.map(\.track.id) == [4, 3])
        #expect(await remote.run(.jump(entry: entries[1])) == .ok)
        #expect(remote.queueState.current?.track.id == 3)
        #expect(await remote.run(.setRepeat(mode: .all)) == .ok)
        #expect(await remote.run(.setShuffle(on: true)) == .ok)
        #expect(remote.playerState.repeatMode == .all && remote.playerState.shuffle)
        #expect(await remote.run(.clearUpcoming) == .ok)
        #expect(remote.queueState.continuing.isEmpty && remote.queueState.playingNext.isEmpty)
        remote.playback.stop()
    }

    @Test func whileTheMacConvertsASongThePhoneSaysItIsLoading() async throws {
        let (remote, _) = try made()
        _ = await remote.run(.playTracks(ids: [1], startAt: 0, shuffled: nil))
        try await Task.sleep(for: .milliseconds(80))
        #expect(remote.playback.preparing?.progress == 0.25)
        #expect(remote.playerState.loading)
        #expect(await remote.run(.stop) == .ok)
        #expect(remote.playerState.playback != .playing && remote.playback.preparing == nil)
    }

    @Test func aSongHeldBackSaysWhyAndSkipsNothing() async throws {
        // Cellular data with "play over cellular" off: the song isn't asked for, and the queue stays where it is.
        let (remote, _) = try made()
        remote.playback.holdReason = { "Playing over cellular data is off." }
        _ = await remote.run(.playAlbum(key: "a", startAt: 0, shuffled: nil))
        try await Task.sleep(for: .milliseconds(60))
        #expect(remote.playerState.error == "Playing over cellular data is off.")
        #expect(remote.queueState.current?.track.id == 1)
        #expect(remote.playerState.playback != .playing && remote.playback.preparing == nil)
        // Allowed again: Play starts the same song.
        remote.playback.holdReason = { nil }
        _ = await remote.run(.playPause)
        try await Task.sleep(for: .milliseconds(60))
        #expect(remote.playback.preparing?.progress == 0.25 && remote.queueState.current?.track.id == 1)
        remote.playback.stop()
    }

    @Test func thePhonesStateSaysWhereItPlaysAndNeverClaimsBitPerfect() async throws {
        let (remote, _) = try made()
        remote.route = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        _ = await remote.run(.playTracks(ids: [1], startAt: 0, shuffled: nil))
        let state = remote.playerState
        #expect(state.output == "AirPods Max")
        #expect(state.signal?.bitPerfect != true)
        #expect(state.volume.route == .fixed)
        remote.playback.stop()
    }
}
#endif
