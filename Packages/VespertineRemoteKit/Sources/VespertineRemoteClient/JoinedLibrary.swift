//
// Vespertine Remote: several libraries in place of one Mac. Someone's music can be in more than one place: on a Mac
// running Vespertine, on an SMB share, in folders on the phone. Each of those answers the questions the app's screens ask
// a Mac; this asks them all and gives one answer, so the screens and the player work with any mix of them as they do
// with one. Nothing here plays: the Mac in the mix does when it is the one chosen to, the phone otherwise.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// Every library numbers its own songs and names its own albums, so two of them can use the same number for different
// songs. Each library in the mix has a slot (1…255, kept for as long as the library is), and what it says is passed on
// with the slot written into it: a song's number carries it in its top bits (`JoinedID`), an album's or a cover's key in
// front. Asking about a song or an album goes back to the library whose slot it carries, with the slot taken off.
//

import Foundation
import VespertineRemoteProtocol

/// One of the libraries in a `JoinedLibrary`: something that answers a Mac's commands and reads its streams.
@MainActor
public protocol LibraryMember: AnyObject {
    /// The library's answer, or `.failed` when it can't be asked right now.
    func send(_ command: RemoteCommand) async -> RemoteReply
    func readStream(_ stream: Int, offset: Int64, length: Int) async throws -> StreamFrame
}

/// A library that is a channel itself (a share, a folder, the demo), asked directly. It is opened when the joined
/// library is (a share starts looking for new songs then), and closed with it.
@MainActor
public final class ChannelMember: LibraryMember {
    public let channel: any RemoteChannel
    public var timeout: Duration
    public private(set) var isOpen = false

    public init(_ channel: any RemoteChannel, timeout: Duration = .seconds(30)) {
        self.channel = channel
        self.timeout = timeout
    }

    public func open() async {
        guard !isOpen else { return }
        isOpen = true
        do { try await channel.open(timeout: timeout) } catch { isOpen = false }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        channel.close()
    }

    public func send(_ command: RemoteCommand) async -> RemoteReply {
        await open()
        return (try? await channel.request(command, timeout: timeout)) ?? .failed(reason: "")
    }

    public func readStream(_ stream: Int, offset: Int64, length: Int) async throws -> StreamFrame {
        await open()
        return try await channel.read(stream: stream, offset: offset, length: length, timeout: timeout)
    }
}

/// A library's slot written into its songs' numbers and its albums' and covers' keys, and read back out of them.
public enum JoinedID {
    /// The bits a library's own song number may use: a share's are below 2^53, a Mac's are row numbers.
    static let bits: Int64 = 54
    public static let slots = 1...255

    /// nil for a number that has no room for a slot (negative, or 2^54 and up): such a song is shown, and can't be asked for.
    public static func join(_ id: Int64, slot: Int) -> Int64? {
        guard id >= 0, id < (1 << bits), slots.contains(slot) else { return nil }
        return Int64(slot) << bits | id
    }

    /// nil for a number that carries no slot.
    public static func split(_ id: Int64) -> (slot: Int, id: Int64)? {
        let slot = Int(id >> bits)
        guard id >= 0, slots.contains(slot) else { return nil }
        return (slot, id & ((1 << bits) - 1))
    }

    public static func join(_ key: String, slot: Int) -> String { "\(slot)~\(key)" }

    public static func split(_ key: String) -> (slot: Int, key: String)? {
        guard let mark = key.firstIndex(of: "~"), let slot = Int(key[..<mark]), slots.contains(slot) else { return nil }
        return (slot, String(key[key.index(after: mark)...]))
    }

    /// The slots of the libraries that are there now, each keeping the one it had, and a library that is new taking the
    /// lowest free one. What a library's songs are called must not change while it is kept: queues and kept songs are
    /// written down by those names.
    public static func assign(_ libraries: [String], kept: [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        var used = Set<Int>()
        for library in libraries {
            if let slot = kept[library], slots.contains(slot), used.insert(slot).inserted { result[library] = slot }
        }
        var next = slots.lowerBound
        for library in libraries where result[library] == nil {
            while used.contains(next) { next += 1 }
            guard slots.contains(next) else { break }
            used.insert(next)
            result[library] = next
        }
        return result
    }
}

/// What a joined library says in words, in the app's language.
public struct JoinedSayings: Sendable {
    /// A song or an album asked for from a library that is no longer in the mix.
    public var gone: String
    /// The Mac was asked to play something that is not in its library (it is on a share or in a folder).
    public var notOnTheMac: String
    /// A playlist is the Mac's: only its own songs go into one.
    public var playlistsAreTheMacs: String
    /// A playlist was asked for with no Mac in the mix.
    public var noPlaylists: String

