//
// Vespertine: `tidal://track/<id>` in the playback cache: the registered opener resolves the track through the gate and reads its
// stream from the CDN (here a server on 127.0.0.1), and its failures come back as thrown errors with the user's wording.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineTidal

/// A `playbackinfopostpaywall` answer whose BTS manifest names `url`.
func btsPlaybackInfo(url: URL, codec: String = "flac", encryption: String = "NONE", audioMode: String = "STEREO",
                     quality: String = "LOSSLESS") -> FakeResponse {
    let manifest = #"{"mimeType": "audio/flac", "codecs": "\#(codec)", "encryptionType": "\#(encryption)", "urls": ["\#(url.absoluteString)"]}"#
    return FakeResponse(json: """
        {"trackId": 7, "assetPresentation": "FULL", "audioMode": "\(audioMode)", "audioQuality": "\(quality)",
         "manifestMimeType": "application/vnd.tidal.bts", "manifestHash": "fabricated",
         "manifest": "\(Data(manifest.utf8).base64EncodedString())", "bitDepth": 16, "sampleRate": 44100}
        """)
}

/// A DASH answer whose MPD has the fixture's three segments at `/dash/init.mp4` and `/dash/<n>.m4s` on `server`.
func dashPlaybackInfo(server: FakeHTTPServer, segments: Int) -> FakeResponse {
    let mpd = """
        <?xml version='1.0' encoding='UTF-8'?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
          <Period id="0"><AdaptationSet id="0" contentType="audio" mimeType="audio/mp4">
            <Representation id="0" codecs="flac" bandwidth="4800000" audioSamplingRate="96000">
              <SegmentTemplate timescale="96000" initialization="\(server.url("/dash/init.mp4"))" media="\(server.url("/dash/"))$Number$.m4s" startNumber="1">
                <SegmentTimeline><S d="96000" r="\(segments - 1)"/></SegmentTimeline>
              </SegmentTemplate>
            </Representation>
          </AdaptationSet></Period>
        </MPD>
        """
    return FakeResponse(json: """
        {"trackId": 7, "assetPresentation": "FULL", "audioMode": "STEREO", "audioQuality": "HI_RES_LOSSLESS",
         "manifestMimeType": "application/dash+xml", "manifestHash": "fabricated",
         "manifest": "\(Data(mpd.utf8).base64EncodedString())", "bitDepth": 24, "sampleRate": 96000}
        """)
}

/// The registry is process-wide: every test here registers `tidal`, one at a time.
@Suite("TIDAL playback registration", .serialized)
struct TidalPlaybackTests {
    private func cache() throws -> (NetworkPlaybackCache, URL) {
        let directory = try DASHFixture.temporaryDirectory("tidal-playback")
        return (NetworkPlaybackCache(directory: directory, budget: 64 << 20), directory)
    }

    @Test("URLs and cache keys: tidal://track/<id> and tidal:<id>")
    func addresses() {
        #expect(TidalPlayback.url(trackId: 7).absoluteString == "tidal://track/7")
        #expect(TidalPlayback.cacheKey(trackId: 7) == "tidal:7")
        #expect(TidalPlayback.trackId(from: URL(string: "tidal://track/123")!) == 123)
        #expect(TidalPlayback.trackId(from: URL(string: "tidal://album/123")!) == nil)
        #expect(TidalPlayback.trackId(from: URL(string: "tidal://track/x")!) == nil)
    }

