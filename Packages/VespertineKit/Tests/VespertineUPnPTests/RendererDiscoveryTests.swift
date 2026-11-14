//
// Vespertine: renderer discovery, and the switch it lives behind: off, nothing is searched and nothing listens.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineUPnP

/// Answers searches with fixed replies and counts them.
final class CountingSearcher: SSDPSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var replies: [SSDPResponse]
    init(replies: [SSDPResponse] = []) { self.replies = replies }
    var searches: Int { lock.withLock { count } }
    func search(targets: [String], mx: Int, wait: TimeInterval) async -> [SSDPResponse] {
        lock.withLock { count += 1 }
        return replies
    }
}

@Suite("Renderer discovery", .serialized)
struct RendererDiscoveryTests {
    @Test("With the switch off (the default), discovery never starts: no search, no media server")
    func offByDefault() async throws {
        let searcher = CountingSearcher()
        let service = RendererService(discovery: RendererDiscovery(searcher: searcher))
        #expect(!service.isEnabled)
        service.refresh()
        await service.discovery.searchOnce()
        try await Task.sleep(for: .milliseconds(100))
        #expect(searcher.searches == 0)
        #expect(!service.discovery.isRunning)
        #expect(!service.media.isRunning)
        try await service.setEnabled(false)
        #expect(searcher.searches == 0)
        #expect(!service.media.isRunning)
    }

    @Test("On, it searches and serves; off again, it stops both")
    func onThenOff() async throws {
        let searcher = CountingSearcher()
        let service = RendererService(discovery: RendererDiscovery(searcher: searcher))
        try await service.setEnabled(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(searcher.searches >= 1)
        #expect(service.media.isRunning)
        try await service.setEnabled(false)
        #expect(!service.media.isRunning)
        #expect(!service.discovery.isRunning)
        let before = searcher.searches
        service.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(searcher.searches == before)
    }

    @Test("A found renderer is read and listed; one gone from three searches is dropped")
    func listsAndDrops() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        defer { fake.stop() }
        let reply = SSDPResponse(location: fake.location, st: SSDP.rendererTargets[0], usn: "uuid:fake-\(fake.port)::x", udn: "uuid:fake-\(fake.port)")
        let searcher = CountingSearcher(replies: [reply, reply])
        let discovery = RendererDiscovery(searcher: searcher)
        discovery.start()
        defer { discovery.stop() }
        try await Task.sleep(for: .milliseconds(300))
        await discovery.searchOnce()
        #expect(discovery.renderers.map(\.name) == ["Fake Renderer"])
        #expect(discovery.renderers.first?.kind == .openHome)
        searcher.replies = []
        for _ in 0..<2 { await discovery.searchOnce() }
        #expect(discovery.renderers.count == 1)
        await discovery.searchOnce()
        #expect(discovery.renderers.isEmpty)
    }
}

@Suite("Renderer switch, flipped quickly", .serialized)
struct RendererSwitchRaceTests {
    @Test("On, off, on, off in a row ends with nothing listening and nothing searching", arguments: 0..<5)
    func rapidToggle(_ run: Int) async throws {
        let searcher = CountingSearcher()
        let service = RendererService(discovery: RendererDiscovery(searcher: searcher))
        service.want(true)
        service.want(false)
        service.want(true)
        service.want(false)
        await service.settled()
        #expect(!service.isEnabled)
        #expect(!service.media.isRunning)
        #expect(!service.discovery.isRunning)
        let searches = searcher.searches
        try await Task.sleep(for: .milliseconds(200))
        #expect(searcher.searches == searches)
        // And the last word wins the other way too.
        service.want(false)
        service.want(true)
        await service.settled()
        #expect(service.media.isRunning)
        #expect(service.discovery.isRunning)
        service.want(false)
        await service.settled()
        #expect(!service.media.isRunning)
    }
}
