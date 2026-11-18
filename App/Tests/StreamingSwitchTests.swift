//
// Vespertine: the Settings switch for music servers, off by default. Off, no provider is made, nothing is sent, no Keychain item
// is read and a server's songs are in no list. On then off leaves nothing running. A sign-in leaves the credential nowhere but
// the credential store.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineLibrary
import VespertineOpenSubsonic
import VespertineStreaming
@testable import Vespertine

/// A provider that reaches no server and notes what was done with it.
private nonisolated final class CountingProvider: StreamingProvider, @unchecked Sendable {
    struct Notes: Sendable {
        var made = 0
        var stopped = 0
        var asked: [String] = []
        /// Listing the library never ends until it is cancelled.
        var hangs = false
        var songs: [StreamedSong] = []
    }

    static let providerID = "counting"
    let id = CountingProvider.providerID
    let account: String
    let capabilities: ProviderCapabilities = [.library, .favorites, .playReports]
    let playbackMode = ProviderPlaybackMode.engine
    let storagePolicy = ProviderStoragePolicy.transientCacheOnly
    let notes: Locked<Notes>
    let credentials: any CredentialStore

    init(account: String, credentials: any CredentialStore, notes: Locked<Notes>) {
        self.account = account
        self.credentials = credentials
        self.notes = notes
        notes.withLock { $0.made += 1 }
    }

    static func descriptor(_ notes: Locked<Notes>) -> ProviderDescriptor {
        ProviderDescriptor(id: providerID, name: "Counting", capabilities: [.library, .favorites, .playReports], playbackMode: .engine,
                           storagePolicy: .transientCacheOnly) { account, credentials in
            CountingProvider(account: account, credentials: credentials, notes: notes)
        }
    }

    private func note(_ what: String) { notes.withLock { $0.asked.append(what) } }

    func session() async -> ProviderSession {
        credentials.load(provider: id, account: account) == nil ? .signedOut : .signedIn(user: "listener")
    }

    func signIn(_ request: ProviderSignIn) async throws -> ProviderSession {
        note("signIn")
        try credentials.save(Data("kept".utf8), provider: id, account: account)
        return .signedIn(user: request.user)
    }

    func signOut() async {
        note("signOut")
        credentials.delete(provider: id, account: account)
    }

    func search(_ text: String, limit: Int) async throws -> [StreamedSong] { [] }

    func library(progress: @escaping @Sendable (Int) -> Void) async throws -> ProviderLibrary {
        note("library")
        if notes.withLock({ $0.hangs }) {
            while true { try await Task.sleep(for: .milliseconds(5)) }
        }
        return ProviderLibrary(songs: notes.withLock { $0.songs })
    }

    func tracks(of albumID: String) async throws -> [StreamedSong] { [] }
    func openStream(_ songID: String) throws -> any RemoteCacheReader { throw StreamingError.unsupported }
    func setStarred(_ starred: Bool, songID: String) async throws { note("\(starred ? "star" : "unstar") \(songID)") }
    func reportPlayed(songID: String, at date: Date) async throws { note("played \(songID)") }
    func artwork(_ coverArt: String) async throws -> Data { throw StreamingError.unsupported }
    var waitingUntil: Date? { nil }
    func stop() { notes.withLock { $0.stopped += 1 } }
}

/// The least of an OpenSubsonic server on 127.0.0.1: every method is answered "ok" with nothing in it, and each request's
/// first line is noted.
private nonisolated final class TinySubsonic: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tiny-subsonic")
    private let seen = Locked<[String]>([])

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    /// Starts listening and answers the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
    var requests: [String] { seen.withLock { $0 } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            var all = soFar
            if let data { all.append(data) }
            guard all.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() } else { self?.read(connection, all) }
                return
            }
            let line = String(decoding: all.prefix { $0 != 13 }, as: UTF8.self)
            self?.seen.withLock { $0.append(line) }
            let body = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"tiny","openSubsonic":true}}"#.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("Music servers settings switch", .serialized) @MainActor
struct StreamingSwitchTests {
    private struct Scratch {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let settings: AppSettings
        let library: LibraryStore
        let credentials: MemoryCredentialStore
        let notes: Locked<CountingProvider.Notes>
    }

