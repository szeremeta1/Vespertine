//
// Vespertine Remote: several libraries answering as one: a Mac's, a share's and a folder's, here made up in memory.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteClient
import VespertineRemoteProtocol

/// A channel that only counts how often it was opened and closed, and answers nothing unless open.
@MainActor
private final class Door: RemoteChannel {
    var onPush: (@MainActor (ServerMessage) -> Void)?
    var onClose: (@MainActor (String?) -> Void)?
    var opened = 0
    var closed = 0
    private var isOpen = false

    func open(timeout: Duration) async throws { opened += 1; isOpen = true }
    func close() { closed += 1; isOpen = false }
    func request(_ command: RemoteCommand, timeout: Duration) async throws -> RemoteReply {
        guard isOpen else { throw RemoteLinkError.closed }
        if case .albums = command { return .albums(items: [], total: 0) }
        return .ok
    }
}

/// A made-up library: albums with songs, answered as a Mac or a share answers. It writes down what it was asked.
@MainActor
private final class FakeLibrary: LibraryMember {
    var albums: [AlbumSummary] = []
    var songs: [String: [TrackSummary]] = [:]
    var playlists: [PlaylistSummary] = []
    var favorites = Set<Int64>()
    var offline = false
    var asked: [RemoteCommand] = []
    var reads: [Int] = []
    private var nextStream = 100

    /// `albums`: (artist, title, year, first song number, songs).
    init(_ albums: [(String, String, Int?, Int64, Int)], genre: String = "Jazz") {
        for (artist, title, year, first, count) in albums {
            let key = "\(artist)|\(title)"
            self.albums.append(AlbumSummary(key: key, title: title, artist: artist, year: year, trackCount: count, duration: Double(count) * 200,
                                            format: "FLAC", artworkKey: "art-\(first)", hiRes: false, dsd: false, multichannel: false))
            songs[key] = (0..<count).map { index in
                TrackSummary(id: first + Int64(index), title: "\(title) \(index + 1)", artist: artist, album: title, albumKey: key, duration: 200,
                             trackNumber: index + 1, discNumber: 1, format: "FLAC 16/44.1", artworkKey: "art-\(first)", favorite: false)
            }
        }
        self.genre = genre
    }

    private let genre: String
    private var all: [TrackSummary] { albums.flatMap { songs[$0.key] ?? [] }.map { var song = $0; song.favorite = favorites.contains($0.id ?? -1); return song } }

    func send(_ command: RemoteCommand) async -> RemoteReply {
        asked.append(command)
        guard !offline else { return .failed(reason: "") }
        switch command {
        case .albums(let offset, let limit, let sort, let filter):
            let listed = AlbumListing.arrange(albums, sort: sort, filter: filter)
            return .albums(items: Array(listed.dropFirst(offset).prefix(limit)), total: listed.count)
        case .albumTracks(let key):
            return songs[key].map { .tracks(items: $0) } ?? .failed(reason: "no such album")
        case .songs(let offset, let limit, let sort):
            let sorted = SongListing.arrange(all.sorted { $0.title < $1.title }, sort: sort)
            return .songs(items: Array(sorted.dropFirst(offset).prefix(limit)), total: sorted.count)
        case .tracks(let ids):
            return .tracks(items: ids.compactMap { id in all.first { $0.id == id } })
        case .artists:
            let names = Set(albums.map(\.artist)).sorted()
            return .artists(items: names.map { name in ArtistSummary(name: name, albumCount: albums.filter { $0.artist == name }.count, artworkKey: nil) })
        case .genres:
            return .genres(items: [GenreSummary(key: genre.lowercased(), name: genre, albumCount: albums.count, artworkKeys: albums.compactMap(\.artworkKey))])
        case .library:
            return .library(LibraryOverview(albums: albums.count, artists: Set(albums.map(\.artist)).count, songs: all.count, genres: 1,
                                            favorites: favorites.count, playlists: playlists.count,
                                            sources: [SourceSummary(id: 1, name: "Source", kind: .network, online: true, scanning: false, albumCount: albums.count, detail: "")]))
        case .favorites:
            return .tracks(items: all.filter(\.favorite))
        case .setFavorite(let ids, let on):
            if on { favorites.formUnion(ids) } else { favorites.subtract(ids) }
            return .ok
        case .playlists:
            return .playlists(items: playlists)
        case .search(let text, let limit):
            return .tracks(items: Array(all.filter { $0.title.contains(text) }.prefix(limit)))
        case .artwork(let key, let size):
            return .artwork(key: key, size: size, mimeType: "image/png", data: Data(key.utf8))
        case .streamOpen(let id, _, _, _):
            nextStream += 1
            return .streamOpened(StreamDescriptor(stream: nextStream, kind: .original, byteSize: 10, format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: 44_100, bitDepth: 16, channels: 2, channelLabels: nil, lossless: true),
                                                  frames: nil, tag: "tag-\(id)", chunkSize: 4))
        default:
            return .ok
        }
    }

    func readStream(_ stream: Int, offset: Int64, length: Int) async throws -> StreamFrame {
        reads.append(stream)
        return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: true, payload: Data([UInt8(stream & 0xff)]))
    }
}

