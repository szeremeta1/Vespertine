//
// Vespertine: the OpenSubsonic provider against a server on 127.0.0.1: signing in with an API key and with a token, walking
// the library a page at a time, search, stars, a song's file byte for byte and from the middle, a converted stream told for
// what it is, a credential the server stops accepting, and a server that stops answering.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineAudio
@testable import VespertineLibrary
@testable import VespertineOpenSubsonic
@testable import VespertineStreaming

@Suite("OpenSubsonic")
struct OpenSubsonicTests {
    private func credential(_ store: MemoryCredentialStore, account: String = "home") throws -> OpenSubsonicCredential {
        let data = try #require(store.load(provider: "opensubsonic", account: account))
        return try JSONDecoder().decode(OpenSubsonicCredential.self, from: data)
    }

    /// A server with `albums` albums of `songsEach` songs, and a provider for it that is not signed in yet.
    private func rig(albums: Int = 3, songsEach: Int = 2, pageSize: Int = 500, timeout: TimeInterval = 20, gate: RequestGate = RequestGate()) async throws
        -> (server: FakeSubsonic, provider: OpenSubsonicProvider, store: MemoryCredentialStore) {
        let server = try await FakeSubsonic()
        server.change { state in
            for album in 0..<albums {
                for song in 0..<songsEach {
                    let id = "song-\(album)-\(song)"
                    state.songs.append(.init(id: id, title: "Song \(album) \(song)", album: String(format: "Album %04d", album), albumId: "al-\(album)",
                                             artist: "Artist \(album % 5)", track: song + 1, data: FakeSubsonic.flac(bytes: 4096, seed: UInt32(album * 100 + song))))
                }
            }
        }
        let store = MemoryCredentialStore()
        let provider = OpenSubsonicProvider(account: "home", credentials: store, timeout: timeout, gate: gate, albumPageSize: pageSize)
        return (server, provider, store)
    }

