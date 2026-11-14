//
// Vespertine Remote: a pretend Mac inside the app, for trying the remote without one (and for App Review, which has no
// Mac running Vespertine). It keeps a small made-up library, a queue and a clock, and answers every command the way the
// real server does, without any network or sound.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

@MainActor
public final class DemoMac: RemoteChannel {
    public static let serverID = "vespertine-demo"

    public var onPush: (@MainActor (ServerMessage) -> Void)?
    public var onClose: (@MainActor (String?) -> Void)?

    public let info: ServerInfo
    /// Makes a cover for an album key at a size (the app draws them); nil answers like a missing cover.
    private let artwork: @MainActor (String, Int) -> Data?

    private struct Album {
        var summary: AlbumSummary
        var tracks: [Int64]
        var genre: String
        var source: Int64
        /// Its place among the albums by when it was added (0: the newest).
        var added: Int
    }

    /// A second copy of one song (a Dolby Atmos mix beside the stereo file): song ID → the other copy's ID.
    private var otherCopies: [Int64: Int64] = [:]
    private let sourceNames: [(Int64, String, SourceKind)] = [(1, "Music", .folder), (2, "Studio NAS", .network), (3, "Archive Drive", .external)]

    private var albums: [Album] = []
    private var tracks: [Int64: TrackSummary] = [:]
    private var playlists: [(PlaylistSummary, [Int64])] = []

    private var current: QueueItem?
    private var playingNext: [QueueItem] = []
    private var continuing: [QueueItem] = []
    private var played: [QueueItem] = []
    private var revision = 1
    private var nextEntry = 0

    private var playback: PlaybackValue = .paused
    private var position: Double = 0
    private var positionAt = Date()
    private var shuffle = false
    private var repeatMode: RepeatModeValue = .off
    private var transitions: Bool? = false
    private var outputs: [OutputSummary] = []
    private var level = 0.55
    private var muted = false

    private var isOpen = false
    private var clock: Task<Void, Never>?

    public init(name: String, appVersion: String = "1.1.0", artwork: @escaping @MainActor (String, Int) -> Data?) {
        info = ServerInfo(name: name, serverID: Self.serverID, appVersion: appVersion)
        self.artwork = artwork
        makeLibrary()
        outputs = [
            OutputSummary(uid: nil, name: "System Default", detail: "MacBook Pro Speakers", kind: .systemDefault, selected: false, ready: true),
            OutputSummary(uid: "demo-dac", name: "Desk DAC", detail: "USB DAC · 44.1–768 kHz · DSD512", kind: .device, selected: true, ready: true),
            OutputSummary(uid: "demo-receiver", name: "Living Room Receiver", detail: "HDMI · 8 channels · 32–192 kHz", kind: .device, selected: false, ready: true),
            OutputSummary(uid: "demo-group", name: "Bar", detail: "Speaker group · 2 outputs", kind: .speakerGroup, selected: false, ready: false),
        ]
        if let first = albums.first {
            load(first.tracks, startAt: 0)
            position = 74
        }
    }

    // MARK: RemoteChannel

    public func open(timeout: Duration) async throws {
        isOpen = true
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        clock?.cancel()
        clock = nil
        onClose?(nil)
    }

    public func request(_ command: RemoteCommand, timeout: Duration) async throws -> RemoteReply {
        guard isOpen else { throw RemoteLinkError.closed }
        let reply = perform(command)
        if case .hello = command {
            // Like the Mac: the welcome first, then everything a new remote needs to draw itself.
            Task { [weak self] in
                guard let self, self.isOpen else { return }
                self.onPush?(.player(self.playerState()))
                self.onPush?(.queue(self.queueState()))
                self.onPush?(.outputs(OutputsState(outputs: self.outputs)))
            }
        }
        return reply
    }

    // MARK: Commands

    private let notInLibrary = RemoteReply.failed(reason: "That isn’t in the demo library.")