    public init(gone: String, notOnTheMac: String, playlistsAreTheMacs: String, noPlaylists: String) {
        self.gone = gone
        self.notOnTheMac = notOnTheMac
        self.playlistsAreTheMacs = playlistsAreTheMacs
        self.noPlaylists = noPlaylists
    }

    public static let english = JoinedSayings(gone: "That isn’t in your library any more.",
                                              notOnTheMac: "That isn’t in the Mac’s library, so the Mac can’t play it. Choose this device to play it.",
                                              playlistsAreTheMacs: "Playlists are kept on the Mac, and hold only songs from the Mac’s library.",
                                              noPlaylists: "Playlists are kept on the Mac.")
}

@MainActor
public final class JoinedLibrary: RemoteChannel {
    public static let serverID = "vespertine-library"

    public struct Member {
        public enum Kind: Sendable, Equatable { case mac, share, folder }

        public var slot: Int
        public var name: String
        public var kind: Kind
        public var library: any LibraryMember
        /// A Mac that can send its songs to the phone (false for one whose Vespertine is too old to). Shares and folders
        /// always can: the phone reads them itself.
        public var canStream: @MainActor () -> Bool
        /// What a Mac said of itself when it answered; nil for a share or a folder, and for a Mac not heard from yet.
        public var server: @MainActor () -> ServerInfo?

        public init(slot: Int, name: String, kind: Kind, library: any LibraryMember,
                    canStream: @escaping @MainActor () -> Bool = { true }, server: @escaping @MainActor () -> ServerInfo? = { nil }) {
            self.slot = slot
            self.name = name
            self.kind = kind
            self.library = library
            self.canStream = canStream
            self.server = server
        }
    }

    public var onPush: (@MainActor (ServerMessage) -> Void)?
    public var onClose: (@MainActor (String?) -> Void)?
    /// What the lists hold changed (a library came or went, or who plays did): screens showing them load them again.
    public var onChange: (@MainActor () -> Void)?

    /// The libraries in the mix. At most one is a Mac.
    public var members: [Member] { didSet { changed() } }
    /// The Mac in the mix is who plays. The lists then hold what it can play, its own library; with this device playing
    /// they hold every library's.
    public var macPlays: Bool {
        didSet { if macPlays != oldValue { changed() } }
    }
    /// Goes up when what the lists hold changed.
    public private(set) var revision = 0
    /// How many albums or songs a library is asked for at a time while lists are put together.
    public var pageSize = 200

    private let name: String
    private let sayings: JoinedSayings
    private let now: @Sendable () -> Date
    private var isOpen = false
    /// What the Mac last said of its player, queue and outputs, with the slot written in: said again to a session that
    /// signs in later.
    private var lastPlayer: PlayerState?
    private var lastQueue: QueueState?
    private var lastOutputs: OutputsState?
    /// Open streams: the number the phone knows each by, and whose it is.
    private var streams: [Int: (slot: Int, stream: Int)] = [:]
    private var nextStream = 0
    private var albumLists: [String: Merge<AlbumSummary>] = [:]
    private var songList: Merge<TrackSummary>?
    private var artistList: [ArtistSummary]?
    private var genreList: [GenreSummary]?

    public init(name: String, members: [Member] = [], macPlays: Bool = false, sayings: JoinedSayings = .english,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.name = name
        self.members = members
        self.macPlays = macPlays
        self.sayings = sayings
        self.now = now
    }

    /// The Mac in the mix, if there is one.
    public var mac: Member? { members.first { $0.kind == .mac } }

    /// A library in the mix says its own lists changed (a share's scan found new songs, a Mac came back).
    public func changed() {
        albumLists = [:]
        songList = nil
        artistList = nil
        genreList = nil
        revision += 1
        onChange?()
    }

