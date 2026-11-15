//
// Vespertine: a renderer that sat unused and isn't where Vespertine left it: its connection closed, or the renderer itself
// restarted on another port. The first Play after that must play, or say why not; it must never do nothing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

@Suite("Renderer playback: a stale link", .serialized)
struct StaleLinkTests {
    /// A playback to the renderer as it was at `old`, with the app's hooks.
    private func harness(old: FakeRenderer, lostAfter: TimeInterval = 0.3) async throws -> Harness {
        let media = MediaServer()
        try await media.start()
        let device = try await RendererDevice.load(location: old.location)
        let queue = try (0..<2).map { PlayableItem(url: try makeWAV(seed: $0 + 1)) }
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media, pollInterval: 0.05, lostAfter: lostAfter)
        playback.nextItemProvider = { finished in finished.id == queue[0].id ? queue[1] : nil }
        playback.metadataProvider = { item in RendererTrackInfo(title: item.url.lastPathComponent, artist: "Artist", duration: 1) }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        return Harness(fake: old, media: media, playback: playback, events: events, queue: queue)
    }

    @Test("A call whose kept connection had died is sent once more; anything else is not, and a second loss is the error")
    func staleConnection() async throws {
        let tries = Locked(0)
        let answer = try await SOAPClient.overStaleConnection { () async throws -> String in
            if tries.withLock({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
            return "answered"
        }
        #expect(answer == "answered")
        #expect(tries.withLock { $0 } == 2)

        tries.withLock { $0 = 0 }
        await #expect(throws: URLError.self) {
            _ = try await SOAPClient.overStaleConnection { () async throws -> String in
                tries.withLock { $0 += 1 }
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(tries.withLock { $0 } == 2)

        tries.withLock { $0 = 0 }
        await #expect(throws: URLError.self) {
            _ = try await SOAPClient.overStaleConnection { () async throws -> String in
                tries.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }
        #expect(tries.withLock { $0 } == 1)
    }

    @Test("OpenHome: a renderer that can't be reached for its sources fails the load; one that only refuses to list them is played to")
    func openHomeSourceCheck() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        let device = try await RendererDevice.load(location: fake.location)
        let transport = try OpenHomeTransport(description: device.description)
        let track = RendererTrack(uri: URL(string: "http://127.0.0.1:1/media/a.flac")!, metadata: "")
        // Refused (a renderer without that action): left on its source, the song still loaded.
        fake.fail("SourceXml", code: 401)
        try await transport.load(current: track, next: nil)
        #expect(fake.playlistURIs == [track.uri.absoluteString])
        // Gone: an error, by name, and nothing further asked of it.
        fake.stop()
        let error = await #expect(throws: UPnPError.self) { try await transport.load(current: track, next: nil) }
        #expect(error?.isLinkFailure == true)
    }

    @Test("The renderer restarted on another port: the first Play finds it there and plays", arguments: [true, false])
    func movedRendererPlays(openHome: Bool) async throws {
        let kind: FakeRenderer.Kind = openHome ? .openHome : .av(setNext: true)
        let old = try await FakeRenderer(kind: kind, udn: "uuid:moved")
        let h = try await harness(old: old)
        defer { h.close() }
        old.stop()
        let new = try await FakeRenderer(kind: kind, udn: "uuid:moved")
        defer { new.stop() }
        #expect(new.port != old.port)
        let asked = Locked(0)
        h.playback.relocate = { known in
            asked.withLock { $0 += 1 }
            #expect(known.description.location == old.location)
            return try? await RendererDevice.load(location: new.location)
        }
        h.playback.play(h.queue[0])
        #expect(h.playback.isStarting)
        #expect(await h.events.wait(for: "started \(h.queue[0].url.lastPathComponent)"))
        #expect(!h.events.all.contains { $0.hasPrefix("failed") })
        #expect(asked.withLock { $0 } == 1)
        #expect(h.playback.renderer.description.location == new.location)
        #expect(h.playback.isEngaged)
        #expect(!h.playback.isStarting)
        let uri = try #require(new.currentURI)
        #expect(await new.fetched(uri) == (try Data(contentsOf: h.queue[0].url)))
        // Everything after it goes to the new address as well.
        h.playback.pause()
        for _ in 0..<100 where new.transportState != "Paused" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(new.transportState == "Paused")
    }

    @Test("The renderer is nowhere: the first Play says so, by name, and doesn't sit there")
    func goneRendererSaysSo() async throws {
        let old = try await FakeRenderer(kind: .openHome, udn: "uuid:gone")
        let h = try await harness(old: old)
        defer { h.close() }
        old.stop()
        let asked = Locked(0)
        h.playback.relocate = { _ in asked.withLock { $0 += 1 }; return nil }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "failed Fake Renderer couldn't play the song"))
        #expect(asked.withLock { $0 } == 1)
        #expect(h.playback.snapshot.state == .stopped)
        #expect(!h.playback.isStarting)
        #expect(!h.playback.wantsPlaying)
    }

    @Test("A renderer found where it already was isn't a new address: the song fails once, with no second try")
    func sameAddressIsNotRelocated() async throws {
        let old = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:same")
        let h = try await harness(old: old)
        defer { h.close() }
        let known = h.playback.renderer
        old.stop()
        h.playback.relocate = { _ in known }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "failed"))
        #expect(h.events.all.filter { $0.hasPrefix("failed") }.count == 1)
    }

    @Test("A refusal is not a lost link: the renderer isn't looked for, the song fails with its reason")
    func refusalDoesNotRelocate() async throws {
        let old = try await FakeRenderer(kind: .av(setNext: true))
        let h = try await harness(old: old)
        defer { h.close() }
        let asked = Locked(0)
        h.playback.relocate = { _ in asked.withLock { $0 += 1 }; return nil }
        old.fail("SetAVTransportURI", code: 714)
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "failed"))
        #expect(h.events.all.first { $0.hasPrefix("failed") }?.contains("714") == true)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test("Discovery finds a renderer again at its new address, and answers nil for one that is where it was or gone")
    func discoveryRelocates() async throws {
        let old = try await FakeRenderer(kind: .openHome, udn: "uuid:roams")
        func reply(_ fake: FakeRenderer) -> SSDPResponse {
            SSDPResponse(location: fake.location, st: SSDP.rendererTargets[0], usn: "uuid:roams::x", udn: "uuid:roams")
        }
        let searcher = CountingSearcher(replies: [reply(old)])
        let discovery = RendererDiscovery(searcher: searcher)
        let known = try await RendererDevice.load(location: old.location)
        // Not started (the switch is off): nothing is searched.
        #expect(await discovery.relocate(known) == nil)
        #expect(searcher.searches == 0)
        discovery.start()
        defer { discovery.stop() }
        while discovery.searches == 0 || discovery.isSearching { try await Task.sleep(for: .milliseconds(5)) }
        // Where it was.
        #expect(await discovery.relocate(known) == nil)
        // Restarted on another port.
        old.stop()
        let new = try await FakeRenderer(kind: .openHome, udn: "uuid:roams")
        defer { new.stop() }
        searcher.replies = [reply(new)]
        let before = searcher.searches
        let found = try #require(await discovery.relocate(known))
        #expect(searcher.searches == before + 1)
        #expect(found.uid == known.uid)
        #expect(found.description.location == new.location)
        #expect(discovery.renderers.map(\.description.location) == [new.location])
        // Gone.
        searcher.replies = []
        #expect(await discovery.relocate(known) != nil)   // still listed at its new address (one missed search doesn't drop it)
        #expect(await discovery.relocate(found) == nil)
    }
}