    private func scratch() throws -> Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-streamingswitch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false },
                                       shownProviders: StreamingModel.enabled(in: defaults))
        return Scratch(root: root, defaults: defaults, suite: suite, settings: settings, library: library,
                       credentials: MemoryCredentialStore(), notes: Locked(CountingProvider.Notes()))
    }

    private func clean(_ scratch: Scratch) {
        scratch.defaults.removePersistentDomain(forName: scratch.suite)
        removeScratch(scratch.root)
    }

    private func model(_ scratch: Scratch, library: LibraryStore? = nil) -> StreamingModel {
        StreamingModel(library: library ?? scratch.library, defaults: scratch.defaults, player: nil, credentials: scratch.credentials,
                       descriptors: [CountingProvider.descriptor(scratch.notes)])
    }

    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(90)
        while !condition() {
            if Date() > end { return condition() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func song(_ id: String, title: String) -> StreamedSong {
        StreamedSong(id: id, title: title, artist: "Server Artist", album: "Server Album", albumArtist: "Server Artist", albumId: "al-1",
                     trackNumber: 1, duration: 200, suffix: "flac", bitDepth: 16, sampleRate: 44_100, channels: 2, size: 20_000_000)
    }

    @Test("Every provider's switch, and its play reports, are off until the listener turns them on")
    func offByDefault() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        #expect(!StreamingModel.ids.isEmpty)
        for id in StreamingModel.ids {
            #expect(scratch.defaults.object(forKey: StreamingCore.enabledKey(id)) as? Bool == false)
            #expect(scratch.defaults.object(forKey: StreamingCore.playReportsKey(id)) as? Bool == false)
            #expect(StreamingCore.enabledKey(id) == "streaming.\(id).enabled")
        }
        #expect(StreamingModel.enabled(in: scratch.defaults).isEmpty)
        let app = StreamingModel(library: scratch.library, defaults: scratch.defaults, player: nil, credentials: scratch.credentials)
        #expect(!app.anyOn)
        #expect(app.core.enabled.isEmpty)
        #expect(app.core.constructedCount == 0)
        #expect(scratch.credentials.loadCount == 0)
    }

    @Test("Off, nothing is made, nothing is asked, no credential is read, and a server's songs are in no list; nothing was deleted")
    func offIsOff() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        scratch.notes.withLock { $0.songs = [song("s1", title: "From The Server")] }
        let id = CountingProvider.providerID

        // On once: an account signs in and its one song is listed.
        let first = model(scratch)
        first.setOn(true, id)
        #expect(await first.signIn(id, name: "Home", request: ProviderSignIn(server: "", user: "listener", secret: .password("x"))) == nil)
        #expect(await until { scratch.library.allTracks().contains { $0.title == "From The Server" } })
        #expect(await until { first.accounts(id).first.map { !first.state($0).syncing } == true })
        #expect(scratch.library.streamedAccounts.count == 1)

        // Off: gone from every list at once, and still in the database.
        first.setOn(false, id)
        #expect(scratch.defaults.bool(forKey: StreamingCore.enabledKey(id)) == false)
        #expect(scratch.library.allTracks().allSatisfy { !$0.isStreamed })
        #expect(scratch.library.search("Server").isEmpty)
        #expect(await until { scratch.library.streamedAccounts.isEmpty && scratch.library.albums.isEmpty && scratch.library.artists.isEmpty })
        #expect(first.accounts(id).isEmpty)
        #expect(!scratch.credentials.isEmpty)

        // The next launch with the switch off: the library is read without them, and the provider is never made.
        let made = scratch.notes.withLock { $0.made }, asked = scratch.notes.withLock { $0.asked }, loads = scratch.credentials.loadCount
        let relaunched = try LibraryStore(dataDirectory: scratch.root.appendingPathComponent("library"), automaticScanning: { false },
                                          shownProviders: StreamingModel.enabled(in: scratch.defaults))
        let second = model(scratch, library: relaunched)
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.core.constructedCount == 0)
        #expect(scratch.notes.withLock { $0.made } == made)
        #expect(scratch.notes.withLock { $0.asked } == asked)
        #expect(scratch.credentials.loadCount == loads)
        #expect(relaunched.streamedAccounts.isEmpty)
        #expect(relaunched.allTracks().isEmpty)
        #expect(relaunched.albums.isEmpty)
        #expect(relaunched.stats.tracks == 0)

        // On again: the account, its songs and its sign-in are all still there.
        second.setOn(true, id)
        #expect(relaunched.allTracks().contains { $0.title == "From The Server" })
        #expect(await until { second.accounts(id).first.map { second.state($0).session == .signedIn(user: "listener") } == true })
    }

    @Test("A server that stopped answering mid-play is named in the player's words and on its own row, until a song from it plays again")
    func serverUnanswered() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        scratch.notes.withLock { $0.songs = [song("s1", title: "From The Server")] }
        let id = CountingProvider.providerID
        let app = model(scratch)
        app.setOn(true, id)
        #expect(await app.signIn(id, name: "Home", request: ProviderSignIn(server: "", user: "listener", secret: .password("x"))) == nil)
        #expect(await until { scratch.library.allTracks().contains { $0.isStreamed } })
        // The list of accounts follows the database a moment later: waited for, not assumed.
        #expect(await until { !app.accounts(id).isEmpty })
        let account = try #require(app.accounts(id).first)
        #expect(await until { !app.state(account).syncing && app.state(account).session == .signedIn(user: "listener") })
        let track = try #require(scratch.library.allTracks().first { $0.isStreamed })
        let signedIn = ServerStatus.line(app.state(account), waitingUntil: nil)

        let said = try #require(app.unanswered(track))
        #expect(said == PlayerController.notAnswering("Home"))
        #expect(ServerStatus.line(app.state(account), waitingUntil: nil) == said, "the row no longer says only who is signed in")
        #expect(app.state(account).session == .signedIn(user: "listener"), "not answering is no reason to sign out")

        app.answered(track)
        #expect(app.state(account).problem == nil)
        #expect(ServerStatus.line(app.state(account), waitingUntil: nil) == signedIn)

        // Off: nothing is said for a provider that is not there.
        app.setOn(false, id)
        #expect(app.unanswered(track) == nil)
    }

    @Test("A song whose server stopped answering says so in Now Playing, and every start of a song from that server, the same one played again too, says the server answers")
    func stopReasonAndReplay() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        scratch.notes.withLock { $0.songs = [song("s1", title: "From The Server")] }
        let id = CountingProvider.providerID
        let app = model(scratch)
        app.setOn(true, id)
        #expect(await app.signIn(id, name: "Home", request: ProviderSignIn(server: "", user: "listener", secret: .password("x"))) == nil)
        #expect(await until { scratch.library.allTracks().contains { $0.isStreamed } })
        // The list of accounts follows the database a moment later: waited for, not assumed (the server's name comes from it).
        #expect(await until { !app.accounts(id).isEmpty })
        let track = try #require(scratch.library.allTracks().first { $0.isStreamed })

        let shares = NetworkShareManager(library: scratch.library, settings: scratch.settings, dataDirectory: scratch.root)
        let player = PlayerController(library: scratch.library, settings: scratch.settings, shares: shares)
        defer { player.stop() }
        let answered = Locked(0)
        player.serverUnanswered = { _ in PlayerController.notAnswering("Home") }
        player.serverAnswered = { _ in answered.withLock { $0 += 1 } }
        player.serverName = { _ in "Home" }
        // The engine's events and snapshots are handed to the player here, one after another with nothing between them: the
        // song itself never plays (its provider serves no audio), and what the engine says of that comes after this test's turn.
        player.play([track])
        let item = try #require(player.current?.item)
        let engineSays = try #require(player.engine.eventHandler)
        var playing = player.engine.snapshot
        playing.lastError = nil
        playing.outputDevice = nil
        playing.item = item
        playing.state = .playing
        playing.isBuffering = false
        playing.position = 1

        // While the song waits for its server, the notice names the server, not the folder the song's copy is kept in.
        var stalled = playing
        stalled.isBuffering = true
        stalled.shareStalledSeconds = 12
        player.poll(stalled)
        let notice = try #require(player.shareNotice)
        #expect(notice.contains("“Home”"), "\(notice)")
        #expect(app.serverName(of: track) == "Home")
        stalled.shareStalledSeconds = nil
        player.poll(stalled)
        #expect(player.shareNotice == nil)

        engineSays(.failed(item, StreamingCore.notAnsweringMessage))
        #expect(player.stopReason == PlayerController.notAnswering("Home"), "Now Playing says why the song stopped")
        #expect(player.lastError == PlayerController.notAnswering("Home"))
        #expect(answered.withLock { $0 } == 0)
        // The banner goes by itself after a few seconds. The phone remote is still told why playback stopped.
        var stopped = playing
        stopped.state = .stopped
        player.poll(stopped)
        player.clearError()
        #expect(player.lastError == nil && player.errorForRemote == PlayerController.notAnswering("Home"))

        // The same queue entry is played again and is heard.
        engineSays(.trackStarted(item))
        #expect(player.stopReason == nil, "a song that started has no reason for having stopped")
        var waiting = playing
        waiting.isBuffering = true
        player.poll(waiting)
        #expect(answered.withLock { $0 } == 0, "a song still waited for is not its server answering")
        player.poll(playing)
        #expect(answered.withLock { $0 } == 1)
        player.poll(playing)
        #expect(answered.withLock { $0 } == 1, "once for each start")

        // And again: the entry that was reported before is reported again when it starts again.
        engineSays(.failed(item, StreamingCore.notAnsweringMessage))
        engineSays(.trackStarted(item))
        player.poll(playing)
        #expect(answered.withLock { $0 } == 2)
    }

    @Test("On then off leaves no task running and the provider stopped")
    func onThenOffLeavesNothing() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        scratch.notes.withLock { $0.hangs = true }
        let id = CountingProvider.providerID
        let app = model(scratch)
        app.setOn(true, id)
        #expect(await app.signIn(id, name: "Home", request: ProviderSignIn(server: "", user: "listener", secret: .password("x"))) == nil)
        // The listing that never ends is running.
        #expect(await until { scratch.notes.withLock { $0.asked.contains("library") } })
        #expect(app.core.runningTaskCount == 1)

        app.setOn(false, id)
        #expect(scratch.notes.withLock { $0.stopped } == 1)
        #expect(await until { app.core.runningTaskCount == 0 })
        #expect(app.core.enabled.isEmpty)
        #expect(app.accounts(id).isEmpty)
        // Nothing can be started for a provider that is off.
        #expect(app.core.start(id) {} == nil)
        #expect(app.core.provider(id, account: "any") == nil)
        let asked = scratch.notes.withLock { $0.asked }
        try await Task.sleep(for: .milliseconds(100))
        #expect(scratch.notes.withLock { $0.asked } == asked)
    }

    @Test("After signing in, the password and the token made from it are in no setting and in no file of the library")
    func credentialStaysInItsStore() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let server = try TinySubsonic()
        let port = try await server.start()
        defer { server.stop() }
        let id = OpenSubsonicProvider.providerID, password = "correct-horse-battery-staple-7731"
        let app = StreamingModel(library: scratch.library, defaults: scratch.defaults, player: nil, credentials: scratch.credentials)
        app.setOn(true, id)
        let failure = await app.signIn(id, name: "", request: ProviderSignIn(server: "http://127.0.0.1:\(port)", user: "listener", secret: .password(password)))
        #expect(failure == nil)
        let account = try #require(app.accounts(id).first)
        #expect(await until { !app.state(account).syncing && app.state(account).lastSync != nil })
        #expect(!server.requests.isEmpty)

        // What is kept, read back from the store: the token and salt in place of the password.
        let stored = try #require(account.streamedAccount.flatMap { scratch.credentials.load(provider: $0.provider, account: $0.account) })
        let kept = try JSONDecoder().decode(OpenSubsonicCredential.self, from: stored)
        #expect(kept.password == nil)
        let token = try #require(kept.token), salt = try #require(kept.salt)
        let secrets = [password, token, salt].map { Data($0.utf8) }

        // No setting holds any of it.
        scratch.defaults.synchronize()
        for (key, value) in scratch.defaults.dictionaryRepresentation() {
            let text = Data("\(key)=\(value)".utf8)
            for secret in secrets { #expect(text.range(of: secret) == nil, "a secret is in the setting \(key)") }
        }
        // No file under the data directory does: the library's database and its journal, the covers, and anything else written there.
        var files = 0
        let walker = try #require(FileManager.default.enumerator(at: scratch.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for url in walker.allObjects.compactMap({ $0 as? URL }) where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = try Data(contentsOf: url)
            files += 1
            for secret in secrets { #expect(data.range(of: secret) == nil, "a secret is in \(url.lastPathComponent)") }
        }
        #expect(files > 0)
        // The account's row names the provider and a random id, nothing of the sign-in.
        #expect(!account.path.contains("listener"))
        #expect(!account.path.contains("127.0.0.1"))

        // Signing out deletes the item.
        app.signOut(account)
        #expect(await until { scratch.credentials.isEmpty })
    }
}