    public var info: ServerInfo {
        let told = mac?.server()
        return ServerInfo(name: told?.name ?? mac?.name ?? name, serverID: Self.serverID, appVersion: told?.appVersion ?? "",
                          protocolVersion: RemoteProtocol.version, portable: told?.portable)
    }

    // MARK: RemoteChannel

    public func open(timeout: Duration) async throws {
        isOpen = true
        for member in members { await (member.library as? ChannelMember)?.open() }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        streams.removeAll()
        for member in members { (member.library as? ChannelMember)?.close() }
        onClose?(nil)
    }

    /// Something the Mac in the mix said without being asked: what plays, its queue, its outputs. Passed on with the
    /// Mac's slot written into the songs. Its goodbyes are its own session's business.
    public func macSaid(_ message: ServerMessage) {
        guard let slot = mac?.slot else { return }
        switch message {
        case .player(var state):
            state.nowPlaying = state.nowPlaying.map { NowPlaying(entry: $0.entry, track: Self.joined($0.track, slot)) }
            lastPlayer = state
            if isOpen { onPush?(.player(state)) }
        case .queue(var state):
            func items(_ list: [QueueItem]) -> [QueueItem] { list.map { QueueItem(entry: $0.entry, track: Self.joined($0.track, slot)) } }
            state.current = state.current.map { QueueItem(entry: $0.entry, track: Self.joined($0.track, slot)) }
            state.playingNext = items(state.playingNext)
            state.continuing = items(state.continuing)
            lastQueue = state
            if isOpen { onPush?(.queue(state)) }
        case .outputs(let state):
            lastOutputs = state
            if isOpen { onPush?(.outputs(state)) }
        case .streamsClosed(let reason):
            if isOpen { onPush?(.streamsClosed(reason: reason)) }
        case .goodbye, .reply:
            break
        }
    }

