//
// Vespertine: an OpenSubsonic server on 127.0.0.1 for the provider's tests. It checks each request's credential the way the
// API says (an API key, or a token made from the password and a salt, or the password itself), answers the methods the
// provider uses, serves songs by byte range, and notes everything it was asked.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
@testable import VespertineUPnP

final class FakeSubsonic: @unchecked Sendable {
    struct Song {
        var id: String
        var title: String
        var album: String
        var albumId: String
        var artist: String
        var track: Int
        var suffix = "flac"
        var data = Data()
        /// What `stream` sends in place of the file, whatever "format" asks for (a server set to convert).
        var converted: (data: Data, type: String)?
        var bitDepth: Int? = 24
        var samplingRate: Int? = 96_000
    }

    struct Request: Equatable {
        var method: String
        var query: [String: String]
        var range: String?
    }

    enum Mood { case fine, tooMany(retryAfter: Int?), unauthorized, silent, notSubsonic, redirect(String) }

    struct State {
        var passwords: [String: String] = ["listener": "correct horse"]
        var apiKeys: [String: String] = ["key-for-listener": "listener"]
        var takesTokens = true
        var takesAPIKeys = true
        var songs: [Song] = []
        var playlists: [(id: String, name: String, songs: [String])] = []
        var starred: Set<String> = []
        var scrobbles: [(id: String, time: String?)] = []
        var covers: [String: Data] = [:]
        var mood = Mood.fine
        /// Answers the same first page whatever offset is asked (a server that ignores it).
        var ignoresOffset = false
        /// Sends ids and numbers as JSON numbers and strings mixed, as servers do.
        var requests: [Request] = []
        var bytesServed = 0
        var released = false
    }

    private let lock = NSLock()
    private var state = State()
    private var server: HTTPServer!
    private(set) var port: UInt16 = 0

    init() async throws {
        server = HTTPServer(maximumConnections: 64) { [weak self] request in await self?.handle(request) ?? .status(503) }
        port = try await server.start()
    }

    func stop() {
        lock.withLock { state.released = true }
        server.stop()
    }

    var address: String { "http://127.0.0.1:\(port)" }