    private func perform(_ command: RemoteCommand) -> RemoteReply {
        switch command {
        case .hello(_, _, let version, let highest):
            return RemoteProtocol.negotiate(baseline: version, highest: highest) != nil ? .welcome(info) : .failed(reason: "")
        case .pair:
            return .failed(reason: "")
        case .streamInfo, .streamOpen, .streamRead, .streamClose:
            // The demo library has no audio files; its sound comes with the phone player's bundled clips.
            return .failed(reason: "The demo library has nothing to stream.")

        case .playPause: setPlayback(playback == .playing ? .paused : .playing)
        case .play: setPlayback(.playing)
        case .pause: setPlayback(.paused)
        case .stop:
            setPlayback(.stopped)
            moveTo(0)
        case .next: advance(userAsked: true)
        case .previous:
            if currentPosition > 3 || played.isEmpty {
                moveTo(0)
            } else if let last = played.popLast() {
                if let current { continuing.insert(current, at: 0) }
                current = last
                bump()
                moveTo(0)
            }
        case .seek(let seconds): moveTo(min(max(0, seconds), duration))
        case .setShuffle(let on):
            shuffle = on
            if on { continuing.shuffle() }
            bump()
        case .setRepeat(let mode): repeatMode = mode

        case .jump(let entry):
            if let index = playingNext.firstIndex(where: { $0.entry == entry }) {
                if let current { played.append(current) }
                current = playingNext[index]
                playingNext.removeFirst(index + 1)
            } else if let index = continuing.firstIndex(where: { $0.entry == entry }) {
                if let current { played.append(current) }
                played.append(contentsOf: continuing.prefix(index))
                current = continuing[index]
                continuing.removeFirst(index + 1)
            } else {
                return .failed(reason: "That song isn’t in the queue any more.")
            }
            bump()
            moveTo(0)
            setPlayback(.playing)
        case .removeFromQueue(let entries):
            playingNext.removeAll { entries.contains($0.entry) }
            continuing.removeAll { entries.contains($0.entry) }
            bump()
        case .moveInQueue(let entries, let before):
            let moving = (playingNext + continuing).filter { entries.contains($0.entry) }
            guard !moving.isEmpty else { return .failed(reason: "That song isn’t in the queue any more.") }
            let inNext = playingNext.contains { entries.contains($0.entry) }
            playingNext.removeAll { entries.contains($0.entry) }
            continuing.removeAll { entries.contains($0.entry) }
            if let before, let index = playingNext.firstIndex(where: { $0.entry == before }) {
                playingNext.insert(contentsOf: moving, at: index)
            } else if let before, let index = continuing.firstIndex(where: { $0.entry == before }) {
                continuing.insert(contentsOf: moving, at: index)
            } else if inNext {
                playingNext.append(contentsOf: moving)
            } else {
                continuing.append(contentsOf: moving)
            }
            bump()
        case .clearUpcoming:
            playingNext.removeAll()
            continuing.removeAll()
            bump()

        case .playAlbum(let key, let startAt, let shuffled):
            guard let album = albums.first(where: { $0.summary.key == key }) else { return notInLibrary }
            play(album.tracks, startAt: startAt, shuffled: shuffled)
        case .playTracks(let ids, let startAt, let shuffled):
            let known = ids.filter { tracks[$0] != nil }
            guard !known.isEmpty else { return notInLibrary }
            play(known, startAt: min(startAt, known.count - 1), shuffled: shuffled)
        case .playPlaylist(let id, let shuffled):
            guard let playlist = playlists.first(where: { $0.0.id == id }) else { return notInLibrary }
            play(playlist.1, startAt: 0, shuffled: shuffled)
        case .playNext(let ids):
            playingNext.insert(contentsOf: items(ids), at: 0)
            bump()
        case .addToQueue(let ids):
            playingNext.append(contentsOf: items(ids))
            bump()
        case .setFavorite(let ids, let on):
            for id in ids { tracks[id]?.favorite = on }
            refreshFavorites()
        case .playAlbums(let keys, let shuffled):
            let ids = keys.flatMap { key in albums.first { $0.summary.key == key }?.tracks ?? [] }
            guard !ids.isEmpty else { return notInLibrary }
            play(ids, startAt: 0, shuffled: shuffled)
        case .playCopy(let ids, let startAt):
            let known = ids.filter { tracks[$0] != nil }
            guard !known.isEmpty else { return notInLibrary }
            play(known, startAt: startAt, shuffled: nil)

        case .albums(let offset, let limit):
            let start = min(max(0, offset), albums.count)
            let end = min(albums.count, start + max(0, limit))
            return .albums(items: albums[start..<end].map(\.summary), total: albums.count)
        case .tracks(let ids):
            return .tracks(items: ids.compactMap { tracks[$0] })
        case .albumTracks(let key):
            guard let album = albums.first(where: { $0.summary.key == key }) else { return notInLibrary }
            return .tracks(items: album.tracks.compactMap { tracks[$0] })
        case .artists:
            let names = Array(Set(albums.map(\.summary.artist))).sorted()
            return .artists(items: names.map { name in
                let theirs = albums.filter { $0.summary.artist == name }
                return ArtistSummary(name: name, albumCount: theirs.count, artworkKey: theirs.first?.summary.artworkKey)
            })
        case .artistAlbums(let name):
            let theirs = albums.filter { $0.summary.artist == name }.map(\.summary)
            return .albums(items: theirs, total: theirs.count)
        case .playlists:
            return .playlists(items: playlists.map(summary))
        case .playlistTracks(let id):
            guard let playlist = playlists.first(where: { $0.0.id == id }) else { return notInLibrary }
            return .tracks(items: playlist.1.compactMap { tracks[$0] })
        case .favorites:
            // A song in two copies is listed once, with its copies beside it.
            let hidden = Set(otherCopies.values)
            return .tracks(items: allTracks.filter { $0.favorite && !hidden.contains($0.id ?? 0) }.map(withCopies))
        case .library:
            let favorites = allTracks.filter { $0.favorite && !otherCopies.values.contains($0.id ?? 0) }.count
            return .library(LibraryOverview(albums: albums.count, artists: Set(albums.map(\.summary.artist)).count, songs: allTracks.count,
                                            genres: Set(albums.map(\.genre)).count, favorites: favorites, playlists: playlists.count, sources: sources))
        case .genres:
            return .genres(items: Set(albums.map(\.genre)).sorted().map { genre in
                let theirs = albums.filter { $0.genre == genre }
                return GenreSummary(key: genre.lowercased(), name: genre, albumCount: theirs.count, artworkKeys: Array(theirs.compactMap(\.summary.artworkKey).prefix(4)))
            })
        case .genreAlbums(let key):
            let theirs = albums.filter { $0.genre.lowercased() == key }.map(\.summary)
            return .albums(items: theirs, total: theirs.count)
        case .recentlyAdded(let limit):
            let newest = albums.sorted { $0.added < $1.added }.prefix(min(max(1, limit), 150)).map(\.summary)
            return .albums(items: newest, total: newest.count)
        case .sourceAlbums(let id):
            guard sourceNames.contains(where: { $0.0 == id }) else { return notInLibrary }
            let theirs = albums.filter { $0.source == id }.map(\.summary)
            return .albums(items: theirs, total: theirs.count)
        case .search(let text, let limit):
            let words = text.lowercased().split(separator: " ").map(String.init)
            guard !words.isEmpty else { return .tracks(items: []) }
            let found = allTracks.filter { track in
                let haystack = "\(track.title) \(track.artist) \(track.album)".lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            return .tracks(items: Array(found.prefix(min(max(1, limit), 500))))
        case .songs(let offset, let limit):
            let songs = allTracks.sorted { ($0.title, $0.id ?? 0) < ($1.title, $1.id ?? 0) }
            let start = min(max(0, offset), songs.count)
            let end = min(songs.count, start + min(max(1, limit), 500))
            return .songs(items: Array(songs[start..<end]), total: songs.count)
        case .find(let text, let limit):
            let words = text.lowercased().split(separator: " ").map(String.init)
            guard !words.isEmpty else { return .found(SearchResults(tracks: [], albums: [], artists: [], playlists: [])) }
            let limit = min(max(1, limit), 500)
            func matches(_ haystack: String) -> Bool { words.allSatisfy { haystack.lowercased().contains($0) } }
            let artists = Array(Set(albums.map(\.summary.artist))).sorted().filter(matches).map { name in
                let theirs = albums.filter { $0.summary.artist == name }
                return ArtistSummary(name: name, albumCount: theirs.count, artworkKey: theirs.first?.summary.artworkKey)
            }
            return .found(SearchResults(
                tracks: Array(allTracks.filter { matches("\($0.title) \($0.artist) \($0.album)") }.prefix(limit)),
                albums: Array(albums.map(\.summary).filter { matches("\($0.title) \($0.artist)") }.prefix(limit)),
                artists: Array(artists.prefix(limit)),
                playlists: Array(playlists.map(summary).filter { matches($0.name) }.prefix(limit))))
        case .addToPlaylist(let id, let ids):
            guard let index = playlists.firstIndex(where: { $0.0.id == id }) else { return notInLibrary }
            guard !playlists[index].0.smart else { return .failed(reason: "A smart playlist chooses its own songs.") }
            let known = ids.filter { tracks[$0] != nil }
            guard !known.isEmpty else { return notInLibrary }
            playlists[index].1.append(contentsOf: known)
            return .ok
        case .createPlaylist(let name, let ids):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failed(reason: "A playlist needs a name.") }
            let id = (playlists.map(\.0.id).max() ?? 0) + 1
            playlists.append((PlaylistSummary(id: id, name: String(trimmed.prefix(200)), smart: false), ids.filter { tracks[$0] != nil }))
            return .playlists(items: playlists.map(summary))
        case .artwork(let key, let size):
            guard albums.contains(where: { $0.summary.artworkKey == key }), let data = artwork(key, size) else {
                return .failed(reason: "")
            }
            return .artwork(key: key, size: size, mimeType: "image/png", data: data)

        case .selectOutput(let uid):
            guard let index = outputs.firstIndex(where: { $0.uid == uid }) else {
                return .failed(reason: "That output isn’t connected to this Mac.")
            }
            guard outputs[index].ready else { return .failed(reason: "“\(outputs[index].name)” isn’t connected.") }
            for i in outputs.indices { outputs[i].selected = i == index }
            onPush?(.outputs(OutputsState(outputs: outputs)))
        case .volume(let action):
            switch action {
            case .up: level = min(1, level + 0.05); muted = false
            case .down: level = max(0, level - 0.05)
            case .mute: muted.toggle()
            }
        case .setVolume(let value):
            level = min(1, max(0, value))
            muted = false
        case .setTransitions(let on):
            transitions = on
        }
        pushPlayer()
        return .ok
    }