    public func request(_ command: RemoteCommand, timeout: Duration) async throws -> RemoteReply {
        guard isOpen else { throw RemoteLinkError.closed }
        switch command {
        case .hello(_, _, let version, let highest):
            guard RemoteProtocol.negotiate(baseline: version, highest: highest) != nil else { return .failed(reason: "") }
            Task { [weak self] in
                guard let self, self.isOpen else { return }
                // With no Mac in the mix, or none heard from yet: an idle player, an empty queue and no outputs.
                self.onPush?(.player(self.lastPlayer ?? PlayerState(playback: .stopped, loading: false, nowPlaying: nil, position: 0, positionAt: self.now(),
                                                                    duration: 0, shuffle: false, repeatMode: .off, signal: nil, output: nil,
                                                                    volume: VolumeState(route: .fixed, level: nil, muted: false), waitingFor: nil, error: nil, transitions: nil)))
                self.onPush?(.queue(self.lastQueue ?? QueueState(revision: 1, current: nil, playingNext: [], continuing: [], continuingTotal: 0)))
                self.onPush?(.outputs(self.lastOutputs ?? OutputsState(outputs: [])))
            }
            return .welcome(info)
        case .pair:
            return .failed(reason: "")
        case .ping, .setLanguage:
            return .ok

        // Playing, the queue, the outputs and their sound are the Mac's.
        case .playPause, .play, .pause, .next, .previous, .stop, .seek, .setShuffle, .setRepeat,
             .jump, .removeFromQueue, .moveInQueue, .clearUpcoming,
             .selectOutput, .volume, .setVolume, .setTransitions,
             .setEqualizer, .setRoomCorrection, .setSpatialMode, .setSpatializeStereo, .setBalance:
            return await mac?.library.send(command) ?? .failed(reason: "")

        // The Mac plays what is in its own library.
        case .playAlbum(let key, let startAt, let shuffled):
            guard let mac else { return .failed(reason: "") }
            guard let split = JoinedID.split(key), split.slot == mac.slot else { return .failed(reason: sayings.notOnTheMac) }
            return await mac.library.send(.playAlbum(key: split.key, startAt: startAt, shuffled: shuffled))
        case .playAlbums(let keys, let shuffled):
            guard let mac else { return .failed(reason: "") }
            let own = keys.compactMap(JoinedID.split).filter { $0.slot == mac.slot }.map(\.key)
            guard !own.isEmpty else { return .failed(reason: sayings.notOnTheMac) }
            return await mac.library.send(.playAlbums(keys: own, shuffled: shuffled))
        case .playTracks(let ids, let startAt, let shuffled):
            guard let mac else { return .failed(reason: "") }
            guard let list = Self.macsOwn(ids, startAt: startAt, slot: mac.slot) else { return .failed(reason: sayings.notOnTheMac) }
            return await mac.library.send(.playTracks(ids: list.ids, startAt: list.startAt, shuffled: shuffled))
        case .playCopy(let ids, let startAt):
            guard let mac else { return .failed(reason: "") }
            guard let list = Self.macsOwn(ids, startAt: startAt, slot: mac.slot) else { return .failed(reason: sayings.notOnTheMac) }
            return await mac.library.send(.playCopy(ids: list.ids, startAt: list.startAt))
        case .playNext(let ids):
            guard let mac else { return .failed(reason: "") }
            let own = Self.own(ids, slot: mac.slot)
            guard !own.isEmpty else { return .failed(reason: sayings.notOnTheMac) }
            return await mac.library.send(.playNext(ids: own))
        case .addToQueue(let ids):
            guard let mac else { return .failed(reason: "") }
            let own = Self.own(ids, slot: mac.slot)
            guard !own.isEmpty else { return .failed(reason: sayings.notOnTheMac) }
            return await mac.library.send(.addToQueue(ids: own))

        // Playlists are the Mac's, and hold its songs.
        case .playPlaylist:
            return await mac?.library.send(command) ?? .failed(reason: sayings.noPlaylists)
        case .playlists:
            guard let mac, case .playlists(let items) = await mac.library.send(.playlists) else { return .playlists(items: []) }
            return .playlists(items: items.map { Self.joined($0, mac.slot) })
        case .playlistTracks:
            guard let mac else { return .failed(reason: sayings.noPlaylists) }
            return Self.joined(await mac.library.send(command), mac.slot)
        case .addToPlaylist(let id, let ids):
            guard let mac else { return .failed(reason: sayings.noPlaylists) }
            let own = Self.own(ids, slot: mac.slot)
            guard own.count == ids.count else { return .failed(reason: sayings.playlistsAreTheMacs) }
            return await mac.library.send(.addToPlaylist(id: id, ids: own))
        case .createPlaylist(let name, let ids):
            guard let mac else { return .failed(reason: sayings.noPlaylists) }
            let own = Self.own(ids, slot: mac.slot)
            guard own.count == ids.count else { return .failed(reason: sayings.playlistsAreTheMacs) }
            guard case .playlists(let items) = await mac.library.send(.createPlaylist(name: name, ids: own)) else { return .failed(reason: "") }
            return .playlists(items: items.map { Self.joined($0, mac.slot) })

        // A heart goes to the library the song is in.
        case .setFavorite(let ids, let on):
            var failure: RemoteReply?
            var known = false
            for (slot, own) in Self.bySlot(ids) {
                guard let member = member(slot) else { continue }
                known = true
                let reply = await member.library.send(.setFavorite(ids: own, on: on))
                if reply != .ok, failure == nil { failure = reply }
            }
            return failure ?? (known ? .ok : .failed(reason: sayings.gone))

        // One album, one cover, some songs: asked of the library they are in.
        case .albumTracks(let key):
            guard let split = JoinedID.split(key), let member = member(split.slot) else { return .failed(reason: sayings.gone) }
            return Self.joined(await member.library.send(.albumTracks(key: split.key)), member.slot)
        case .artwork(let key, let size):
            guard let split = JoinedID.split(key), let member = member(split.slot) else { return .failed(reason: "") }
            return Self.joined(await member.library.send(.artwork(key: split.key, size: size)), member.slot)
        case .sourceAlbums(let id):
            guard let split = JoinedID.split(id), let member = member(split.slot) else { return .failed(reason: sayings.gone) }
            return Self.joined(await member.library.send(.sourceAlbums(id: split.id)), member.slot)
        case .tracks(let ids):
            var found: [Int64: TrackSummary] = [:]
            for (slot, own) in Self.bySlot(ids) {
                guard let member = member(slot), case .tracks(let items) = await member.library.send(.tracks(ids: own)) else { continue }
                for item in items.map({ Self.joined($0, slot) }) { if let id = item.id { found[id] = item } }
            }
            return .tracks(items: ids.compactMap { found[$0] })
        case .streamInfo(let ids, let maxSampleRate):
            var found: [Int64: StreamInfo] = [:]
            for (slot, own) in Self.bySlot(ids) {
                guard let member = member(slot), case .streamInfo(let items) = await member.library.send(.streamInfo(ids: own, maxSampleRate: maxSampleRate)) else { continue }
                for var item in items {
                    guard let id = JoinedID.join(item.id, slot: slot) else { continue }
                    item.id = id
                    found[id] = item
                }
            }
            return .streamInfo(items: ids.compactMap { found[$0] })

        // Streams: opened in the library the song is in, and known to the phone by a number of this channel's own.
        case .streamOpen(let id, let maxSampleRate, let smaller, let dop):
            guard let split = JoinedID.split(id), let member = member(split.slot) else { return .failed(reason: sayings.gone) }
            let reply = await member.library.send(.streamOpen(id: split.id, maxSampleRate: maxSampleRate, smaller: smaller, dop: dop))
            guard case .streamOpened(var descriptor) = reply else { return reply }
            guard isOpen else { return .failed(reason: "") }
            nextStream += 1
            streams[nextStream] = (member.slot, descriptor.stream)
            // More than a handful open means some were never closed: the oldest are forgotten.
            for old in streams.keys.sorted().dropLast(16) { streams[old] = nil }
            descriptor.stream = nextStream
            return .streamOpened(descriptor)
        case .streamClose(let stream):
            guard let open = streams.removeValue(forKey: stream), let member = member(open.slot) else { return .ok }
            return await member.library.send(.streamClose(stream: open.stream))
        case .streamRead:
            return .failed(reason: "")

        // The lists: every library's, put together.
        case .albums(let offset, let limit, let sort, let filter):
            let page = await albums(sort: sort, filter: filter).page(offset: offset, limit: limit)
            return .albums(items: page.items, total: page.total)
        case .songs(let offset, let limit):
            let page = await songs().page(offset: offset, limit: limit)
            return .songs(items: page.items, total: page.total)
        case .artists:
            return .artists(items: await artists())
        case .genres:
            return .genres(items: await genres())
        case .artistAlbums, .genreAlbums:
            var all: [AlbumSummary] = []
            for member in listed {
                if case .albums(let items, _) = await member.library.send(command) { all += items.map { Self.joined($0, member.slot) } }
            }
            return .albums(items: all, total: all.count)
        case .recentlyAdded(let limit):
            var lists: [[AlbumSummary]] = []
            for member in listed {
                if case .albums(let items, _) = await member.library.send(command) { lists.append(items.map { Self.joined($0, member.slot) }) }
            }
            let newest = Self.inTurn(lists, limit: limit)
            return .albums(items: newest, total: newest.count)
        case .favorites:
            var all: [TrackSummary] = []
            for member in listed {
                if case .tracks(let items) = await member.library.send(.favorites) { all += items.map { Self.joined($0, member.slot) } }
            }
            return .tracks(items: all)
        case .search(_, let limit):
            var lists: [[TrackSummary]] = []
            for member in listed {
                if case .tracks(let items) = await member.library.send(command) { lists.append(items.map { Self.joined($0, member.slot) }) }
            }
            return .tracks(items: Self.inTurn(lists, limit: limit))
        case .find(_, let limit):
            var tracks: [[TrackSummary]] = [], albums: [[AlbumSummary]] = [], artists: [[ArtistSummary]] = [], playlists: [PlaylistSummary] = []
            for member in listed {
                guard case .found(let results) = await member.library.send(command) else { continue }
                tracks.append(results.tracks.map { Self.joined($0, member.slot) })
                albums.append(results.albums.map { Self.joined($0, member.slot) })
                artists.append(results.artists.map { Self.joined($0, member.slot) })
                playlists += results.playlists.map { Self.joined($0, member.slot) }
            }
            return .found(SearchResults(tracks: Self.inTurn(tracks, limit: limit), albums: Self.inTurn(albums, limit: limit),
                                        artists: Array(Self.union(artists.flatMap { $0 }).prefix(max(0, limit))), playlists: playlists))
        case .library:
            return .library(await overview())
        }
    }

