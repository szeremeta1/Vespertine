//
// Vespertine: the OpenSubsonic provider. It reads one account on a server the listener runs or was given an account on
// (Navidrome, Gonic, Airsonic and the like): lists its library, searches it, stars songs, and opens a song's file as the
// server has it ("format=raw"), which the engine then plays like any file. Held to the rules in docs/STREAMING.md.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary
import VespertineStreaming

public final class OpenSubsonicProvider: StreamingProvider, @unchecked Sendable {
    public static let providerID = "opensubsonic"

    /// What the streaming core is told of this provider. The server is the listener's own or one they have an account on, and
    /// the API hands out the files themselves, so keeping a copy is allowed by its terms; the app has no offline copies yet.
    public static let descriptor = ProviderDescriptor(
        id: providerID, name: "OpenSubsonic",
        capabilities: [.search, .library, .playlists, .favorites, .playReports, .rangeRequests, .severalAccounts],
        playbackMode: .engine,
        storagePolicy: .offlineAllowed(termsReference: "https://opensubsonic.netlify.app/docs/endpoints/download/"),
        make: { account, credentials in OpenSubsonicProvider(account: account, credentials: credentials) })

    public let id = OpenSubsonicProvider.providerID
    public let account: String
    public let capabilities = OpenSubsonicProvider.descriptor.capabilities
    public let playbackMode = ProviderPlaybackMode.engine
    public let storagePolicy = OpenSubsonicProvider.descriptor.storagePolicy

    /// How many albums a page of the album list asks for.
    private let pageSize: Int

    private let credentials: any CredentialStore
    private let gate: RequestGate
    private let http: URLSession
    private let timeout: TimeInterval

    private struct State {
        var credential: OpenSubsonicCredential?
        var loaded = false
        var stopped = false
        /// An http address was checked to be on the listener's own network.
        var addressChecked = false
    }
    private let state = Locked(State())

    /// `timeout`: how long a request may go without a byte. `gate`: tests pass one whose events they read. `albumPageSize`: how
    /// many albums a page of the album list asks for (the API allows up to 500).
    public init(account: String, credentials: any CredentialStore, timeout: TimeInterval = 20, gate: RequestGate = RequestGate(),
                albumPageSize: Int = 500) {
        pageSize = max(1, min(500, albumPageSize))
        self.account = account
        self.credentials = credentials
        self.timeout = timeout
        self.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        http = URLSession(configuration: configuration, delegate: OpenSubsonicRedirects(), delegateQueue: nil)
    }

    deinit { http.invalidateAndCancel() }

    public var waitingUntil: Date? { gate.waitingUntil }

    public func stop() {
        state.withLock { $0.stopped = true }
        http.invalidateAndCancel()
    }

    // MARK: The credential

    /// The account's Keychain item, read once and kept in memory while the provider lives.
    private func stored() -> OpenSubsonicCredential? {
        state.withLock { state in
            if !state.loaded {
                state.loaded = true
                state.credential = credentials.load(provider: id, account: account).flatMap { try? JSONDecoder().decode(OpenSubsonicCredential.self, from: $0) }
            }
            return state.credential
        }
    }

    private func client() throws -> OpenSubsonicClient {
        guard !state.withLock({ $0.stopped }) else { throw StreamingError.off }
        guard let credential = stored(), credential.canSignIn, let base = URL(string: credential.server) else { throw StreamingError.signedOut }
        return OpenSubsonicClient(base: base, credential: credential, session: http)
    }

    /// The server no longer accepts `credential`: its secret is taken out of the Keychain item, so nothing is sent with it
    /// again. The address and the name stay, for signing in again. A credential that was replaced meanwhile is left alone.
    private func refused(_ credential: OpenSubsonicCredential) {
        let stripped = state.withLock { state -> OpenSubsonicCredential? in
            guard state.credential == credential else { return nil }
            state.credential = credential.withoutSecret
            return state.credential
        }
        guard let stripped, let data = try? JSONEncoder().encode(stripped) else { return }
        try? credentials.save(data, provider: id, account: account)
    }

    public func session() async -> ProviderSession {
        guard let credential = stored(), credential.canSignIn else { return .signedOut }
        return .signedIn(user: credential.user)
    }

    public func rememberedSignIn() async -> (server: String, user: String)? {
        stored().map { (server: $0.server, user: $0.user) }
    }