    // MARK: Playback

    private var duration: Double { current?.track.duration ?? 0 }

    private var currentPosition: Double {
        playback == .playing ? min(duration, position + Date().timeIntervalSince(positionAt)) : position
    }

    private func setPlayback(_ value: PlaybackValue) {
        position = currentPosition
        positionAt = Date()
        if value == .playing, current == nil { advance(userAsked: false) }
        playback = current == nil ? .stopped : value
    }

    private func moveTo(_ seconds: Double) {
        position = seconds
        positionAt = Date()
    }

    private func tick() {
        guard isOpen, playback == .playing, current != nil, currentPosition >= duration else { return }
        if repeatMode == .one {
            moveTo(0)
        } else {
            advance(userAsked: false)
        }
        pushPlayer()
    }

    private func advance(userAsked: Bool) {
        if let current { played.append(current) }
        if !playingNext.isEmpty {
            current = playingNext.removeFirst()
        } else if !continuing.isEmpty {
            current = continuing.removeFirst()
        } else if repeatMode == .all, !played.isEmpty {
            continuing = played
            played.removeAll()
            current = continuing.removeFirst()
        } else {
            current = nil
            playback = .stopped
        }
        bump()
        moveTo(0)
    }

    private func play(_ ids: [Int64], startAt: Int, shuffled: Bool?) {
        if let shuffled { shuffle = shuffled }
        load(ids, startAt: startAt)
        moveTo(0)
        playback = .playing
        bump()
    }

