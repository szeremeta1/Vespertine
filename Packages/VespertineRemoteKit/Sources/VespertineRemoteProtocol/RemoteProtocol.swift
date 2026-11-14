//
// Vespertine: the remote protocol's constants and the messages a remote and the Mac exchange.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// A remote (the iPhone or iPad app) finds a Mac on Bonjour, opens one connection to it over TLS with a pre-shared key, and
// sends `ClientMessage`s as JSON text. The Mac answers each with a `ServerMessage.reply` carrying the same `id`, and pushes
// `ServerMessage.player`, `.queue` and `.outputs` whenever what they describe changes.
//
// Encoding: Swift's own Codable form for enums, so a command reads `{"id":3,"command":{"seek":{"seconds":61.5}}}` and a
// command without arguments `{"id":4,"command":{"next":{}}}`. Dates are seconds since 1970; `Data` is base64.
//

import Foundation

public enum RemoteProtocol {
    /// Bumped when a message changes in a way an older remote or Mac would misread. Both sides say theirs in the handshake.
    /// Version 2 adds the stream channel (`RemoteCommand.streamOpen` and friends, answered with `StreamFrame`s); everything
    /// else is as version 1, so a version 1 phone is still served as a remote (see `negotiate`).
    public static let version = 2
    /// The oldest version a Mac still serves.
    public static let minimumVersion = 1
    /// The first version with the stream channel.
    public static let streamVersion = 2

    /// The version a connection speaks, from what its `hello` or `pair` said: `baseline` is the version field every
    /// version reads (a phone that can do more sends 1 there, so an old Mac accepts it), `highest` the newest the phone
    /// speaks (absent from a version 1 phone). nil: the phone needs a newer Mac than this one.
    public static func negotiate(baseline: Int, highest: Int?) -> Int? {
        guard baseline >= minimumVersion, baseline <= version else { return nil }
        return min(max(highest ?? baseline, baseline), version)
    }

    /// The most bytes one `StreamFrame` carries.
    public static let maximumChunk = 1024 * 1024
    /// What a phone asks for in one read unless it knows better.
    public static let defaultChunkSize = 256 * 1024
    /// The Bonjour service a Mac running the remote server advertises.
    public static let serviceType = "_vespertine._tcp"
    /// TXT record keys of that service.
    public enum TXTKey {
        /// The Mac's stable server ID (the one in a pairing link).
        public static let serverID = "id"
        /// `RemoteProtocol.version` of the Mac.
        public static let protocolVersion = "v"
        /// Vespertine's version on the Mac ("1.1.0").
        public static let appVersion = "app"
        /// The port the Mac listens on (the same one Bonjour resolves to, for a phone to keep against its typed address).
        public static let port = "port"
    }

    /// The TLS pre-shared key identity a phone uses while pairing with the code from the QR link, and with the typed code.
    public static let pairingLinkIdentity = "vespertine-pair-link"
    public static let pairingCodeIdentity = "vespertine-pair-code"

    /// The biggest message either side accepts (a 900 px cover in base64 is about 300 KB).
    public static let maximumMessageSize = 4 * 1024 * 1024

    /// A JSON encoder and decoder with the protocol's settings.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: Remote → Mac

public struct ClientMessage: Codable, Sendable, Equatable {
    /// Chosen by the remote; the reply carries it back. Unique per connection.
    public var id: Int
    public var command: RemoteCommand

    public init(id: Int, command: RemoteCommand) {
        self.id = id
        self.command = command
    }
}

public enum RemoteCommand: Codable, Sendable, Equatable {
    // Session
    /// First message on a connection made with a device key. `device` is the ID the Mac gave at pairing.
    /// `protocolVersion` is the baseline every Mac reads (1); `highestProtocolVersion` the newest the phone speaks (nil from a
    /// version 1 phone), which an old Mac ignores and a new one answers in `ServerInfo.protocolVersion`.
    case hello(device: String, name: String, protocolVersion: Int, highestProtocolVersion: Int? = nil)
    /// First message on a connection made with a pairing key: asks to be paired under `name` ("Alex's iPhone").
    case pair(name: String, protocolVersion: Int, highestProtocolVersion: Int? = nil)

    // Transport
    case playPause
    case play
    case pause
    case next
    case previous
    case stop
    case seek(seconds: Double)
    case setShuffle(on: Bool)
    case setRepeat(mode: RepeatModeValue)

    // Queue (entries are `QueueItem.entry`)
    case jump(entry: String)
    case removeFromQueue(entries: [String])
    /// Moves upcoming entries before `before` (nil: to the end).
    case moveInQueue(entries: [String], before: String?)
    case clearUpcoming

    // Playing from the library
    /// Plays an album from its `startAt`th song (0: the first).
    case playAlbum(key: String, startAt: Int, shuffled: Bool?)
    /// Plays these songs as a list, from the `startAt`th.
    case playTracks(ids: [Int64], startAt: Int, shuffled: Bool?)
    case playPlaylist(id: Int64, shuffled: Bool?)
    case playNext(ids: [Int64])
    case addToQueue(ids: [Int64])
    case setFavorite(ids: [Int64], on: Bool)
    /// Plays these albums one after another (a genre's, a source's, the newest ones), in the order given.
    case playAlbums(keys: [String], shuffled: Bool?)
    /// Plays these songs from the `startAt`th, and that one as the very copy it is (one picked from `TrackSummary.copies`),
    /// whatever copy the output would have chosen.
    case playCopy(ids: [Int64], startAt: Int)

