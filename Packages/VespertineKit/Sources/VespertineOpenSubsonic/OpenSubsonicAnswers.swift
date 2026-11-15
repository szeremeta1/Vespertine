//
// Vespertine: what an OpenSubsonic (or older Subsonic) server answers, read leniently. Servers differ in small ways: an id is
// a string on one and a number on another, a list with nothing in it is left out, a field one server has another lacks.
// Nothing here throws over such a difference; only an answer that is not the API at all is malformed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineLibrary

/// A value that may arrive as a string, a number or a boolean.
struct Loose: Decodable, Sendable {
    let string: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            string = text
        } else if let whole = try? container.decode(Int64.self) {
            string = String(whole)
        } else if let number = try? container.decode(Double.self) {
            string = String(number)
        } else if let flag = try? container.decode(Bool.self) {
            string = flag ? "true" : "false"
        } else {
            string = nil
        }
    }

    var text: String? { string.flatMap { $0.isEmpty ? nil : $0 } }
    var int: Int? { string.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    var int64: Int64? { string.flatMap { Int64($0) ?? Double($0).map { Int64($0) } } }
    var double: Double? { string.flatMap(Double.init) }
    var bool: Bool? { string.map { $0 == "true" || $0 == "1" } }
}

/// One string, or a list of them (OpenSubsonic's `isrc`), or a list of objects with a name (its `genres`).
struct LooseList: Decodable, Sendable {
    struct Named: Decodable, Sendable { var name: Loose? }
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([Loose].self) {
            values = list.compactMap(\.text)
        } else if let named = try? container.decode([Named].self) {
            values = named.compactMap { $0.name?.text }
        } else if let one = try? container.decode(Loose.self) {
            values = one.text.map { [$0] } ?? []
        } else {
            values = []
        }
    }
}

struct SubsonicEnvelope: Decodable, Sendable {
    let response: SubsonicAnswer
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicAnswer: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        var code: Loose?
        var message: Loose?
    }
    struct AlbumList: Decodable, Sendable { var album: [SubsonicAlbum]? }
    struct SearchResult: Decodable, Sendable { var song: [SubsonicSong]? }
    struct Starred: Decodable, Sendable { var song: [SubsonicSong]? }
    struct Playlists: Decodable, Sendable { var playlist: [SubsonicPlaylist]? }
    struct Artists: Decodable, Sendable {
        struct Index: Decodable, Sendable { var artist: [SubsonicArtist]? }
        var index: [Index]?
    }
    struct Extension: Decodable, Sendable { var name: Loose? }
    struct TokenInfo: Decodable, Sendable { var username: Loose? }

    var status: Loose?
    var error: Failure?
    var openSubsonic: Loose?
    var albumList2: AlbumList?
    var album: SubsonicAlbum?
    var searchResult3: SearchResult?
    var starred2: Starred?
    var playlists: Playlists?
    var playlist: SubsonicPlaylist?
    var artists: Artists?
    var openSubsonicExtensions: [Extension]?
    var tokenInfo: TokenInfo?
}

struct SubsonicArtist: Decodable, Sendable {
    var id: Loose?
    var name: Loose?
    var albumCount: Loose?
}

struct SubsonicAlbum: Decodable, Sendable {
    var id: Loose?
    var name: Loose?
    var artist: Loose?
    var songCount: Loose?
    var song: [SubsonicSong]?
}

struct SubsonicPlaylist: Decodable, Sendable {
    var id: Loose?
    var name: Loose?
    var entry: [SubsonicSong]?
}

struct SubsonicSong: Decodable, Sendable {
    struct Gain: Decodable, Sendable {
        var trackGain: Loose?
        var albumGain: Loose?
        var trackPeak: Loose?
        var albumPeak: Loose?
    }

    var id: Loose?
    var isDir: Loose?
    var title: Loose?
    var album: Loose?
    var artist: Loose?
    var displayArtist: Loose?
    var displayAlbumArtist: Loose?
    var albumId: Loose?
    var track: Loose?
    var discNumber: Loose?
    var year: Loose?
    var genre: Loose?
    var coverArt: Loose?
    var size: Loose?
    var contentType: Loose?
    var suffix: Loose?
    var duration: Loose?
    var bitRate: Loose?
    var bitDepth: Loose?
    var samplingRate: Loose?
    var channelCount: Loose?
    var starred: Loose?
    var isrc: LooseList?
    var musicBrainzId: Loose?
    var replayGain: Gain?

    /// The song as the library takes it; nil for a folder or an entry without an id.
    var song: StreamedSong? {
        guard let id = id?.text, isDir?.bool != true else { return nil }
        var song = StreamedSong(id: id, title: title?.text ?? id,
                                artist: displayArtist?.text ?? artist?.text, album: album?.text, albumArtist: displayAlbumArtist?.text,
                                albumId: albumId?.text, genre: genre?.text, year: year?.int.flatMap { $0 > 0 ? $0 : nil },
                                trackNumber: track?.int.flatMap { $0 > 0 ? $0 : nil }, discNumber: discNumber?.int.flatMap { $0 > 0 ? $0 : nil },
                                duration: max(0, duration?.double ?? 0), suffix: suffix?.text, mediaType: contentType?.text,
                                bitrate: bitRate?.double.flatMap { $0 > 0 ? $0 : nil }, bitDepth: bitDepth?.int.flatMap { $0 > 0 ? $0 : nil },
                                sampleRate: samplingRate?.double.flatMap { $0 > 0 ? $0 : nil },
                                channels: channelCount?.int.flatMap { $0 > 0 ? $0 : nil }, size: max(0, size?.int64 ?? 0),
                                coverArt: coverArt?.text, isrc: isrc?.values.first, musicBrainzRecordingID: musicBrainzId?.text,
                                starred: starred?.text != nil)
        if let gain = replayGain {
            let values = (gain.trackGain?.double, gain.trackPeak?.double, gain.albumGain?.double, gain.albumPeak?.double)
            if values.0 != nil || values.1 != nil || values.2 != nil || values.3 != nil {
                song.replayGain = (trackGain: values.0, trackPeak: values.1, albumGain: values.2, albumPeak: values.3)
            }
        }
        return song
    }
}

/// An artist as a server's index lists one.
public struct OpenSubsonicArtist: Sendable, Hashable {
    public var id: String
    public var name: String
    public var albumCount: Int
}