    private func signIn(_ provider: OpenSubsonicProvider, _ server: FakeSubsonic) async throws {
        _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "", secret: .apiKey("key-for-listener")))
    }

    // MARK: Signing in

    @Test("An API key signs in, is the only credential sent, and is what the Keychain item holds")
    func apiKey() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        #expect(await provider.session() == .signedOut)
        let session = try await provider.signIn(ProviderSignIn(server: server.address, user: "", secret: .apiKey("key-for-listener")))
        #expect(session == .signedIn(user: "listener"), "the name comes from the server's tokenInfo")
        #expect(await provider.session() == .signedIn(user: "listener"))
        for request in server.requests {
            #expect(request.query["apiKey"] == "key-for-listener")
            #expect(request.query["u"] == nil && request.query["p"] == nil && request.query["t"] == nil)
            #expect(request.query["c"] == "Vespertine" && request.query["f"] == "json" && request.query["v"] == "1.16.1")
        }
        let kept = try credential(store)
        #expect(kept == OpenSubsonicCredential(server: server.address, user: "listener", apiKey: "key-for-listener"))
        #expect(await provider.rememberedSignIn()?.server == server.address)
    }

    @Test("A password signs in by token and salt: the password is never sent and never kept")
    func token() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        let session = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("correct horse")))
        #expect(session == .signedIn(user: "listener"))
        _ = try await provider.search("song", limit: 5)
        #expect(!server.requests.isEmpty)
        for request in server.requests {
            #expect(request.query["u"] == "listener")
            #expect(request.query["t"]?.count == 32 && (request.query["s"]?.count ?? 0) >= 6)
            #expect(request.query["p"] == nil && request.query["apiKey"] == nil)
            #expect(!request.query.values.contains { $0.contains("correct horse") })
        }
        let kept = try credential(store)
        #expect(kept.password == nil && kept.apiKey == nil)
        #expect(kept.token == OpenSubsonicCredential.token(password: "correct horse", salt: try #require(kept.salt)))
        #expect(!String(decoding: try #require(store.load(provider: "opensubsonic", account: "home")), as: UTF8.self).contains("correct horse"))
        // The token the API defines: MD5 of the password and then the salt (its documentation's own example).
        #expect(OpenSubsonicCredential.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
    }

    @Test("A server that takes no token gets the password, which is then the one thing that can be kept")
    func passwordOnly() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        server.change { $0.takesTokens = false }
        let session = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("correct horse")))
        #expect(session == .signedIn(user: "listener"))
        #expect(try credential(store).password == "correct horse")
        #expect(try credential(store).token == nil)
        #expect(server.requests.last?.query["p"] == "enc:636f727265637420686f727365")
        _ = try await provider.search("song", limit: 5)
    }

    @Test("A wrong password or key is refused and nothing is kept")
    func wrongCredential() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        await #expect(throws: StreamingError.signedOut) {
            _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("wrong")))
        }
        #expect(server.requests.count == 1, "a refused password is not tried again another way")
        await #expect(throws: StreamingError.signedOut) {
            _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "", secret: .apiKey("no-such-key")))
        }
        await #expect(throws: StreamingError.signedOut) {
            _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("")))
        }
        #expect(store.isEmpty)
        #expect(await provider.session() == .signedOut)
        await #expect(throws: StreamingError.signedOut) { _ = try await provider.search("song", limit: 5) }
    }

    @Test("A server that takes no API keys says so in its own words")
    func keysNotSupported() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        server.change { $0.takesAPIKeys = false }
        await #expect(throws: StreamingError.server("Provided authentication mechanism not supported.")) {
            _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "", secret: .apiKey("key-for-listener")))
        }
        #expect(store.isEmpty)
    }

    @Test("Something that is not an OpenSubsonic server is told apart")
    func notSubsonic() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        server.change { $0.mood = .notSubsonic }
        await #expect(throws: StreamingError.malformedAnswer) {
            _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("correct horse")))
        }
        #expect(store.isEmpty)
    }

    @Test("Signing out deletes the Keychain item")
    func signOut() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        #expect(!store.isEmpty)
        await provider.signOut()
        #expect(store.isEmpty)
        #expect(await provider.session() == .signedOut)
        let before = server.requests.count
        await #expect(throws: StreamingError.signedOut) { _ = try await provider.search("song", limit: 5) }
        #expect(server.requests.count == before, "nothing is sent without a credential")
    }

    // MARK: Addresses

    @Test("An address is https unless it says http; a trailing /rest goes; names and passwords in it are refused")
    func addresses() throws {
        #expect(try OpenSubsonicAddress.parse("music.example").absoluteString == "https://music.example")
        #expect(try OpenSubsonicAddress.parse(" https://music.example/ ").absoluteString == "https://music.example")
        #expect(try OpenSubsonicAddress.parse("https://music.example/navidrome/rest/").absoluteString == "https://music.example/navidrome")
        #expect(try OpenSubsonicAddress.parse("HTTP://192.0.2.7:4533").absoluteString == "http://192.0.2.7:4533")
        #expect(try OpenSubsonicAddress.parse("https://music.example/?x=1#top").absoluteString == "https://music.example")
        for bad in ["", "   ", "ftp://music.example", "https://listener:pw@music.example", "not an address", "https://"] {
            #expect(throws: StreamingError.badAddress) { _ = try OpenSubsonicAddress.parse(bad) }
        }
    }

    @Test("http is only for a server on the listener's own network")
    func httpOnlyLocal() async throws {
        #expect(OpenSubsonicAddress.isLocal([127, 0, 0, 1]))
        #expect(OpenSubsonicAddress.isLocal([10, 1, 2, 3]))
        #expect(OpenSubsonicAddress.isLocal([172, 16, 0, 1]) && OpenSubsonicAddress.isLocal([172, 31, 255, 254]))
        #expect(!OpenSubsonicAddress.isLocal([172, 32, 0, 1]))
        #expect(OpenSubsonicAddress.isLocal([192, 168, 1, 20]))
        #expect(OpenSubsonicAddress.isLocal([169, 254, 3, 4]))
        #expect(OpenSubsonicAddress.isLocal([100, 64, 0, 1]) && OpenSubsonicAddress.isLocal([100, 127, 255, 254]))
        #expect(!OpenSubsonicAddress.isLocal([100, 128, 0, 1]))
        #expect(!OpenSubsonicAddress.isLocal([192, 0, 2, 7]))
        #expect(!OpenSubsonicAddress.isLocal([8, 8, 8, 8]))
        #expect(!OpenSubsonicAddress.isLocal([0, 0, 0, 0]) && !OpenSubsonicAddress.isLocal([224, 0, 0, 251]))
        var v6 = [UInt8](repeating: 0, count: 16)
        v6[15] = 1
        #expect(OpenSubsonicAddress.isLocal(v6))
        v6 = [0xfd, 0x12] + [UInt8](repeating: 0, count: 13) + [1]
        #expect(OpenSubsonicAddress.isLocal(v6))
        v6 = [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1]
        #expect(OpenSubsonicAddress.isLocal(v6))
        v6 = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
        #expect(!OpenSubsonicAddress.isLocal(v6))
        v6 = [UInt8](repeating: 0, count: 10) + [0xff, 0xff, 192, 0, 2, 7]
        #expect(!OpenSubsonicAddress.isLocal(v6))

        #expect(throws: StreamingError.insecureAddress) { try OpenSubsonicAddress.check(URL(string: "http://192.0.2.7:4533")!) }
        #expect(throws: Never.self) { try OpenSubsonicAddress.check(URL(string: "http://127.0.0.1:4533")!) }
        #expect(throws: Never.self) { try OpenSubsonicAddress.check(URL(string: "https://192.0.2.7")!) }

        // Signing in to such an address is refused before anything is sent, and nothing is kept.
        let store = MemoryCredentialStore()
        let provider = OpenSubsonicProvider(account: "home", credentials: store)
        await #expect(throws: StreamingError.insecureAddress) {
            _ = try await provider.signIn(ProviderSignIn(server: "http://192.0.2.7:4533", user: "listener", secret: .password("correct horse")))
        }
        #expect(store.isEmpty)
    }

    @Test("A redirect to another host is not followed: the credential goes nowhere else")
    func redirects() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        let elsewhere = try await FakeSubsonic()
        defer { elsewhere.stop() }
        // "localhost" is another host than "127.0.0.1" as far as a credential is concerned.
        server.change { $0.mood = .redirect("http://localhost:\(elsewhere.port)") }
        await #expect(throws: StreamingError.status(302)) {
            _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("correct horse")))
        }
        #expect(elsewhere.requests.isEmpty)
        #expect(store.isEmpty)
    }

    // MARK: The library

    @Test("The library is listed a page of albums at a time, every album once, with playlists and stars")
    func paging() async throws {
        let (server, provider, _) = try await rig(albums: 123, songsEach: 2, pageSize: 50)
        defer { server.stop() }
        server.change { state in
            state.playlists = [("pl-1", "Late", ["song-2-1", "song-0-0"]), ("pl-2", "Empty", [])]
            state.starred = ["song-1-0", "song-122-1"]
        }
        try await signIn(provider, server)
        let progress = Locked([Int]())
        let library = try await provider.library { count in progress.withLock { $0.append(count) } }

        #expect(server.requests("getAlbumList2").map { $0.query["offset"] } == ["0", "50", "100"])
        #expect(server.requests("getAlbumList2").allSatisfy { $0.query["size"] == "50" && $0.query["type"] == "alphabeticalByName" })
        #expect(server.requests("getAlbum").count == 123)
        #expect(Set(server.requests("getAlbum").compactMap { $0.query["id"] }).count == 123)
        #expect(library.songs.count == 246)
        #expect(Set(library.songs.map(\.id)).count == 246)
        #expect(library.songs.prefix(4).map(\.id) == ["song-0-0", "song-0-1", "song-1-0", "song-1-1"], "in the server's order")
        #expect(progress.withLock { $0 }.last == 246)
        #expect(progress.withLock { $0 } == progress.withLock { $0 }.sorted())
        #expect(library.playlists == [StreamedPlaylist(id: "pl-1", name: "Late", songIDs: ["song-2-1", "song-0-0"]), StreamedPlaylist(id: "pl-2", name: "Empty", songIDs: [])])
        #expect(library.starred == ["song-1-0", "song-122-1"])

        let song = try #require(library.songs.first)
        #expect(song.title == "Song 0 0" && song.album == "Album 0000" && song.albumId == "al-0" && song.artist == "Artist 0")
        #expect(song.trackNumber == 1 && song.discNumber == 1 && song.year == 2001 && song.genre == "Jazz")
        #expect(song.suffix == "flac" && song.bitDepth == 24 && song.sampleRate == 96_000 && song.channels == 2)
        #expect(song.size == 4096 && song.duration == 200 && song.coverArt == "cover-al-0")
        #expect(song.isrc == "ZZTST2600001" && song.musicBrainzRecordingID == "mb-song-0-0")
        #expect(song.replayGain?.trackGain == -6.5 && song.replayGain?.albumGain == -7.25 && song.replayGain?.albumPeak == nil)
        #expect(library.songs[1].trackNumber == 2, "a number sent as a string is still a number")
    }

    @Test("A server that answers the same page whatever the offset does not keep the walk going")
    func stuckPaging() async throws {
        let (server, provider, _) = try await rig(albums: 30, songsEach: 1, pageSize: 10)
        defer { server.stop() }
        server.change { $0.ignoresOffset = true }
        try await signIn(provider, server)
        let library = try await provider.library { _ in }
        #expect(server.requests("getAlbumList2").count == 2)
        #expect(library.songs.count == 10)
    }

    @Test("Search asks for songs only, and an album's songs come from getAlbum")
    func searchAndAlbum() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        let found = try await provider.search("  song 1 ", limit: 7)
        #expect(found.map(\.id) == ["song-1-0", "song-1-1"])
        let request = try #require(server.requests("search3").last)
        #expect(request.query["query"] == "song 1" && request.query["songCount"] == "7")
        #expect(request.query["albumCount"] == "0" && request.query["artistCount"] == "0")
        #expect(try await provider.search("   ", limit: 7).isEmpty)
        #expect(server.requests("search3").count == 1, "nothing is asked for an empty search")
        #expect(try await provider.search("nothing like it", limit: 7).isEmpty)

        #expect(try await provider.tracks(of: "al-2").map(\.id) == ["song-2-0", "song-2-1"])
        await #expect(throws: StreamingError.server("The requested data was not found.")) { _ = try await provider.tracks(of: "al-none") }
        #expect(try await provider.artists().map(\.name) == ["Artist 0", "Artist 1", "Artist 2"])
        #expect(try await provider.artists().first?.albumCount == 1)
    }

    @Test("Starring and unstarring reach the server; what was played is sent with its time")
    func starAndReport() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        try await provider.setStarred(true, songID: "song-0-1")
        #expect(server.read(\.starred) == ["song-0-1"])
        try await provider.setStarred(false, songID: "song-0-1")
        #expect(server.read(\.starred).isEmpty)
        await #expect(throws: StreamingError.server("The requested data was not found.")) { try await provider.setStarred(true, songID: "no-such") }

        try await provider.reportPlayed(songID: "song-1-0", at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(server.read { $0.scrobbles.map(\.id) } == ["song-1-0"])
        #expect(server.read { $0.scrobbles.first?.time } == "1800000000000")
        #expect(server.requests("scrobble").first?.query["submission"] == "true")
    }

    @Test("A cover's bytes come back as they are; a failure in their place is the server's words")
    func covers() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        let picture = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4])
        server.change { $0.covers["cover-al-0"] = picture }
        try await signIn(provider, server)
        #expect(try await provider.artwork("cover-al-0") == picture)
        await #expect(throws: StreamingError.server("The requested data was not found.")) { _ = try await provider.artwork("cover-none") }
    }

    // MARK: Playing

    @Test("A song is asked for with format=raw and arrives byte for byte")
    func streamIsTheFile() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        let file = FakeSubsonic.flac(bytes: 300_000, seed: 7)
        server.change { $0.songs[0].data = file }
        try await signIn(provider, server)
        let reader = try provider.openStream("song-0-0")
        defer { reader.cancel() }
        #expect(reader.size == 300_000)
        #expect(reader.fileExtension == "flac")
        var read = Data()
        while read.count < file.count {
            let part = try reader.read(at: Int64(read.count), count: 50_000)
            #expect(!part.isEmpty)
            if part.isEmpty { break }
            read.append(part)
        }
        #expect(read == file)
        let requests = server.requests("stream")
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.query["format"] == "raw" && $0.query["id"] == "song-0-0" && $0.query["apiKey"] == "key-for-listener" })
        #expect(requests.allSatisfy { $0.range != nil }, "always by ranges")
    }

    @Test("Seeking reads from where it lands, without fetching what comes before")
    func seekByRange() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        let file = FakeSubsonic.flac(bytes: 4_000_000, seed: 11)
        server.change { $0.songs[0].data = file }
        try await signIn(provider, server)
        let reader = try provider.openStream("song-0-0")
        defer { reader.cancel() }
        let part = try reader.read(at: 3_500_000, count: 4096)
        #expect(part == file.subdata(in: 3_500_000..<3_504_096))
        let ranges = server.requests("stream").compactMap(\.range)
        #expect(ranges.contains { $0.hasPrefix("bytes=3500000-") })
        #expect(server.read(\.bytesServed) < 1_000_000, "the three megabytes before the seek were never sent")
    }

    @Test("A stream the server converted is told for what it is, and is never bit-perfect")
    func convertedStream() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        let file = FakeSubsonic.flac(bytes: 300_000, seed: 3)
        server.change { state in
            state.songs[0].data = file
            state.songs[1].data = file
            // The server is set to convert this one whatever is asked.
            state.songs[1].converted = (FakeSubsonic.mp3(bytes: 40_000), "audio/mpeg")
        }
        try await signIn(provider, server)

        let database = try LibraryDatabase.inMemory()
        let core = StreamingCore(database: database, credentials: store)
        core.register(ProviderDescriptor(id: "opensubsonic", name: "OpenSubsonic", capabilities: OpenSubsonicProvider.descriptor.capabilities,
                                         playbackMode: .engine, storagePolicy: OpenSubsonicProvider.descriptor.storagePolicy) { _, _ in provider })
        core.setEnabled(["opensubsonic"])
        defer { core.setEnabled([]) }
        try database.addStreamedSource(provider: "opensubsonic", account: "home", name: "Home server")
        _ = try await core.sync("opensubsonic", account: "home")

        let original = StreamLocation.Ref(provider: "opensubsonic", account: "home", id: "song-0-0")
        let converted = StreamLocation.Ref(provider: "opensubsonic", account: "home", id: "song-0-1")
        let first = try StreamScheme.open(original.url)
        let second = try StreamScheme.open(converted.url)
        defer { first.cancel(); second.cancel() }
        #expect(StreamFindings.finding(cacheKey: original.cacheKey) == .init(converted: false, fileExtension: "flac", size: 300_000))
        #expect(StreamFindings.finding(cacheKey: converted.cacheKey) == .init(converted: true, fileExtension: "mp3", size: 40_000))
        #expect(server.requests("stream").allSatisfy { $0.query["format"] == "raw" }, "raw was asked for all the same")

        #expect(StreamVerdict.mayBeBitPerfect(mode: .engine, converted: false))
        #expect(!StreamVerdict.mayBeBitPerfect(mode: .engine, converted: true))

        // The signal path of a song that would otherwise be bit-perfect says who converted it.
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2)
        let plan = FormatPlanner.plan(source: source, device: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false))
        let applied = AppliedFormat(sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 2, exclusive: false, bufferFrames: 512)
        var path = SignalPath(source: source, decoderName: "test", plan: plan, applied: applied, deviceName: "Test", deviceUID: "Test",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
        #expect(path.isBitPerfect && path.statusLine == "BIT-PERFECT")
        path.convertedByServer = true
        #expect(!path.isBitPerfect)
        #expect(!path.isUntouched)
        #expect(path.statusLine == "CONVERTED BY THE SERVER")

        // Reading it replaces the listed format and keeps the note.
        let lossy = ConfirmedStreamFormat(codec: "MP3", isLossless: false, isDSD: false, sampleRate: 44_100, bitDepth: nil, channels: 2, converted: true)
        #expect(try database.confirmStreamedFormat(lossy, location: converted.location))
        let track = try #require(try database.allTracks().first { $0.location == converted.location })
        #expect(!track.isLossless && !track.formatIsListed)
        #expect(try database.streamedInfo(trackID: try #require(track.id))?.converted == true)
    }

    // MARK: When it goes wrong

    @Test("After the password changes the account is signed out cleanly: its secret is gone and nothing more is sent")
    func passwordChanged() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("correct horse")))
        _ = try await provider.search("song", limit: 5)
        server.change { $0.passwords["listener"] = "a new one" }

        await #expect(throws: StreamingError.signedOut) { _ = try await provider.search("song", limit: 5) }
        #expect(await provider.session() == .signedOut)
        let kept = try credential(store)
        #expect(kept == OpenSubsonicCredential(server: server.address, user: "listener"), "the address and the name stay for signing in again")
        #expect(!kept.canSignIn)
        #expect(await provider.rememberedSignIn()?.user == "listener")

        let before = server.requests.count
        await #expect(throws: StreamingError.signedOut) { _ = try await provider.search("song", limit: 5) }
        await #expect(throws: StreamingError.signedOut) { _ = try await provider.library { _ in } }
        #expect(throws: StreamingError.signedOut) { _ = try provider.openStream("song-0-0") }
        #expect(server.requests.count == before, "nothing is sent with a credential the server refused")

        // Signing in again with the new password works.
        #expect(try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("a new one"))) == .signedIn(user: "listener"))
        #expect(try await provider.search("song 0", limit: 5).count == 2)
    }

    @Test("A 401 from in front of the server signs out the same way")
    func unauthorizedStatus() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        server.change { $0.mood = .unauthorized }
        await #expect(throws: StreamingError.signedOut) { _ = try await provider.search("song", limit: 5) }
        #expect(try !credential(store).canSignIn)
        #expect(await provider.session() == .signedOut)
    }

    @Test("A song opened with a credential the server no longer takes says signed out, not “can't decode”")
    func streamRefusedCredential() async throws {
        let (server, provider, store) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        server.change { $0.apiKeys = [:] }
        #expect(throws: StreamingError.signedOut) { _ = try provider.openStream("song-0-0") }
        #expect(try !credential(store).canSignIn)
    }

    @Test("A song the server doesn't have says so in the server's words")
    func streamMissing() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        #expect(throws: StreamingError.server("The requested data was not found.")) { _ = try provider.openStream("no-such-song") }
        #expect(await provider.session() == .signedIn(user: "listener"), "a missing song is no reason to sign out")
    }

    @Test("When the server asks to wait, nothing more is sent until it said")
    func askedToWait() async throws {
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let gate = RequestGate(clock: { now.withLock { $0 } })
        let (server, provider, _) = try await rig(gate: gate)
        defer { server.stop() }
        try await signIn(provider, server)
        server.change { $0.mood = .tooMany(retryAfter: 120) }
        await #expect(throws: StreamingError.askedToWait(seconds: 120)) { _ = try await provider.search("song", limit: 5) }
        #expect(provider.waitingUntil == now.withLock { $0 }.addingTimeInterval(120))

        server.change { $0.mood = .fine }
        let before = server.requests.count
        await #expect(throws: StreamingError.askedToWait(seconds: 120)) { _ = try await provider.search("song", limit: 5) }
        #expect(throws: StreamingError.askedToWait(seconds: 120)) { _ = try provider.openStream("song-0-0") }
        #expect(server.requests.count == before, "held back, not sent")
        #expect(await provider.session() == .signedIn(user: "listener"))

        now.withLock { $0 += 121 }
        #expect(provider.waitingUntil == nil)
        #expect(try await provider.search("song 0", limit: 5).count == 2)
    }

    @Test("A 429 that doesn't say how long is a minute's wait")
    func askedToWaitWithoutLength() async throws {
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (server, provider, _) = try await rig(gate: RequestGate(clock: { now.withLock { $0 } }))
        defer { server.stop() }
        try await signIn(provider, server)
        server.change { $0.mood = .tooMany(retryAfter: nil) }
        await #expect(throws: StreamingError.askedToWait(seconds: 60)) { _ = try await provider.search("song", limit: 5) }
        #expect(provider.waitingUntil == now.withLock { $0 }.addingTimeInterval(60))
    }

    @Test("A server that is gone gives the system's reason, without the address or the credential in it")
    func serverGone() async throws {
        let (server, provider, store) = try await rig()
        try await signIn(provider, server)
        server.stop()
        // The port stays closed: nothing listens there now.
        do {
            _ = try await provider.search("song", limit: 5)
            Issue.record("answered by a server that is gone")
        } catch StreamingError.notAnswering(let reason) {
            #expect(!reason.isEmpty)
            #expect(!reason.contains("key-for-listener") && !reason.contains("127.0.0.1") && !reason.contains("apiKey"))
            let sentence = try #require(StreamingError.notAnswering(reason).errorDescription)
            #expect(!sentence.contains("key-for-listener") && !sentence.contains("127.0.0.1"))
        }
        #expect(try credential(store).canSignIn, "not answering is no reason to sign out")
        #expect(await provider.session() == .signedIn(user: "listener"))
    }

    @Test("A server that accepts the connection and then says nothing is given up on")
    func serverSilent() async throws {
        let (server, provider, store) = try await rig(timeout: 1)
        defer { server.stop() }
        try await signIn(provider, server)
        server.change { $0.mood = .silent }
        do {
            _ = try await provider.search("song", limit: 5)
            Issue.record("answered by a server that says nothing")
        } catch StreamingError.notAnswering(let reason) {
            #expect(!reason.contains("key-for-listener"))
        }
        #expect(try credential(store).canSignIn)
    }

    @Test("A provider that was stopped sends nothing more")
    func stopped() async throws {
        let (server, provider, _) = try await rig()
        defer { server.stop() }
        try await signIn(provider, server)
        provider.stop()
        let before = server.requests.count
        await #expect(throws: StreamingError.off) { _ = try await provider.search("song", limit: 5) }
        #expect(throws: StreamingError.off) { _ = try provider.openStream("song-0-0") }
        #expect(server.requests.count == before)
    }

    // MARK: With the core

    @Test("Off: the server hears nothing and the Keychain item is not read. On: its songs sit in the library; off again they are gone from it")
    func throughTheCore() async throws {
        let (server, _, store) = try await rig(albums: 4, songsEach: 3)
        defer { server.stop() }
        server.change { state in
            state.covers["cover-al-0"] = Data([0x89, 0x50, 0x4e, 0x47, 9, 9])
            state.starred = ["song-3-2"]
            state.playlists = [("pl-1", "Late", ["song-2-1"])]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opensubsonic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(url: file)
        let core = StreamingCore(database: database, credentials: store)
        core.register(OpenSubsonicProvider.descriptor)

        core.setEnabled([])
        #expect(core.provider("opensubsonic", account: "home") == nil)
        #expect(server.requests.isEmpty)
        #expect(store.loadCount == 0)

        core.setEnabled(["opensubsonic"])
        defer { core.setEnabled([]) }
        let account = try core.addAccount("opensubsonic", name: "Home server")
        let provider = try #require(core.provider("opensubsonic", account: account))
        _ = try await provider.signIn(ProviderSignIn(server: server.address, user: "listener", secret: .password("correct horse")))
        let summary = try await core.sync("opensubsonic", account: account, artwork: ArtworkStore(directory: directory.appendingPathComponent("art")))
        #expect(summary.added == 12 && summary.playlists == 1)
        #expect(try database.allTracks().count == 12)
        #expect(try database.allTracks().allSatisfy { $0.isStreamed && $0.formatSummary == "FLAC · 24/96 ≈" })
        #expect(try database.albums().count == 4)
        #expect(try database.favoriteTracks().map(\.title) == ["Song 3 2"])
        #expect(try database.playlists().map(\.name) == ["Late"])
        #expect(try core.accounts("opensubsonic").map(\.displayName) == ["Home server"])

        // Nothing of the credential or the server's address is in the library's file.
        let kept = try credential(store, account: account)
        var bytes = try Data(contentsOf: file)
        for suffix in ["-wal", "-shm"] { bytes.append((try? Data(contentsOf: URL(fileURLWithPath: file.path + suffix))) ?? Data()) }
        for secret in ["correct horse", try #require(kept.token), try #require(kept.salt), "127.0.0.1:\(server.port)"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is in the library's file")
        }

        core.setEnabled([])
        #expect(try database.allTracks().isEmpty)
        #expect(try database.albums().isEmpty)
        #expect(try database.playlists().isEmpty)
        #expect(try database.favoriteTracks().isEmpty)
        #expect(try database.stats().tracks == 0)
        let before = server.requests.count
        await #expect(throws: StreamingError.off) { _ = try await core.sync("opensubsonic", account: account) }
        await #expect(throws: StreamingError.off) { _ = try await provider.search("song", limit: 5) }
        #expect(server.requests.count == before)
        #expect(!store.isEmpty, "turning it off deletes nothing")
    }
}