    // Playlists
    /// Adds these songs at the end of a playlist (not a smart one: its rules choose its songs).
    case addToPlaylist(id: Int64, ids: [Int64])
    /// Makes a playlist of these songs (none: an empty one). Answered with `.playlists`, the new one included.
    case createPlaylist(name: String, ids: [Int64])

    // Library (answered with a page or a list)
    case albums(offset: Int, limit: Int)
    case albumTracks(key: String)
    case artists
    case artistAlbums(name: String)
    case playlists
    case playlistTracks(id: Int64)
    case favorites
    case search(text: String, limit: Int)
    /// Every song, by title, a page at a time (answered with `.songs`).
    case songs(offset: Int, limit: Int)
    /// A search answered in groups (`.found`): songs, albums, artists and playlists, up to `limit` of each.
    case find(text: String, limit: Int)
    /// The library at a glance (answered with `.library`): how much it holds, and its sources.
    case library
    case genres
    case genreAlbums(key: String)
    /// The albums added last, newest first, up to `limit` (the Mac's own page shows 150).
    case recentlyAdded(limit: Int)
    /// The albums with songs in a source (`SourceSummary.id`).
    case sourceAlbums(id: Int64)
    /// These songs by library ID, in the order asked (answered with `.tracks`; IDs the library doesn't have are left out). A
    /// phone that plays songs itself builds its own queue from them.
    case tracks(ids: [Int64])
    /// A cover by `artworkKey`, about `size` pixels on its long side (160 or 600 are stored; others pick the nearest).
    case artwork(key: String, size: Int)

    // Output and sound
    /// nil: the Mac's System Default.
    case selectOutput(uid: String?)
    case volume(action: VolumeAction)
    /// 0…1, on whatever `VolumeState.route` says moves.
    case setVolume(level: Double)
    case setTransitions(on: Bool)

    // Streaming to the phone (protocol 2): the phone plays the song itself from the Mac's bytes.
    /// What the Mac would send for these songs (answered with `.streamInfo`): the original file or a lossless FLAC it makes,
    /// the format that arrives, and why a song can't be streamed. `maxSampleRate`: the most the phone's output can use (48000
    /// for AirPods), which a conversion on the Mac is kept to.
    case streamInfo(ids: [Int64], maxSampleRate: Double?)
    /// Opens a song for reading (answered with `.streamOpened`, or `.streamPreparing` while the Mac converts it: ask again).
    case streamOpen(id: Int64, maxSampleRate: Double?)
    /// Reads up to `length` bytes (at most `RemoteProtocol.maximumChunk`) from `offset` of an open stream. Answered with a
    /// `StreamFrame` (binary) carrying this command's `id`, or `.failed`.
    case streamRead(stream: Int, offset: Int64, length: Int)
    case streamClose(stream: Int)
}

public enum RepeatModeValue: String, Codable, Sendable, Equatable {
    case off, all, one
}

public enum VolumeAction: String, Codable, Sendable, Equatable {
    case up, down, mute
}

// MARK: Mac → remote

public enum ServerMessage: Codable, Sendable, Equatable {
    /// The answer to the command with `id`.
    case reply(id: Int, result: RemoteReply)
    /// What's playing and how. Sent after `hello` and whenever it changes (the position only when it jumps: a remote
    /// moves its scrubber itself from `PlayerState.position` and `positionAt`).
    case player(PlayerState)
    case queue(QueueState)
    case outputs(OutputsState)
    /// The Mac is closing the connection (the remote server was turned off, or this phone was removed).
    case goodbye(reason: GoodbyeReason)
}

public enum GoodbyeReason: String, Codable, Sendable, Equatable {
    case serverStopped, deviceRemoved, protocolMismatch, notPaired
}

public enum RemoteReply: Codable, Sendable, Equatable {
    case ok
    /// The command wasn't carried out; `reason` is a sentence in the Mac's language, for showing as it is.
    case failed(reason: String)
    case welcome(ServerInfo)
    /// Pairing worked: connect again with TLS identity `device` and this key from now on.
    case paired(device: String, key: Data, server: ServerInfo)
    case albums(items: [AlbumSummary], total: Int)
    case tracks(items: [TrackSummary])
    case artists(items: [ArtistSummary])
    case playlists(items: [PlaylistSummary])
    case artwork(key: String, size: Int, mimeType: String, data: Data)
    /// A page of the library's songs and how many there are in all.
    case songs(items: [TrackSummary], total: Int)
    case found(SearchResults)
    case library(LibraryOverview)
    case genres(items: [GenreSummary])
    // Protocol 2
    case streamInfo(items: [StreamInfo])
    case streamOpened(StreamDescriptor)
    /// The Mac is converting this song to FLAC; ask again with `streamOpen` (`progress` 0…1 when it knows).
    case streamPreparing(progress: Double?)
}

public struct ServerInfo: Codable, Sendable, Equatable {
    /// The Mac's name as it appears in Bonjour ("Living Room Mac mini").
    public var name: String
    public var serverID: String
    public var appVersion: String
    public var protocolVersion: Int

    public init(name: String, serverID: String, appVersion: String, protocolVersion: Int = RemoteProtocol.version) {
        self.name = name
        self.serverID = serverID
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
    }
}