@MainActor
@Suite struct JoinedLibraryTests {
    private struct Rig {
        var library: JoinedLibrary
        var mac: FakeLibrary
        var share: FakeLibrary
        var folder: FakeLibrary
    }

    /// A Mac, a share and a folder. The share and the folder number their songs alike, as two copies of one folder do.
    private func rig(macPlays: Bool = false, macCanStream: Bool = true) async throws -> Rig {
        let mac = FakeLibrary([("Bill Evans", "Waltz for Debby", 1962, 1, 3), ("Miles Davis", "Kind of Blue", 1959, 10, 2)])
        mac.playlists = [PlaylistSummary(id: 7, name: "Evening", smart: false, trackCount: 2, artworkKeys: ["art-1"])]
        let share = FakeLibrary([("Alice Coltrane", "Journey in Satchidananda", 1971, 5001, 2), ("Nina Simone", "Pastel Blues", 1965, 5010, 2)])
        let folder = FakeLibrary([("Bill Evans", "Moon Beams", 1962, 5001, 2)], genre: "Piano")
        let library = JoinedLibrary(name: "Library", members: [
            .init(slot: 1, name: "Studio Mac", kind: .mac, library: mac, canStream: { macCanStream },
                  server: { ServerInfo(name: "Studio Mac", serverID: "mac-1", appVersion: "1.2.1") }),
            .init(slot: 2, name: "NAS", kind: .share, library: share),
            .init(slot: 5, name: "On My iPhone", kind: .folder, library: folder),
        ], macPlays: macPlays)
        library.pageSize = 1
        try await library.open(timeout: .seconds(1))
        return Rig(library: library, mac: mac, share: share, folder: folder)
    }

    private func ask(_ library: JoinedLibrary, _ command: RemoteCommand) async throws -> RemoteReply {
        try await library.request(command, timeout: .seconds(1))
    }

    private func albums(_ library: JoinedLibrary, offset: Int = 0, limit: Int = 100, sort: AlbumSort? = nil) async throws -> (items: [AlbumSummary], total: Int) {
        guard case .albums(let items, let total) = try await ask(library, .albums(offset: offset, limit: limit, sort: sort)) else { return ([], -1) }
        return (items, total)
    }

    private func songs(_ library: JoinedLibrary, album title: String) async throws -> [TrackSummary] {
        let key = try #require(try await albums(library).items.first { $0.title == title }?.key)
        guard case .tracks(let items) = try await ask(library, .albumTracks(key: key)) else { return [] }
        return items
    }

    // MARK: Slots

    @Test func aSlotIsWrittenIntoANumberAndAKeyAndReadBack() throws {
        let id = try #require(JoinedID.join(5001, slot: 5))
        #expect(id != 5001)
        #expect(JoinedID.split(id)?.slot == 5)
        #expect(JoinedID.split(id)?.id == 5001)
        // A share's numbers go up to 2^53.
        let large: Int64 = (1 << 53) - 1
        #expect(JoinedID.split(try #require(JoinedID.join(large, slot: 255)))?.id == large)
        #expect(JoinedID.join(-1, slot: 1) == nil)
        #expect(JoinedID.join(1 << 54, slot: 1) == nil)
        #expect(JoinedID.join(1, slot: 0) == nil)
        #expect(JoinedID.split(Int64(5001)) == nil)
        let key = JoinedID.join("Bill Evans|Moon~Beams", slot: 12)
        #expect(JoinedID.split(key)?.slot == 12)
        #expect(JoinedID.split(key)?.key == "Bill Evans|Moon~Beams")
        #expect(JoinedID.split("no slot here") == nil)
    }