    func change(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    var requests: [Request] { read(\.requests) }
    func requests(_ method: String) -> [Request] { requests.filter { $0.method == method } }

    /// A song's file: "fLaC" and then bytes that are different at every offset.
    static func flac(bytes: Int, seed: UInt32) -> Data {
        var data = Data("fLaC".utf8)
        var value = seed
        data.reserveCapacity(bytes)
        while data.count < bytes {
            value = value &* 1_664_525 &+ 1_013_904_223
            data.append(UInt8(truncatingIfNeeded: value >> 16))
        }
        return data
    }

    /// What a converting server sends: MPEG audio frame headers and filler.
    static func mp3(bytes: Int) -> Data {
        var data = Data([0xff, 0xfb, 0x90, 0x64])
        data.append(Data(repeating: 0x55, count: bytes - 4))
        return data
    }

    // MARK: Answers

    private static func json(_ body: [String: Any], status: String = "ok") -> HTTPResponse {
        var answer: [String: Any] = ["status": status, "version": "1.16.1", "type": "fake", "serverVersion": "1.0", "openSubsonic": true]
        for (key, value) in body { answer[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: ["subsonic-response": answer])
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", "\(data.count)")], body: .data(data))
    }

    private static func failure(_ code: Int, _ message: String) -> HTTPResponse {
        json(["error": ["code": code, "message": message]], status: "failed")
    }

    private func refusal(_ query: [String: String], _ state: State) -> HTTPResponse? {
        if let key = query["apiKey"] {
            guard state.takesAPIKeys else { return Self.failure(42, "Provided authentication mechanism not supported.") }
            if query["u"] != nil { return Self.failure(43, "Multiple conflicting authentication mechanisms provided.") }
            return state.apiKeys[key] == nil ? Self.failure(44, "Invalid API key.") : nil
        }
        guard let user = query["u"] else { return Self.failure(10, "Required parameter is missing.") }
        guard let password = state.passwords[user] else { return Self.failure(40, "Wrong username or password.") }
        if let token = query["t"], let salt = query["s"] {
            guard state.takesTokens else { return Self.failure(41, "Token authentication not supported for LDAP users.") }
            let expected = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
            return token == expected ? nil : Self.failure(40, "Wrong username or password.")
        }
        if let sent = query["p"] {
            var plain = sent
            if sent.hasPrefix("enc:") {
                let hex = Array(sent.dropFirst(4))
                var bytes: [UInt8] = []
                var index = 0
                while index + 1 < hex.count {
                    bytes.append(UInt8(String(hex[index...index + 1]), radix: 16) ?? 0)
                    index += 2
                }
                plain = String(decoding: bytes, as: UTF8.self)
            }
            return plain == password ? nil : Self.failure(40, "Wrong username or password.")
        }
        return Self.failure(10, "Required parameter is missing.")
    }

    private static func child(_ song: Song, starred: Bool, index: Int) -> [String: Any] {
        // Ids as the server has them; numbers now as numbers, now as strings.
        var child: [String: Any] = ["id": song.id, "isDir": false, "title": song.title, "album": song.album, "albumId": song.albumId,
                                    "artist": song.artist, "displayAlbumArtist": song.artist, "track": index % 2 == 0 ? song.track as Any : "\(song.track)" as Any,
                                    "discNumber": 1, "year": 2001, "genre": "Jazz", "coverArt": "cover-\(song.albumId)", "size": song.data.count,
                                    "contentType": "audio/flac", "suffix": song.suffix, "duration": 200, "bitRate": 2800, "channelCount": 2,
                                    "isrc": ["ZZTST2600001"], "musicBrainzId": "mb-\(song.id)",
                                    "replayGain": ["trackGain": -6.5, "albumGain": -7.25, "trackPeak": 0.98]]
        if let bits = song.bitDepth { child["bitDepth"] = bits }
        if let rate = song.samplingRate { child["samplingRate"] = rate }
        if starred { child["starred"] = "2026-01-02T03:04:05Z" }
        return child
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        var method = request.path.hasPrefix("/rest/") ? String(request.path.dropFirst(6)) : request.path
        if method.hasSuffix(".view") { method.removeLast(5) }
        let query = request.query
        let state = lock.withLock { () -> State in
            self.state.requests.append(Request(method: method, query: query, range: request.headers["range"]))
            return self.state
        }
        switch state.mood {
        case .fine: break
        case .tooMany(let retry): return HTTPResponse(status: 429, headers: [("Content-Length", "0")] + (retry.map { [("Retry-After", "\($0)")] } ?? []))
        case .unauthorized: return .status(401)
        case .notSubsonic:
            let page = Data("<html><body>It works!</body></html>".utf8)
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/html"), ("Content-Length", "\(page.count)")], body: .data(page))
        case .redirect(let target):
            return HTTPResponse(status: 302, headers: [("Location", target + request.path), ("Content-Length", "0")])
        case .silent:
            while !lock.withLock({ self.state.released }) { try? await Task.sleep(for: .milliseconds(20)) }
            return .status(503)
        }
        guard request.path.hasPrefix("/rest/") else { return .status(404) }
        if let refusal = refusal(query, state) { return refusal }

        switch method {
        case "ping":
            return Self.json([:])
        case "tokenInfo":
            return Self.json(["tokenInfo": ["username": query["apiKey"].flatMap { state.apiKeys[$0] } ?? ""]])
        case "getAlbumList2":
            var seen = Set<String>()
            let albums = state.songs.filter { seen.insert($0.albumId).inserted }
            let size = Int(query["size"] ?? "10") ?? 10, offset = state.ignoresOffset ? 0 : Int(query["offset"] ?? "0") ?? 0
            let page = albums.dropFirst(offset).prefix(size).map { ["id": $0.albumId, "name": $0.album, "artist": $0.artist, "songCount": 1] as [String: Any] }
            // A page with nothing in it leaves the list out, as servers do.
            return Self.json(["albumList2": page.isEmpty ? [:] : ["album": Array(page)]])
        case "getAlbum":
            let songs = state.songs.filter { $0.albumId == query["id"] }
            guard let first = songs.first else { return Self.failure(70, "The requested data was not found.") }
            return Self.json(["album": ["id": first.albumId, "name": first.album, "artist": first.artist,
                                        "song": songs.enumerated().map { Self.child($0.element, starred: state.starred.contains($0.element.id), index: $0.offset) }]])
        case "getArtists":
            var counts: [String: Set<String>] = [:]
            for song in state.songs { counts[song.artist, default: []].insert(song.albumId) }
            let artists = counts.keys.sorted().map { ["id": "ar-\($0)", "name": $0, "albumCount": counts[$0]!.count] as [String: Any] }
            return Self.json(["artists": ["ignoredArticles": "The", "index": [["name": "#", "artist": artists]]]])
        case "search3":
            let text = (query["query"] ?? "").lowercased()
            let count = Int(query["songCount"] ?? "20") ?? 20
            let found = state.songs.filter { $0.title.lowercased().contains(text) }.prefix(count)
            return Self.json(["searchResult3": found.isEmpty ? [:] : ["song": found.enumerated().map { Self.child($0.element, starred: false, index: $0.offset) }]])
        case "getPlaylists":
            return Self.json(["playlists": ["playlist": state.playlists.map { ["id": $0.id, "name": $0.name, "songCount": $0.songs.count] as [String: Any] }]])
        case "getPlaylist":
            guard let playlist = state.playlists.first(where: { $0.id == query["id"] }) else { return Self.failure(70, "The requested data was not found.") }
            let entries = playlist.songs.compactMap { id in state.songs.first { $0.id == id } }
            return Self.json(["playlist": ["id": playlist.id, "name": playlist.name,
                                           "entry": entries.enumerated().map { Self.child($0.element, starred: false, index: $0.offset) }]])
        case "getStarred2":
            let songs = state.songs.filter { state.starred.contains($0.id) }
            return Self.json(["starred2": ["song": songs.enumerated().map { Self.child($0.element, starred: true, index: $0.offset) }]])
        case "star", "unstar":
            guard let id = query["id"], state.songs.contains(where: { $0.id == id }) else { return Self.failure(70, "The requested data was not found.") }
            lock.withLock {
                if method == "star" {
                    self.state.starred.insert(id)
                } else {
                    self.state.starred.remove(id)
                }
                return
            }
            return Self.json([:])
        case "scrobble":
            guard let id = query["id"] else { return Self.failure(10, "Required parameter is missing.") }
            lock.withLock { self.state.scrobbles.append((id, query["time"])) }
            return Self.json([:])
        case "getCoverArt":
            guard let data = query["id"].flatMap({ state.covers[$0] }) else { return Self.failure(70, "The requested data was not found.") }
            return HTTPResponse(status: 200, headers: [("Content-Type", "image/png"), ("Content-Length", "\(data.count)")], body: .data(data))
        case "stream":
            guard let song = state.songs.first(where: { $0.id == query["id"] }) else { return Self.failure(70, "The requested data was not found.") }
            let (data, type) = song.converted ?? (song.data, "audio/flac")
            let size = Int64(data.count)
            guard case .range(let range) = ByteRange.parse(request.headers["range"], size: size) else {
                lock.withLock { self.state.bytesServed += data.count }
                return HTTPResponse(status: 200, headers: [("Content-Type", type), ("Content-Length", "\(size)"), ("Accept-Ranges", "bytes")], body: .data(data))
            }
            let part = data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
            lock.withLock { self.state.bytesServed += part.count }
            return HTTPResponse(status: 206, headers: [("Content-Type", type), ("Content-Length", "\(part.count)"), ("Accept-Ranges", "bytes"),
                                                       ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)")], body: .data(part))
        default:
            return Self.failure(0, "No such method.")
        }
    }
}