    public func signIn(_ request: ProviderSignIn) async throws -> ProviderSession {
        guard !state.withLock({ $0.stopped }) else { throw StreamingError.off }
        let base = try OpenSubsonicAddress.parse(request.server)
        try await Self.offThread { try OpenSubsonicAddress.check(base) }
        let server = base.absoluteString
        let user = request.user.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [OpenSubsonicCredential]
        switch request.secret {
        case .apiKey(let key):
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw StreamingError.signedOut }
            candidates = [OpenSubsonicCredential(server: server, user: user, apiKey: key)]
        case .password(let password):
            guard !user.isEmpty, !password.isEmpty else { throw StreamingError.signedOut }
            let salt = OpenSubsonicCredential.newSalt()
            // The token first: with it the password itself need not be kept. The password only for a server that takes no token.
            candidates = [OpenSubsonicCredential(server: server, user: user, token: OpenSubsonicCredential.token(password: password, salt: salt), salt: salt),
                          OpenSubsonicCredential(server: server, user: user, password: password)]
        }
        var failure: any Error = StreamingError.signedOut
        for candidate in candidates {
            let client = OpenSubsonicClient(base: base, credential: candidate, session: http)
            do {
                _ = try await send(client, "ping", [], .browsing)
            } catch let refusal as OpenSubsonicRefusal {
                failure = refusal.asStreamingError
                continue
            }
            var kept = candidate
            if kept.apiKey != nil, kept.user.isEmpty,
               let name = try? await send(client, "tokenInfo", [], .browsing).tokenInfo?.username?.text {
                kept.user = name
            }
            try credentials.save(try JSONEncoder().encode(kept), provider: id, account: account)
            state.withLock { state in
                state.credential = kept
                state.loaded = true
                state.addressChecked = true
            }
            return .signedIn(user: kept.user)
        }
        throw failure
    }

    public func signOut() async {
        credentials.delete(provider: id, account: account)
        state.withLock { state in
            state.credential = nil
            state.loaded = true
        }
    }

    // MARK: Requests

    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// One request through the gate. A server that asks to wait closes the gate until it said.
    private func send(_ client: OpenSubsonicClient, _ method: String, _ items: [(String, String)], _ priority: RequestPriority) async throws -> SubsonicAnswer {
        let gate = gate
        let url = client.url(method, items)
        return try await gate.run(priority) {
            switch try await client.fetch(url) {
            case .wait(let seconds):
                gate.askedToWait(retryAfter: seconds)
                throw StreamingError.askedToWait(seconds: seconds ?? RequestGate.defaultWait)
            case .answer(let data, _):
                return try OpenSubsonicClient.answer(data)
            }
        }
    }

    private func call(_ method: String, _ items: [(String, String)] = [], _ priority: RequestPriority) async throws -> SubsonicAnswer {
        let client = try client()
        try await checkAddress(client.base)
        do {
            return try await send(client, method, items, priority)
        } catch StreamingError.signedOut {
            refused(client.credential)
            throw StreamingError.signedOut
        } catch let refusal as OpenSubsonicRefusal {
            throw refusal.asStreamingError
        }
    }

    /// An http address is checked once in the provider's life to be on the listener's own network (sign-in checks it too).
    private func checkAddress(_ base: URL) async throws {
        guard OpenSubsonicAddress.isUnencrypted(base), !state.withLock({ $0.addressChecked }) else { return }
        try await Self.offThread { try OpenSubsonicAddress.check(base) }
        state.withLock { $0.addressChecked = true }
    }

    // MARK: The library

    public func search(_ text: String, limit: Int) async throws -> [StreamedSong] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let answer = try await call("search3", [("query", query), ("songCount", "\(max(1, limit))"), ("albumCount", "0"), ("artistCount", "0")], .browsing)
        return (answer.searchResult3?.song ?? []).compactMap(\.song)
    }

    public func tracks(of albumID: String) async throws -> [StreamedSong] {
        try await albumSongs(albumID, .browsing)
    }

    private func albumSongs(_ albumID: String, _ priority: RequestPriority) async throws -> [StreamedSong] {
        let album = try await call("getAlbum", [("id", albumID)], priority).album
        return (album?.song ?? []).compactMap { entry in
            guard var song = entry.song else { return nil }
            if song.albumId == nil { song.albumId = albumID }
            if song.album == nil { song.album = album?.name?.text }
            return song
        }
    }

    /// The ids of every album, a page at a time. A server that answers the same page whatever the offset ends the walk.
    func albumIDs() async throws -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await call("getAlbumList2", [("type", "alphabeticalByName"), ("size", "\(pageSize)"), ("offset", "\(offset)")], .sync)
                .albumList2?.album ?? []
            let fresh = page.compactMap { $0.id?.text }.filter { seen.insert($0).inserted }
            ids += fresh
            if page.count < pageSize || fresh.isEmpty { break }
            offset += page.count
        }
        return ids
    }

    /// The artists of the server's index.
    public func artists() async throws -> [OpenSubsonicArtist] {
        let answer = try await call("getArtists", [], .browsing)
        return (answer.artists?.index ?? []).flatMap { $0.artist ?? [] }.compactMap { artist in
            guard let id = artist.id?.text else { return nil }
            return OpenSubsonicArtist(id: id, name: artist.name?.text ?? id, albumCount: artist.albumCount?.int ?? 0)
        }
    }

    public func library(progress: @escaping @Sendable (Int) -> Void) async throws -> ProviderLibrary {
        let albums = try await albumIDs()
        var songs: [StreamedSong] = []
        var seen = Set<String>()
        var index = 0
        // A few albums at a time: the gate lets no more than its slots through, and playback and browsing go ahead of these.
        while index < albums.count {
            try Task.checkCancellation()
            let batch = Array(albums[index..<min(index + 4, albums.count)])
            let lists = try await withThrowingTaskGroup(of: (Int, [StreamedSong]).self) { group -> [[StreamedSong]] in
                for (position, album) in batch.enumerated() {
                    group.addTask { (position, try await self.albumSongs(album, .sync)) }
                }
                var found = [[StreamedSong]](repeating: [], count: batch.count)
                for try await (position, list) in group { found[position] = list }
                return found
            }
            for song in lists.joined() where seen.insert(song.id).inserted { songs.append(song) }
            progress(songs.count)
            index += batch.count
        }

        var playlists: [StreamedPlaylist] = []
        for listing in try await call("getPlaylists", [], .sync).playlists?.playlist ?? [] {
            try Task.checkCancellation()
            guard let id = listing.id?.text else { continue }
            let entries = try await call("getPlaylist", [("id", id)], .sync).playlist?.entry ?? []
            playlists.append(StreamedPlaylist(id: id, name: listing.name?.text ?? id, songIDs: entries.compactMap { $0.id?.text }))
        }

        var starred = Set(songs.filter(\.starred).map(\.id))
        for song in try await call("getStarred2", [], .sync).starred2?.song ?? [] {
            if let id = song.id?.text { starred.insert(id) }
        }
        return ProviderLibrary(songs: songs, playlists: playlists, starred: starred)
    }

    public func setStarred(_ starred: Bool, songID: String) async throws {
        _ = try await call(starred ? "star" : "unstar", [("id", songID)], .browsing)
    }

    public func reportPlayed(songID: String, at date: Date) async throws {
        _ = try await call("scrobble", [("id", songID), ("time", "\(Int64(date.timeIntervalSince1970 * 1000))"), ("submission", "true")], .sync)
    }

    public func artwork(_ coverArt: String) async throws -> Data {
        let client = try client()
        try await checkAddress(client.base)
        let gate = gate
        let url = client.url("getCoverArt", [("id", coverArt)])
        do {
            return try await gate.run(.sync) {
                switch try await client.fetch(url) {
                case .wait(let seconds):
                    gate.askedToWait(retryAfter: seconds)
                    throw StreamingError.askedToWait(seconds: seconds ?? RequestGate.defaultWait)
                case .answer(let data, let type):
                    // A failure arrives as an answer of the API where the picture should be.
                    if type == "application/json" || type == "text/xml" || type == "application/xml" {
                        _ = try OpenSubsonicClient.answer(data)
                        throw StreamingError.malformedAnswer
                    }
                    guard !data.isEmpty else { throw StreamingError.malformedAnswer }
                    return data
                }
            }
        } catch StreamingError.signedOut {
            refused(client.credential)
            throw StreamingError.signedOut
        } catch let refusal as OpenSubsonicRefusal {
            throw refusal.asStreamingError
        }
    }

    // MARK: Playing

    /// Opens the song's file as the server has it: "format=raw" asks for no conversion. The bytes are read by ranges, so a
    /// seek fetches from where it lands. Blocks while the server is asked: the playback cache calls it on its own thread.
    public func openStream(_ songID: String) throws -> any RemoteCacheReader {
        let client = try client()
        try OpenSubsonicAddress.check(client.base)
        try gate.throwIfWaiting()
        let url = client.url("stream", [("id", songID), ("format", "raw")])
        do {
            return try HTTPStreamReader(url: url, options: .init(policy: .listenersOwn, idleTimeout: timeout,
                                                                 notAnsweringMessage: StreamingCore.notAnsweringMessage))
        } catch let refusal as StreamRefusal {
            switch refusal {
            case .status(429):
                gate.askedToWait(retryAfter: nil)
                throw StreamingError.askedToWait(seconds: RequestGate.defaultWait)
            case .status(401), .status(403):
                refused(client.credential)
                throw StreamingError.signedOut
            case .notDecodable, .empty, .unknownLength:
                // The API reports a failure in place of the song, with status 200. Asking again for its first bytes reads it.
                try diagnose(client, url)
                throw refusal
            default:
                throw refusal
            }
        }
    }

    /// Asks for the first bytes at `url` and throws the failure the server reports there, if it is one. Blocking.
    private func diagnose(_ client: OpenSubsonicClient, _ url: URL) throws {
        let done = DispatchSemaphore(value: 0)
        let body = Locked<Data?>(nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = timeout
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        http.dataTask(with: request) { data, _, _ in
            body.withLock { $0 = data }
            done.signal()
        }.resume()
        done.wait()
        guard let data = body.withLock({ $0 }) else { return }
        do {
            _ = try OpenSubsonicClient.answer(data)
        } catch StreamingError.signedOut {
            refused(client.credential)
            throw StreamingError.signedOut
        } catch let refusal as OpenSubsonicRefusal {
            throw refusal.asStreamingError
        } catch StreamingError.malformedAnswer {
            // Not an answer of the API: the stream itself is what couldn't be played.
            return
        }
    }
}
