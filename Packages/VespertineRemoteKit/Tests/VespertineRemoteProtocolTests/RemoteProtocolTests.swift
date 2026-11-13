//
// Vespertine: the remote protocol's wire format, pairing links and position arithmetic.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try RemoteProtocol.encoder().encode(value)
    return try RemoteProtocol.decoder().decode(T.self, from: data)
}

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try RemoteProtocol.encoder().encode(value), as: UTF8.self)
}

private let track = TrackSummary(id: 42, title: "So What", artist: "Miles Davis", album: "Kind of Blue",
                                 albumKey: "miles davis\u{1F}kind of blue", duration: 562.3, trackNumber: 1, discNumber: 1,
                                 format: "FLAC · 24/192", artworkKey: "abc123", favorite: true)

/// A favorite the library has twice: the ALAC file and a Dolby Atmos mix.
private let copied: TrackSummary = {
    var song = track
    song.copies = [TrackCopy(id: 42, format: "ALAC · 24/96", hiRes: true, edition: nil, location: "Music › Miles Davis/Kind of Blue", duration: 562.3, favorite: true, preferred: false),
                   TrackCopy(id: 43, format: "Dolby Atmos · 768k · 5.1", hiRes: false, edition: "Dolby Atmos", location: "Music Share › Spatial", duration: 562.3, favorite: true, preferred: true)]
    return song
}()

@Suite struct WireFormat {
    @Test func commandsKeepTheirShape() throws {
        // The web remote and other clients write these by hand: the shape is part of the protocol.
        #expect(try json(ClientMessage(id: 3, command: .seek(seconds: 61.5))) == #"{"command":{"seek":{"seconds":61.5}},"id":3}"#)
        #expect(try json(ClientMessage(id: 4, command: .next)) == #"{"command":{"next":{}},"id":4}"#)
        #expect(try json(ClientMessage(id: 5, command: .selectOutput(uid: nil))) == #"{"command":{"selectOutput":{}},"id":5}"#)
        #expect(try json(ClientMessage(id: 6, command: .volume(action: .up))) == #"{"command":{"volume":{"action":"up"}},"id":6}"#)
    }