    public func read(stream: Int, offset: Int64, length: Int, timeout: Duration) async throws -> StreamFrame {
        guard isOpen, let open = streams[stream], let member = member(open.slot) else { throw RemoteLinkError.closed }
        var frame = try await member.library.readStream(open.stream, offset: offset, length: length)
        frame.stream = stream
        return frame
    }

    // MARK: The lists

    private func member(_ slot: Int) -> Member? { members.first { $0.slot == slot } }

    /// The libraries the lists are made from: the Mac's alone while it plays, else every library the phone can play from.
    private var listed: [Member] {
        if macPlays, let mac { return [mac] }
        return members.filter { $0.kind != .mac || $0.canStream() }
    }

    private func albums(sort: AlbumSort?, filter: AlbumFilter?) -> Merge<AlbumSummary> {
        let name = "\(sort?.rawValue ?? "")|\(filter?.rawValue ?? "")"
        if let list = albumLists[name] { return list }
        let size = pageSize
        let list = Merge<AlbumSummary>(feeds: listed.map { member in
            { offset in
                guard case .albums(let items, let total) = await member.library.send(.albums(offset: offset, limit: size, sort: sort, filter: filter)) else { return nil }
                return (items.map { Self.joined($0, member.slot) }, total)
            }
        }, before: Self.order(sort))
        albumLists[name] = list
        return list
    }

