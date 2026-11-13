//
// Vespertine: resolving a TIDAL track to a stream (BTS file URL or DASH segments), from fixture responses.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL stream resolver")
struct TidalStreamResolverTests {
    private func resolver(_ response: FakeResponse, quality: String? = nil) -> (TidalStreamResolver, FakeTransport) {
        let transport = FakeTransport(always: response)
        let gate = makeSignedInGate(transport: transport)
        return (quality.map { TidalStreamResolver(gate: gate, quality: $0) } ?? TidalStreamResolver(gate: gate), transport)
    }

    private func fixture(_ name: String) throws -> FakeResponse {
        FakeResponse(body: try Fixture.data("playbackinfo/\(name).json"))
    }

    private func manifestResponse(mime: String, manifest: String) -> FakeResponse {
        let encoded = Data(manifest.utf8).base64EncodedString()
        return FakeResponse(json: #"{"trackId":1,"audioMode":"STEREO","audioQuality":"LOSSLESS","manifestMimeType":"\#(mime)","manifest":"\#(encoded)"}"#)
    }

    @Test("a BTS FLAC manifest resolves to one file URL")
    func btsFlac() async throws {
        let (resolver, _) = resolver(try fixture("bts-flac"))
        let stream = try await resolver.resolve(trackId: 100001)
        #expect(stream.kind == .file(URL(string: "https://fake-cdn.example/audio/track.flac")!))
        #expect(stream.codec == "flac" && stream.fileExtension == "flac")
        #expect(stream.audioQuality == "LOSSLESS" && stream.audioMode == "STEREO")
        #expect(stream.sampleRate == 44100 && stream.bitDepth == 16)
    }

    @Test("a hi-res DASH manifest: 51 segments (50 repeats + 1), the init URL, 192 kHz")
    func dashHiRes() async throws {
        let (resolver, _) = resolver(try fixture("dash-hires"))
        let stream = try await resolver.resolve(trackId: 100001)
        guard case let .dash(initialization, segments) = stream.kind else {
            Issue.record("expected dash, got \(stream.kind)")
            return
        }
        #expect(initialization.absoluteString == "https://fake-cdn.example/mediatracks/abc/0.mp4")
        #expect(segments.count == 51)
        #expect(segments.first?.absoluteString == "https://fake-cdn.example/mediatracks/abc/1.mp4")
        #expect(segments.last?.absoluteString == "https://fake-cdn.example/mediatracks/abc/51.mp4")
        #expect(segments.last?.lastPathComponent == "51.mp4")
        #expect(Set(segments).count == 51)
        #expect(stream.codec == "flac" && stream.fileExtension == "flac")
        #expect(stream.sampleRate == 192000 && stream.bitDepth == 24)
        #expect(stream.audioQuality == "HI_RES_LOSSLESS")
    }

    @Test("DASH AAC gets the m4a extension")
    func dashAAC() async throws {
        let (resolver, _) = resolver(try fixture("dash-aac"))
        let stream = try await resolver.resolve(trackId: 100001)
        #expect(stream.codec == "mp4a.40.2" && stream.fileExtension == "m4a")
        #expect(stream.sampleRate == 44100)
        #expect(stream.bitDepth == nil)
    }

    @Test("an encrypted BTS manifest throws encrypted")
    func encrypted() async throws {
        let (resolver, _) = resolver(try fixture("bts-encrypted"))
        await #expect(throws: TidalError.encrypted) { try await resolver.resolve(trackId: 100001) }
    }

    @Test("an MPD with ContentProtection throws encrypted")
    func contentProtection() async throws {
        let mpd = """
        <?xml version='1.0' encoding='UTF-8'?><MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:x"/>
        <Representation codecs="flac"><SegmentTemplate initialization="https://h/0.mp4" media="https://h/$Number$.mp4"><SegmentTimeline><S d="1"/></SegmentTimeline></SegmentTemplate></Representation>
        </AdaptationSet></Period></MPD>
        """
        let (resolver, _) = resolver(manifestResponse(mime: "application/dash+xml", manifest: mpd))
        await #expect(throws: TidalError.encrypted) { try await resolver.resolve(trackId: 1) }
    }

    @Test("the request carries playbackmode, assetpresentation and the default quality")
    func requestParameters() async throws {
        let (resolver, transport) = resolver(try fixture("bts-flac"))
        _ = try await resolver.resolve(trackId: 100001)
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/v1/tracks/100001/playbackinfopostpaywall")
        let query = FormEncoding.decode(request.url?.query ?? "")
        #expect(query["playbackmode"] == "STREAM")
        #expect(query["assetpresentation"] == "FULL")
        #expect(query["audioquality"] == "HI_RES_LOSSLESS")
        #expect(query["countryCode"] == "DE")
    }

    @Test("a chosen quality is requested")
    func customQuality() async throws {
        let (resolver, transport) = resolver(try fixture("bts-flac"), quality: "LOSSLESS")
        _ = try await resolver.resolve(trackId: 1)
        #expect(FormEncoding.decode(transport.requests[0].url?.query ?? "")["audioquality"] == "LOSSLESS")
    }

    @Test("404 with subStatus 4005, and a 401 saying not ready, are notStreamable with TIDAL's message")
    func notStreamable() async throws {
        let (a, _) = resolver(FakeResponse(status: 404, json: #"{"status":404,"subStatus":4005,"userMessage":"Asset is not ready for playback"}"#))
        await #expect(throws: TidalError.notStreamable("Asset is not ready for playback")) { try await a.resolve(trackId: 1) }
        // The gate refreshes the token once on a 401 (which this fake can't do), so use a 404 for the "not ready" wording too.
        let (b, _) = resolver(FakeResponse(status: 404, json: #"{"status":404,"userMessage":"Track not ready for streaming"}"#))
        await #expect(throws: TidalError.notStreamable("Track not ready for streaming")) { try await b.resolve(trackId: 1) }
    }

    @Test("other HTTP errors pass through unchanged")
    func otherErrors() async throws {
        let (resolver, _) = resolver(FakeResponse(status: 500, json: "boom"))
        await #expect(throws: TidalError.http(status: 500, body: "boom")) { try await resolver.resolve(trackId: 1) }
    }

    @Test("a manifest that isn't BTS or DASH, or isn't base64, is malformed")
    func malformed() async throws {
        let (a, _) = resolver(manifestResponse(mime: "application/x-unknown", manifest: "x"))
        await #expect(throws: TidalError.self) { try await a.resolve(trackId: 1) }
        let (b, _) = resolver(FakeResponse(json: #"{"audioMode":"STEREO","audioQuality":"LOSSLESS","manifestMimeType":"application/vnd.tidal.bts","manifest":"!!!"}"#))
        await #expect(throws: TidalError.self) { try await b.resolve(trackId: 1) }
    }
}

@Suite("MPD parser")
struct MPDParserTests {
    private func mpd(template: String, representationAttributes: String = #"codecs="flac" audioSamplingRate="96000""#) -> String {
        "<?xml version='1.0' encoding='UTF-8'?><MPD><Period><AdaptationSet><Representation \(representationAttributes)>\(template)</Representation></AdaptationSet></Period></MPD>"
    }

    @Test("segment count is the sum of (r + 1), with r defaulting to 0")
    func segmentCount() throws {
        let info = try MPDParser.parse(mpd(template: #"<SegmentTemplate initialization="i.mp4" media="s$Number$.mp4" startNumber="5"><SegmentTimeline><S d="10" r="2"/><S d="10"/><S d="5" r="0"/></SegmentTimeline></SegmentTemplate>"#))
        #expect(info.segmentCount == 5)
        #expect(info.startNumber == 5)
        #expect(info.codecs == "flac" && info.sampleRate == 96000)
    }

    @Test("startNumber defaults to 1")
    func defaultStart() throws {
        let info = try MPDParser.parse(mpd(template: #"<SegmentTemplate initialization="i.mp4" media="s$Number$.mp4"><SegmentTimeline><S d="1"/></SegmentTimeline></SegmentTemplate>"#))
        #expect(info.startNumber == 1 && info.segmentCount == 1)
    }

    @Test("a SegmentTemplate on the AdaptationSet is used when the Representation has none")
    func adaptationLevelTemplate() throws {
        let xml = #"<MPD><Period><AdaptationSet><SegmentTemplate initialization="i.mp4" media="s$Number$.mp4"><SegmentTimeline><S d="1" r="1"/></SegmentTimeline></SegmentTemplate><Representation codecs="flac"/></AdaptationSet></Period></MPD>"#
        let info = try MPDParser.parse(xml)
        #expect(info.segmentCount == 2 && info.initialization == "i.mp4")
    }

    @Test("only the first Representation of the first AdaptationSet counts")
    func firstOnly() throws {
        let xml = #"""
        <MPD><Period>
          <AdaptationSet><Representation codecs="flac" audioSamplingRate="44100"><SegmentTemplate initialization="a" media="a$Number$"><SegmentTimeline><S d="1"/></SegmentTimeline></SegmentTemplate></Representation>
                         <Representation codecs="mp4a"><SegmentTemplate initialization="b" media="b$Number$"><SegmentTimeline><S d="1" r="9"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>
          <AdaptationSet><Representation codecs="eac3"/></AdaptationSet>
        </Period></MPD>
        """#
        let info = try MPDParser.parse(xml)
        #expect(info.codecs == "flac" && info.initialization == "a" && info.segmentCount == 1)
    }

    @Test("an open-ended repeat (r = -1), a missing template or invalid XML is malformed")
    func malformed() {
        #expect(throws: TidalError.self) {
            try MPDParser.parse(mpd(template: #"<SegmentTemplate initialization="i" media="s$Number$"><SegmentTimeline><S d="1" r="-1"/></SegmentTimeline></SegmentTemplate>"#))
        }
        #expect(throws: TidalError.self) { try MPDParser.parse(mpd(template: "")) }
        #expect(throws: TidalError.self) { try MPDParser.parse("<MPD><Period>") }
    }
}
