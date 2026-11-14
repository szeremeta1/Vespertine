//
// Vespertine: matching a local song to TIDAL by its ISRC: the first track TIDAL can stream, nothing when there is none, and no request
// at all for a song without an ISRC.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL ISRC lookup")
struct TidalISRCLookupTests {
    private func lookup(_ reply: @escaping @Sendable (URLRequest) -> FakeResponse) -> (TidalISRCLookup, FakeTransport) {
        let transport = FakeTransport { reply($0) }
        return (TidalISRCLookup(gate: makeSignedInGate(transport: transport)), transport)
    }

    private func page(_ items: [String]) -> FakeResponse {
        FakeResponse(json: #"{"limit":10,"offset":0,"totalNumberOfItems":\#(items.count),"items":[\#(items.joined(separator: ","))]}"#)
    }

    private func item(_ id: Int, streamReady: Bool?, allowStreaming: Bool? = true) -> String {
        let ready = streamReady.map { "\"streamReady\":\($0)," } ?? ""
        let allow = allowStreaming.map { "\"allowStreaming\":\($0)," } ?? ""
        return #"{"id":\#(id),"title":"Song \#(id)","duration":200,\#(ready)\#(allow)"trackNumber":1,"volumeNumber":1,"explicit":false,"audioQuality":"LOSSLESS","artists":[{"id":1,"name":"A","type":"MAIN"}],"album":{"id":2,"title":"B"}}"#
    }

    @Test("A match: GET tracks?isrc=<isrc>, and the first track TIDAL can stream")
    func match() async throws {
        let (lookup, transport) = lookup { _ in page([item(1, streamReady: false), item(2, streamReady: true), item(3, streamReady: true)]) }
        let track = try await lookup.track(forISRC: "GBAYE0200700")
        #expect(track?.id == 2)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET" && request.url?.path == "/v1/tracks")
        #expect(request.url?.query?.contains("isrc=GBAYE0200700") == true)
        #expect(transport.requests.count == 1)
    }

    @Test("No items: nil")
    func noItems() async throws {
        let (lookup, _) = lookup { _ in page([]) }
        #expect(try await lookup.track(forISRC: "GBAYE0200700") == nil)
    }

    @Test("Only tracks that can't be streamed: nil")
    func onlyUnstreamable() async throws {
        let (lookup, _) = lookup { _ in page([item(1, streamReady: false), item(2, streamReady: true, allowStreaming: false)]) }
        #expect(try await lookup.track(forISRC: "GBAYE0200700") == nil)
    }

    @Test("A song without an ISRC is refused before any request", arguments: [nil, "", "   "] as [String?])
    func noISRC(isrc: String?) async throws {
        let (lookup, transport) = lookup { _ in page([item(1, streamReady: true)]) }
        #expect(try await lookup.track(forISRC: isrc) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test("The ISRC is trimmed and upper-cased before it is asked for")
    func normalized() async throws {
        let (lookup, transport) = lookup { _ in page([item(1, streamReady: true)]) }
        _ = try await lookup.track(forISRC: " gbaye0200700 ")
        #expect(transport.requests.first?.url?.query?.contains("isrc=GBAYE0200700") == true)
    }

    @Test("A track with no streamReady flag counts as streamable (TIDAL leaves it out of some answers)")
    func missingFlag() async throws {
        let (lookup, _) = lookup { _ in page([item(9, streamReady: nil)]) }
        #expect(try await lookup.track(forISRC: "GBAYE0200700")?.id == 9)
    }

    @Test("The words for the toast and the refusal")
    func words() {
        #expect(TidalISRCLookup.addedMessage(title: "Clocks") == "Added the TIDAL version of “Clocks”")
        #expect(TidalISRCLookup.refusal == "Not on TIDAL")
    }
}
