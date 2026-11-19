//
// Vespertine: what a remote sees and does, in terms of the app: the protocol's states built from the app model, and its
// commands carried out through the same calls the window, the Controls menu and the media keys use. Nothing here touches
// the engine or the audio thread.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAirPlay
import VespertineAudio
import VespertineLibrary
import VespertineRemoteProtocol
import VespertineUPnP

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
            error: player.errorForRemote,
            transitions: settings.transitionsFeature ? settings.transitions.enabled : nil,
            sound: soundState)
    }

    /// The Mac output whose room correction and Spatial Audio a remote sets: the one playing or chosen. A speaker group
    /// has its own pages for those on the Mac, and a network player or AirPlay receiver has neither.
    private var soundDevice: OutputDevice? {
        guard !model.networkOutputChosen, let device = model.activeDevice, !GroupOutput.isGroupOutput(device) else { return nil }
        return device
    }

    /// The output whose equalizer a remote sets: the Mac output playing or chosen, or the chosen network player (which
    /// is sent the equalized song). An AirPlay receiver has none.
    private var equalizerUID: String? {
        if model.rendererChosen { return settings.selectedDeviceUID }
        return model.networkOutputChosen ? nil : model.activeDevice?.uid
    }

    /// The sound settings of the output in use, as its panel on the Mac has them; nil with no output to set them on.
    var soundState: SoundState? {
        var sound = SoundState()
        if let uid = equalizerUID {
            let playsHere = uid == model.activeDevice?.uid
            sound.equalizer = RemoteSound.equalizer(for: uid, settings: settings,
                                                    bypassed: playsHere ? model.equalizerStatus.reason.map { String(localized: "Not applied: \($0.explanation)") } : nil)
        }
        if let device = soundDevice {
            sound.room = RemoteSound.room(for: device.uid, settings: settings)
            sound.spatial = RemoteSound.spatial(for: device, settings: settings)
        }
        if let device = model.balanceDevice {
            sound.balance = BalanceState(value: settings.balance(for: device.uid), bypassed: model.balanceBypass?.explanation)
        }
        return sound.isEmpty ? nil : sound
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
            let detail = model.networkOutputChosen
                ? String(localized: "NOT RESPONDING", comment: "Output list: the chosen network player doesn't answer (short, uppercase)")
                : String(localized: "NOT CONNECTED · WAITING FOR IT", bundle: ReplyWords.bundle, comment: "Output list: the chosen device is missing and playback waits for it")
            outputs.append(OutputSummary(uid: uid, name: missing, detail: detail,
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
        // Network players and AirPlay receivers, while their switches are on, as the Mac's own list has them (a phone that
        // doesn't know of them shows them as devices). Receivers Vespertine can't send to are left out: they can't be chosen.
        if let renderers = model.renderers {
            for r in renderers.renderers where !outputs.contains(where: { $0.uid == r.uid }) {
                outputs.append(OutputSummary(uid: r.uid, name: r.name, detail: RendererText.detail(r), kind: .device, selected: selected == r.uid, ready: true))
            }
        }
        if let airPlay = model.airPlay {
            for d in airPlay.devices where d.isSupported && !outputs.contains(where: { $0.uid == d.uid }) {
                outputs.append(OutputSummary(uid: d.uid, name: d.name, detail: AirPlayText.detail(d), kind: .device, selected: selected == d.uid, ready: true))
            }
        }
        return OutputsState(outputs: outputs)
    }

    func trackSummary(_ track: Track) -> TrackSummary {
        TrackSummary(id: track.id, title: track.title, artist: track.displayArtist.libraryDisplayName, album: track.displayAlbum.libraryDisplayName,
                     albumKey: track.albumKey, duration: track.duration, trackNumber: track.trackNumber, discNumber: track.discNumber,
                     format: track.formatSummary, artworkKey: model.artworkKey(track), favorite: library.isFavorite(track),
                     surround: track.isMultichannel, plays: track.playCount, lastPlayed: track.lastPlayedAt?.timeIntervalSince1970,
                     added: track.addedAt.timeIntervalSince1970)
    }

    /// Songs as a phone that plays them itself is given them: each with its version in the other layout beside it
    /// (`TrackSummary.otherLayout`), so the phone's own output picks the one that plays. Only while versions are
    /// combined and the output is what picks (Settings); `acrossEditions` false keeps to each song's own album.
    func trackSummaries(_ tracks: [Track], acrossEditions: Bool = true) -> [TrackSummary] {
        guard model.settings.versionPreference == .matchOutput else { return tracks.map(trackSummary) }
        let others = Self.otherLayouts(of: tracks, in: library, acrossEditions: acrossEditions, isLocal: { [shares = model.shares] in !shares.isNetwork($0) })
        return zip(tracks, others).map { track, other in
            var summary = trackSummary(track)
            if let other, let id = other.id {
                summary.otherLayout = TrackVersion(id: id, album: other.displayAlbum.libraryDisplayName, albumKey: other.albumKey, duration: other.duration,
                                                   format: other.formatSummary, artworkKey: model.artworkKey(other))
            }
            return summary
        }
    }

    /// Songs listed once with their copies beside them (Favorites, Songs), and each one's version in the other layout.
    func trackSummaries(_ songs: [Self.ListedSong]) -> [TrackSummary] {
        zip(trackSummaries(songs.map(\.shown)), songs).map { summary, song in
            var summary = summary
            summary.copies = Self.copies(of: song, in: library)
            return summary
        }
    }

    func albumSummary(_ album: Album) -> AlbumSummary {
        AlbumSummary(key: album.key, title: album.title.libraryDisplayName, artist: album.artist.libraryDisplayName, year: album.year,
                     trackCount: album.trackCount, duration: album.duration, format: album.formatSummary, artworkKey: album.artworkKey,
                     hiRes: AlbumFilter.countsAsHiRes(aboveCD: album.isHiRes, dsd: album.isDSD, maxSampleRate: album.maxSampleRate),
                     dsd: album.isDSD, multichannel: album.isMultichannel)
    }

    // MARK: The library's own commands
    // These need only the library, so they are tested against a real one (App/Tests/RemoteLibraryTests.swift).

    /// A playlist as a remote lists it: its name, how many songs it has, and up to four of their covers for a tile.
    static func playlistSummary(_ playlist: Playlist, in library: LibraryStore, artworkKey: (Track) -> String?) -> PlaylistSummary? {
        guard let id = playlist.id else { return nil }
        let tracks = library.tracks(in: playlist)
        var covers: [String] = []
        for track in tracks {
            guard covers.count < 4 else { break }
            if let key = artworkKey(track), !covers.contains(key) { covers.append(key) }
        }
        return PlaylistSummary(id: id, name: playlist.name.libraryDisplayName, smart: playlist.isSmart, trackCount: tracks.count, artworkKeys: covers)
    }

    /// A search answered in groups: songs as the search field finds them; albums, artists and playlists by name (every
    /// word, anywhere, whatever its case or accents). Up to `limit` of each.
    /// `oneCopyEach`: found songs with each song once (`AppModel.oneCopyEach`), while a song's versions are combined.
    static func find(_ text: String, limit: Int, in library: LibraryStore, track: (Track) -> TrackSummary, album: (Album) -> AlbumSummary,
                     artworkKey: (Track) -> String?, oneCopyEach: ([Track]) -> [Track] = { $0 }) -> SearchResults {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults(tracks: [], albums: [], artists: [], playlists: []) }
        let limit = min(max(1, limit), 500)
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ names: String...) -> Bool {
            words.allSatisfy { word in names.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        }
        let albums = Array(library.albums.lazy.filter { matches($0.title.libraryDisplayName, $0.artist.libraryDisplayName) }.prefix(limit))
        let artists = Array(library.artists.lazy.filter { matches($0.name.libraryDisplayName) }.prefix(limit))
        let playlists = Array(library.playlists.lazy.filter { matches($0.name.libraryDisplayName) }.prefix(limit))
        return SearchResults(
            tracks: oneCopyEach(library.search(trimmed)).prefix(limit).map(track),
            albums: albums.map(album),
            artists: artists.map { ArtistSummary(name: $0.name.libraryDisplayName, albumCount: $0.albumCount, artworkKey: $0.artworkKey) },
            playlists: playlists.compactMap { playlistSummary($0, in: library, artworkKey: artworkKey) })
    }

    /// Adds songs at the end of a playlist. A smart playlist's rules choose its songs: a remote doesn't offer one.
    static func addToPlaylist(_ id: Int64, ids: [Int64], in library: LibraryStore) -> RemoteReply {
        guard let playlist = (try? library.database.playlists())?.first(where: { $0.id == id }) else { return notInLibrary }
        guard !playlist.isSmart else { return unavailable }
        let found = library.tracks(ids: ids).compactMap(\.id)
        guard !found.isEmpty else { return notInLibrary }
        library.append(Array(found.prefix(playlistBatch)), to: playlist)
        return .ok
    }

    /// Makes a playlist of these songs (a remote asks for the name first) and answers with every playlist, the new one included.
    static func createPlaylist(named name: String, ids: [Int64], in library: LibraryStore, artworkKey: (Track) -> String?) -> RemoteReply {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !trimmed.isEmpty else { return unavailable }
        let found = Array(library.tracks(ids: ids).compactMap(\.id).prefix(playlistBatch))
        guard library.createPlaylist(name: trimmed, trackIDs: found) != nil else {
            return .failed(reason: String(localized: "Couldn't save the playlist: \(trimmed)", bundle: ReplyWords.bundle))
        }
        // Read from the database: the library's own list hears of the new playlist a moment later.
        let all = (try? library.database.playlists()) ?? library.playlists
        return .playlists(items: all.compactMap { playlistSummary($0, in: library, artworkKey: artworkKey) })
    }

    // MARK: Songs in several copies

    /// A song as a list of songs shows it: one of its copies, and every copy the library has (just that one, usually).
    struct ListedSong {
        var shown: Track
        var copies: [Track]
    }

    /// The favorite songs as the Favorites page lists them, the most recently favorited first: each song once, however
    /// many of its copies are favorites (an ALAC and a Dolby Atmos copy of one song), as the copy `choose` picks among
    /// the favorite ones (the one that plays on this output), with every copy of it in the library beside it.
    static func favoriteSongs(in library: LibraryStore, choose: ([Track]) -> Track) -> [ListedSong] {
        library.songs(listing: library.favoriteTracks()).compactMap { song in
            song.listed.isEmpty ? nil : ListedSong(shown: choose(song.listed), copies: song.all)
        }
    }

    /// A song's copies as the Mac's "COPIES" list has them (format, edition, where it is); nil for a song in one copy.
    static func copies(of song: ListedSong, in library: LibraryStore) -> [TrackCopy]? {
        guard song.copies.count > 1 else { return nil }
        let analyzed = LibraryCopies.analyze(song.copies)
        return song.copies.compactMap { copy in
            guard let id = copy.id else { return nil }
            return TrackCopy(id: id, format: copy.formatSummary, hiRes: copy.isHiRes, edition: analyzed.copy(of: copy)?.edition,
                             location: library.displayPath((copy.filePath as NSString).deletingLastPathComponent), duration: copy.duration,
                             favorite: library.isFavorite(copy), preferred: library.isPreferredCopy(copy))
        }
    }

    /// For each track, its song's version in the other layout (the Dolby Atmos mix of a stereo track, the stereo track of
    /// an Atmos mix): the one that would play there, as `LibraryStore.playbackSongs` and `TrackVersions.choose` have it.
    /// nil for a song in one layout, a track that plays as itself (its album's copy was chosen), and while versions
    /// aren't combined.
    static func otherLayouts(of tracks: [Track], in library: LibraryStore, acrossEditions: Bool = true,
                             isLocal: (Track) -> Bool = { _ in true }) -> [Track?] {
        guard library.combinesVersions else { return tracks.map { _ in nil } }
        return zip(tracks, library.playbackSongs(of: tracks, acrossEditions: acrossEditions)).map { track, song in
            let others = song.versions.filter { $0.isMultichannel != track.isMultichannel }
            return TrackVersions.choose(others, multichannel: !track.isMultichannel, isLocal: isLocal, isPreferred: library.isPreferredCopy)
        }
    }

    // MARK: Sections of the library

    static func genres(of library: LibraryStore) -> [VespertineRemoteProtocol.GenreSummary] {
        library.genres.map { .init(key: $0.key, name: $0.name, albumCount: $0.albumCount, artworkKeys: $0.artworkKeys) }
    }

    /// The sources as the sidebar lists them. `connecting`: a network share that's being mounted now.
    static func sources(of library: LibraryStore, connecting: (LibrarySource) -> Bool = { _ in false }) -> [SourceSummary] {
        library.sources.compactMap { source in
            guard let id = source.id else { return nil }
            let kind: SourceKind = source.isNetwork ? .network : source.path.hasPrefix("/Volumes/") ? .external : source.mode == .managed ? .managed : .folder
            return SourceSummary(id: id, name: source.displayName, kind: kind, online: source.isOnline,
                                 scanning: connecting(source) || library.scanProgress?.sourcePath == source.path,
                                 albumCount: library.albums(inSource: id).count, detail: source.statusLine)
        }
    }

    /// `songs`: how many rows the Songs list has, when that isn't every file: while a song's versions are combined, a
    /// stereo and a surround copy are one row, and the count beside "Songs" says what the list holds.
    static func overview(of library: LibraryStore, songs: Int? = nil, connecting: (LibrarySource) -> Bool = { _ in false }) -> LibraryOverview {
        LibraryOverview(albums: library.stats.albums, artists: library.stats.artists, songs: songs ?? library.stats.tracks, genres: library.genres.count,
                        favorites: library.favoriteCount, playlists: library.playlists.count, sources: sources(of: library, connecting: connecting))
    }

    /// The most songs one command adds to a playlist.
    static let playlistBatch = 5_000
    /// The most albums one command plays.
    static let albumBatch = 2_000

    /// Every song by title, kept until the library changes: a remote asks for it a page at a time.
    private static var songList: (library: ObjectIdentifier, revision: Int, count: Int, surround: Bool?, tracks: [Track])?

    /// `oneCopyEach`: the songs with each song once, as the copy that plays on this output (`AppModel.oneCopyEach`), while a
    /// song's versions are combined; `surround` is what that choice hangs on (whether the output wants surround), so the
    /// list is made again when it changes.
    static func songs(of library: LibraryStore, surround: Bool? = nil, oneCopyEach: ([Track]) -> [Track] = { $0 },
                      sort: SongSort? = nil) -> [Track] {
        let id = ObjectIdentifier(library)
        let byTitle: [Track]
        if let songList, songList.library == id, songList.revision == library.revision, songList.count == library.stats.tracks,
           songList.surround == surround {
            byTitle = songList.tracks
        } else {
            byTitle = Self.byTitle(oneCopyEach(library.allTracks()))
            songList = (id, library.revision, library.stats.tracks, surround, byTitle)
            sortedSongs = [:]
        }
        guard let sort, sort != .title else { return byTitle }
        if let kept = sortedSongs[sort] { return kept }
        let sorted = arrange(byTitle, sort: sort)
        sortedSongs[sort] = sorted
        return sorted
    }

    /// The other orders of the song list, worked out from the one by title as a phone first asks for each.
    private static var sortedSongs: [SongSort: [Track]] = [:]

    /// Songs by title put in `sort`'s order, as `SongListing.order` has it for the phone: ties stay in title order.
    nonisolated static func arrange(_ byTitle: [Track], sort: SongSort) -> [Track] {
        func words(_ a: String, _ b: String) -> Bool? {
            switch a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: nil
            }
        }
        func inAlbum(_ a: Track, _ b: Track) -> Bool? {
            let x = (a.discNumber ?? 0, a.trackNumber ?? 0), y = (b.discNumber ?? 0, b.trackNumber ?? 0)
            return x == y ? nil : x < y
        }
        func newest(_ a: Date?, _ b: Date?) -> Bool? {
            switch (a, b) {
            case (nil, nil): nil
            case (nil, _): false
            case (_, nil): true
            case (let x?, let y?): x == y ? nil : x > y
            }
        }
        let earlier: (Track, Track) -> Bool? = switch sort {
        case .title: { _, _ in nil }
        case .artist: { a, b in words(a.displayArtist, b.displayArtist) ?? words(a.displayAlbum, b.displayAlbum) ?? inAlbum(a, b) }
        case .album: { a, b in words(a.displayAlbum, b.displayAlbum) ?? inAlbum(a, b) }
        case .mostPlayed: { a, b in a.playCount == b.playCount ? nil : a.playCount > b.playCount }
        case .recentlyPlayed: { a, b in newest(a.lastPlayedAt, b.lastPlayedAt) }
        case .recentlyAdded: { a, b in newest(a.addedAt, b.addedAt) }
        }
        return byTitle.enumerated().sorted { earlier($0.element, $1.element) ?? ($0.offset < $1.offset) }.map(\.element)
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
        case .hello, .pair, .artwork, .streamInfo, .streamOpen, .streamRead, .streamClose, .setLanguage:
            return Self.unavailable
        case .ping:
            return .ok

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
        case .playPlaylist(let id, let startAt, let shuffled):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return notInLibrary }
            let tracks = library.tracks(in: playlist)
            guard !tracks.isEmpty else { return notInLibrary }
            // A tapped song sends where to start, and nil shuffle (keep the setting, as a song row on the Mac does);
            // the Play and Shuffle buttons send neither start nor nil.
            player.play(tracks, startAt: startAt ?? 0, shuffled: startAt == nil ? (shuffled ?? false) : shuffled,
                        transitions: library.transitions(of: playlist))
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
        case .playAlbums(let keys, let shuffled):
            // Each album as its own page plays it (its chosen copy, or the best one for the output).
            let tracks = keys.prefix(Self.albumBatch).flatMap { model.playableTracks(albumKey: $0) }
            guard !tracks.isEmpty else { return notInLibrary }
            player.play(tracks, shuffled: shuffled)
        case .playCopy(let ids, let startAt):
            let tracks = ordered(ids)
            guard !tracks.isEmpty else { return notInLibrary }
            let index = min(max(0, startAt), tracks.count - 1)
            player.play(tracks, startAt: index, exactly: [tracks[index].location])

        case .albums(let offset, let limit, let sort, let filter):
            let albums = library.albums
            // Sorted or narrowed, the whole list is arranged before a page is cut from it; plain pages skip that.
            if (sort ?? .library) != .library || (filter ?? .all) != .all {
                let listed = AlbumListing.arrange(albums.map(albumSummary), sort: sort, filter: filter)
                let start = min(max(0, offset), listed.count)
                let end = min(start + min(max(1, limit), 500), listed.count)
                return .albums(items: Array(listed[start..<end]), total: listed.count)
            }
            let start = min(max(0, offset), albums.count)
            let end = min(start + min(max(1, limit), 500), albums.count)
            return .albums(items: albums[start..<end].map(albumSummary), total: albums.count)
        case .tracks(let ids):
            return .tracks(items: trackSummaries(ordered(ids)))
        case .albumTracks(let key):
            // An album whose "copies" are different songs (a stereo album with a surround bonus track) is listed whole:
            // choosing one copy would leave songs off the phone's page, where they could be neither played nor kept.
            if library.albumCopies(albumKey: key).sharesNoSongs { return .tracks(items: library.tracks(albumKey: key).map(trackSummary)) }
            // An album's page is that edition: only its own versions go with its songs.
            return .tracks(items: trackSummaries(model.playableTracks(albumKey: key), acrossEditions: false))
        case .artists:
            return .artists(items: library.artists.map { ArtistSummary(name: $0.name.libraryDisplayName, albumCount: $0.albumCount, artworkKey: $0.artworkKey) })
        case .artistAlbums(let name):
            let albums = library.albums(artist: name)
            return .albums(items: albums.map(albumSummary), total: albums.count)
        case .playlists:
            return .playlists(items: library.playlists.compactMap { Self.playlistSummary($0, in: library, artworkKey: { model.artworkKey($0) }) })
        case .playlistTracks(let id, let offset, let limit):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return notInLibrary }
            // Each song's other version goes with it (`trackSummaries`), a page's worth at a time.
            let tracks = library.tracks(in: playlist)
            guard let offset else { return .tracks(items: trackSummaries(tracks)) }
            let start = min(max(0, offset), tracks.count)
            let end = min(start + min(max(1, limit ?? PlaylistPages.pageSize), PlaylistPages.pageSize), tracks.count)
            return .songs(items: trackSummaries(Array(tracks[start..<end])), total: tracks.count)
        case .favorites:
            return .tracks(items: trackSummaries(Self.favoriteSongs(in: library, choose: model.listedCopy)))
        case .library:
            // The same list the Songs page is given (kept until the library or the output changes), so the two agree.
            let listed = library.combinesVersions
                ? Self.songs(of: library, surround: model.outputWantsMultichannel(), oneCopyEach: model.oneCopyEach).count : nil
            return .library(Self.overview(of: library, songs: listed, connecting: { $0.isNetwork && model.shares.status(of: $0) == .connecting }))
        case .genres:
            return .genres(items: Self.genres(of: library))
        case .genreAlbums(let key):
            let albums = library.albums(genre: key)
            return .albums(items: albums.map(albumSummary), total: albums.count)
        case .recentlyAdded(let limit):
            let albums = library.recentlyAddedAlbums(limit: min(max(1, limit), AppModel.recentlyAddedLimit))
            return .albums(items: albums.map(albumSummary), total: albums.count)
        case .sourceAlbums(let id):
            guard library.sources.contains(where: { $0.id == id }) else { return notInLibrary }
            let albums = library.albums(inSource: id)
            return .albums(items: albums.map(albumSummary), total: albums.count)
        case .search(let text, let limit):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .tracks(items: []) }
            return .tracks(items: model.oneCopyEach(library.search(trimmed)).prefix(min(max(1, limit), 500)).map(trackSummary))

        case .songs(let offset, let limit, let sort):
            let songs = Self.songs(of: library, surround: library.combinesVersions ? model.outputWantsMultichannel() : nil, oneCopyEach: model.oneCopyEach,
                                   sort: sort)
            let start = min(max(0, offset), songs.count)
            let end = min(start + min(max(1, limit), 500), songs.count)
            // Each song's other copies go with it, so the phone can list and play them (as on Favorites).
            let page = Array(songs[start..<end])
            guard library.combinesVersions else { return .songs(items: page.map(trackSummary), total: songs.count) }
            let listed = zip(page, library.versions(of: page)).map { Self.ListedSong(shown: $0, copies: $1) }
            return .songs(items: trackSummaries(listed), total: songs.count)
        case .find(let text, let limit):
            return .found(Self.find(text, limit: limit, in: library, track: trackSummary, album: albumSummary, artworkKey: { model.artworkKey($0) },
                                    oneCopyEach: model.oneCopyEach))

        case .addToPlaylist(let id, let ids):
            return Self.addToPlaylist(id, ids: ids, in: library)
        case .createPlaylist(let name, let ids):
            return Self.createPlaylist(named: name, ids: ids, in: library, artworkKey: { model.artworkKey($0) })

        case .selectOutput(let uid):
            if let uid, !outputsState().outputs.contains(where: { $0.uid == uid }) {
                return .failed(reason: String(localized: "That output isn’t connected to this Mac.", bundle: ReplyWords.bundle, comment: "Remote control: the phone picked an output the Mac no longer has."))
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
                return .failed(reason: String(localized: "Transitions are turned off in Vespertine’s settings on the Mac.", bundle: ReplyWords.bundle, comment: "Remote control: the phone tried to turn on transitions, but the feature is off in Settings."))
            }
            model.setTransitions(on)

        case .setEqualizer(let preset):
            guard let uid = equalizerUID, RemoteSound.setEqualizer(preset, for: uid, settings: settings) else { return Self.unavailable }
            model.syncEngine()
        case .setRoomCorrection(let profile):
            guard let device = soundDevice, RemoteSound.setRoom(profile, for: device.uid, settings: settings) else { return Self.unavailable }
            model.syncEngine()
        case .setSpatialMode(let mode):
            guard let device = soundDevice else { return Self.unavailable }
            RemoteSound.setSpatialMode(mode, for: device, settings: settings)
            model.syncEngine()
        case .setSpatializeStereo(let on):
            guard let device = soundDevice, RemoteSound.setSpatializeStereo(on, for: device, settings: settings) else { return Self.unavailable }
            model.syncEngine()
        case .setBalance(let value):
            // As the Mac's own panel: the slider doesn't move while what plays can't take it (DoP, Spatial Audio), but
            // Center always works.
            let balance = BalanceLaw.snapped(BalanceState.clamped(value))
            guard model.balanceDevice != nil, balance == 0 || model.balanceBypass == nil else { return Self.unavailable }
            model.setBalance(balance)
        }
        return .ok
    }

    private static var unavailable: RemoteReply {
        .failed(reason: String(localized: "This command isn’t available here.", bundle: ReplyWords.bundle, comment: "Remote control: a phone sent a command at the wrong time."))
    }

    private var notInQueue: RemoteReply {
        .failed(reason: String(localized: "That song is no longer in the queue.", bundle: ReplyWords.bundle, comment: "Remote control: the phone acted on a queue entry that has gone."))
    }

    private var notInLibrary: RemoteReply { Self.notInLibrary }

    private static var notInLibrary: RemoteReply {
        .failed(reason: String(localized: "Those songs aren’t in the library anymore.", bundle: ReplyWords.bundle, comment: "Remote control: the phone asked for songs, an album or a playlist the Mac no longer has."))
    }

    private var fixedVolume: RemoteReply {
        .failed(reason: String(localized: "This output has no volume Vespertine can change. Set the level on your amplifier or DAC.", bundle: ReplyWords.bundle, comment: "Remote control: volume asked for on an output whose volume is fixed (bit-perfect, no hardware volume)."))
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

    /// A playlist's songs for `RemoteCommand.playlistTracks`: a page of them (a newer phone, which asks that way because a long
    /// playlist whole would be more than one message holds), or all of them (an older phone, the web remote).
    static func playlistTracks<Song>(_ songs: [Song], offset: Int?, limit: Int?, summary: (Song) -> TrackSummary) -> RemoteReply {
        guard let offset else { return .tracks(items: songs.map(summary)) }
        let start = min(max(0, offset), songs.count)
        let end = min(start + min(max(1, limit ?? PlaylistPages.pageSize), PlaylistPages.pageSize), songs.count)
        return .songs(items: songs[start..<end].map(summary), total: songs.count)
    }

    // MARK: Artwork

    /// A stored cover file for `key` near `size`, read off the main thread. Keys are the library's own (hex and dashes);
    /// anything else is refused, so a key can never name a file outside the artwork folder.
    ///
    /// A size above the largest thumbnail is answered with the original, and a hi-res original can be more than one message
    /// may carry; the largest thumbnail goes then, so the phone gets a cover and not an error.
    static func artwork(key: String, size: Int, store: ArtworkStore?) async -> (mimeType: String, data: Data)? {
        guard let store, !key.isEmpty, key.count <= 128,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let wanted = min(max(size, 1), 2048)
        let first = store.url(for: key, minimumSize: wanted)
        let thumbnails = ArtworkStore.thumbnailSizes.sorted(by: >).map { store.thumbnailURL(key, size: $0) }
        let candidates = [first] + thumbnails.filter { $0 != first }
        return await Task.detached(priority: .userInitiated) { () -> (mimeType: String, data: Data)? in
            for url in candidates {
                guard let data = try? Data(contentsOf: url), data.count <= RemoteProtocol.maximumMessageSize / 2 else { continue }
                return (mimeType: mimeType(of: data), data: data)
            }
            return nil
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
