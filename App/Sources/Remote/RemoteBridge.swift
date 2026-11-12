//
// Vespertine: what a remote sees and does, in terms of the app: the protocol's states built from the app model, and its
// commands carried out through the same calls the window, the Controls menu and the media keys use. Nothing here touches
// the engine or the audio thread.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary
import VespertineRemoteProtocol

/// The app as the remote server drives it.
@MainActor
struct RemoteBridge {
    let model: AppModel

    private var player: PlayerController { model.player }
    private var library: LibraryStore { model.library }
    private var settings: AppSettings { model.settings }

    // MARK: States

    func playerState(now: Date = .now) -> PlayerState {
        let path = player.signalPath
        let state = PlaybackValue(rawValue: player.state.rawValue) ?? .stopped
        return PlayerState(
            playback: state,
            loading: player.loading,
            nowPlaying: player.current.map { NowPlaying(entry: $0.id.uuidString, track: trackSummary($0.track)) },
            position: player.position,
            positionAt: now,
            duration: player.duration > 0 ? player.duration : player.current?.track.duration ?? 0,
            shuffle: player.shuffle,
            repeatMode: RepeatModeValue(rawValue: player.repeatMode.rawValue) ?? .off,
            signal: path.map { SignalSummary(bitPerfect: $0.isBitPerfect, badge: $0.statusLine, deviceFormat: $0.deviceFormatShort, exclusive: $0.applied.exclusive) },
            output: model.activeDevice?.name ?? model.missingChosenOutput,
            volume: volumeState,
            waitingFor: player.waitingForDevice,
            error: player.lastError,
            transitions: settings.transitionsFeature ? settings.transitions.enabled : nil)
    }

    var volumeState: VolumeState {
        switch model.volumeRoute {
        case .hardware:
            VolumeState(route: .hardware, level: model.devices.hardwareVolume.map(Double.init), muted: model.isVolumeMuted)
        case .software:
            VolumeState(route: .software, level: model.activeDevice.map { settings.appVolumeLevel(for: $0.uid) }, muted: model.isVolumeMuted)
        case .fixed:
            VolumeState(route: .fixed, level: nil, muted: false)
        }
    }

    /// What the queue holds, cheap to compare: `queueState` is built only when this changes. (A song's favorite heart
    /// in the queue is refreshed with the next change; the library's own pages are asked for afresh.)
    struct QueueSignature: Equatable {
        var entries: [UUID]
        var current: UUID?
        var playingNext: Int
    }

    var queueSignature: QueueSignature {
        QueueSignature(entries: player.queue.map(\.id), current: player.current?.id, playingNext: player.playingNext.count)
    }

    func queueState(revision: Int) -> QueueState {
        let continuing = player.continuing
        return QueueState(
            revision: revision,
            current: player.current.map { QueueItem(entry: $0.id.uuidString, track: trackSummary($0.track)) },
            playingNext: player.playingNext.map { QueueItem(entry: $0.id.uuidString, track: trackSummary($0.track)) },
            continuing: continuing.prefix(QueueState.continuingLimit).map { QueueItem(entry: $0.id.uuidString, track: trackSummary($0.track)) },
            continuingTotal: continuing.count)
    }

    /// The outputs as the Mac's output list shows them: System Default, the chosen output while it's missing, every
    /// device, then the speaker groups.
    func outputsState() -> OutputsState {
        let selected = settings.selectedDeviceUID
        var outputs = [OutputSummary(uid: nil, name: String(localized: "System Default"), detail: String(localized: "FOLLOWS SOUND SETTINGS"),
                                     kind: .systemDefault, selected: selected == nil, ready: true)]
        if let missing = model.missingChosenOutput, let uid = selected {
            outputs.append(OutputSummary(uid: uid, name: missing, detail: String(localized: "NOT CONNECTED · WAITING FOR IT", comment: "Output list: the chosen device is missing and playback waits for it"),
                                         kind: model.chosenGroup == nil ? .device : .speakerGroup, selected: true, ready: false))
        }
        for device in model.devices.devices where !outputs.contains(where: { $0.uid == device.uid }) {
            outputs.append(OutputSummary(uid: device.uid, name: device.name, detail: "\(device.profile.tag) · \(device.rangeSummary)",
                                         kind: .device, selected: selected == device.uid, ready: true))
        }
        if let groups = model.speakerGroups {
            for row in GroupOutputRows.rows(groups: groups.groups, devices: model.devices.devices) where !outputs.contains(where: { $0.uid == row.uid }) {
                outputs.append(OutputSummary(uid: row.uid, name: row.name, detail: row.detail, kind: .speakerGroup, selected: selected == row.uid, ready: row.isReady))
            }
        }
        return OutputsState(outputs: outputs)
    }