    private func load(_ ids: [Int64], startAt: Int) {
        var queue = items(ids)
        let start = min(max(0, startAt), max(0, queue.count - 1))
        played = Array(queue.prefix(start))
        queue.removeFirst(start)
        current = queue.isEmpty ? nil : queue.removeFirst()
        if shuffle { queue.shuffle() }
        continuing = queue
        playingNext.removeAll()
    }

    private func items(_ ids: [Int64]) -> [QueueItem] {
        ids.compactMap { id in
            guard let track = tracks[id] else { return nil }
            nextEntry += 1
            return QueueItem(entry: "demo-\(nextEntry)", track: track)
        }
    }

    private func bump() {
        revision += 1
        onPush?(.queue(queueState()))
    }

    private func refreshFavorites() {
        func refreshed(_ item: QueueItem) -> QueueItem {
            var item = item
            if let id = item.track.id, let track = tracks[id] { item.track = track }
            return item
        }
        current = current.map(refreshed)
        playingNext = playingNext.map(refreshed)
        continuing = continuing.map(refreshed)
        bump()
    }

    private func pushPlayer() {
        onPush?(.player(playerState()))
    }

    // MARK: State

    private func playerState() -> PlayerState {
        let output = outputs.first(where: \.selected)
        let format = current?.track.format ?? ""
        let signal = current.map { _ in
            SignalSummary(bitPerfect: true, badge: "BIT-PERFECT", deviceFormat: Self.deviceFormat(for: format), exclusive: true)
        }
        return PlayerState(
            playback: playback, loading: false,
            nowPlaying: current.map { NowPlaying(entry: $0.entry, track: $0.track) },
            position: currentPosition, positionAt: Date(), duration: duration,
            shuffle: shuffle, repeatMode: repeatMode, signal: signal, output: output?.name,
            volume: VolumeState(route: output?.uid == "demo-receiver" ? .fixed : .hardware,
                                level: output?.uid == "demo-receiver" ? nil : level, muted: muted),
            waitingFor: nil, error: nil, transitions: transitions)
    }

