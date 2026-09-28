//
// Nocturne — MusicBrainz / Cover Art Archive lookup and ListenBrainz scrobbling.
// All services are open and free; no account is needed except a ListenBrainz token for scrobbling.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security

// MARK: - MusicBrainz

public struct MBReleaseSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String?
    public var country: String?
    public var trackCount: Int
    public var format: String?
    public var label: String?
    public var score: Int
}

public struct MBTrack: Sendable, Hashable {
    public var disc: Int
    public var position: Int
    public var title: String
    public var artist: String
    public var recordingID: String
    public var length: Double?
}

public struct MBRelease: Sendable, Hashable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String?
    public var label: String?
    public var genre: String?
    public var discCount: Int
    public var tracks: [MBTrack]
}

public actor MusicBrainzClient {
    public static let shared = MusicBrainzClient()

    private let session: URLSession
    private var lastRequest = Date.distantPast
    private let userAgent = "Nocturne/0.1 (open-source macOS audio player)"

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    /// MusicBrainz asks for at most one request per second.
    private func get(_ url: URL) async throws -> Data {
        // Recheck after suspension: another actor call may have acquired this slot while we slept.
        while true {
            let wait = 1.1 - Date().timeIntervalSince(lastRequest)
            if wait <= 0 { break }
            try await Task.sleep(for: .seconds(wait))
        }
        try Task.checkCancellation()
        lastRequest = .now
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func searchReleases(artist: String, album: String, trackCount: Int? = nil) async throws -> [MBReleaseSummary] {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "") }
        var query = "release:\"\(esc(album))\" AND artist:\"\(esc(artist))\""
        if let trackCount { query += " AND tracks:\(trackCount)" }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        comps.queryItems = [.init(name: "query", value: query), .init(name: "fmt", value: "json"), .init(name: "limit", value: "12")]
        let json = try JSONSerialization.jsonObject(with: try await get(comps.url!)) as? [String: Any]
        let releases = json?["releases"] as? [[String: Any]] ?? []
        return releases.compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
            let media = r["media"] as? [[String: Any]] ?? []
            let labels = (r["label-info"] as? [[String: Any]])?.compactMap { ($0["label"] as? [String: Any])?["name"] as? String }
            return MBReleaseSummary(
                id: id, title: title, artist: Self.credit(r["artist-credit"]), date: r["date"] as? String,
                country: r["country"] as? String,
                trackCount: (r["track-count"] as? Int) ?? media.reduce(0) { $0 + (($1["track-count"] as? Int) ?? 0) },
                format: media.compactMap { $0["format"] as? String }.first, label: labels?.first,
                score: (r["score"] as? Int) ?? 0)
        }
    }

    public func release(id: String) async throws -> MBRelease {
        guard UUID(uuidString: id) != nil else { throw URLError(.badURL) }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)")!
        comps.queryItems = [.init(name: "inc", value: "recordings+artist-credits+labels+genres+release-groups"), .init(name: "fmt", value: "json")]
        guard let r = try JSONSerialization.jsonObject(with: try await get(comps.url!)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let media = r["media"] as? [[String: Any]] ?? []
        var tracks: [MBTrack] = []
        for medium in media {
            let disc = (medium["position"] as? Int) ?? 1
            for t in medium["tracks"] as? [[String: Any]] ?? [] {
                let recording = t["recording"] as? [String: Any]
                tracks.append(MBTrack(
                    disc: disc, position: (t["position"] as? Int) ?? 0,
                    title: (t["title"] as? String) ?? "",
                    artist: Self.credit(t["artist-credit"] ?? recording?["artist-credit"]),
                    recordingID: (recording?["id"] as? String) ?? "",
                    length: (t["length"] as? Double).map { $0 / 1000 }))
            }
        }
        let labels = (r["label-info"] as? [[String: Any]])?.compactMap { ($0["label"] as? [String: Any])?["name"] as? String }
        let genres = ((r["genres"] as? [[String: Any]]) ?? ((r["release-group"] as? [String: Any])?["genres"] as? [[String: Any]]) ?? [])
            .sorted { (($0["count"] as? Int) ?? 0) > (($1["count"] as? Int) ?? 0) }
            .compactMap { ($0["name"] as? String)?.capitalized }
        return MBRelease(id: id, title: (r["title"] as? String) ?? "", artist: Self.credit(r["artist-credit"]),
                         date: r["date"] as? String, label: labels?.first, genre: genres.first,
                         discCount: max(1, media.count), tracks: tracks)
    }

    /// Front cover from the Cover Art Archive (1200 px).
    public func frontCover(releaseID: String) async throws -> Data? {
        guard UUID(uuidString: releaseID) != nil else { throw URLError(.badURL) }
        let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-1200")!
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    static func credit(_ value: Any?) -> String {
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.map { (($0["name"] as? String) ?? "") + (($0["joinphrase"] as? String) ?? "") }.joined()
    }
}

public extension MBRelease {
    /// Tag edits for `track`, matched by disc/track number (falling back to order).
    func edit(for track: Track, index: Int) -> TagEdit? {
        let match = tracks.first { $0.disc == (track.discNumber ?? 1) && $0.position == track.trackNumber }
            ?? (tracks.indices.contains(index) ? tracks[index] : nil)
        guard let match else { return nil }
        var fields: [TagField: String?] = [
            .title: match.title, .artist: match.artist, .album: title, .albumArtist: artist,
            .trackNumber: String(match.position), .trackTotal: String(tracks.filter { $0.disc == match.disc }.count),
            .discNumber: String(match.disc), .discTotal: String(discCount),
            .musicBrainzReleaseID: id, .musicBrainzRecordingID: match.recordingID,
        ]
        if let date { fields[.releaseDate] = date }
        if let label { fields[.label] = label }
        if let genre, track.genre == nil { fields[.genre] = genre }
        return TagEdit(fields: fields)
    }
}

// MARK: - ListenBrainz

public actor ListenBrainzClient {
    public static let shared = ListenBrainzClient()
    private let session = URLSession(configuration: .default)

    public enum Kind: String { case single, playingNow = "playing_now" }

    public func submit(_ track: Track, kind: Kind, listenedAt: Date = .now) async throws {
        guard let token = Keychain.read("listenbrainz-token"), !token.isEmpty else { return }
        var metadata: [String: Any] = ["artist_name": track.displayArtist, "track_name": track.title]
        if let album = track.album { metadata["release_name"] = album }
        var info: [String: Any] = ["media_player": "Nocturne", "submission_client": "Nocturne", "duration": Int(track.duration)]
        if let rec = track.musicBrainzRecordingID { info["recording_mbid"] = rec }
        if let rel = track.musicBrainzReleaseID { info["release_mbid"] = rel }
        metadata["additional_info"] = info
        var listen: [String: Any] = ["track_metadata": metadata]
        if kind == .single { listen["listened_at"] = Int(listenedAt.timeIntervalSince1970) }
        let body: [String: Any] = ["listen_type": kind.rawValue, "payload": [listen]]

        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/submit-listens")!)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }

    /// Checks a token; returns the user name when valid.
    public func validate(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/validate-token")!)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["valid"] as? Bool) == true ? json?["user_name"] as? String : nil
    }
}

// MARK: - Keychain

public enum Keychain {
    static let service = "org.nocturne.player"

    public static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ value: String?, account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