    @Test func handWrittenCommandsDecode() throws {
        let decoder = RemoteProtocol.decoder()
        let pause = try decoder.decode(ClientMessage.self, from: Data(#"{"id":1,"command":{"playPause":{}}}"#.utf8))
        #expect(pause == ClientMessage(id: 1, command: .playPause))
        let output = try decoder.decode(ClientMessage.self, from: Data(#"{"id":2,"command":{"selectOutput":{"uid":"AppleUSBAudioEngine:FiiO"}}}"#.utf8))
        #expect(output.command == .selectOutput(uid: "AppleUSBAudioEngine:FiiO"))
        let system = try decoder.decode(ClientMessage.self, from: Data(#"{"id":2,"command":{"selectOutput":{}}}"#.utf8))
        #expect(system.command == .selectOutput(uid: nil))
    }

    @Test func unknownCommandsFailToDecode() {
        // A newer remote's command must fail cleanly (the Mac answers `failed`), never be taken for another one.
        #expect(throws: (any Error).self) {
            try RemoteProtocol.decoder().decode(ClientMessage.self, from: Data(#"{"id":1,"command":{"teleport":{}}}"#.utf8))
        }
    }

    @Test func everyMessageRoundTrips() throws {
        let commands: [RemoteCommand] = [
            .hello(device: "phone-1", name: "Alex's iPhone", protocolVersion: 1), .pair(name: "iPad", protocolVersion: 1),
            .playPause, .play, .pause, .next, .previous, .stop, .seek(seconds: 12), .setShuffle(on: true), .setRepeat(mode: .one),
            .jump(entry: "E1"), .removeFromQueue(entries: ["E1", "E2"]), .moveInQueue(entries: ["E2"], before: nil),
            .moveInQueue(entries: ["E2"], before: "E1"), .clearUpcoming, .playAlbum(key: "k", startAt: 2, shuffled: nil),
            .playTracks(ids: [1, 2], startAt: 1, shuffled: true), .playPlaylist(id: 9, shuffled: false), .playNext(ids: [3]),
            .addToQueue(ids: [4]), .setFavorite(ids: [5], on: false), .albums(offset: 0, limit: 100), .albumTracks(key: "k"),
            .artists, .artistAlbums(name: "Miles Davis"), .playlists, .playlistTracks(id: 2), .favorites,
            .search(text: "blue", limit: 50), .artwork(key: "abc", size: 600), .selectOutput(uid: "u"), .selectOutput(uid: nil),
            .volume(action: .mute), .setVolume(level: 0.5), .setTransitions(on: true),
            .songs(offset: 200, limit: 100), .find(text: "blue", limit: 20), .addToPlaylist(id: 2, ids: [4, 5]),
            .createPlaylist(name: "Sunday", ids: []),
            .library, .genres, .genreAlbums(key: "jazz"), .recentlyAdded(limit: 150), .sourceAlbums(id: 3),
            .playAlbums(keys: ["k", "l"], shuffled: true), .playCopy(ids: [1, 2], startAt: 1),
        ]
        for command in commands {
            let message = ClientMessage(id: 7, command: command)
            #expect(try roundTrip(message) == message)
        }

        let player = PlayerState(playback: .playing, loading: false, nowPlaying: NowPlaying(entry: "E1", track: track),
                                 position: 12.5, positionAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 562.3,
                                 shuffle: false, repeatMode: .all,
                                 signal: SignalSummary(bitPerfect: true, badge: "BIT-PERFECT", deviceFormat: "24/192", exclusive: true),
                                 output: "FiiO K11", volume: VolumeState(route: .hardware, level: 0.4, muted: false),
                                 waitingFor: nil, error: nil, transitions: nil)
        let server = ServerInfo(name: "Living Room", serverID: "S1", appVersion: "1.1.0")
        let messages: [ServerMessage] = [
            .player(player),
            .queue(QueueState(revision: 3, current: QueueItem(entry: "E1", track: track), playingNext: [], continuing: [QueueItem(entry: "E2", track: track)], continuingTotal: 1)),
            .outputs(OutputsState(outputs: [OutputSummary(uid: nil, name: "System Default", detail: "", kind: .systemDefault, selected: true, ready: true)])),
            .goodbye(reason: .deviceRemoved),
            .reply(id: 1, result: .ok), .reply(id: 2, result: .failed(reason: "No")), .reply(id: 3, result: .welcome(server)),
            .reply(id: 4, result: .paired(device: "phone-1", key: Data([1, 2, 3]), server: server)),
            .reply(id: 5, result: .albums(items: [AlbumSummary(key: "k", title: "Kind of Blue", artist: "Miles Davis", year: 1959, trackCount: 5, duration: 2760, format: "FLAC · 24/192", artworkKey: nil, hiRes: true, dsd: false, multichannel: false)], total: 1)),
            .reply(id: 6, result: .tracks(items: [track])),
            .reply(id: 7, result: .artists(items: [ArtistSummary(name: "Miles Davis", albumCount: 3, artworkKey: "a")])),
            .reply(id: 8, result: .playlists(items: [PlaylistSummary(id: 1, name: "Late", smart: true)])),
            .reply(id: 9, result: .artwork(key: "abc", size: 600, mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))),
            .reply(id: 10, result: .songs(items: [track], total: 4_812)),
            .reply(id: 11, result: .found(SearchResults(
                tracks: [track], albums: [], artists: [ArtistSummary(name: "Miles Davis", albumCount: 3, artworkKey: nil)],
                playlists: [PlaylistSummary(id: 1, name: "Late", smart: false, trackCount: 12, artworkKeys: ["a", "b"])]))),
            .reply(id: 12, result: .genres(items: [GenreSummary(key: "jazz", name: "Jazz", albumCount: 12, artworkKeys: ["a", "b"])])),
            .reply(id: 13, result: .library(LibraryOverview(albums: 900, artists: 300, songs: 11_000, genres: 40, favorites: 120, playlists: 9, sources: [
                SourceSummary(id: 3, name: "Music Share", kind: .network, online: true, scanning: false, albumCount: 800, detail: "REFERENCED IN PLACE · ONLINE")]))),
            .reply(id: 14, result: .tracks(items: [copied])),
        ]
        for message in messages { #expect(try roundTrip(message) == message) }
    }
}

@Suite struct Additions {
    @Test func theNewCommandsKeepTheirShape() throws {
        // The web remote writes these by hand too.
        #expect(try json(RemoteCommand.songs(offset: 0, limit: 100)) == #"{"songs":{"limit":100,"offset":0}}"#)
        #expect(try json(RemoteCommand.find(text: "blue", limit: 20)) == #"{"find":{"limit":20,"text":"blue"}}"#)
        #expect(try json(RemoteCommand.addToPlaylist(id: 2, ids: [4, 5])) == #"{"addToPlaylist":{"id":2,"ids":[4,5]}}"#)
        #expect(try json(RemoteCommand.createPlaylist(name: "Sunday", ids: [])) == #"{"createPlaylist":{"ids":[],"name":"Sunday"}}"#)
        #expect(try json(RemoteReply.songs(items: [], total: 0)) == #"{"songs":{"items":[],"total":0}}"#)
    }

    @Test func theLibrarySectionCommandsKeepTheirShape() throws {
        #expect(try json(RemoteCommand.library) == #"{"library":{}}"#)
        #expect(try json(RemoteCommand.genres) == #"{"genres":{}}"#)
        #expect(try json(RemoteCommand.genreAlbums(key: "jazz")) == #"{"genreAlbums":{"key":"jazz"}}"#)
        #expect(try json(RemoteCommand.recentlyAdded(limit: 150)) == #"{"recentlyAdded":{"limit":150}}"#)
        #expect(try json(RemoteCommand.sourceAlbums(id: 3)) == #"{"sourceAlbums":{"id":3}}"#)
        #expect(try json(RemoteCommand.playAlbums(keys: ["k"], shuffled: nil)) == #"{"playAlbums":{"keys":["k"]}}"#)
        #expect(try json(RemoteCommand.playCopy(ids: [1, 2], startAt: 1)) == #"{"playCopy":{"ids":[1,2],"startAt":1}}"#)
    }

    @Test func aSongFromAnOlderMacHasNoCopies() throws {
        // 1.1.2 doesn't say `copies`: the song decodes, and a remote shows it as a song in one copy.
        let old = #"{"album":"Kind of Blue","albumKey":"k","artist":"Miles Davis","duration":562.3,"favorite":true,"format":"FLAC · 24/192","id":42,"title":"So What"}"#
        let song = try RemoteProtocol.decoder().decode(TrackSummary.self, from: Data(old.utf8))
        #expect(song.copies == nil && song.title == "So What")
        // And a song in one copy is sent as before, with no `copies` key for an older remote to trip over.
        #expect(try !json(track).contains("copies"))
    }

    @Test func aPlaylistFromAnOlderMacStillDecodes() throws {
        // 1.1.0 sends only these three; a remote must take them, and say nothing it wasn't told.
        let old = try RemoteProtocol.decoder().decode(PlaylistSummary.self, from: Data(#"{"id":7,"name":"Late","smart":false}"#.utf8))
        #expect(old == PlaylistSummary(id: 7, name: "Late", smart: false))
        #expect(old.trackCount == nil && old.artworkKeys == nil)
        #expect(try json(old) == #"{"id":7,"name":"Late","smart":false}"#)
        let new = PlaylistSummary(id: 7, name: "Late", smart: false, trackCount: 3, artworkKeys: ["a"])
        #expect(try json(new) == #"{"artworkKeys":["a"],"id":7,"name":"Late","smart":false,"trackCount":3}"#)
    }

    @Test func theProtocolVersionStays() {
        // Everything added is new commands and optional fields: nothing a 1.1.0 remote or Mac would misread.
        #expect(RemoteProtocol.version == 1)
    }
}

@Suite struct Position {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ playback: PlaybackValue, at position: Double, _ date: Date) -> PlayerState {
        PlayerState(playback: playback, loading: false, nowPlaying: nil, position: position, positionAt: date, duration: 300,
                    shuffle: false, repeatMode: .off, signal: nil, output: nil, volume: VolumeState(route: .fixed, level: nil, muted: false),
                    waitingFor: nil, error: nil, transitions: nil)
    }

    @Test func playingMovesOnByItself() {
        let playing = state(.playing, at: 10, start)
        #expect(playing.expectedPosition(at: start.addingTimeInterval(5)) == 15)
        #expect(playing.expectedPosition(at: start.addingTimeInterval(1000)) == 300)
        #expect(state(.paused, at: 10, start).expectedPosition(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func onlyJumpsAreNews() {
        let sent = state(.playing, at: 10, start)
        #expect(!sent.differs(from: state(.playing, at: 15.2, start.addingTimeInterval(5))))
        #expect(sent.differs(from: state(.playing, at: 90, start.addingTimeInterval(5))))
        #expect(sent.differs(from: state(.paused, at: 15, start.addingTimeInterval(5))))
    }
}

@Suite struct PairingLinks {
    @Test func linkRoundTrips() throws {
        let link = PairingLink(serverID: "8F3A-11", name: "Alex’s Mac mini & Co +1", secret: PairingSecret.makeLinkSecret())
        #expect(link.url.absoluteString.hasPrefix("vespertine-remote://pair?"))
        #expect(PairingLink(url: link.url) == link)
    }

    @Test func otherLinksAreRefused() {
        #expect(PairingLink(url: URL(string: "https://example.com/pair?id=1&secret=2")!) == nil)
        #expect(PairingLink(url: URL(string: "vespertine-remote://pair?id=1")!) == nil)
        #expect(PairingLink(url: URL(string: "vespertine-remote://open?id=1&secret=2")!) == nil)
    }

    @Test func secretsAreLongAndCodesAreSixDigits() {
        let secret = PairingSecret.makeLinkSecret()
        #expect(secret.count == 26)
        #expect(secret.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        #expect(secret != PairingSecret.makeLinkSecret())
        for _ in 0..<50 {
            let code = PairingSecret.makeTypedCode()
            #expect(code.count == 6 && code.allSatisfy(\.isNumber) && code.first != "0")
        }
        #expect(PairingSecret.normalizedCode("123 456") == "123456")
        #expect(PairingSecret.normalizedCode(" 12-34 56\n") == "123456")
    }

    @Test func base32MatchesRFC4648() {
        // RFC 4648 test vectors, lowercase and without padding.
        #expect(PairingSecret.base32(Array("foobar".utf8)) == "mzxw6ytboi")
        #expect(PairingSecret.base32(Array("f".utf8)) == "my")
        #expect(PairingSecret.base32([]) == "")
    }

    @Test func credentialsAreUnique() {
        let a = DeviceCredential.make(), b = DeviceCredential.make()
        #expect(a.key.count == 32 && a.device.hasPrefix("phone-"))
        #expect(a != b)
    }

    #if canImport(CryptoKit)
    @Test func pairingKeyDependsOnSecretAndServer() {
        let key = PairingKey.derive(secret: "123456", serverID: "A")
        #expect(key.count == 32)
        #expect(key == PairingKey.derive(secret: "123456", serverID: "A"))
        #expect(key != PairingKey.derive(secret: "123457", serverID: "A"))
        #expect(key != PairingKey.derive(secret: "123456", serverID: "B"))
    }
    #endif
}