    private func songs() -> Merge<TrackSummary> {
        if let songList { return songList }
        let size = pageSize
        let list = Merge<TrackSummary>(feeds: listed.map { member in
            { offset in
                guard case .songs(let items, let total) = await member.library.send(.songs(offset: offset, limit: size)) else { return nil }
                return (items.map { Self.joined($0, member.slot) }, total)
            }
        }, before: { Self.words($0.title, before: $1.title) })
        songList = list
        return list
    }

    private func artists() async -> [ArtistSummary] {
        if let artistList { return artistList }
        let asked = revision
        var all: [ArtistSummary] = []
        for member in listed {
            if case .artists(let items) = await member.library.send(.artists) { all += items.map { Self.joined($0, member.slot) } }
        }
        let list = Self.union(all).sorted { Self.words($0.name, before: $1.name) == true }
        if asked == revision { artistList = list }
        return list
    }

    private func genres() async -> [GenreSummary] {
        if let genreList { return genreList }
        let asked = revision
        var order: [String] = []
        var seen: [String: GenreSummary] = [:]
        for member in listed {
            guard case .genres(let items) = await member.library.send(.genres) else { continue }
            for item in items.map({ Self.joined($0, member.slot) }) {
                if var genre = seen[item.key] {
                    genre.albumCount += item.albumCount
                    genre.artworkKeys = Array((genre.artworkKeys + item.artworkKeys).prefix(4))
                    seen[item.key] = genre
                } else {
                    order.append(item.key)
                    seen[item.key] = item
                }
            }
        }
        let list = order.compactMap { seen[$0] }.sorted { Self.words($0.name, before: $1.name) == true }
        if asked == revision { genreList = list }
        return list
    }

    /// How much the lists hold. Artists and genres are counted from the lists themselves: a name two libraries share is
    /// one row, and the count says what the list shows.
    private func overview() async -> LibraryOverview {
        let listed = listed
        var sum = LibraryOverview(albums: 0, artists: 0, songs: 0, genres: 0, favorites: 0, playlists: 0, sources: [])
        var answered = 0
        for member in listed {
            guard case .library(let part) = await member.library.send(.library) else { continue }
            answered += 1
            sum.albums += part.albums
            sum.songs += part.songs
            sum.favorites += part.favorites
            sum.artists += part.artists
            sum.genres += part.genres
            if member.kind == .mac { sum.playlists += part.playlists }
            sum.sources += part.sources.compactMap { source in
                guard let id = JoinedID.join(source.id, slot: member.slot) else { return nil }
                var source = source
                source.id = id
                if member.kind == .folder { source.kind = .folder }
                return source
            }
        }
        if answered > 1 {
            sum.artists = await artists().count
            sum.genres = await genres().count
        }
        return sum
    }