    private func queueState() -> QueueState {
        QueueState(revision: revision, current: current, playingNext: playingNext,
                   continuing: Array(continuing.prefix(QueueState.continuingLimit)), continuingTotal: continuing.count)
    }

    private static func deviceFormat(for format: String) -> String {
        if format.hasPrefix("DSD") { return format.replacingOccurrences(of: " ", with: "") }
        return format.components(separatedBy: " · ").dropFirst().first ?? format
    }

    /// A playlist as the Mac lists it: with its song count and up to four covers for a tile.
    private func summary(_ playlist: (PlaylistSummary, [Int64])) -> PlaylistSummary {
        var summary = playlist.0
        summary.trackCount = playlist.1.count
        var covers: [String] = []
        for key in playlist.1.compactMap({ tracks[$0]?.artworkKey }) where !covers.contains(key) && covers.count < 4 { covers.append(key) }
        summary.artworkKeys = covers
        return summary
    }

    private var allTracks: [TrackSummary] {
        albums.flatMap(\.tracks).compactMap { tracks[$0] }
    }

    private var sources: [SourceSummary] {
        sourceNames.map { id, name, kind in
            SourceSummary(id: id, name: name, kind: kind, online: kind != .external, scanning: false, albumCount: albums.filter { $0.source == id }.count,
                          detail: kind == .external ? "REFERENCED IN PLACE · OFFLINE · SCANNED LAST WEEK" : "REFERENCED IN PLACE · ONLINE · SCANNED 2 HOURS AGO")
        }
    }

