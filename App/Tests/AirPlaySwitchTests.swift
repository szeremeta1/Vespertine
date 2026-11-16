//
// Vespertine: the Settings › Playback switch for AirPlay receivers (AirPlay Players (beta)), off by default. Off, nothing
// about them runs: no Bonjour browsing, no socket, nothing in the output list. A chosen receiver that isn't there is never
// replaced by the Mac's own output.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAirPlay
import VespertineAudio
import VespertineLibrary
@testable import Vespertine

/// Counts browses instead of starting Bonjour.
private final class CountingBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, browsing = false
    var starts: Int { lock.withLock { count } }
    var isBrowsing: Bool { lock.withLock { browsing } }
    func start(onChange: @escaping @Sendable ([BonjourResult]) -> Void) { lock.withLock { count += 1; browsing = true } }
    func stop() { lock.withLock { browsing = false } }
}

@Suite("AirPlay players settings switch", .serialized) @MainActor
struct AirPlaySwitchTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-airplayswitch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("A receiver's cover is the stored 600-pixel picture; a key that isn't the library's, or a picture receivers don't take, is none")
    func cover() throws {
        let (root, _, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtworkStore(directory: root)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 3, count: 500)
        try jpeg.write(to: store.thumbnailURL("abc-123", size: 600))
        try Data("GIF89a".utf8).write(to: store.originalURL("gif-1"))
        try jpeg.write(to: root.deletingLastPathComponent().appendingPathComponent("outside_600.jpg"))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("outside_600.jpg")) }
        #expect(AirPlayCover.data(key: "abc-123", store: store) == jpeg)
        #expect(AirPlayCover.provider(store: store)("abc-123") == jpeg)
        #expect(AirPlayCover.data(key: "gif-1", store: store) == nil)
        #expect(AirPlayCover.data(key: "missing", store: store) == nil)
        #expect(AirPlayCover.data(key: "../outside", store: store) == nil)
        #expect(AirPlayCover.data(key: "", store: store) == nil)
    }

    @Test("The switch says beta, and its line says what off means")
    func words() {
        #expect(AirPlaySwitch.title == "AirPlay Players (beta)")
        #expect(AirPlaySwitch.explanation.localizedCaseInsensitiveContains("off"))
        #expect(AirPlaySwitch.explanation.contains("16-bit / 44.1 kHz"))
    }

    @Test("A new install starts with it off, nothing stored, and no model (so Bonjour is never browsed)")
    func offByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.airPlayPlayersFeature)
        #expect(settings.airPlayDigitalVolume.isEmpty)
        #expect(defaults.persistentDomain(forName: suite)?["airPlayPlayersFeature"] == nil)
        let browser = CountingBrowser()
        var made = false
        let model = AirPlaySwitch.apply(false, to: settings, current: nil, make: {
            made = true
            return AirPlayOutputModel(service: AirPlayService(discovery: AirPlayDiscovery(browser: browser, excludedName: nil)))
        })
        #expect(model == nil)
        #expect(!made)
        #expect(browser.starts == 0)
    }

    @Test("On, Bonjour is browsed; off again, it stops and the model goes")
    func onThenOff() async throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let browser = CountingBrowser()
        let service = AirPlayService(discovery: AirPlayDiscovery(browser: browser, excludedName: nil))
        let model = try #require(AirPlaySwitch.apply(true, to: settings, current: nil, make: { AirPlayOutputModel(service: service) }))
        #expect(settings.airPlayPlayersFeature)
        await service.settled()
        #expect(browser.isBrowsing && browser.starts == 1)
        #expect(AirPlaySwitch.apply(false, to: settings, current: model) == nil)
        await service.settled()
        #expect(!browser.isBrowsing)
        #expect(!service.discovery.isRunning)
        #expect(!settings.airPlayPlayersFeature)
    }

    @Test("A receiver chosen as the output is let go of when the switch goes off")
    func keepsOutput() {
        #expect(!AirPlaySwitch.keepsOutput("raop:B827EB000001", turningOnTo: false))
        #expect(AirPlaySwitch.keepsOutput("raop:B827EB000001", turningOnTo: true))
        #expect(AirPlaySwitch.keepsOutput("upnp:uuid:1", turningOnTo: false))
        #expect(AirPlaySwitch.keepsOutput(nil, turningOnTo: false))
    }

    @Test("Volume: the receiver's own by default (samples untouched), Vespertine's digital volume when chosen")
    func volume() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let uid = "raop:B827EB000001"
        // A receiver nobody set a level for starts low (many take the AirPlay volume as their master volume), never at
        // full level, and whatever the app's digital volume elsewhere.
        settings.digitalVolume = 0.9
        #expect(settings.airPlayLevel(uid: uid) == AppSettings.firstAirPlayLevel)
        #expect(settings.airPlayReceiverVolumeDB(uid: uid) == RAOPVolume.decibels(level: AppSettings.firstAirPlayLevel))
        #expect(settings.airPlayReceiverVolumeDB(uid: uid) < -15)
        settings.setAppVolumeLevel(0.5, for: uid)
        #expect(settings.airPlaySettings(uid: uid).digitalVolumeDB == nil)
        #expect(settings.airPlayReceiverVolumeDB(uid: uid) == -15)
        settings.setAirPlayDigitalVolume(true, for: uid)
        #expect(settings.airPlaySettings(uid: uid).digitalVolumeDB != nil)
        #expect(settings.airPlayReceiverVolumeDB(uid: uid) == 0)
    }

    @Test("A chosen receiver (or player) whose playback can't be made counts as missing: never handed to the Mac's output")
    func neverFallsBack() {
        #expect(AppModel.missingNetworkOutput(chosen: true, hasPlayback: false, missing: nil, name: "moOde") == "moOde")
        #expect(AppModel.missingNetworkOutput(chosen: true, hasPlayback: false, missing: "Gone", name: "moOde") == "Gone")
        #expect(AppModel.missingNetworkOutput(chosen: true, hasPlayback: false, missing: nil, name: nil) != nil)
        #expect(AppModel.missingNetworkOutput(chosen: true, hasPlayback: true, missing: nil, name: "moOde") == nil)
        #expect(AppModel.missingNetworkOutput(chosen: false, hasPlayback: false, missing: nil, name: nil) == nil)
    }

    @Test("The mini player's words for an AirPlay song match its badge")
    func verdict() {
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2)
        let stage = SignalPath.RendererStage(name: "moOde", protocolName: "AirPlay", processing: [], sentCodec: "ALAC", sentSampleRate: 44_100,
                                             sentBitDepth: 16, sentChannels: 2, gapless: true, transport: .airPlay)
        let sent = SignalPath.renderer(stage, source: source, decoderName: "", volume: .fixed)
        #expect(MiniPlayerView.verdictText(sent) == "Sent bit-perfect to moOde: the file's own samples")
        var converted = stage
        converted.processing = [.dithered]
        let path = SignalPath.renderer(converted, source: source, decoderName: "", volume: .fixed)
        #expect(MiniPlayerView.verdictText(path) == "CONVERTED · 16/44.1 SENT")
        #expect(SignalPathView.airPlaySteps(path, converted).last?.value == "not verified")
    }
}
