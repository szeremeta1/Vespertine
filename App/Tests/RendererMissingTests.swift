//
// Vespertine: a network renderer chosen as the output that isn't answering. Nothing plays anywhere else in its place (not the
// Mac's DAC, whatever the fallback setting says): Play says it isn't answering. Pressed while the first search is still
// running, Play waits a few seconds for it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
import VespertineUPnP
@testable import Vespertine

/// A renderer transport that answers everything and plays nothing.
private struct SilentTransport: RendererTransport {
    var gapless: Bool { true }
    func load(current: RendererTrack, next: RendererTrack?) async throws {}
    func replaceNext(_ next: RendererTrack?) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func stop() async throws {}
    func seek(to seconds: TimeInterval) async throws {}
    func status() async throws -> RendererStatus { RendererStatus(state: .stopped, position: 0, duration: nil, currentURI: nil) }
}

@Suite("A chosen renderer that isn't answering", .serialized) @MainActor
struct RendererMissingTests {
    private func fixture(_ body: (PlayerController, [Track], AppSettings) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-renderer-missing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
            buffer.frameLength = 480
            try file.write(from: buffer)
        }
        let original = try MetadataReader.read(url: url, artwork: nil)
        func track(_ id: Int) -> Track { var t = original; t.id = Int64(id); t.title = "S\(id)"; return t }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.outputFallback = .bestAvailable   // the setting that would otherwise move the music to the Mac
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false })
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        defer { player.stop() }
        try await body(player, (1...3).map(track), settings)
    }

    private func renderer() -> RendererDevice {
        let description = DeviceDescription(udn: "uuid:moode", friendlyName: "moOde UPNP", location: URL(string: "http://127.0.0.1:9/d.xml")!, services: [])
        return RendererDevice(description: description, kind: .openHome, capabilities: RendererCapabilities())
    }

    @Test("Play says the renderer isn't answering and nothing plays on the engine")
    func playRefused() async throws {
        try await fixture { player, album, _ in
            player.rendererGrace = { false }
            player.useRenderer(nil, missing: "moOde UPNP")
            player.play(album)
            #expect(player.lastError == "moOde UPNP isn't answering.")
            #expect(player.engine.snapshot.item == nil)
            #expect(player.state != .playing)
            player.togglePlayPause()
            #expect(player.engine.snapshot.item == nil)
        }
    }

    @Test("Pressed during the first search, Play waits for the renderer and starts on it when it appears")
    func graceThenFound() async throws {
        try await fixture { player, album, _ in
            player.rendererGrace = { true }
            player.useRenderer(nil, missing: "moOde UPNP")
            player.play(album)
            #expect(player.lastError == nil)
            #expect(player.engine.snapshot.item == nil)
            let playback = RendererPlayback(renderer: renderer(), transport: SilentTransport(), media: MediaServer())
            defer { playback.shutdown() }
            player.useRenderer(playback)
            #expect(playback.snapshot.item?.id == player.current?.id)
            #expect(player.engine.snapshot.item == nil)
        }
    }

    @Test("Pressed during the first search, Play gives up after the grace and says so")
    func graceRunsOut() async throws {
        try await fixture { player, album, _ in
            player.rendererGrace = { true }
            player.rendererGraceSeconds = 0.3
            player.useRenderer(nil, missing: "moOde UPNP")
            player.play(album)
            try await Task.sleep(for: .milliseconds(700))
            #expect(player.lastError == "moOde UPNP isn't answering.")
            #expect(player.engine.snapshot.item == nil)
        }
    }

    @Test("A renderer that goes away mid-song isn't replaced by the Mac: playback stops there with the message")
    func dropsMidSong() async throws {
        try await fixture { player, album, _ in
            let playback = RendererPlayback(renderer: renderer(), transport: SilentTransport(), media: MediaServer())
            player.useRenderer(playback)
            player.play(album)
            player.useRenderer(nil, missing: "moOde UPNP")
            #expect(player.lastError == "moOde UPNP isn't answering.")
            #expect(player.engine.snapshot.item == nil)
            #expect(player.current != nil)
        }
    }
}
