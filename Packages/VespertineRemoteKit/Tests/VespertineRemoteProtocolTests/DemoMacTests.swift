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
        let mac = DemoMac(name: "Demo", appVersion: "9.8.7") { _, _ in Data([0x89, 0x50, 0x4E, 0x47]) }
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
        // The pretend Mac says the version it was given (the app passes its own), never one written into the demo.
        #expect(mac.info.appVersion == "9.8.7")
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

    @Test func theAlbumsPageIsSortedAndNarrowedByTheMacAcrossPages() async throws {
        let (mac, _) = try await opened()
        guard case .albums(let all, let total) = try await ask(mac, .albums(offset: 0, limit: 500)) else { Issue.record("no albums"); return }
        guard case .albums(let first, let sortedTotal) = try await ask(mac, .albums(offset: 0, limit: 2, sort: .title, filter: nil)),
              case .albums(let second, _) = try await ask(mac, .albums(offset: 2, limit: 2, sort: .title, filter: nil)) else { Issue.record("no albums"); return }
        #expect(sortedTotal == total)
        #expect((first + second).map(\.key) == AlbumListing.arrange(all, sort: .title, filter: nil).prefix(4).map(\.key))
        guard case .albums(let hiRes, let hiResTotal) = try await ask(mac, .albums(offset: 0, limit: 500, sort: nil, filter: .hiRes)) else { Issue.record("no albums"); return }
        #expect(hiRes.allSatisfy(\.hiRes) && hiResTotal == all.filter(\.hiRes).count && hiResTotal < total)
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

    @Test func theSoundOfEachOutputIsSetAndKept() async throws {
        let (mac, pushes) = try await opened()
        #expect(try await ask(mac, .pause) == .ok)
        // The DAC starts with everything off and centered, and offers all four.
        let start = try #require(pushes.lastPlayer?.sound)
        #expect(start.equalizer?.selected == nil && start.equalizer?.presets.count == 2)
        #expect(start.room?.selected == nil && start.room?.chosen == start.room?.profiles.first?.id)
        #expect(start.spatial == SpatialState(mode: .off, spatializeStereo: nil))
        #expect(start.balance == BalanceState(value: 0))

        let preset = try #require(start.equalizer?.presets.last?.id), profile = try #require(start.room?.profiles.first?.id)
        #expect(try await ask(mac, .setEqualizer(preset: preset)) == .ok)
        #expect(try await ask(mac, .setRoomCorrection(profile: profile)) == .ok)
        // Spatialize stereo has nothing to do on a stereo DAC until Spatial Audio is on.
        #expect(try await ask(mac, .setSpatializeStereo(on: true)) != .ok)
        #expect(try await ask(mac, .setSpatialMode(mode: .fixed)) == .ok)
        #expect(try await ask(mac, .setSpatializeStereo(on: true)) == .ok)
        #expect(try await ask(mac, .setBalance(value: -7)) == .ok)
        let set = try #require(pushes.lastPlayer?.sound)
        #expect(set.equalizer?.selected == preset && set.room?.selected == profile)
        #expect(set.spatial == SpatialState(mode: .fixed, spatializeStereo: true))
        #expect(set.balance?.value == -1, "a value past the end stops at it")

        // What this Mac doesn't have is refused, and nothing changes.
        #expect(try await ask(mac, .setEqualizer(preset: "gone")) != .ok)
        #expect(try await ask(mac, .setRoomCorrection(profile: "gone")) != .ok)
        #expect(pushes.lastPlayer?.sound == set)

        // Off again: room correction keeps its choice for next time.
        #expect(try await ask(mac, .setEqualizer(preset: nil)) == .ok)
        #expect(try await ask(mac, .setRoomCorrection(profile: nil)) == .ok)
        #expect(pushes.lastPlayer?.sound?.equalizer?.selected == nil)
        #expect(pushes.lastPlayer?.sound?.room?.selected == nil && pushes.lastPlayer?.sound?.room?.chosen == profile)

        // The receiver has its own sound: nothing set on the DAC, no room profile and no balance to move.
        #expect(try await ask(mac, .selectOutput(uid: "demo-receiver")) == .ok)
        let receiver = try #require(pushes.lastPlayer?.sound)
        #expect(receiver.spatial == SpatialState(mode: .off, spatializeStereo: false))
        #expect(receiver.room?.profiles.isEmpty == true && receiver.balance == nil)
        #expect(try await ask(mac, .setBalance(value: 0.5)) != .ok)
        #expect(try await ask(mac, .setRoomCorrection(profile: profile)) != .ok)
        // Back on the DAC, what was set there is still there.
        #expect(try await ask(mac, .selectOutput(uid: "demo-dac")) == .ok)
        #expect(pushes.lastPlayer?.sound?.spatial == SpatialState(mode: .fixed, spatializeStereo: true))
        #expect(pushes.lastPlayer?.sound?.balance?.value == -1)
        mac.close()
    }

    @Test func looksSongsUpByIDInTheOrderAsked() async throws {
        let (mac, _) = try await opened()
        guard case .songs(let all, _) = try await ask(mac, .songs(offset: 0, limit: 3)), all.count == 3 else { Issue.record("no songs"); return }
        let wanted = [all[2].id, all[0].id].compactMap { $0 }
        guard case .tracks(let found) = try await ask(mac, .tracks(ids: wanted + [-5])) else { Issue.record("no tracks"); return }
        #expect(found.map(\.id) == wanted)
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

    /// TestFlight feedback AOf1M7oLiLlxngkwwaWog5Y: a playlist's page lists it a page at a time, a tapped song plays the rest
    /// in the playlist's order, and Shuffle plays every song, from a random one.
    @Test func aPlaylistPagesPlaysInOrderAndShufflesWhole() async throws {
        let (mac, pushes) = try await opened()
        guard case .playlists(let lists) = try await ask(mac, .playlists) else { Issue.record("no playlists"); return }
        let late = try #require(lists.first { !$0.smart })
        guard case .tracks(let all) = try await ask(mac, .playlistTracks(id: late.id)) else { Issue.record("no tracks"); return }
        guard case .songs(let page, let total) = try await ask(mac, .playlistTracks(id: late.id, offset: 10, limit: 10)) else { Issue.record("no page"); return }
        #expect(total == all.count && page == Array(all[10...]))

        #expect(try await ask(mac, .setShuffle(on: false)) == .ok)
        #expect(try await ask(mac, .playPlaylist(id: late.id, startAt: 3, shuffled: nil)) == .ok)
        let ordered = try #require(pushes.lastQueue)
        #expect(ordered.current?.track.id == all[3].id)
        #expect(ordered.continuing.map(\.track.id) == all[4...].map(\.id))

        var firsts: Set<Int64?> = []
        for _ in 0..<20 {
            #expect(try await ask(mac, .playPlaylist(id: late.id, shuffled: true)) == .ok)
            let shuffled = try #require(pushes.lastQueue)
            let played = [shuffled.current].compactMap { $0 } + shuffled.continuing
            let heard: [Int64] = played.compactMap(\.track.id).sorted()
            let listed: [Int64] = all.compactMap(\.id).sorted()
            #expect(heard == listed)
            firsts.insert(shuffled.current?.track.id)
        }
        #expect(firsts.count > 1, "Shuffle starts from a random song, not always the first")

        // A long playlist (the UI tests' -VTTestPlaylists) is listed a page at a time, and an empty one has no songs.
        let long = mac.addTestPlaylist(name: "Long Mix", songs: 1_200), empty = mac.addTestPlaylist(name: "Nothing Yet", songs: 0)
        guard case .songs(let last, let count) = try await ask(mac, .playlistTracks(id: long, offset: 1_000, limit: 500)) else { Issue.record("no page"); return }
        #expect(count == 1_200 && last.count == 200)
        #expect(try await ask(mac, .playlistTracks(id: empty, offset: 0, limit: 500)) == .songs(items: [], total: 0))
        mac.close()
    }

    /// TestFlight feedback ACUpAP5U-pTc3fiJ6CwJ0Z0 and AOf1M7oLiLlxngkwwaWog5Y: the last song of a playlist plays when it is
    /// tapped, and in a playlist that holds one song more than once the place tapped is what plays, not the song's first place.
    @Test func aPlaylistsLastSongAndASongItHoldsTwicePlayFromThePlaceTapped() async throws {
        let (mac, pushes) = try await opened()
        guard case .songs(let songs, _) = try await ask(mac, .songs(offset: 0, limit: 3)) else { Issue.record("no songs"); return }
        let ids = songs.compactMap(\.id)
        try #require(ids.count == 3)
        let twice = [ids[0], ids[1], ids[0], ids[2]]
        guard case .playlists(let lists) = try await ask(mac, .createPlaylist(name: "Twice", ids: twice)) else { Issue.record("not made"); return }
        let list = try #require(lists.last)
        #expect(list.trackCount == 4)
        #expect(try await ask(mac, .setShuffle(on: false)) == .ok)

        // The second place of the song held twice: what follows is what follows that place.
        #expect(try await ask(mac, .playPlaylist(id: list.id, startAt: 2, shuffled: nil)) == .ok)
        var queue = try #require(pushes.lastQueue)
        #expect(queue.current?.track.id == ids[0] && queue.continuing.map(\.track.id) == [ids[2]])
        // Its first place: the whole playlist follows.
        #expect(try await ask(mac, .playPlaylist(id: list.id, startAt: 0, shuffled: nil)) == .ok)
        queue = try #require(pushes.lastQueue)
        #expect(queue.current?.track.id == ids[0] && queue.continuing.map(\.track.id) == [ids[1], ids[0], ids[2]])
        // The last song: it plays, and nothing comes after it.
        #expect(try await ask(mac, .playPlaylist(id: list.id, startAt: 3, shuffled: nil)) == .ok)
        queue = try #require(pushes.lastQueue)
        #expect(queue.current?.track.id == ids[2] && queue.continuing.isEmpty)
        // Shuffle plays every place once, the song held twice twice.
        #expect(try await ask(mac, .playPlaylist(id: list.id, shuffled: true)) == .ok)
        queue = try #require(pushes.lastQueue)
        #expect(([queue.current].compactMap { $0 } + queue.continuing).compactMap(\.track.id).sorted() == twice.sorted())
        mac.close()
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
        // From the song tapped, not the first (TestFlight feedback tf-7adda59b4b).
        #expect(try await ask(mac, .playPlaylist(id: sunday.id, startAt: 1, shuffled: nil)) == .ok)
        #expect(pushes.lastQueue?.current?.track.id == ids[1])
    }

    @Test func theDemoSpeaksTheWordsItIsGiven() async throws {
        let words = DemoWords(systemDefault: "Systemstandard", builtInSpeakers: "MacBook Pro-Lautsprecher", dac: "USB-DAC", receiver: "HDMI · 8 Kanäle",
                              speakerGroup: "Lautsprechergruppe · 2 Ausgänge", bitPerfect: "BITGENAU", sourceOnline: "ONLINE", sourceOffline: "OFFLINE")
        let mac = DemoMac(name: "Demo", appVersion: "9.8.7", words: words) { _, _ in nil }
        let pushes = Pushes()
        mac.onPush = { pushes.messages.append($0) }
        try await mac.open(timeout: .seconds(1))
        _ = try await ask(mac, .hello(device: "demo", name: "Phone", protocolVersion: RemoteProtocol.version))
        for _ in 0..<20 where pushes.messages.count < 3 { await Task.yield() }
        var outputs: [OutputSummary] = []
        for case .outputs(let state) in pushes.messages { outputs = state.outputs }
        #expect(outputs.first?.name == "Systemstandard" && outputs.first?.detail == "MacBook Pro-Lautsprecher")
        #expect(outputs.map(\.detail).suffix(3) == ["USB-DAC", "HDMI · 8 Kanäle", "Lautsprechergruppe · 2 Ausgänge"])
        #expect(pushes.lastPlayer?.signal?.badge == "BITGENAU")
        guard case .library(let overview) = try await ask(mac, .library) else { Issue.record("no library"); return }
        #expect(Set(overview.sources.map(\.detail)).isSubset(of: ["ONLINE", "OFFLINE"]) && !overview.sources.isEmpty)
        // Nothing of the demo's own English is left in what it says about itself.
        #expect(!outputs.contains { $0.detail.contains("channels") || $0.detail.contains("Speaker") })
        mac.close()
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