    @Test func aLibraryKeepsItsSlotWhenOthersComeAndGo() {
        let first = JoinedID.assign(["mac", "nas"], kept: [:])
        #expect(first == ["mac": 1, "nas": 2])
        // The Mac is forgotten and a folder added: the NAS keeps 2, and the folder takes the free 1.
        let second = JoinedID.assign(["nas", "folder"], kept: first)
        #expect(second == ["nas": 2, "folder": 1])
        #expect(JoinedID.assign(["a", "b"], kept: ["a": 4, "b": 4]) == ["a": 4, "b": 1])
    }

    // MARK: Lists

    @Test func albumsFromEveryLibraryComeAsOneListInOrder() async throws {
        let rig = try await rig()
        let all = try await albums(rig.library)
        #expect(all.total == 5)
        #expect(all.items.map(\.title) == ["Journey in Satchidananda", "Moon Beams", "Waltz for Debby", "Kind of Blue", "Pastel Blues"])
        // Each says which library it is from.
        #expect(all.items.map { JoinedID.split($0.key)?.slot } == [2, 5, 1, 1, 2])
        #expect(all.items[0].artworkKey == "2~art-5001")
    }

    @Test func aPageAsksEachLibraryOnlyForWhatItNeeds() async throws {
        let rig = try await rig()
        let first = try await albums(rig.library, offset: 0, limit: 2)
        #expect(first.items.map(\.title) == ["Journey in Satchidananda", "Moon Beams"])
        #expect(first.total == 5)
        // One album at a time here: the Mac was read once, for its first album, and not for its second.
        #expect(rig.mac.asked.filter { if case .albums = $0 { true } else { false } }.count == 1)
        let second = try await albums(rig.library, offset: 2, limit: 2)
        #expect(second.items.map(\.title) == ["Waltz for Debby", "Kind of Blue"])
        // The first page is not read again for the second.
        #expect(rig.share.asked.filter { $0 == .albums(offset: 0, limit: 1) }.count == 1)
        #expect(try await albums(rig.library, offset: 4, limit: 10).items.map(\.title) == ["Pastel Blues"])
        #expect(try await albums(rig.library, offset: 9, limit: 10).items.isEmpty)
    }

    @Test func albumsSortByYearAcrossLibraries() async throws {
        let rig = try await rig()
        #expect(try await albums(rig.library, sort: .newest).items.map(\.year) == [1971, 1965, 1962, 1962, 1959])
        #expect(try await albums(rig.library, sort: .title).items.first?.title == "Journey in Satchidananda")
    }