    /// A song with its other copy beside it, as Favorites lists a song the library has twice.
    private func withCopies(_ track: TrackSummary) -> TrackSummary {
        guard let id = track.id, let otherID = otherCopies[id], let other = tracks[otherID] else { return track }
        var listed = track
        listed.copies = [(track, "Music › \(track.artist)/\(track.album)"), (other, "Studio NAS › Spatial/\(track.artist)/\(track.album)")].compactMap { copy, place in
            copy.id.map { TrackCopy(id: $0, format: copy.format, hiRes: !copy.format.hasPrefix("Dolby"), edition: nil, location: place,
                                    duration: copy.duration, favorite: copy.favorite, preferred: false) }
        }
        return listed
    }

    // MARK: The made-up library

    private func makeLibrary() {
        // Every name here is invented.
        let catalog: [(String, String, Int, String, Bool, Bool, Bool, [String])] = [
            ("Low Tide Lanterns", "Marisol Vance", 2021, "FLAC · 24/96", true, false, false,
             ["Harbor Lights", "Salt and Cedar", "The Long Pier", "Night Ferry", "Lanterns", "Undertow", "Morning Fog", "Home by Water"]),
            ("Glass Orchard", "The Quiet Engines", 2019, "FLAC · 16/44.1", false, false, false,
             ["Orchard Gate", "Paper Sky", "Small Hours", "Static Bloom", "Copper Wire", "Last Train West", "Glasshouse"]),
            ("Nocturnes for a Small Room", "Ilse Brandt", 2023, "DSD128", true, true, false,
             ["Nocturne No. 1", "Nocturne No. 2", "Interlude in Grey", "Nocturne No. 3", "Lullaby", "Nocturne No. 4"]),
            ("Northern Signal", "Kestrel Park", 2018, "ALAC · 24/192", true, false, false,
             ["Aurora Line", "Radio North", "Frost Map", "Polar Drift", "Signal Fire", "Ice Road"]),
            ("Velvet Hours", "June Okafor", 2022, "FLAC · 24/48", true, false, false,
             ["Velvet", "Slow Dance at Noon", "Coffee Rings", "Blue Sundays", "Window Seat", "Hours", "Goodnight, City"]),
            ("Concert in the Round", "Aster Quartet", 2020, "FLAC · 24/96 · 5.1", true, false, true,
             ["Allegro con brio", "Adagio", "Scherzo", "Finale: Presto"]),
            ("Dust and Chrome", "Highway Saints", 2016, "FLAC · 16/44.1", false, false, false,
             ["Chrome Horses", "Dust Devil", "Mile Marker 9", "Diner Neon", "Two-Lane", "Sundown Run", "Rearview"]),
            ("Fieldwork", "Theo Lindqvist", 2024, "DSD64", true, true, false,
             ["Birch", "Meadow at Dusk", "Rain on Tin", "Fieldwork", "Hollow Oak"]),
            ("Salt Flats", "Mina Okonkwo", 2017, "FLAC · 24/96", true, false, false,
             ["Mirage", "Long Horizon", "Salt Flats", "Heat Haze", "Night Crossing"]),
            ("The Lamp Room", "Pavel Hart", 2021, "FLAC · 16/44.1", false, false, false,
             ["Lamp Room", "Quiet Hours", "Stairwell", "Open Window", "Late Tram", "Bell Tower"]),
            ("Tidal Letters", "Sofia Reyes Trio", 2022, "DSD64", true, true, false,
             ["Letter One", "Letter Two", "Harbour Wind", "Letter Three", "Slack Water"]),
            ("Winter Garden", "Anselm Roth", 2015, "FLAC · 24/88.2", true, false, false,
             ["Frost Frame", "Greenhouse", "Snowmelt", "Winter Garden", "Thaw"]),
            ("Overnight Ferry", "Lena Voss", 2020, "FLAC · 24/96", true, false, false,
             ["Boarding", "Wake", "Deck Lights", "Far Shore", "Landing"]),
            ("Brass and Rain", "The Morrow Brothers", 2018, "FLAC · 16/44.1", false, false, false,
             ["Brass and Rain", "Side Street", "Pawn Shop Blues", "Umbrella", "Last Call"]),
            ("Quiet Machines", "Iris Takahashi", 2023, "FLAC · 24/192", true, false, false,
             ["Idle", "Fan Noise", "Quiet Machines", "Standby", "Reboot", "Low Battery"]),
            ("Evergreen", "Tomás Aldea", 2019, "ALAC · 24/48", true, false, false,
             ["Evergreen", "Pine Road", "Cabin Window", "Woodsmoke", "Clearing"]),
            ("Slow Light", "Nora Beck", 2022, "DSD128", true, true, false,
             ["Dawn", "Slow Light", "Kitchen Radio", "Afternoon", "Dusk"]),
            ("After the Storm", "Wren and Ash", 2024, "FLAC · 24/96", true, false, false,
             ["Still Air", "Puddles", "After the Storm", "Rooftops", "Clear Sky", "Sunset Drive"]),
        ]
        let genres = ["Folk", "Indie Rock", "Classical", "Electronic", "Jazz", "Classical", "Rock", "Ambient", "Electronic", "Jazz", "Jazz", "Classical", "Folk", "Blues", "Electronic", "Folk", "Ambient", "Indie Rock"]
        var id: Int64 = 1000
        for (index, entry) in catalog.enumerated() {
            let (title, artist, year, format, hiRes, dsd, multichannel, titles) = entry
            let key = "demo-album-\(index + 1)"
            var ids: [Int64] = []
            var total: Double = 0
            for (number, song) in titles.enumerated() {
                id += 1
                let length = Double(150 + (index * 37 + number * 53) % 190)
                total += length
                tracks[id] = TrackSummary(id: id, title: song, artist: artist, album: title, albumKey: key, duration: length,
                                          trackNumber: number + 1, discNumber: 1, format: format, artworkKey: key,
                                          favorite: (index + number) % 5 == 0)
                ids.append(id)
            }
            albums.append(Album(summary: AlbumSummary(key: key, title: title, artist: artist, year: year, trackCount: ids.count,
                                                      duration: total, format: format, artworkKey: key, hiRes: hiRes, dsd: dsd,
                                                      multichannel: multichannel),
                                tracks: ids, genre: genres[index % genres.count], source: Int64(index % 3 == 2 ? 2 : index % 7 == 6 ? 3 : 1),
                                added: (index * 7) % catalog.count))
        }
        // One song the library has twice: the stereo file and a Dolby Atmos mix of it. Both are favorites, as on a
        // Mac where the album's copies are bundled; Favorites lists the song once.
        if let first = albums.first?.tracks.first, var atmos = tracks[first] {
            id += 1
            atmos.id = id
            atmos.format = "Dolby Atmos · 768k · 5.1"
            atmos.favorite = true
            tracks[first]?.favorite = true
            tracks[id] = atmos
            otherCopies[first] = id
        }
        let late = albums.flatMap(\.tracks).enumerated().filter { $0.offset % 3 == 1 }.map(\.element)
        let hiRes = albums.filter { $0.summary.hiRes }.flatMap(\.tracks)
        playlists = [
            (PlaylistSummary(id: 1, name: "Late Night", smart: false), Array(late.prefix(14))),
            (PlaylistSummary(id: 2, name: "Hi-Res", smart: true), hiRes),
        ]
    }
}
