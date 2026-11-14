//
// Vespertine: a share answering as a library: the same questions the app asks a Mac, answered from the phone's index
// and the share's own bytes. On a made-up share in memory.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertineShare

/// Waits for something another task is about to make true. The limit only bounds a failure; a pass never waits it out.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<4000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
@Suite struct ShareMacTests {
    private final class Clock: @unchecked Sendable { var now = FakeShare.day }

    private struct Rig {
        var mac: ShareMac
        var browsing: FakeShare
        var playing: FakeShare
        var store: ShareStore
        var clock: Clock
    }

    private func store() -> ShareStore {
        ShareStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("share-tests-\(UUID().uuidString)", isDirectory: true))
    }

    /// A share opened and scanned. The same made-up share serves browsing and playing, each through its own counter.
    private func rig(store: ShareStore? = nil, share: FakeShare = .sample(), clock: Clock = Clock(), scanned: Bool = true,
                     shrink: @escaping @Sendable (Data, Int) -> Data? = { data, _ in data }) async throws -> Rig {
        let store = store ?? self.store()
        let mac = ShareMac(id: "share-test", name: "Studio NAS", files: share, playback: share, store: store, now: { clock.now }, shrink: shrink)
        try await mac.open(timeout: .seconds(1))
        if scanned { #expect(await eventually { !mac.isScanning }) }
        return Rig(mac: mac, browsing: share, playing: share, store: store, clock: clock)
    }

    private func ask(_ mac: ShareMac, _ command: RemoteCommand) async throws -> RemoteReply {
        try await mac.request(command, timeout: .seconds(1))
    }

    private func albums(_ mac: ShareMac) async throws -> [AlbumSummary] {
        guard case .albums(let items, _) = try await ask(mac, .albums(offset: 0, limit: 100)) else { return [] }
        return items
    }

    private func tracks(_ mac: ShareMac, album: String) async throws -> [TrackSummary] {
        let key = try #require(try await albums(mac).first { $0.title == album }?.key)
        guard case .tracks(let items) = try await ask(mac, .albumTracks(key: key)) else { return [] }
        return items
    }

    @Test func aShareSaysHelloAsAMacThatCanSendSongsAndPlaysNothingItself() async throws {
        let rig = try await rig()
        var pushed: [ServerMessage] = []
        rig.mac.onPush = { pushed.append($0) }
        guard case .welcome(let info) = try await ask(rig.mac, .hello(device: "d", name: "phone", protocolVersion: 1, highestProtocolVersion: RemoteProtocol.version)) else {
            Issue.record("no welcome")
            return
        }
        #expect(info.name == "Studio NAS" && info.serverID == "share-test")
        #expect(info.protocolVersion >= RemoteProtocol.streamVersion)
        #expect(await eventually { pushed.count == 3 })
        guard case .player(let player) = pushed[0], case .queue(let queue) = pushed[1], case .outputs(let outputs) = pushed[2] else {
            Issue.record("expected player, queue, outputs")
            return
        }
        #expect(player.playback == .stopped && player.nowPlaying == nil && queue.current == nil && outputs.outputs.isEmpty)
        // Playing is the phone's own business: asked of the share, it is refused rather than pretended.
        #expect(try await ask(rig.mac, .play) == .failed(reason: ""))
        #expect(try await ask(rig.mac, .ping) == .ok)
    }

    @Test func theFirstConnectionScansTheShareAndTheIndexIsKept() async throws {
        let rig = try await rig()
        #expect(rig.mac.scan == .idle && rig.mac.reachable == true)
        #expect(try await albums(rig.mac).map(\.title) == ["Nocturnes for a Small Room", "Northern Signal", "Demos"])
        guard case .library(let overview) = try await ask(rig.mac, .library) else { Issue.record("no overview"); return }
        #expect(overview.albums == 3 && overview.songs == 4 && overview.artists == 3 && overview.genres == 2 && overview.playlists == 0)
        #expect(overview.sources.map(\.name) == ["Studio NAS"] && overview.sources[0].kind == .network && overview.sources[0].online)

        // The next launch has the library at once, without asking the share for anything.
        rig.browsing.forgetCounts()
        let again = try await self.rig(store: rig.store, share: rig.browsing, clock: rig.clock, scanned: false)
        #expect(again.mac.scan == .idle)
        #expect(try await albums(again.mac).count == 3)
        #expect(rig.browsing.listed.isEmpty)

        // A day later a connection looks again by itself.
        rig.clock.now = FakeShare.day.addingTimeInterval(25 * 3600)
        rig.browsing.put("New/01 Fresh.flac", FlacMaker.file(["TITLE": "Fresh", "ARTIST": "Nora Beck", "ALBUM": "Slow Light"]))
        let later = try await self.rig(store: rig.store, share: rig.browsing, clock: rig.clock)
        #expect(try await albums(later.mac).map(\.title).contains("Slow Light"))
        #expect(later.mac.library.scanned == rig.clock.now)
    }

    @Test func scanningIsShownAndAFailedScanKeepsTheLibrary() async throws {
        let rig = try await rig()
        var changes = 0
        rig.mac.onChange = { changes += 1 }
        rig.browsing.failure = .timedOut
        rig.mac.rescan()
        #expect(rig.mac.isScanning)
        #expect(await eventually { rig.mac.scan == .failed(.timedOut) })
        #expect(rig.mac.reachable == false)
        #expect(try await albums(rig.mac).count == 3)
        #expect(changes >= 2)
        guard case .library(let overview) = try await ask(rig.mac, .library) else { Issue.record("no overview"); return }
        #expect(overview.sources[0].online == false)

        rig.browsing.failure = nil
        rig.browsing.remove("Kestrel Park/Northern Signal/04 Aurora Line.m4a")
        rig.mac.rescan()
        #expect(await eventually { rig.mac.scan == .idle })
        #expect(try await albums(rig.mac).map(\.title) == ["Nocturnes for a Small Room", "Demos"])
        #expect(rig.mac.reachable == true)
    }

    @Test func aFirstScanCutShortKeepsWhatItFoundAndTheNextConnectionFinishesIt() async throws {
        let share = FakeShare.sample()
        share.unanswered = ["Ilse Brandt/Nocturnes/02 Nocturne.flac"]
        let store = self.store()
        let mac = ShareMac(id: "share-test", name: "Studio NAS", files: share, playback: share, store: store, now: { FakeShare.day })
        mac.glimpseEvery = 1
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { mac.scan == .failed(.timedOut) })
        // The three songs read before the line died can be browsed and played, and the scan is not called done.
        #expect(try await albums(mac).map(\.title) == ["Northern Signal", "Demos"])
        #expect(mac.library.scanned == nil && mac.revision == 0)
        #expect(store.library()?.songs.count == 3)

        share.unanswered = []
        share.forgetCounts()
        let again = try await rig(store: store, share: share)
        #expect(try await albums(again.mac).count == 3)
        #expect(again.mac.library.scanned == FakeShare.day && again.mac.revision == 1)
        #expect(Set(share.readPaths) == ["Ilse Brandt/Nocturnes/02 Nocturne.flac", "Loose/Demos/broken.flac"])
    }

    @Test func aFinishedScanThatChangedTheLibraryTellsTheScreens() async throws {
        let rig = try await rig()
        #expect(rig.mac.revision == 1)
        rig.mac.rescan()
        #expect(await eventually { !rig.mac.isScanning })
        #expect(rig.mac.revision == 1)
        rig.browsing.put("New/01 Fresh.flac", FlacMaker.file(["TITLE": "Fresh"]))
        rig.mac.rescan()
        #expect(await eventually { !rig.mac.isScanning })
        #expect(rig.mac.revision == 2)
    }

    @Test func aSavedShareKeepsItsAddressAndPassword() throws {
        let address = try #require(ShareAddress(typed: "smb://nas.tail1a2b3.ts.net/music/Albums", user: "listener"))
        let share = SavedShare(name: SavedShare.suggestedName(for: address), address: address, password: "p&ss é", addedAt: FakeShare.day)
        #expect(share.name == "Albums" && share.id.hasPrefix(ShareMac.prefix))
        #expect(SavedShare.suggestedName(for: try #require(ShareAddress(typed: "nas/music"))) == "music")
        #expect(try JSONDecoder().decode(SavedShare.self, from: JSONEncoder().encode(share)) == share)
    }

    @Test func aSongIsOpenedAndReadAsItsOwnFile() async throws {
        let rig = try await rig()
        let song = try #require(try await tracks(rig.mac, album: "Nocturnes for a Small Room").first)
        #expect(song.title == "Nocturne No. 2" && song.format == "FLAC · 24/96")
        let id = try #require(song.id)

        guard case .streamInfo(let infos) = try await ask(rig.mac, .streamInfo(ids: [id, 12345], maxSampleRate: 48_000)), let info = infos.first else {
            Issue.record("no stream info")
            return
        }
        #expect(infos.count == 1 && info.streamable && info.kind == .original && info.byteSize == Int64(SongFixtures.flac2496.count))

        // Whatever rate the output runs at, the file is sent as it is: nothing on a share converts anything.
        guard case .streamOpened(let stream) = try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: 48_000)) else { Issue.record("not opened"); return }
        #expect(stream.kind == .original && stream.byteSize == Int64(SongFixtures.flac2496.count) && stream.frames == 1920)
        #expect(stream.format == StreamFormat(codec: "FLAC", container: "flac", sampleRate: 96_000, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true))

        var whole = Data()
        var ended = false
        while !ended {
            let frame = try await rig.mac.read(stream: stream.stream, offset: Int64(whole.count), length: 4096, timeout: .seconds(1))
            #expect(frame.stream == stream.stream && frame.offset == Int64(whole.count))
            whole.append(frame.payload)
            ended = frame.endOfStream
        }
        #expect(whole == SongFixtures.flac2496)

        #expect(try await ask(rig.mac, .streamClose(stream: stream.stream)) == .ok)
        await #expect(throws: RemoteLinkError.closed) { _ = try await rig.mac.read(stream: stream.stream, offset: 0, length: 16, timeout: .seconds(1)) }

        // The same song opened again has the same tag, so a stream that dropped carries on where it was.
        guard case .streamOpened(let again) = try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        #expect(again.tag == stream.tag && again.stream != stream.stream)
    }

    @Test func containersAreNamedSoThatCoreAudioOpensThem() async throws {
        let rig = try await rig()
        let alac = try #require(try await tracks(rig.mac, album: "Northern Signal").first?.id)
        guard case .streamOpened(let stream) = try await ask(rig.mac, .streamOpen(id: alac, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        #expect(stream.format.container == "m4a" && stream.format.codec == "ALAC" && stream.format.sampleRate == 192_000)
        let wav = try #require(try await tracks(rig.mac, album: "Demos").first?.id)
        guard case .streamOpened(let wave) = try await ask(rig.mac, .streamOpen(id: wav, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        #expect(wave.format.container == "wav")
    }

    @Test func aShareThatCantBeReachedIsSaidWhenASongIsOpenedNotLater() async throws {
        let rig = try await rig()
        let id = try #require(try await tracks(rig.mac, album: "Nocturnes for a Small Room").first?.id)
        guard case .streamOpened(let stream) = try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened"); return }

        rig.playing.failure = .unreachable
        #expect(try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: "The share can’t be reached (unreachable)."))
        #expect(rig.mac.reachable == false)
        await #expect(throws: RemoteLinkError.readFailed("The share can’t be reached (unreachable).")) {
            _ = try await rig.mac.read(stream: stream.stream, offset: 0, length: 16, timeout: .seconds(1))
        }
        // The library is still there to look through.
        #expect(try await albums(rig.mac).count == 3)

        rig.playing.failure = nil
        guard case .streamOpened = try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: nil)) else { Issue.record("not opened again"); return }
        #expect(rig.mac.reachable == true)
    }

    @Test func aFileThatChangedOrWentSinceTheScanIsNotPlayedAsTheOldOne() async throws {
        let rig = try await rig()
        let id = try #require(try await tracks(rig.mac, album: "Nocturnes for a Small Room").first?.id)
        rig.playing.put("Ilse Brandt/Nocturnes/02 Nocturne.flac", SongFixtures.surroundFlac)
        #expect(try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: ShareSayings.english.changed))
        rig.playing.remove("Ilse Brandt/Nocturnes/02 Nocturne.flac")
        #expect(try await ask(rig.mac, .streamOpen(id: id, maxSampleRate: nil)) == .failed(reason: ShareSayings.english.notInLibrary))
        #expect(try await ask(rig.mac, .streamOpen(id: 4242, maxSampleRate: nil)) == .failed(reason: ShareSayings.english.notInLibrary))
        // The share answered: it is the file that is the trouble.
        #expect(rig.mac.reachable == true)
    }

    @Test func coversComeFromTheFolderOrTheFileAndAreFetchedOnce() async throws {
        let share = FakeShare.sample()
        share.put("Embedded/01.flac", SongFixtures.flac2496)
        let rig = try await rig(share: share, shrink: { data, size in data + Data([UInt8(size & 0xff)]) })
        let folder = try #require(try await albums(rig.mac).first { $0.title == "Nocturnes for a Small Room" && $0.artworkKey != nil }?.artworkKey)
        rig.browsing.forgetCounts()
        guard case .artwork(let key, let size, let type, let data) = try await ask(rig.mac, .artwork(key: folder, size: 300)) else { Issue.record("no cover"); return }
        #expect(key == folder && size == 300 && type == "image/jpeg")
        #expect(data == SongFixtures.cover + Data([44]))   // made no larger than 300 by what the app gave to do it
        #expect(rig.browsing.readPaths.contains { $0.hasSuffix("cover.jpg") || $0.hasSuffix("01.flac") })

        // Asked again, it comes from the phone.
        rig.browsing.forgetCounts()
        guard case .artwork(_, _, _, let again) = try await ask(rig.mac, .artwork(key: folder, size: 300)) else { Issue.record("no cover"); return }
        #expect(again == data && rig.browsing.readPaths.isEmpty)

        #expect(try await ask(rig.mac, .artwork(key: "share-0", size: 300)) == .failed(reason: ""))
        // A cover the app can't read as a picture is no cover.
        let plain = try await self.rig(share: share, shrink: { _, _ in nil })
        #expect(try await ask(plain.mac, .artwork(key: folder, size: 300)) == .failed(reason: ""))
    }

    @Test func anEmbeddedCoverIsCutOutOfItsFile() async throws {
        let share = FakeShare()
        share.put("Embedded/01.flac", SongFixtures.flac2496)
        let rig = try await rig(share: share)
        let key = try #require(try await albums(rig.mac).first?.artworkKey)
        guard case .artwork(_, _, _, let data) = try await ask(rig.mac, .artwork(key: key, size: 600)) else { Issue.record("no cover"); return }
        #expect(data == SongFixtures.cover)
    }

    @Test func favoritesAreKeptOnThePhone() async throws {
        let rig = try await rig()
        let id = try #require(try await tracks(rig.mac, album: "Northern Signal").first?.id)
        #expect(try await ask(rig.mac, .setFavorite(ids: [id], on: true)) == .ok)
        guard case .tracks(let favorites) = try await ask(rig.mac, .favorites) else { Issue.record("no favorites"); return }
        #expect(favorites.map(\.id) == [id] && favorites[0].favorite)
        #expect(try await ask(rig.mac, .setFavorite(ids: [999], on: true)) == .failed(reason: ShareSayings.english.notInLibrary))

        let again = try await self.rig(store: rig.store, share: rig.browsing, clock: rig.clock, scanned: false)
        guard case .tracks(let kept) = try await ask(again.mac, .favorites) else { Issue.record("no favorites"); return }
        #expect(kept.map(\.id) == [id])
        #expect(try await ask(again.mac, .setFavorite(ids: [id], on: false)) == .ok)
        guard case .tracks(let none) = try await ask(again.mac, .favorites) else { Issue.record("no favorites"); return }
        #expect(none.isEmpty)
    }

    @Test func theLibraryAnswersTheScreensQuestions() async throws {
        let rig = try await rig()
        let mac = rig.mac
        guard case .albums(let hiRes, let total) = try await ask(mac, .albums(offset: 0, limit: 10, sort: .title, filter: .hiRes)) else { Issue.record("no albums"); return }
        #expect(hiRes.map(\.title) == ["Nocturnes for a Small Room", "Northern Signal"] && total == 2)
        guard case .albums(let surround, _) = try await ask(mac, .albums(offset: 0, limit: 10, sort: nil, filter: .surround)) else { Issue.record("no albums"); return }
        #expect(surround.map(\.title) == ["Demos"])
        guard case .albums(let page, let all) = try await ask(mac, .albums(offset: 2, limit: 5)) else { Issue.record("no albums"); return }
        #expect(page.map(\.title) == ["Demos"] && all == 3)
        guard case .artists(let artists) = try await ask(mac, .artists) else { Issue.record("no artists"); return }
        #expect(artists.map(\.name) == ["Ilse Brandt Trio", "Kestrel Park", "Loose"])
        guard case .albums(let theirs, _) = try await ask(mac, .artistAlbums(name: "Kestrel Park")) else { Issue.record("no albums"); return }
        #expect(theirs.map(\.title) == ["Northern Signal"])
        guard case .genres(let genres) = try await ask(mac, .genres) else { Issue.record("no genres"); return }
        #expect(genres.map(\.name) == ["Classical", "Electronic"])
        guard case .albums(let classical, _) = try await ask(mac, .genreAlbums(key: "classical")) else { Issue.record("no albums"); return }
        #expect(classical.map(\.title) == ["Nocturnes for a Small Room"])
        guard case .albums(let source, _) = try await ask(mac, .sourceAlbums(id: 1)) else { Issue.record("no albums"); return }
        #expect(source.count == 3)
        guard case .found(let found) = try await ask(mac, .find(text: "nocturne", limit: 10)) else { Issue.record("nothing found"); return }
        #expect(found.tracks.map(\.title) == ["Nocturne No. 2"] && found.albums.count == 1)
        guard case .songs(let songs, let count) = try await ask(mac, .songs(offset: 0, limit: 2)) else { Issue.record("no songs"); return }
        #expect(count == 4 && songs.map(\.title) == ["Allegro", "Aurora Line"])
        let ids = songs.compactMap(\.id)
        guard case .tracks(let asked) = try await ask(mac, .tracks(ids: ids.reversed() + [77])) else { Issue.record("no tracks"); return }
        #expect(asked.map(\.title) == ["Aurora Line", "Allegro"])
        // Playlists are the Mac's.
        #expect(try await ask(mac, .playlists) == .playlists(items: []))
        #expect(try await ask(mac, .createPlaylist(name: "x", ids: ids)) == .failed(reason: ShareSayings.english.noPlaylists))
    }

    @Test func aScanCutOffByClosingStartsAgainWhenTheShareIsOpenedAgain() async throws {
        let share = FakeShare.sample()
        let mac = ShareMac(id: "share-test", name: "Studio NAS", files: share, playback: share, store: store(), now: { FakeShare.day })
        try await mac.open(timeout: .seconds(1))
        #expect(mac.isScanning)
        mac.close()
        #expect(mac.scan == .idle)
        // The app comes back to the front: the same share is opened again and the scan runs to its end.
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { !mac.isScanning && mac.library.scanned != nil })
        #expect(try await albums(mac).count == 3)
    }

    @Test func closingLetsGoOfTheShare() async throws {
        let rig = try await rig()
        var closed = false
        rig.mac.onClose = { _ in closed = true }
        rig.mac.close()
        #expect(closed && rig.browsing.rests == 2)
        await #expect(throws: RemoteLinkError.closed) { _ = try await rig.mac.request(.ping, timeout: .seconds(1)) }
    }
}