    @Test func twoLibrariesWithTheSameSongNumbersStayApart() async throws {
        let rig = try await rig()
        let journey = try await songs(rig.library, album: "Journey in Satchidananda")
        let moon = try await songs(rig.library, album: "Moon Beams")
        #expect(journey.count == 2 && moon.count == 2)
        #expect(Set(journey.compactMap(\.id)).isDisjoint(with: moon.compactMap(\.id)))
        // Asked for together, in an order of the phone's choosing, they come back in that order from the right library.
        let ids = [try #require(moon[1].id), try #require(journey[0].id), try #require(moon[0].id)]
        guard case .tracks(let items) = try await ask(rig.library, .tracks(ids: ids)) else { Issue.record("no tracks"); return }
        #expect(items.map(\.title) == ["Moon Beams 2", "Journey in Satchidananda 1", "Moon Beams 1"])
        #expect(items.map(\.id) == ids)
        #expect(rig.folder.asked.contains(.tracks(ids: [5002, 5001])))
        #expect(rig.share.asked.contains(.tracks(ids: [5001])))
    }

    @Test func everySongIsListedOnceInTitleOrder() async throws {
        let rig = try await rig()
        guard case .songs(let items, let total) = try await ask(rig.library, .songs(offset: 0, limit: 50)) else { Issue.record("no songs"); return }
        #expect(total == 11)
        #expect(items.count == 11)
        #expect(items.map(\.title) == items.map(\.title).sorted())
        #expect(Set(items.compactMap(\.id)).count == 11)
    }

    @Test func mostPlayedSongsComeFirstAcrossLibrariesAndTheShareFollowsByTitle() async throws {
        let rig = try await rig()
        // The Mac's songs have plays; the share and folder have none, as a share the phone reads never does.
        for (key, list) in rig.mac.songs {
            rig.mac.songs[key] = list.enumerated().map { i, song in
                var song = song
                song.plays = song.title == "Kind of Blue 2" ? 40 : i
                song.lastPlayed = song.plays == 0 ? nil : 1_700_000_000 + Double(song.plays ?? 0)
                return song
            }
        }
        guard case .songs(let items, let total) = try await ask(rig.library, .songs(offset: 0, limit: 50, sort: .mostPlayed))
        else { Issue.record("no songs"); return }
        #expect(total == 11)
        #expect(items.prefix(3).map(\.title) == ["Kind of Blue 2", "Waltz for Debby 3", "Waltz for Debby 2"])
        let rest = items.dropFirst(3).map(\.title)
        #expect(rest == rest.sorted(), "never played: by title")
        #expect(rig.mac.asked.contains(.songs(offset: 0, limit: 1, sort: .mostPlayed)), "each library is asked for its own most played")

        guard case .songs(let recent, _) = try await ask(rig.library, .songs(offset: 0, limit: 3, sort: .recentlyPlayed))
        else { Issue.record("no songs"); return }
        #expect(recent.map(\.title) == ["Kind of Blue 2", "Waltz for Debby 3", "Waltz for Debby 2"])
    }

    @Test func songsSortByArtistThenAlbumAndTrack() async throws {
        let rig = try await rig()
        guard case .songs(let items, _) = try await ask(rig.library, .songs(offset: 0, limit: 50, sort: .artist))
        else { Issue.record("no songs"); return }
        #expect(items.map(\.artist) == items.map(\.artist).sorted())
        #expect(items.filter { $0.artist == "Bill Evans" }.map(\.title)
                == ["Moon Beams 1", "Moon Beams 2", "Waltz for Debby 1", "Waltz for Debby 2", "Waltz for Debby 3"])
    }

    @Test func anArtistInTwoLibrariesIsOneRowAndTheCountsSayWhatTheListsShow() async throws {
        let rig = try await rig()
        guard case .artists(let artists) = try await ask(rig.library, .artists) else { Issue.record("no artists"); return }
        #expect(artists.map(\.name) == ["Alice Coltrane", "Bill Evans", "Miles Davis", "Nina Simone"])
        #expect(artists.first { $0.name == "Bill Evans" }?.albumCount == 2)
        guard case .genres(let genres) = try await ask(rig.library, .genres) else { Issue.record("no genres"); return }
        #expect(genres.map(\.name) == ["Jazz", "Piano"])
        #expect(genres.first?.albumCount == 4)
        guard case .library(let overview) = try await ask(rig.library, .library) else { Issue.record("no overview"); return }
        #expect(overview.albums == 5)
        #expect(overview.songs == 11)
        #expect(overview.artists == artists.count)
        #expect(overview.genres == genres.count)
        #expect(overview.playlists == 1)
        // Each library's sources are told apart, and a folder is called one.
        #expect(Set(overview.sources.map(\.id)).count == 3)
        #expect(overview.sources.map(\.kind) == [.network, .network, .folder])
    }

    @Test func aLibraryThatCannotBeAskedLeavesTheOthersListed() async throws {
        let rig = try await rig()
        rig.mac.offline = true
        let all = try await albums(rig.library)
        #expect(all.items.map(\.title) == ["Journey in Satchidananda", "Moon Beams", "Pastel Blues"])
        #expect(all.total == 3)
        // The Mac is back: told so, the list is put together again with it.
        rig.mac.offline = false
        let before = rig.library.revision
        rig.library.changed()
        #expect(rig.library.revision == before + 1)
        #expect(try await albums(rig.library).total == 5)
    }

