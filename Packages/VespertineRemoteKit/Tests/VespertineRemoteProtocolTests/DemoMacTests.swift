//
// Vespertine Remote: the demo Mac answers like a real one (it's what App Review and people without a Mac see).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol

@MainActor
struct DemoMacTests {
    private func opened() async throws -> (DemoMac, Pushes) {
        let mac = DemoMac(name: "Demo") { _, _ in Data([0x89, 0x50, 0x4E, 0x47]) }
        let pushes = Pushes()
        mac.onPush = { pushes.messages.append($0) }
        try await mac.open(timeout: .seconds(1))
        return (mac, pushes)
    }

    @MainActor final class Pushes {
        var messages: [ServerMessage] = []
        var lastQueue: QueueState? {
            for case .queue(let state) in messages.reversed() { return state }
            return nil
        }
        var lastPlayer: PlayerState? {
            for case .player(let state) in messages.reversed() { return state }
            return nil
        }
    }

    private func ask(_ mac: DemoMac, _ command: RemoteCommand) async throws -> RemoteReply {
        try await mac.request(command, timeout: .seconds(1))
    }

    @Test func welcomesThenSendsEverything() async throws {
        let (mac, pushes) = try await opened()
        let reply = try await ask(mac, .hello(device: "demo", name: "Phone", protocolVersion: RemoteProtocol.version))
        #expect(reply == .welcome(mac.info))
        for _ in 0..<20 where pushes.messages.count < 3 { await Task.yield() }
        #expect(pushes.lastPlayer?.nowPlaying != nil)
        #expect(pushes.lastQueue?.current != nil)
        #expect(pushes.messages.contains { if case .outputs(let state) = $0 { state.outputs.count == 4 } else { false } })
        mac.close()
    }

    @Test func browsesAndSearchesTheLibrary() async throws {
        let (mac, _) = try await opened()
        guard case .albums(let page, let total) = try await ask(mac, .albums(offset: 0, limit: 3)) else { Issue.record("no albums"); return }
        #expect(page.count == 3 && total == 18)
        guard case .tracks(let songs) = try await ask(mac, .albumTracks(key: page[0].key)) else { Issue.record("no tracks"); return }
        #expect(songs.first?.trackNumber == 1)
        guard case .tracks(let found) = try await ask(mac, .search(text: "nocturne", limit: 50)) else { Issue.record("no search"); return }
        #expect(found.count == 6) // every song on "Nocturnes for a Small Room"
        guard case .artwork(_, _, let type, _) = try await ask(mac, .artwork(key: page[0].artworkKey!, size: 300)) else { Issue.record("no art"); return }
        #expect(type == "image/png")
        #expect(try await ask(mac, .artwork(key: "../nope", size: 300)) == .failed(reason: ""))
        #expect(try await ask(mac, .pair(name: "x", protocolVersion: RemoteProtocol.version)) == .failed(reason: ""))
    }

    @Test func playsAndEditsTheQueue() async throws {
        let (mac, pushes) = try await opened()
        guard case .albums(let albums, _) = try await ask(mac, .albums(offset: 0, limit: 10)) else { return }
        #expect(try await ask(mac, .playAlbum(key: albums[1].key, startAt: 2, shuffled: nil)) == .ok)
        let queue = try #require(pushes.lastQueue)
        #expect(queue.current?.track.trackNumber == 3)
        #expect(pushes.lastPlayer?.playback == .playing)

        #expect(try await ask(mac, .next) == .ok)
        #expect(pushes.lastQueue?.current?.track.trackNumber == 4)

        let ids = try #require(queue.continuing.last?.track.id)
        #expect(try await ask(mac, .playNext(ids: [ids])) == .ok)
        let next = try #require(pushes.lastQueue?.playingNext.first)
        #expect(next.track.id == ids)
        #expect(try await ask(mac, .jump(entry: next.entry)) == .ok)
        #expect(pushes.lastQueue?.current?.entry == next.entry)

        let rest = try #require(pushes.lastQueue?.continuing)
        #expect(try await ask(mac, .moveInQueue(entries: [rest.last!.entry], before: rest.first!.entry)) == .ok)
        #expect(pushes.lastQueue?.continuing.first?.entry == rest.last!.entry)
        #expect(try await ask(mac, .clearUpcoming) == .ok)
        #expect(pushes.lastQueue?.continuing.isEmpty == true)

        #expect(try await ask(mac, .seek(seconds: 30)) == .ok)
        #expect(try await ask(mac, .pause) == .ok)
        #expect(pushes.lastPlayer.map { Int($0.position) } == 30)
    }