    func trackSummary(_ track: Track) -> TrackSummary {
        TrackSummary(id: track.id, title: track.title, artist: track.displayArtist.libraryDisplayName, album: track.displayAlbum.libraryDisplayName,
                     albumKey: track.albumKey, duration: track.duration, trackNumber: track.trackNumber, discNumber: track.discNumber,
                     format: track.formatSummary, artworkKey: model.artworkKey(track), favorite: library.isFavorite(track))
    }

    func albumSummary(_ album: Album) -> AlbumSummary {
        AlbumSummary(key: album.key, title: album.title.libraryDisplayName, artist: album.artist.libraryDisplayName, year: album.year,
                     trackCount: album.trackCount, duration: album.duration, format: album.formatSummary, artworkKey: album.artworkKey,
                     hiRes: album.isHiRes, dsd: album.isDSD, multichannel: album.isMultichannel)
    }

    /// A playlist as a remote lists it: its name, how many songs it has, and up to four of their covers for a tile.
    func playlistSummary(_ playlist: Playlist) -> PlaylistSummary? {
        guard let id = playlist.id else { return nil }
        let tracks = library.tracks(in: playlist)
        var covers: [String] = []
        for track in tracks {
            guard covers.count < 4 else { break }
            if let key = model.artworkKey(track), !covers.contains(key) { covers.append(key) }
        }
        return PlaylistSummary(id: id, name: playlist.name.libraryDisplayName, smart: playlist.isSmart, trackCount: tracks.count, artworkKeys: covers)
    }

    /// The most songs one command adds to a playlist.
    static let playlistBatch = 5_000

    /// Every song by title, kept until the library changes: a remote asks for it a page at a time.
    private static var songList: (library: ObjectIdentifier, revision: Int, count: Int, tracks: [Track])?

    static func songs(of library: LibraryStore) -> [Track] {
        let id = ObjectIdentifier(library)
        if let songList, songList.library == id, songList.revision == library.revision, songList.count == library.stats.tracks {
            return songList.tracks
        }
        let tracks = byTitle(library.allTracks())
        songList = (id, library.revision, library.stats.tracks, tracks)
        return tracks
    }