    // MARK: Who plays

    @Test func whileTheMacPlaysTheListsAreWhatItCanPlay() async throws {
        let rig = try await rig(macPlays: true)
        #expect(try await albums(rig.library).items.map(\.title) == ["Waltz for Debby", "Kind of Blue"])
        guard case .library(let overview) = try await ask(rig.library, .library) else { Issue.record("no overview"); return }
        #expect(overview.albums == 2 && overview.sources.count == 1)
        #expect(rig.share.asked.isEmpty && rig.folder.asked.isEmpty)
        // This device takes over: every library is listed, and the screens are told to load again.
        var changes = 0
        rig.library.onChange = { changes += 1 }
        rig.library.macPlays = false
        #expect(changes == 1)
        #expect(try await albums(rig.library).total == 5)
    }

    @Test func aMacTooOldToSendSongsIsNotListedForThisDevice() async throws {
        let rig = try await rig(macCanStream: false)
        #expect(try await albums(rig.library).items.map { JoinedID.split($0.key)?.slot }.contains(1) == false)
        rig.library.macPlays = true
        #expect(try await albums(rig.library).items.map(\.title) == ["Waltz for Debby", "Kind of Blue"])
    }

    @Test func theMacIsAskedToPlayOnlyItsOwnSongs() async throws {
        let rig = try await rig()
        let waltz = try await songs(rig.library, album: "Waltz for Debby").compactMap(\.id)
        let moon = try await songs(rig.library, album: "Moon Beams").compactMap(\.id)
        // A mixed list, started at the Mac's second song: the Mac gets its three, and starts at its second.
        let mixed = [moon[0], waltz[0], moon[1], waltz[1], waltz[2]]
        #expect(try await ask(rig.library, .playTracks(ids: mixed, startAt: 3, shuffled: false)) == .ok)
        #expect(rig.mac.asked.last == .playTracks(ids: [1, 2, 3], startAt: 1, shuffled: false))
        // Started at a song in the folder: the Mac can't, and says why.
        let before = rig.mac.asked.count
        #expect(try await ask(rig.library, .playTracks(ids: mixed, startAt: 0, shuffled: false)) == .failed(reason: JoinedSayings.english.notOnTheMac))
        #expect(rig.mac.asked.count == before)
        let moonKey = try #require(try await albums(rig.library).items.first { $0.title == "Moon Beams" }?.key)
        #expect(try await ask(rig.library, .playAlbum(key: moonKey, startAt: 0, shuffled: nil)) == .failed(reason: JoinedSayings.english.notOnTheMac))
        let waltzKey = try #require(try await albums(rig.library).items.first { $0.title == "Waltz for Debby" }?.key)
        #expect(try await ask(rig.library, .playAlbum(key: waltzKey, startAt: 2, shuffled: nil)) == .ok)
        #expect(rig.mac.asked.last == .playAlbum(key: "Bill Evans|Waltz for Debby", startAt: 2, shuffled: nil))
        #expect(try await ask(rig.library, .addToQueue(ids: moon)) == .failed(reason: JoinedSayings.english.notOnTheMac))
    }

    @Test func transportAndOutputsGoToTheMacAndNowhereWithoutOne() async throws {
        let rig = try await rig()
        #expect(try await ask(rig.library, .next) == .ok)
        #expect(try await ask(rig.library, .selectOutput(uid: "dac")) == .ok)
        #expect(rig.mac.asked == [.next, .selectOutput(uid: "dac")])
        #expect(rig.share.asked.isEmpty)
        rig.library.members.removeAll { $0.kind == .mac }
        #expect(try await ask(rig.library, .next) == .failed(reason: ""))
    }

    // MARK: Hearts, playlists, covers

    @Test func aHeartGoesToTheLibraryTheSongIsIn() async throws {
        let rig = try await rig()
        let moon = try await songs(rig.library, album: "Moon Beams").compactMap(\.id)
        let waltz = try await songs(rig.library, album: "Waltz for Debby").compactMap(\.id)
        #expect(try await ask(rig.library, .setFavorite(ids: [moon[0], waltz[2]], on: true)) == .ok)
        #expect(rig.folder.favorites == [5001])
        #expect(rig.mac.favorites == [3])
        #expect(rig.share.favorites.isEmpty)
        guard case .tracks(let hearts) = try await ask(rig.library, .favorites) else { Issue.record("no favorites"); return }
        #expect(Set(hearts.compactMap(\.id)) == [moon[0], waltz[2]])
        #expect(hearts.filter { $0.favorite }.count == hearts.count)
    }