    // MARK: Slots in and out

    /// A list of songs as the Mac can play it: its own songs, and where in them the song asked for is. nil when that
    /// song isn't the Mac's.
    static func macsOwn(_ ids: [Int64], startAt: Int, slot: Int) -> (ids: [Int64], startAt: Int)? {
        guard !ids.isEmpty else { return ([], 0) }
        let split = ids.map(JoinedID.split)
        let start = min(max(startAt, 0), ids.count - 1)
        guard split[start]?.slot == slot else { return nil }
        return (split.compactMap { $0?.slot == slot ? $0?.id : nil }, split[..<start].filter { $0?.slot == slot }.count)
    }

    static func own(_ ids: [Int64], slot: Int) -> [Int64] {
        ids.compactMap(JoinedID.split).filter { $0.slot == slot }.map(\.id)
    }

    /// Songs by the library they are in, each with its own numbers, in the order asked.
    static func bySlot(_ ids: [Int64]) -> [(slot: Int, ids: [Int64])] {
        var order: [Int] = []
        var groups: [Int: [Int64]] = [:]
        for id in ids {
            guard let split = JoinedID.split(id) else { continue }
            if groups[split.slot] == nil { order.append(split.slot) }
            groups[split.slot, default: []].append(split.id)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    public nonisolated static func joined(_ track: TrackSummary, _ slot: Int) -> TrackSummary {
        var track = track
        track.id = track.id.flatMap { JoinedID.join($0, slot: slot) }
        track.albumKey = JoinedID.join(track.albumKey, slot: slot)
        track.artworkKey = track.artworkKey.map { JoinedID.join($0, slot: slot) }
        track.copies = track.copies?.compactMap { copy in
            guard let id = JoinedID.join(copy.id, slot: slot) else { return nil }
            var copy = copy
            copy.id = id
            return copy
        }
        track.otherLayout = track.otherLayout.flatMap { other in
            guard let id = JoinedID.join(other.id, slot: slot) else { return nil }
            return TrackVersion(id: id, album: other.album, albumKey: JoinedID.join(other.albumKey, slot: slot), duration: other.duration,
                                format: other.format, artworkKey: other.artworkKey.map { JoinedID.join($0, slot: slot) })
        }
        return track
    }

    static func joined(_ album: AlbumSummary, _ slot: Int) -> AlbumSummary {
        var album = album
        album.key = JoinedID.join(album.key, slot: slot)
        album.artworkKey = album.artworkKey.map { JoinedID.join($0, slot: slot) }
        return album
    }

    static func joined(_ artist: ArtistSummary, _ slot: Int) -> ArtistSummary {
        ArtistSummary(name: artist.name, albumCount: artist.albumCount, artworkKey: artist.artworkKey.map { JoinedID.join($0, slot: slot) })
    }

    static func joined(_ genre: GenreSummary, _ slot: Int) -> GenreSummary {
        GenreSummary(key: genre.key, name: genre.name, albumCount: genre.albumCount, artworkKeys: genre.artworkKeys.map { JoinedID.join($0, slot: slot) })
    }

    /// A playlist keeps its number (only the Mac has playlists); its covers are the Mac's.
    static func joined(_ playlist: PlaylistSummary, _ slot: Int) -> PlaylistSummary {
        var playlist = playlist
        playlist.artworkKeys = playlist.artworkKeys?.map { JoinedID.join($0, slot: slot) }
        return playlist
    }

    /// A library's answer with its slot written into every song, album and cover in it.
    static func joined(_ reply: RemoteReply, _ slot: Int) -> RemoteReply {
        switch reply {
        case .tracks(let items): .tracks(items: items.map { joined($0, slot) })
        case .songs(let items, let total): .songs(items: items.map { joined($0, slot) }, total: total)
        case .albums(let items, let total): .albums(items: items.map { joined($0, slot) }, total: total)
        case .artwork(let key, let size, let mimeType, let data): .artwork(key: JoinedID.join(key, slot: slot), size: size, mimeType: mimeType, data: data)
        default: reply
        }
    }

    /// One row for each name: its albums counted together, and the first cover there is.
    static func union(_ artists: [ArtistSummary]) -> [ArtistSummary] {
        var order: [String] = []
        var seen: [String: ArtistSummary] = [:]
        for artist in artists {
            if var known = seen[artist.name] {
                known.albumCount += artist.albumCount
                known.artworkKey = known.artworkKey ?? artist.artworkKey
                seen[artist.name] = known
            } else {
                order.append(artist.name)
                seen[artist.name] = artist
            }
        }
        return order.compactMap { seen[$0] }
    }

    /// The lists taken from in turn (the first of each, then the second of each…), up to `limit`.
    static func inTurn<Item>(_ lists: [[Item]], limit: Int) -> [Item] {
        var result: [Item] = []
        var row = 0
        while result.count < limit, lists.contains(where: { $0.count > row }) {
            for list in lists where list.count > row && result.count < limit { result.append(list[row]) }
            row += 1
        }
        return result
    }

    /// Whether `a` comes before `b` as names are sorted; nil when neither does.
    static func words(_ a: String, before b: String) -> Bool? {
        switch a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: nil
        }
    }

    /// The order the albums of several libraries are put in, for each way the Albums page sorts.
    static func order(_ sort: AlbumSort?) -> (AlbumSummary, AlbumSummary) -> Bool? {
        func byYear(newestFirst: Bool) -> (AlbumSummary, AlbumSummary) -> Bool? {
            { a, b in
                switch (a.year, b.year) {
                case (nil, nil): nil
                case (nil, _): false
                case (_, nil): true
                case (let x?, let y?): x == y ? nil : (newestFirst ? x > y : x < y)
                }
            }
        }
        switch sort ?? .library {
        case .library, .artist: return { words($0.artist, before: $1.artist) ?? words($0.title, before: $1.title) }
        case .title: return { words($0.title, before: $1.title) }
        case .newest: return byYear(newestFirst: true)
        case .oldest: return byYear(newestFirst: false)
        }
    }
}

/// Lists that are each in order, read a page at a time and put together into one list in that order. Only as much is
/// asked of each library as the page wanted needs, and what was put together is kept for the next page.
@MainActor
final class Merge<Item: Sendable> {
    /// A page of one library's list from `offset`, and how long that list is; nil when the library can't be asked.
    typealias Feed = @MainActor (_ offset: Int) async -> (items: [Item], total: Int)?