    /// Songs in the order a list of titles reads: by title as the Finder would sort it, then artist and album.
    nonisolated static func byTitle(_ tracks: [Track]) -> [Track] {
        tracks.sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
            let artist = a.displayArtist.localizedStandardCompare(b.displayArtist)
            if artist != .orderedSame { return artist == .orderedAscending }
            return (a.albumKey, a.discNumber ?? 0, a.trackNumber ?? 0, a.id ?? 0) < (b.albumKey, b.discNumber ?? 0, b.trackNumber ?? 0, b.id ?? 0)
        }
    }

    // MARK: Commands

    /// Carries out a command (everything but the session ones and artwork, which the connection handles).
    func perform(_ command: RemoteCommand) -> RemoteReply {
        switch command {
        case .hello, .pair, .artwork:
            return .failed(reason: String(localized: "This command isn’t available here.", comment: "Remote control: a phone sent a command at the wrong time."))

        case .playPause: player.togglePlayPause()
        case .play: if player.state != .playing { player.togglePlayPause() }
        case .pause: player.pause()
        case .next: player.next()
        case .previous: player.previous()
        case .stop: player.stop()
        case .seek(let seconds): player.seek(to: max(0, seconds))
        case .setShuffle(let on): player.shuffle = on
        case .setRepeat(let mode): player.repeatMode = RepeatMode(rawValue: mode.rawValue) ?? .off

        case .jump(let entry):
            guard let id = queueID(entry) else { return notInQueue }
            player.jump(to: id)
        case .removeFromQueue(let entries):
            player.removeFromQueue(entries.compactMap(queueID))
        case .moveInQueue(let entries, let before):
            let ids = entries.compactMap(queueID)
            guard !ids.isEmpty else { return notInQueue }
            player.moveUpcoming(ids, before: before.flatMap(queueID))
        case .clearUpcoming: player.clearUpcoming()

        case .playAlbum(let key, let startAt, let shuffled):
            let tracks = model.playableTracks(albumKey: key)
            guard !tracks.isEmpty else { return notInLibrary }
            player.play(tracks, startAt: startAt, shuffled: shuffled)
        case .playTracks(let ids, let startAt, let shuffled):
            let tracks = ordered(ids)
            guard !tracks.isEmpty else { return notInLibrary }
            player.play(tracks, startAt: startAt, shuffled: shuffled)
        case .playPlaylist(let id, let shuffled):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return notInLibrary }
            let tracks = library.tracks(in: playlist)
            guard !tracks.isEmpty else { return notInLibrary }
            player.play(tracks, shuffled: shuffled ?? false, transitions: library.transitions(of: playlist))
        case .playNext(let ids):
            let tracks = ordered(ids)
            guard !tracks.isEmpty else { return notInLibrary }
            player.playNext(tracks)
        case .addToQueue(let ids):
            let tracks = ordered(ids)
            guard !tracks.isEmpty else { return notInLibrary }
            player.addToQueue(tracks)
        case .setFavorite(let ids, let on):
            let tracks = library.tracks(ids: ids)
            guard !tracks.isEmpty else { return notInLibrary }
            // A song is all its copies, as the heart in the window treats it.
            let all = Set(library.playbackVersions(of: tracks).flatMap { $0 }.compactMap(\.id) + ids)
            library.setFavorite(on, trackIDs: Array(all))

        case .albums(let offset, let limit):
            let albums = library.albums
            let start = min(max(0, offset), albums.count)
            let end = min(start + min(max(1, limit), 500), albums.count)
            return .albums(items: albums[start..<end].map(albumSummary), total: albums.count)
        case .albumTracks(let key):
            return .tracks(items: model.playableTracks(albumKey: key).map(trackSummary))
        case .artists:
            return .artists(items: library.artists.map { ArtistSummary(name: $0.name.libraryDisplayName, albumCount: $0.albumCount, artworkKey: $0.artworkKey) })
        case .artistAlbums(let name):
            let albums = library.albums(artist: name)
            return .albums(items: albums.map(albumSummary), total: albums.count)
        case .playlists:
            return .playlists(items: library.playlists.compactMap(playlistSummary))
        case .playlistTracks(let id):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return notInLibrary }
            return .tracks(items: library.tracks(in: playlist).map(trackSummary))
        case .favorites:
            return .tracks(items: library.favoriteTracks().map(trackSummary))
        case .search(let text, let limit):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .tracks(items: []) }
            return .tracks(items: library.search(trimmed).prefix(min(max(1, limit), 500)).map(trackSummary))

        case .songs(let offset, let limit):
            let songs = Self.songs(of: library)
            let start = min(max(0, offset), songs.count)
            let end = min(start + min(max(1, limit), 500), songs.count)
            return .songs(items: songs[start..<end].map(trackSummary), total: songs.count)
        case .find(let text, let limit):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .found(SearchResults(tracks: [], albums: [], artists: [], playlists: [])) }
            let limit = min(max(1, limit), 500)
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            // Names are matched the way the search field matches songs: every word, anywhere, whatever its case or accents.
            func matches(_ names: String...) -> Bool {
                words.allSatisfy { word in names.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            }
            return .found(SearchResults(
                tracks: library.search(trimmed).prefix(limit).map(trackSummary),
                albums: library.albums.lazy.filter { matches($0.title.libraryDisplayName, $0.artist.libraryDisplayName) }.prefix(limit).map(albumSummary),
                artists: library.artists.lazy.filter { matches($0.name.libraryDisplayName) }.prefix(limit)
                    .map { ArtistSummary(name: $0.name.libraryDisplayName, albumCount: $0.albumCount, artworkKey: $0.artworkKey) },
                playlists: library.playlists.lazy.filter { matches($0.name.libraryDisplayName) }.prefix(limit).compactMap(playlistSummary)))

        case .addToPlaylist(let id, let ids):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return notInLibrary }
            guard !playlist.isSmart else {
                return .failed(reason: String(localized: "A smart playlist chooses its own songs. Pick another playlist.", comment: "Remote control: the phone tried to add songs to a smart playlist."))
            }
            let found = ordered(ids).compactMap(\.id)
            guard !found.isEmpty else { return notInLibrary }
            library.append(Array(found.prefix(Self.playlistBatch)), to: playlist)
        case .createPlaylist(let name, let ids):
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !trimmed.isEmpty else {
                return .failed(reason: String(localized: "A playlist needs a name.", comment: "Remote control: the phone asked for a new playlist without a name."))
            }
            let found = Array(ordered(ids).compactMap(\.id).prefix(Self.playlistBatch))
            guard let made = library.createPlaylist(name: trimmed, trackIDs: found) else {
                return .failed(reason: String(localized: "The playlist couldn’t be made.", comment: "Remote control: making a playlist from the phone failed."))
            }
            // The library's own list hears of the new playlist a moment later.
            var all = library.playlists
            if !all.contains(where: { $0.id == made.id }) { all.append(made) }
            return .playlists(items: all.compactMap(playlistSummary))

        case .selectOutput(let uid):
            if let uid, !outputsState().outputs.contains(where: { $0.uid == uid }) {
                return .failed(reason: String(localized: "That output isn’t connected to this Mac.", comment: "Remote control: the phone picked an output the Mac no longer has."))
            }
            model.selectDevice(uid)
        case .volume(let action):
            guard model.volumeRoute != .fixed else { return fixedVolume }
            model.adjustVolume(action == .up ? .up : action == .down ? .down : .mute)
        case .setVolume(let level):
            let level = min(max(level, 0), 1)
            switch model.volumeRoute {
            case .hardware: model.devices.setHardwareVolume(Float(level))
            case .software:
                guard let device = model.activeDevice else { return fixedVolume }
                settings.setAppVolumeLevel(level, for: device.uid)
                model.syncEngine()
            case .fixed: return fixedVolume
            }
        case .setTransitions(let on):
            guard settings.transitionsFeature else {
                return .failed(reason: String(localized: "Transitions are turned off in Vespertine’s settings on the Mac.", comment: "Remote control: the phone tried to turn on transitions, but the feature is off in Settings."))
            }
            model.setTransitions(on)
        }
        return .ok
    }

    private var notInQueue: RemoteReply {
        .failed(reason: String(localized: "That song is no longer in the queue.", comment: "Remote control: the phone acted on a queue entry that has gone."))
    }

    private var notInLibrary: RemoteReply {
        .failed(reason: String(localized: "Those songs aren’t in the library anymore.", comment: "Remote control: the phone asked for songs, an album or a playlist the Mac no longer has."))
    }

    private var fixedVolume: RemoteReply {
        .failed(reason: String(localized: "This output has no volume Vespertine can change. Set the level on your amplifier or DAC.", comment: "Remote control: volume asked for on an output whose volume is fixed (bit-perfect, no hardware volume)."))
    }

    private func queueID(_ entry: String) -> UUID? {
        guard let id = UUID(uuidString: entry), player.queue.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The library's songs with `ids`, in the order given.
    private func ordered(_ ids: [Int64]) -> [Track] {
        let byID = Dictionary(library.tracks(ids: ids).compactMap { t in t.id.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    // MARK: Artwork

    /// A stored cover file for `key` near `size`, read off the main thread. Keys are the library's own (hex and dashes);
    /// anything else is refused, so a key can never name a file outside the artwork folder.
    static func artwork(key: String, size: Int, store: ArtworkStore?) async -> (mimeType: String, data: Data)? {
        guard let store, !key.isEmpty, key.count <= 128,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let url = store.url(for: key, minimumSize: min(max(size, 1), 2048))
        return await Task.detached(priority: .userInitiated) { () -> (mimeType: String, data: Data)? in
            guard let data = try? Data(contentsOf: url), data.count <= RemoteProtocol.maximumMessageSize / 2 else { return nil }
            return (mimeType: mimeType(of: data), data: data)
        }.value
    }

    nonisolated static func mimeType(of data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if head.count >= 12, Array(head[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "application/octet-stream"
    }
}
