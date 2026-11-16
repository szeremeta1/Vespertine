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

/// What the output list was told to choose.
@MainActor private final class Chosen {
    var list: [String] = []
}

@Suite("AirPlay players settings switch", .serialized) @MainActor
struct AirPlaySwitchTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-airplayswitch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func locked(_ pw: String) throws -> AirPlayDevice {
        let record = try #require(RAOPRecord.parse(serviceName: "AABBCCDDEE10@Den", txt: ["et": "0", "pw": pw]))
        return AirPlayDevice(deviceID: record.deviceID, name: record.name, raop: record)
    }

    private func model(_ passwords: AirPlayPasswords) -> AirPlayOutputModel {
        let model = AirPlayOutputModel(service: AirPlayService(discovery: AirPlayDiscovery(browser: CountingBrowser(), excludedName: nil)))
        model.passwords = passwords
        return model
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Choosing a receiver with a password asks for it; one with a saved password, or without one, is chosen at once")
    func choosing() async throws {
        let den = try locked("true")
        let chosen = Chosen()
        let empty = model(.memory())
        empty.choose(den) { chosen.list.append($0) }
        await settle { empty.passwordRequest != nil }
        #expect(empty.passwordRequest == AirPlayPasswordRequest(device: den, refused: false))
        #expect(chosen.list.isEmpty)

        let saved = model(.memory([den.deviceID: "attic"]))
        saved.choose(den) { chosen.list.append($0) }
        await settle { !chosen.list.isEmpty }
        #expect(chosen.list == [den.uid])
        #expect(saved.passwordRequest == nil)

        let open = try locked("false")
        let any = model(.memory())
        any.choose(open) { chosen.list.append($0) }
        #expect(chosen.list == [den.uid, open.uid])
        #expect(any.passwordRequest == nil)
    }

    @Test("The password given is saved under the receiver's id and the receiver is chosen; Cancel saves nothing; Forget removes it")
    func submitting() async throws {
        let den = try locked("true")
        let passwords = AirPlayPasswords.memory()
        let airPlay = model(passwords)
        let chosen = Chosen()
        airPlay.choose(den) { chosen.list.append($0) }
        await settle { airPlay.passwordRequest != nil }
        airPlay.cancelPassword()
        #expect(airPlay.passwordRequest == nil && chosen.list.isEmpty && passwords.read(den.deviceID) == nil)

        airPlay.choose(den) { chosen.list.append($0) }
        await settle { airPlay.passwordRequest != nil }
        await airPlay.submit(password: "attic") { chosen.list.append($0) }
        #expect(passwords.read(den.deviceID) == "attic")
        #expect(chosen.list == [den.uid])
        #expect(airPlay.passwordRequest == nil)
        // Nothing is asked for: no sheet, nothing saved.
        await airPlay.submit(password: "other") { chosen.list.append($0) }
        #expect(passwords.read(den.deviceID) == "attic" && chosen.list == [den.uid])

        await airPlay.forgetPassword(for: den)
        #expect(passwords.read(den.deviceID) == nil)
        #expect(AirPlayPasswords.account("AABBCCDDEE10") == "airplay-password-AABBCCDDEE10")
    }

    @Test("The output list says a receiver has a password")
    func passwordDetail() throws {
        #expect(AirPlayText.detail(try locked("true")) == "AIRPLAY · ALAC 16/44.1 · PASSWORD")
        #expect(AirPlayText.detail(try locked("false")) == "AIRPLAY · ALAC 16/44.1")
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
