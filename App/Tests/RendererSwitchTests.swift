//
// Vespertine: the Settings › Playback switch for network renderers (UPnP Renderers (beta)), off by default. Off, nothing
// about them runs: no search on the network, no media server, nothing in the output list.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
import VespertineUPnP
@testable import Vespertine

/// Counts searches instead of sending them.
private final class CountingSearcher: SSDPSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var searches: Int { lock.withLock { count } }
    func search(targets: [String], mx: Int, wait: TimeInterval) async -> [SSDPResponse] {
        lock.withLock { count += 1 }
        return []
    }
}

@Suite("UPnP renderers settings switch", .serialized) @MainActor
struct RendererSwitchTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-rendererswitch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("The switch says beta, and its line says what off means")
    func switchExists() {
        #expect(RendererSwitch.title == "UPnP Renderers (beta)")
        #expect(!RendererSwitch.explanation.contains("\n"))
        #expect(RendererSwitch.explanation.localizedCaseInsensitiveContains("off"))
    }

    @Test("A new install starts with it off, nothing stored, and no model (so discovery never starts)")
    func offByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.upnpRenderersFeature)
        #expect(defaults.persistentDomain(forName: suite)?["upnpRenderersFeature"] == nil)
        let searcher = CountingSearcher()
        var made = false
        let model = RendererSwitch.apply(false, to: settings, current: nil, make: {
            made = true
            return RendererOutputModel(service: RendererService(discovery: RendererDiscovery(searcher: searcher)))
        })
        #expect(model == nil)
        #expect(!made)
        #expect(searcher.searches == 0)
    }

    @Test("On, discovery and the media server start; off again, they stop and the model goes")
    func onThenOff() async throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let searcher = CountingSearcher()
        let service = RendererService(discovery: RendererDiscovery(searcher: searcher))
        let model = try #require(RendererSwitch.apply(true, to: settings, current: nil, make: { RendererOutputModel(service: service) }))
        #expect(settings.upnpRenderersFeature)
        for _ in 0..<100 where !service.media.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(service.media.isRunning)
        #expect(searcher.searches >= 1)
        #expect(RendererSwitch.apply(false, to: settings, current: model) == nil)
        for _ in 0..<100 where service.media.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!service.media.isRunning)
        #expect(!service.discovery.isRunning)
        #expect(!settings.upnpRenderersFeature)
    }

    @Test("A renderer chosen as the output is let go of when the switch goes off")
    func keepsOutput() {
        #expect(!RendererSwitch.keepsOutput("upnp:uuid:1", turningOnTo: false))
        #expect(RendererSwitch.keepsOutput("upnp:uuid:1", turningOnTo: true))
        #expect(RendererSwitch.keepsOutput("BuiltInSpeakerDevice", turningOnTo: false))
        #expect(RendererSwitch.keepsOutput(nil, turningOnTo: false))
    }
}