    @Test func outputsVolumeAndFavorites() async throws {
        let (mac, pushes) = try await opened()
        #expect(try await ask(mac, .setVolume(level: 0.2)) == .ok)
        #expect(pushes.lastPlayer?.volume.level == 0.2)
        #expect(try await ask(mac, .selectOutput(uid: "demo-receiver")) == .ok)
        #expect(pushes.lastPlayer?.volume.route == .fixed)
        #expect(try await ask(mac, .selectOutput(uid: "demo-group")) != .ok)
        #expect(try await ask(mac, .selectOutput(uid: "gone")) != .ok)

        guard case .tracks(let before) = try await ask(mac, .favorites) else { return }
        // The demo starts on the first album's first song.
        guard case .albums(let albums, _) = try await ask(mac, .albums(offset: 0, limit: 1)),
              case .tracks(let songs) = try await ask(mac, .albumTracks(key: albums[0].key)) else { Issue.record("no library"); return }
        let song = songs[0]
        #expect(try await ask(mac, .setFavorite(ids: [song.id!], on: !song.favorite)) == .ok)
        guard case .tracks(let after) = try await ask(mac, .favorites) else { return }
        #expect(after.count == before.count + (song.favorite ? -1 : 1))
        #expect(pushes.lastQueue?.current?.track.favorite == !song.favorite)
    }

    @Test func listsSongsInPages() async throws {
        let (mac, _) = try await opened()
        guard case .songs(let first, let total) = try await ask(mac, .songs(offset: 0, limit: 10)) else { Issue.record("no songs"); return }
        #expect(first.count == 10 && total > 10)
        #expect(first.map(\.title) == first.map(\.title).sorted())
        guard case .songs(let last, _) = try await ask(mac, .songs(offset: total - 3, limit: 10)) else { Issue.record("no songs"); return }
        #expect(last.count == 3)
        guard case .songs(let past, _) = try await ask(mac, .songs(offset: total + 50, limit: 10)) else { Issue.record("no songs"); return }
        #expect(past.isEmpty)
        guard case .songs(let negative, _) = try await ask(mac, .songs(offset: -5, limit: -1)) else { Issue.record("no songs"); return }
        #expect(negative.count == 1 && negative.first == first.first)
    }

    @Test func findsInGroups() async throws {
        let (mac, _) = try await opened()
        guard case .found(let nocturne) = try await ask(mac, .find(text: "nocturne", limit: 50)) else { Issue.record("no results"); return }
        #expect(nocturne.tracks.count == 6)
        #expect(nocturne.albums.map(\.title) == ["Nocturnes for a Small Room"])
        guard case .found(let artist) = try await ask(mac, .find(text: "LINDQVIST", limit: 50)) else { Issue.record("no results"); return }
        #expect(artist.artists.map(\.name) == ["Theo Lindqvist"])
        #expect(!artist.albums.isEmpty && !artist.tracks.isEmpty)
        guard case .found(let playlist) = try await ask(mac, .find(text: "late", limit: 50)) else { Issue.record("no results"); return }
        #expect(playlist.playlists.map(\.name) == ["Late Night"])
        guard case .found(let limited) = try await ask(mac, .find(text: "a", limit: 2)) else { Issue.record("no results"); return }
        #expect(limited.tracks.count == 2 && limited.albums.count <= 2)
        #expect(try await ask(mac, .find(text: "   ", limit: 50)) == .found(SearchResults(tracks: [], albums: [], artists: [], playlists: [])))
    }

    @Test func playlistsSayWhatTheyHoldAndTakeMore() async throws {
        let (mac, pushes) = try await opened()
        guard case .playlists(let lists) = try await ask(mac, .playlists) else { Issue.record("no playlists"); return }
        let late = try #require(lists.first { !$0.smart }), smart = try #require(lists.first { $0.smart })
        #expect(late.trackCount == 14)
        #expect((1...4).contains(late.artworkKeys?.count ?? 0))
        guard case .songs(let songs, _) = try await ask(mac, .songs(offset: 0, limit: 2)) else { Issue.record("no songs"); return }
        let ids = songs.compactMap(\.id)

        #expect(try await ask(mac, .addToPlaylist(id: late.id, ids: ids)) == .ok)
        guard case .tracks(let longer) = try await ask(mac, .playlistTracks(id: late.id)) else { Issue.record("no tracks"); return }
        #expect(longer.count == 16 && longer.suffix(2).map(\.id) == ids)
        // A smart playlist's rules choose its songs; a playlist or songs that aren't there are refused.
        #expect(try await ask(mac, .addToPlaylist(id: smart.id, ids: ids)) != .ok)
        #expect(try await ask(mac, .addToPlaylist(id: 999, ids: ids)) != .ok)
        #expect(try await ask(mac, .addToPlaylist(id: late.id, ids: [-1])) != .ok)

        guard case .playlists(let more) = try await ask(mac, .createPlaylist(name: "  Sunday  ", ids: ids)) else { Issue.record("not made"); return }
        let sunday = try #require(more.last)
        #expect(more.count == lists.count + 1 && sunday.name == "Sunday" && sunday.trackCount == 2 && !sunday.smart)
        #expect(try await ask(mac, .createPlaylist(name: " ", ids: [])) != .ok)
        #expect(try await ask(mac, .playPlaylist(id: sunday.id, shuffled: false)) == .ok)
        #expect(pushes.lastQueue?.current?.track.id == ids[0])
    }

    @Test func refusesOnceClosed() async throws {
        let (mac, _) = try await opened()
        var closed = false
        mac.onClose = { _ in closed = true }
        mac.close()
        #expect(closed)
        await #expect(throws: RemoteLinkError.closed) { try await mac.request(.play, timeout: .seconds(1)) }
    }
}