    private struct Reader {
        var feed: Feed
        var waiting: ArraySlice<Item> = []
        var read = 0
        var total: Int?
        var done = false
    }

    private var readers: [Reader]
    private let before: (Item, Item) -> Bool?
    private var merged: [Item] = []
    private var tail: Task<Void, Never>?

    init(feeds: [Feed], before: @escaping (Item, Item) -> Bool?) {
        readers = feeds.map { Reader(feed: $0) }
        self.before = before
    }

    /// The items from `offset`, up to `limit` of them, and how many there are in all.
    func page(offset: Int, limit: Int) async -> (items: [Item], total: Int) {
        // One page is put together at a time: two at once would read the same part of a library twice.
        let earlier = tail
        let work = Task { @MainActor [self] () -> (items: [Item], total: Int) in
            await earlier?.value
            let start = max(0, offset)
            await fill(to: start + max(0, limit))
            let end = min(merged.count, start + max(0, limit))
            return (start < end ? Array(merged[start..<end]) : [], readers.reduce(0) { $0 + ($1.total ?? 0) })
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func fill(to count: Int) async {
        while true {
            // Every library that has more is read before choosing: what comes next can be in any of them.
            for index in readers.indices where readers[index].waiting.isEmpty && !readers[index].done {
                guard let page = await readers[index].feed(readers[index].read) else {
                    readers[index].done = true
                    continue
                }
                readers[index].total = page.total
                readers[index].read += page.items.count
                readers[index].waiting = page.items[...]
                if page.items.isEmpty || readers[index].read >= page.total { readers[index].done = true }
            }
            guard merged.count < count else { return }
            var first: Int?
            for index in readers.indices {
                guard let item = readers[index].waiting.first else { continue }
                // Ties stay in the order the libraries are in.
                if let chosen = first, let held = readers[chosen].waiting.first, before(item, held) != true { continue }
                first = index
            }
            guard let first, let item = readers[first].waiting.popFirst() else { return }
            merged.append(item)
        }
    }
}