    @Test func playlistsAreTheMacsAndHoldOnlyItsSongs() async throws {
        let rig = try await rig()
        guard case .playlists(let lists) = try await ask(rig.library, .playlists) else { Issue.record("no playlists"); return }
        #expect(lists.map(\.id) == [7])
        #expect(lists.first?.artworkKeys == ["1~art-1"])
        let moon = try await songs(rig.library, album: "Moon Beams").compactMap(\.id)
        let waltz = try await songs(rig.library, album: "Waltz for Debby").compactMap(\.id)
        #expect(try await ask(rig.library, .addToPlaylist(id: 7, ids: [waltz[0], moon[0]])) == .failed(reason: JoinedSayings.english.playlistsAreTheMacs))
        #expect(try await ask(rig.library, .addToPlaylist(id: 7, ids: [waltz[0], waltz[1]])) == .ok)
        #expect(rig.mac.asked.last == .addToPlaylist(id: 7, ids: [1, 2]))
        rig.library.members.removeAll { $0.kind == .mac }
        #expect(try await ask(rig.library, .playlists) == .playlists(items: []))
        #expect(try await ask(rig.library, .playlistTracks(id: 7)) == .failed(reason: JoinedSayings.english.noPlaylists))
    }

    @Test func aCoverIsFetchedFromItsOwnLibrary() async throws {
        let rig = try await rig()
        let key = try #require(try await albums(rig.library).items.first { $0.title == "Moon Beams" }?.artworkKey)
        guard case .artwork(let answered, _, _, let data) = try await ask(rig.library, .artwork(key: key, size: 160)) else { Issue.record("no cover"); return }
        #expect(answered == key)
        #expect(data == Data("art-5001".utf8))
        #expect(rig.folder.asked.last == .artwork(key: "art-5001", size: 160))
        #expect(rig.share.asked.contains(.artwork(key: "art-5001", size: 160)) == false)
    }

    @Test func searchTakesFromEachLibraryInTurn() async throws {
        let rig = try await rig()
        guard case .tracks(let found) = try await ask(rig.library, .search(text: "1", limit: 3)) else { Issue.record("no results"); return }
        #expect(found.count == 3)
        #expect(found.map { $0.id.flatMap(JoinedID.split)?.slot } == [1, 2, 5])
    }

    // MARK: Streams

    @Test func aSongIsOpenedAndReadInItsOwnLibrary() async throws {
        let rig = try await rig()
        let moon = try await songs(rig.library, album: "Moon Beams").compactMap(\.id)
        let journey = try await songs(rig.library, album: "Journey in Satchidananda").compactMap(\.id)
        guard case .streamOpened(let first) = try await ask(rig.library, .streamOpen(id: moon[0], maxSampleRate: 48_000)),
              case .streamOpened(let second) = try await ask(rig.library, .streamOpen(id: journey[0], maxSampleRate: nil)) else { Issue.record("not opened"); return }
        // Both libraries call their stream 101: the phone knows them by different numbers.
        #expect(first.stream != second.stream)
        #expect(rig.folder.asked.last == .streamOpen(id: 5001, maxSampleRate: 48_000))
        let frame = try await rig.library.read(stream: second.stream, offset: 0, length: 4, timeout: .seconds(1))
        #expect(frame.stream == second.stream)
        #expect(rig.share.reads == [101] && rig.folder.reads.isEmpty)
        #expect(try await ask(rig.library, .streamClose(stream: first.stream)) == .ok)
        #expect(rig.folder.asked.last == .streamClose(stream: 101))
        await #expect(throws: RemoteLinkError.closed) { try await rig.library.read(stream: first.stream, offset: 0, length: 4, timeout: .seconds(1)) }
    }

