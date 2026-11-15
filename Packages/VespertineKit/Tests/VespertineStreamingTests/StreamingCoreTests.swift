//
// Vespertine: the rules every streaming provider is held to (docs/STREAMING.md), tested on the core that enforces them with a
// provider that talks to nothing: off is off, nothing kept unless the terms allow it, an honest verdict, and the library that
// holds a server's songs beside the files.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineAudio
@testable import VespertineLibrary
@testable import VespertineStreaming

@Suite("Streaming core")
struct StreamingCoreTests {
    private func rig(policy: ProviderStoragePolicy = .transientCacheOnly, mode: ProviderPlaybackMode = .engine) throws
        -> (core: StreamingCore, database: LibraryDatabase, shared: Locked<FakeProvider.Shared>, credentials: MemoryCredentialStore, fileIDs: [Int64]) {
        let (database, ids) = try TestLibrary.files()
        let credentials = MemoryCredentialStore()
        let core = StreamingCore(database: database, credentials: credentials)
        let shared = Locked(FakeProvider.Shared())
        core.register(FakeProvider.descriptor(mode: mode, policy: policy, shared: shared))
        shared.withLock {
            $0.listing = ProviderLibrary(
                songs: [
                    // The album the files have too, and one only the server has.
                    TestLibrary.song("s1", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1, cover: "c1"),
                    TestLibrary.song("s2", title: "Low Tide", artist: "The Night Shift", album: "Quiet Hours", number: 2, cover: "c1"),
                    TestLibrary.song("s3", title: "Last Light 夜", artist: "Lena Marsh", album: "Longshore", number: 1, genre: "Ambient", suffix: "mp3", bits: nil, rate: nil),
                ],
                playlists: [StreamedPlaylist(id: "p1", name: "From the server", songIDs: ["s3", "s1"])],
                starred: ["s3"])
        }
        return (core, database, shared, credentials, ids)
    }

    // MARK: Off is off

    @Test("The switch's key is streaming.<id>.enabled, and it and the play reports are registered off")
    func defaults() throws {
        let suite = "streaming-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(StreamingCore.enabledKey("opensubsonic") == "streaming.opensubsonic.enabled")
        StreamingCore.registerDefaults(defaults, providers: ["opensubsonic", "fake"])
        #expect(defaults.object(forKey: "streaming.opensubsonic.enabled") as? Bool == false)
        #expect(defaults.object(forKey: "streaming.fake.enabled") as? Bool == false)
        #expect(defaults.object(forKey: StreamingCore.playReportsKey("opensubsonic")) as? Bool == false)
    }

    @Test("A provider that is off is never made, sends nothing, and its Keychain item is not read")
    func offMakesNothing() async throws {
        let (core, database, shared, credentials, _) = try rig()
        // An account from an earlier session, with its credential.
        try database.addStreamedSource(provider: "fake", account: "home", name: "Home server")
        try credentials.save(Data("secret".utf8), provider: "fake", account: "home")
        core.setEnabled([])

        #expect(core.provider("fake", account: "home") == nil)
        #expect(try core.accounts("fake").isEmpty)
        #expect(throws: StreamingError.off) { try core.addAccount("fake", name: "Another") }
        await #expect(throws: StreamingError.off) { try await core.sync("fake", account: "home") }
        #expect(core.start("fake") {} == nil)
        let ref = StreamLocation.Ref(provider: "fake", account: "home", id: "s1")
        #expect(throws: StreamingError.off) { _ = try StreamScheme.open(ref.url) }
        #expect(throws: StreamingError.off) { _ = try core.open(ref) }
        var song = TestLibrary.song("s1", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1)
            .track(location: ref.location, sourceID: 99, at: .now)
        song.id = 1000
        #expect(await core.reportPlayed(song) == false)
        await #expect(throws: StreamingError.off) { try await core.setStarred(true, track: song) }

        #expect(core.constructedCount == 0)
        #expect(shared.withLock { $0.made } == 0)
        #expect(shared.withLock { $0.asked }.isEmpty)
        #expect(credentials.loadCount == 0)
        #expect(core.runningTaskCount == 0)
    }