    @Test("A BTS track: the cache entry for tidal://track/7 holds the file's bytes, resolved at playback priority")
    func btsEntry() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let file = try DASHFixture.source()
        server.serve("/audio/7.flac", file)
        let transport = FakeTransport { _ in btsPlaybackInfo(url: server.url("/audio/7.flac")) }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try cache.entry(key: TidalPlayback.cacheKey(trackId: 7), url: TidalPlayback.url(trackId: 7))
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.url.pathExtension == "flac")
        #expect(try Data(contentsOf: entry.url) == file)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url?.path.hasSuffix("tracks/7/playbackinfopostpaywall") == true)
    }

    @Test("The stream a track resolved to is remembered for the signal path (DASH or one file); unregistering forgets the reader")
    func remembersStreamAndUnregisters() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/audio/8.flac", try DASHFixture.source())
        let transport = FakeTransport { _ in btsPlaybackInfo(url: server.url("/audio/8.flac")) }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try cache.entry(key: TidalPlayback.cacheKey(trackId: 8), url: TidalPlayback.url(trackId: 8))
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(TidalPlayback.lastStream(trackId: 8)?.isDASH == false)
        #expect(TidalPlayback.lastStream(trackId: 9) == nil)
        TidalPlayback.unregister()
        #expect(!NetworkPlaybackCache.hasRemoteReader(scheme: "tidal"))
        #expect(throws: (any Error).self) { _ = try cache.entry(key: "tidal:10", url: TidalPlayback.url(trackId: 10)) }
    }

    @Test("A DASH track: the cache entry holds the remuxed FLAC")
    func dashEntry() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/dash/init.mp4", try DASHFixture.initSegment())
        let chunks = try DASHFixture.chunks()
        for (index, chunk) in chunks.enumerated() { server.serve("/dash/\(index + 1).m4s", chunk) }
        let transport = FakeTransport { _ in dashPlaybackInfo(server: server, segments: chunks.count) }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try cache.entry(key: "tidal:8", url: TidalPlayback.url(trackId: 8))
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.url.pathExtension == "flac")
        #expect(try Data(contentsOf: entry.url) == (try DASHFixture.remuxed()))
    }

    @Test("An expired URL mid-copy is resolved again through the gate and the copy is still the file")
    func renewsThroughGate() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let file = noise(3 << 20, seed: 21)
        server.serve("/audio/9.flac", file)
        server.expire("/audio/9.flac", afterBytes: 1 << 20)
        let tokens = Counter()
        let transport = FakeTransport { _ in btsPlaybackInfo(url: server.url("/audio/9.flac", token: "t\(tokens.next())")) }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try cache.entry(key: "tidal:9", url: TidalPlayback.url(trackId: 9))
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(try Data(contentsOf: entry.url) == file)
        #expect(transport.requests.count >= 2, "resolved again")
    }

    @Test("Dolby Atmos (E-AC-3) is read as one file and staged as .m4a, for the system renderer")
    func atmos() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/audio/atmos.mp4", noise(10_000))
        let transport = FakeTransport { _ in btsPlaybackInfo(url: server.url("/audio/atmos.mp4"), codec: "eac3", audioMode: "DOLBY_ATMOS") }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try cache.entry(key: "tidal:10", url: TidalPlayback.url(trackId: 10))
        #expect(entry.url.pathExtension == "m4a")
    }

    @Test("An encrypted stream throws from the entry, described as the spec words it")
    func encrypted() throws {
        let transport = FakeTransport { _ in btsPlaybackInfo(url: URL(string: "https://cdn.invalid/x.flac")!, encryption: "OLD_AES") }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try cache.entry(key: "tidal:11", url: TidalPlayback.url(trackId: 11))
            Issue.record("an encrypted stream opened")
        } catch {
            #expect(error as? TidalError == .encrypted)
            #expect(error.localizedDescription == "This track's stream is encrypted")
        }
    }

    @Test("During a backoff the entry throws backingOff and nothing is sent")
    func backoff() async throws {
        let transport = FakeTransport { _ in FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "300"]) }
        let resolver = TidalStreamResolver(gate: makeSignedInGate(transport: transport))
        // The 429 that starts the backoff.
        await #expect(throws: TidalError.self) { _ = try await resolver.resolve(trackId: 1) }
        let sent = transport.requests.count
        TidalPlayback.register(resolver: resolver)
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        for id in 12...15 {
            do {
                _ = try cache.entry(key: "tidal:\(id)", url: TidalPlayback.url(trackId: id))
                Issue.record("opened during a backoff")
            } catch TidalError.backingOff(let remaining, _) {
                #expect(remaining > 290 && remaining <= 300)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(transport.requests.count == sent, "nothing was sent during the backoff")
        #expect(TidalError.backingOff(remaining: 300, reason: "x").localizedDescription == "TIDAL asked us to wait 5 min")
    }

    @Test("A track whose resolution never answers fails with \"TIDAL isn't answering\"")
    func notAnswering() throws {
        let latch = Latch()
        let transport = FakeTransport { _ in await latch.wait(); return FakeResponse(status: 500, json: "{}") }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let directory = try DASHFixture.temporaryDirectory("tidal-silent"); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Locked(0.0)
        let cache = NetworkPlaybackCache(directory: directory, budget: 64 << 20, noProgressLimit: 5, clock: { clock.value })
        Thread { Thread.sleep(forTimeInterval: 0.2); clock.mutate { $0 = 10 } }.start()
        do {
            _ = try cache.entry(key: "tidal:20", url: TidalPlayback.url(trackId: 20))
            Issue.record("opened")
        } catch {
            #expect(error.localizedDescription == "TIDAL isn't answering")
        }
        Task { await latch.releaseAll() }
    }

    @Test("A URL that isn't a track throws instead of resolving anything")
    func notATrack() throws {
        let transport = FakeTransport { _ in FakeResponse(status: 500, json: "{}") }
        TidalPlayback.register(resolver: TidalStreamResolver(gate: makeSignedInGate(transport: transport)))
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: TidalError.self) { _ = try cache.entry(key: "tidal:x", url: URL(string: "tidal://album/5")!) }
        #expect(transport.requests.isEmpty)
    }
}