    @Test func aSongFromALibraryThatIsGoneSaysSo() async throws {
        let rig = try await rig()
        let moon = try await songs(rig.library, album: "Moon Beams").compactMap(\.id)
        rig.library.members.removeAll { $0.kind == .folder }
        #expect(try await ask(rig.library, .streamOpen(id: moon[0], maxSampleRate: nil)) == .failed(reason: JoinedSayings.english.gone))
        #expect(try await ask(rig.library, .tracks(ids: moon)) == .tracks(items: []))
    }

    // MARK: What the Mac says

    @Test func whatTheMacPlaysIsPassedOnWithItsSlotAndSaidAgainAtSignIn() async throws {
        let rig = try await rig()
        var pushed: [ServerMessage] = []
        rig.library.onPush = { pushed.append($0) }
        let song = try #require(rig.mac.songs["Miles Davis|Kind of Blue"]?.first)
        let state = PlayerState(playback: .playing, loading: false, nowPlaying: NowPlaying(entry: "e1", track: song), position: 3, positionAt: Date(timeIntervalSince1970: 0),
                                duration: 200, shuffle: false, repeatMode: .off, signal: nil, output: "DAC", volume: VolumeState(route: .hardware, level: 0.5, muted: false),
                                waitingFor: nil, error: nil, transitions: nil)
        rig.library.macSaid(.player(state))
        rig.library.macSaid(.queue(QueueState(revision: 2, current: QueueItem(entry: "e1", track: song), playingNext: [], continuing: [QueueItem(entry: "e2", track: song)], continuingTotal: 1)))
        rig.library.macSaid(.goodbye(reason: .serverStopped))
        #expect(pushed.count == 2)
        let expected = try #require(JoinedID.join(10, slot: 1))
        guard case .player(let told) = pushed[0], case .queue(let queue) = pushed[1] else { Issue.record("wrong messages"); return }
        #expect(told.nowPlaying?.track.id == expected)
        #expect(told.nowPlaying?.track.albumKey == "1~Miles Davis|Kind of Blue")
        #expect(queue.current?.track.id == expected && queue.continuing.first?.track.id == expected)
        // A session signing in later is told the same, not an idle player.
        pushed = []
        guard case .welcome(let info) = try await ask(rig.library, .hello(device: "", name: "phone", protocolVersion: 1, highestProtocolVersion: 2)) else { Issue.record("no welcome"); return }
        #expect(info.name == "Studio Mac" && info.appVersion == "1.2.1" && info.serverID == JoinedLibrary.serverID)
        #expect(await eventually { pushed.count == 3 })
        #expect(pushed.first == .player(told))
    }

    @Test func withNoMacSignInTellsOfAnIdlePlayer() async throws {
        let rig = try await rig()
        rig.library.members.removeAll { $0.kind == .mac }
        var pushed: [ServerMessage] = []
        rig.library.onPush = { pushed.append($0) }
        guard case .welcome(let info) = try await ask(rig.library, .hello(device: "", name: "phone", protocolVersion: 1, highestProtocolVersion: 2)) else { Issue.record("no welcome"); return }
        #expect(info.name == "Library" && info.protocolVersion == RemoteProtocol.version)
        #expect(await eventually { pushed.count == 3 })
        guard case .player(let state) = pushed[0] else { Issue.record("no player"); return }
        #expect(state.playback == .stopped && state.nowPlaying == nil)
    }

    @Test func aShareInTheMixIsOpenedAndClosedWithIt() async throws {
        let door = Door()
        let library = JoinedLibrary(name: "Library", members: [.init(slot: 3, name: "NAS", kind: .share, library: ChannelMember(door))])
        try await library.open(timeout: .seconds(1))
        #expect(door.opened == 1 && door.closed == 0)
        #expect(try await ask(library, .ping) == .ok)
        library.close()
        #expect(door.closed == 1)
        // Opened again with the library (the app came back to the front), not left shut.
        try await library.open(timeout: .seconds(1))
        #expect(door.opened == 2)
        // One added while the library is open is opened the first time it is asked.
        let late = Door()
        library.members.append(.init(slot: 4, name: "Files", kind: .folder, library: ChannelMember(late)))
        _ = try await ask(library, .albums(offset: 0, limit: 10, sort: nil))
        #expect(late.opened == 1 && door.opened == 2)
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<4000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}