    @Test("While a provider is off every library query answers as if its account had never been added, and nothing is deleted")
    func offLeavesEveryQueryAlone() async throws {
        let (core, database, _, credentials, fileIDs) = try rig()
        core.setEnabled([])
        let before = try LibraryAnswers(database)

        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: "Home server")
        _ = try await core.provider("fake", account: account)?.signIn(ProviderSignIn(server: "https://music.example", user: "listener", secret: .password("pw")))
        let summary = try await core.sync("fake", account: account)
        #expect(summary.added == 3)
        #expect(summary.playlists == 1)
        // The listener plays one of the server's songs and puts another in a playlist of their own.
        let streamed = try database.allTracks().filter(\.isStreamed)
        #expect(streamed.count == 3)
        try database.recordHistory(try #require(streamed.first?.id), at: Date(timeIntervalSince1970: 1_700_000_400))
        let evenings = try #require(try database.playlists().first { $0.name == "Evenings" })
        try database.append(trackIDs: [try #require(streamed.last?.id)], to: try #require(evenings.id))

        let on = try LibraryAnswers(database)
        #expect(on.tracks.count == before.tracks.count + 3)
        #expect(on.albums.count == before.albums.count + 1, "the album both have is one album; the server's own is new")
        #expect(on.artists.count == before.artists.count + 1)
        #expect(on.genres.contains("Ambient"))
        #expect(on.playlists.count == before.playlists.count + 1)
        #expect(on.favorites.count == before.favorites.count + 1, "the song starred on the server")
        #expect(on.history.count == before.history.count + 1)
        #expect(on.search.count > before.search.count)
        #expect(on.searchSubstring.count == 1)
        #expect(on.stats.tracks == before.stats.tracks + 3)
        #expect(on.stats.bytes == before.stats.bytes, "a streamed song takes no room on disk")
        #expect(on.accounts.count == 1)
        #expect(on.folders == before.folders, "an account is not a folder")

        core.setEnabled([])
        let off = try LibraryAnswers(database)
        #expect(off.albums == before.albums)
        #expect(off.albumsByTitle == before.albumsByTitle)
        #expect(off.albumsOfArtist == before.albumsOfArtist)
        #expect(off.albumTracks == before.albumTracks)
        #expect(off.tracks == before.tracks)
        #expect(off.tracksByID == before.tracksByID)
        #expect(off.artists == before.artists)
        #expect(off.genres == before.genres)
        #expect(off.playlists == before.playlists)
        #expect(off.playlistTracks == before.playlistTracks)
        #expect(off.search == before.search)
        #expect(off.searchSubstring == before.searchSubstring)
        #expect(off.history == before.history)
        #expect(off.favorites == before.favorites)
        #expect(off.favoriteIDs == before.favoriteIDs)
        #expect(off.stats == before.stats)
        #expect(off.folders == before.folders)
        #expect(off.accounts == before.accounts)
        #expect(off == before)
        #expect(try database.tracks(ids: fileIDs).count == fileIDs.count)

        // Nothing was deleted: the rows and the credential are where they were, and come back with the switch.
        let rows = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM track") }
        #expect(rows == before.tracks.count + 3)
        #expect(!credentials.isEmpty)
        core.setEnabled(["fake"])
        #expect(try LibraryAnswers(database) == on)
    }

    @Test("A database nobody set a switch on shows everything (the command-line tools)")
    func untouchedDatabaseShowsAll() throws {
        let (database, _) = try TestLibrary.files()
        try database.addStreamedSource(provider: "fake", account: "home", name: nil)
        try database.writeStreamedSongs([TestLibrary.song("s1", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1)],
                                        provider: "fake", account: "home")
        #expect(database.shownProviders == nil)
        #expect(try database.allTracks().count == 4)
        database.shownProviders = []
        #expect(try database.allTracks().count == 3)
    }

    @Test("Turning a provider off stops it and leaves no task of its running")
    func offLeavesNothingRunning() async throws {
        let (core, _, shared, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        #expect(core.provider("fake", account: account) != nil)
        let began = Locked(false)
        let task = core.start("fake") {
            began.withLock { $0 = true }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(task != nil)
        #expect(await Patience.until { began.withLock { $0 } })
        #expect(core.runningTaskCount == 1)

        core.setEnabled([])
        #expect(shared.withLock { $0.stopped } == 1)
        #expect(await Patience.until { core.runningTaskCount == 0 })
        await task?.value
        #expect(core.provider("fake", account: account) == nil)
        #expect(core.start("fake") {} == nil)
        #expect(core.constructedCount == 1)
    }

    @Test("A task that ends by itself is forgotten")
    func finishedTasksAreForgotten() async throws {
        let (core, _, _, _, _) = try rig()
        core.setEnabled(["fake"])
        let task = core.start("fake") {}
        await task?.value
        #expect(await Patience.until { core.runningTaskCount == 0 })
    }

    // MARK: Keeping audio

    @Test("A provider whose terms allow only the transient cache has nothing pinned, kept or copied")
    func transientOnlyIsNeverKept() async throws {
        let (core, database, _, _, _) = try rig(policy: .transientCacheOnly)
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        _ = try await core.sync("fake", account: account)
        let streamed = try #require(try database.allTracks().first(where: \.isStreamed))
        let file = try #require(try database.allTracks().first { !$0.isStreamed })

        #expect(!core.mayKeep(streamed))
        #expect(throws: StreamingError.keepingRefused) { try core.checkKeeping(streamed) }
        #expect(core.mayKeep(file))
        #expect(throws: Never.self) { try core.checkKeeping(file) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NetworkCache(directory: directory, limitBytes: 1 << 30)
        cache.mayKeep = { core.mayKeep($0) }
        cache.request([streamed], offline: true)
        #expect(!cache.isPending(streamed))
        #expect(!cache.isOffline(streamed))
        #expect(cache.usage().queued == 0)
        let bytes = directory.appendingPathComponent("song.flac")
        try Data("not kept".utf8).write(to: bytes)
        #expect(!cache.adopt(streamed, from: bytes))
        #expect(!cache.isAvailable(streamed))
        #expect(cache.usage().cachedFiles == 0)
    }

    @Test("The cache refuses a streamed song by default, whatever its provider says")
    func cacheRefusesStreamedByDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NetworkCache(directory: directory, limitBytes: 1 << 30)
        let ref = StreamLocation.Ref(provider: "fake", account: "home", id: "s1")
        let streamed = TestLibrary.song("s1", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1)
            .track(location: ref.location, sourceID: 1, at: .now)
        cache.request([streamed], offline: true)
        #expect(!cache.isPending(streamed))
        #expect(cache.usage().queued == 0)
    }

    @Test("A provider whose terms allow keeping says so, with where they do")
    func offlineAllowedMayKeep() async throws {
        let (core, database, _, _, _) = try rig(policy: .offlineAllowed(termsReference: "https://music.example/terms"))
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        _ = try await core.sync("fake", account: account)
        let streamed = try #require(try database.allTracks().first(where: \.isStreamed))
        #expect(core.mayKeep(streamed))
        #expect(ProviderStoragePolicy.offlineAllowed(termsReference: "x").allowsKeeping)
        #expect(!ProviderStoragePolicy.transientCacheOnly.allowsKeeping)
    }

    // MARK: The verdict

    @Test("A provider's own player is never bit-perfect, and neither is a converted stream")
    func verdict() {
        #expect(StreamVerdict.mayBeBitPerfect(mode: .engine, converted: false))
        #expect(!StreamVerdict.mayBeBitPerfect(mode: .engine, converted: true))
        #expect(!StreamVerdict.mayBeBitPerfect(mode: .external, converted: false))
        #expect(!StreamVerdict.mayBeBitPerfect(mode: .external, converted: true))
    }

    @Test("A stream of another size or container than the server lists is converted; what can't be told is not")
    func conversion() {
        let listed = StreamListing(size: 1000, suffix: "flac")
        #expect(!StreamVerdict.isConverted(listed: listed, size: 1000, fileExtension: "flac"))
        #expect(StreamVerdict.isConverted(listed: listed, size: 400, fileExtension: "flac"))
        #expect(StreamVerdict.isConverted(listed: listed, size: 1000, fileExtension: "mp3"))
        #expect(!StreamVerdict.isConverted(listed: StreamListing(size: 1000, suffix: "aif"), size: 1000, fileExtension: "aiff"))
        #expect(!StreamVerdict.isConverted(listed: StreamListing(size: 1000, suffix: "alac"), size: 1000, fileExtension: "m4a"))
        #expect(!StreamVerdict.isConverted(listed: StreamListing(), size: 123, fileExtension: "mp3"))
        #expect(StreamVerdict.isConverted(listed: StreamListing(size: 0, suffix: "flac"), size: 123, fileExtension: "ogg"))
    }

    @Test("Opening a song notes whether what arrived is the file the server lists")
    func openNotesConversion() async throws {
        let (core, _, shared, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        _ = try await core.sync("fake", account: account)
        shared.withLock {
            $0.streams["s1"] = (Data(count: 30_000_000), "flac")   // the file as listed
            $0.streams["s2"] = (Data(count: 4_000_000), "mp3")     // converted on the way
        }
        let same = StreamLocation.Ref(provider: "fake", account: account, id: "s1")
        let other = StreamLocation.Ref(provider: "fake", account: account, id: "s2")
        #expect(StreamFindings.finding(cacheKey: same.cacheKey) == nil)
        _ = try StreamScheme.open(same.url)
        _ = try StreamScheme.open(other.url)
        #expect(StreamFindings.finding(cacheKey: same.cacheKey) == .init(converted: false, fileExtension: "flac", size: 30_000_000))
        #expect(StreamFindings.finding(cacheKey: other.cacheKey) == .init(converted: true, fileExtension: "mp3", size: 4_000_000))
    }

    @Test("A provider with a player of its own hands the engine no stream")
    func externalHasNoStream() async throws {
        let (core, _, _, _, _) = try rig(mode: .external)
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        #expect(throws: StreamingError.unsupported) { _ = try core.open(StreamLocation.Ref(provider: "fake", account: account, id: "s1")) }
    }

    @Test("While the server asked to wait, a song is not opened")
    func waitingRefusesStreams() async throws {
        let (core, _, shared, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        shared.withLock { $0.waitingUntil = Date().addingTimeInterval(30) }
        do {
            _ = try core.open(StreamLocation.Ref(provider: "fake", account: account, id: "s1"))
            Issue.record("opened while waiting")
        } catch StreamingError.askedToWait(let seconds) {
            #expect(seconds > 0 && seconds <= 30)
        }
        #expect(!shared.withLock { $0.asked }.contains("open s1"))
    }

    @Test("A format the server only lists is marked ≈ until the song is read")
    func listedFormatIsMarked() async throws {
        let (core, database, _, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        _ = try await core.sync("fake", account: account)
        let lossy = try #require(try database.allTracks().first { $0.title.hasPrefix("Last Light") })
        #expect(lossy.formatSummary == "MP3 ≈", "no rate is listed, so none is claimed")
        var listed = try #require(try database.allTracks().first { $0.isStreamed && $0.title == "Lamplight" })
        #expect(listed.formatSummary == "FLAC · 24/96 ≈")
        #expect(try database.streamedInfo(trackID: try #require(listed.id))?.listed == true)
        let longshore = try #require(try database.albums().first { $0.title == "Longshore" })
        #expect(longshore.formatSummary.hasSuffix(" ≈"))

        // Read: it was a 16-bit file all along.
        let read = ConfirmedStreamFormat(codec: "FLAC", isLossless: true, isDSD: false, sampleRate: 44_100, bitDepth: 16, channels: 2, converted: false)
        #expect(try database.confirmStreamedFormat(read, location: listed.location))
        #expect(try !database.confirmStreamedFormat(read, location: listed.location), "the same again changes nothing")
        listed = try #require(try database.tracks(ids: [listed.id!]).first)
        #expect(listed.formatSummary == "FLAC · 16/44.1")
        #expect(try database.streamedInfo(trackID: listed.id!) == StreamedTrackInfo(albumId: "al-Quiet Hours", coverArt: "c1", suffix: "flac", listed: false, converted: false))

        // The next sync keeps what was read while the server's file is the same size, and lists again when it is not.
        _ = try await core.sync("fake", account: account)
        #expect(try database.tracks(ids: [listed.id!]).first?.formatSummary == "FLAC · 16/44.1")
        try database.writeStreamedSongs([TestLibrary.song("s1", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1, size: 31_000_000)],
                                        provider: "fake", account: account)
        #expect(try database.tracks(ids: [listed.id!]).first?.formatSummary == "FLAC · 24/96 ≈")
    }

    // MARK: The library

    @Test("An album the files and a server both have is one album with two copies, and the files lead at equal quality")
    func oneAlbumTwoCopies() async throws {
        let (core, database, _, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        _ = try await core.sync("fake", account: account)
        let album = try #require(try database.albums().first { $0.title == "Quiet Hours" })
        #expect(album.trackCount == 4)
        #expect(!album.formatSummary.hasSuffix("≈"), "the files were read at the album's format, so it is not a guess")
        let copies = LibraryCopies.analyze(try database.tracks(albumKey: album.key))
        #expect(copies.copies.count == 2)
        #expect(copies.songs.count == 2)
        #expect(copies.songs.allSatisfy { $0.tracks.count == 2 })
        #expect(copies.copies.filter(\.isStreamed).count == 1)
        let best = try #require(copies.bestCopy(multichannel: false))
        #expect(!best.isStreamed)
    }

    @Test("A sync keeps plays and ratings, hides what the server dropped, and mirrors its playlists and stars")
    func syncAgain() async throws {
        let (core, database, shared, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: "Home server")
        _ = try await core.sync("fake", account: account)
        let first = try #require(try database.allTracks().first { $0.isStreamed && $0.title == "Lamplight" })
        try database.markPlayed(try #require(first.id))
        try database.setRating(4, trackIDs: [first.id!])
        #expect(try database.favoriteTracks().contains { $0.title.hasPrefix("Last Light") })
        let mirrored = try #require(try database.playlists().first { $0.name == "From the server" })
        #expect(try database.tracks(in: mirrored).map(\.title) == ["Last Light 夜", "Lamplight"])
        #expect(try database.streamedPlaylistIDs() == [try #require(mirrored.id)])

        shared.withLock {
            $0.listing.songs.removeAll { $0.id == "s3" }
            $0.listing.playlists = [StreamedPlaylist(id: "p2", name: "Another", songIDs: ["s2"])]
            $0.listing.starred = ["s1"]
        }
        let summary = try await core.sync("fake", account: account)
        #expect(summary.added == 0)
        #expect(summary.updated == 2)
        #expect(summary.removed == 1)
        let again = try #require(try database.tracks(ids: [first.id!]).first)
        #expect(again.playCount == 1)
        #expect(again.rating == 4)
        #expect(again.addedAt == first.addedAt)
        #expect(try !database.allTracks().contains { $0.title.hasPrefix("Last Light") })
        // (A new library also has the two smart playlists every library starts with.)
        let names = Set(try database.playlists().map(\.name))
        #expect(names.isSuperset(of: ["All jazz", "Another", "Evenings"]))
        #expect(!names.contains("From the server"), "a playlist the server no longer has goes")
        #expect(try database.favoriteTracks().filter(\.isStreamed).map(\.title) == ["Lamplight"])
        #expect(try database.favoriteTracks().contains { !$0.isStreamed }, "a file's favorite is not the server's to remove")
    }

    @Test("Covers are fetched once for each of the server's cover ids")
    func covers() async throws {
        let (core, database, shared, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = ArtworkStore(directory: directory)
        let summary = try await core.sync("fake", account: account, artwork: artwork)
        #expect(shared.withLock { $0.asked.filter { $0 == "cover c1" }.count } == 1)
        #expect(summary.covers <= 1)
        _ = try await core.sync("fake", account: account, artwork: artwork)
        if summary.covers == 1 {
            #expect(shared.withLock { $0.asked.filter { $0 == "cover c1" }.count } == 1, "a cover the library has is not asked for again")
            #expect(try database.allTracks().filter { $0.isStreamed && $0.artworkKey != nil }.count == 2)
        }
    }

    @Test("Removing an account signs it out and takes its songs, playlists and Keychain item with it")
    func removeAccount() async throws {
        let (core, database, _, credentials, _) = try rig()
        core.setEnabled(["fake"])
        let before = try LibraryAnswers(database)
        let account = try core.addAccount("fake", name: "Home server")
        _ = try await core.provider("fake", account: account)?.signIn(ProviderSignIn(server: "https://music.example", user: "listener", secret: .apiKey("k")))
        #expect(!credentials.isEmpty)
        _ = try await core.sync("fake", account: account)
        try await core.removeAccount("fake", account: account)
        #expect(credentials.isEmpty)
        #expect(try LibraryAnswers(database) == before)
        let rows = try await database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM streamedTrack"), try Int.fetchOne(db, sql: "SELECT count(*) FROM streamedPlaylist"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM track WHERE filePath = ''"))
        }
        #expect(rows.0 == 0 && rows.1 == 0 && rows.2 == 0)
    }

    @Test("The migration adds two empty tables and no column to the ones a library has")
    func migration() async throws {
        let (database, _) = try TestLibrary.files()
        let found = try await database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM streamedTrack"), try Int.fetchOne(db, sql: "SELECT count(*) FROM streamedPlaylist"),
             try db.columns(in: "source").map(\.name), try db.columns(in: "track").map(\.name))
        }
        #expect(found.0 == 0 && found.1 == 0)
        #expect(!found.2.contains { $0.lowercased().contains("provider") || $0.lowercased().contains("account") })
        #expect(!found.3.contains { $0.lowercased().contains("stream") || $0.lowercased().contains("listed") })
    }

    @Test("A song's place names its provider, account and id, and nothing of the server or the credential")
    func locations() throws {
        let ref = StreamLocation.Ref(provider: "opensubsonic", account: "3f2a", id: "tr-1/a b")
        #expect(ref.location == "vespertine-stream://opensubsonic/3f2a/tr-1%2Fa%20b")
        #expect(StreamLocation.ref(ref.location) == ref)
        #expect(StreamLocation.ref(ref.url) == ref)
        #expect(ref.cacheKey == "stream:opensubsonic:3f2a:tr-1%2Fa%20b")
        #expect(StreamLocation.account(of: ref.location)?.provider == "opensubsonic")
        #expect(StreamLocation.ref("vespertine-stream://opensubsonic/3f2a") == nil)
        #expect(StreamLocation.ref("/Volumes/test-mac/Music/a.flac") == nil)
        let source = LibrarySource(path: StreamLocation.sourcePath(provider: "opensubsonic", account: "3f2a"), mode: .reference, name: "Home server")
        #expect(source.isStreamed)
        #expect(source.displayName == "Home server")
    }

    // MARK: What the server is told

    @Test("The server is told what was played only after the listener turns that on")
    func playReports() async throws {
        let (core, database, shared, _, _) = try rig()
        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: nil)
        _ = try await core.sync("fake", account: account)
        let streamed = try #require(try database.allTracks().first { $0.isStreamed && $0.title == "Lamplight" })
        let file = try #require(try database.allTracks().first { !$0.isStreamed })

        #expect(core.playReports.isEmpty)
        #expect(await core.reportPlayed(streamed) == false)
        #expect(!shared.withLock { $0.asked }.contains("played s1"))

        core.playReports = ["fake"]
        #expect(await core.reportPlayed(file) == false, "a file has no server to tell")
        #expect(await core.reportPlayed(streamed))
        #expect(shared.withLock { $0.asked.filter { $0 == "played s1" }.count } == 1)

        try await core.setStarred(true, track: streamed)
        try await core.setStarred(false, track: streamed)
        #expect(shared.withLock { $0.asked }.suffix(2) == ["star s1", "unstar s1"])
    }

    @Test("The library's own counts leave out a server's songs: its only album and artist are not counted, and the shared album stays")
    func fileCounts() async throws {
        let (core, database, _, _, fileIDs) = try rig()
        core.setEnabled([])
        let before = try database.stats()
        #expect(try database.stats(filesOnly: true) == before)

        core.setEnabled(["fake"])
        let account = try core.addAccount("fake", name: "Home server")
        _ = try await core.provider("fake", account: account)?.signIn(ProviderSignIn(server: "https://music.example", user: "listener", secret: .password("pw")))
        _ = try await core.sync("fake", account: account)

        let all = try database.stats()
        #expect(all.tracks == fileIDs.count + 3)
        #expect(all.albums == before.albums + 1)
        #expect(try database.stats(filesOnly: true) == before)
    }
}
