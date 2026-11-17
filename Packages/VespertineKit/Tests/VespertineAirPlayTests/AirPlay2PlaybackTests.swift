//
// Vespertine: the queue played on the fake receiver as an AirPlay 2 one: a receiver that asks for no PIN plays with
// nothing kept; one that shows a PIN is paired with once (the PIN typed, the keys kept) and plays with those keys after;
// one never paired with, or that has forgotten this Mac, fails the song and asks for the PIN.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

@Suite("AirPlay 2 playback", .serialized, .timeLimit(.minutes(2))) @MainActor
struct AirPlay2PlaybackTests {
    /// What a HomePod mini advertises.
    static let features = "0x4A7FCA00,0xBC354BD0"

    func device(_ receiver: FakeRAOPReceiver, flags: String) throws -> AirPlayDevice {
        let record = try #require(AirPlayRecord.parse(serviceName: "Kitchen", txt: ["deviceid": "AA:00:00:00:00:02", "features": Self.features, "flags": flags]))
        return AirPlayDevice(deviceID: record.deviceID, name: "Kitchen", raop: nil, airplay: record, host: "127.0.0.1", port: receiver.port)
    }

    func playback(_ receiver: FakeRAOPReceiver, flags: String) throws -> (AirPlayPlayback, EventLog) {
        let kitchen = try device(receiver, flags: flags)
        let p = try #require(AirPlayPlayback(device: kitchen))
        p.pairingSecret = hex(srpSecret)
        let log = EventLog()
        p.eventHandler = { event in log.events.append(event) }
        return (p, log)
    }

    func wait(_ condition: @MainActor () -> Bool) async { await untilTrue(condition) }

    /// Pairs with the fake receiver by its PIN, as the app does once.
    func keys(_ receiver: FakeRAOPReceiver, pin: String = "3939") async throws -> AirPlayPairingKeys {
        let pairing = AirPlayPINPairing(endpoint: endpoint(receiver))
        try await pairing.begin()
        return try await pairing.finish(pin: pin, identity: AirPlayPairingIdentity(), secret: hex(srpSecret))
    }

    @Test("A receiver that asks for no PIN plays the song sample for sample, with its title, and nothing kept is read")
    func open() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        let (url, samples) = try writeWAV(seconds: 0.6, seed: 41)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, flags: "0x4")
        defer { p.shutdown() }
        let read = Locked(0)
        let asked = Locked(0)
        p.pairingProvider = { read.withLock { $0 += 1 }; return nil }
        p.pairingRefused = { asked.withLock { $0 += 1 } }
        p.metadataProvider = { _ in RendererTrackInfo(title: "Song", artist: "Artist", album: "Album", duration: 0.6) }
        let item = PlayableItem(url: url)
        p.play(item, at: 0)
        await wait { log.ended }
        #expect(log.started == [item.id])
        #expect(log.failures.isEmpty)
        #expect(Array(receiver.methods.prefix(5)) == ["POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(receiver.requests.prefix(2).allSatisfy { $0.url == "/pair-setup" })
        #expect(receiver.unopened == 0)
        #expect(Array(receiver.samples.map(Int32.init).prefix(samples.count)) == samples)
        let parameters = receiver.requests.filter { $0.method == "SET_PARAMETER" }
        #expect(parameters.contains { $0["Content-Type"] == "application/x-dmap-tagged" && DMAP.parse($0.body)["minm"] == Data("Song".utf8) })
        #expect(parameters.contains { String(decoding: $0.body, as: UTF8.self).hasPrefix("progress: ") })
        #expect(read.withLock { $0 } == 0)
        #expect(asked.withLock { $0 } == 0)
        // The receiver is told of a Mac with a made-up address, never an empty one.
        let told = try #require(receiver.setups.first)
        #expect((told["deviceID"] as? String)?.count == 17)
        #expect((told["name"] as? String)?.isEmpty == false)
    }

    @Test("A receiver that shows a PIN: paired with once, it plays with the kept keys and shows no PIN again")
    func paired() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let pairing = FakePairing(allowsTransient: false)
        receiver.pairing = pairing
        let kept = try await keys(receiver)
        #expect(pairing.pinShown == 1)
        #expect(pairing.controllers.count == 1)
        // What the app stores is what it gets back.
        let stored = try JSONEncoder().encode(kept)
        let restored = try JSONDecoder().decode(AirPlayPairingKeys.self, from: stored)
        #expect(restored == kept)
        let before = receiver.requests.count

        let (url, samples) = try writeWAV(seconds: 0.6, seed: 42)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, flags: "0x204")
        defer { p.shutdown() }
        let asked = Locked(0)
        p.pairingProvider = { restored }
        p.pairingRefused = { asked.withLock { $0 += 1 } }
        let item = PlayableItem(url: url)
        p.play(item, at: 0)
        await wait { log.ended }
        #expect(log.started == [item.id])
        #expect(log.failures.isEmpty)
        let ours = Array(receiver.requests.dropFirst(before))
        #expect(ours.prefix(5).map { $0.method ?? "" } == ["POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(ours.prefix(2).allSatisfy { $0.url == "/pair-verify" })
        #expect(Array(receiver.samples.map(Int32.init).prefix(samples.count)) == samples)
        #expect(pairing.pinShown == 1)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test("A receiver that shows a PIN and was never paired with fails the song, asks for the PIN once, and is sent nothing")
    func neverPaired() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing(allowsTransient: false)
        let (url, _) = try writeWAV(seconds: 0.6, seed: 43)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, flags: "0x204")
        defer { p.shutdown() }
        let asked = Locked(0)
        p.pairingRefused = { asked.withLock { $0 += 1 } }
        p.play(PlayableItem(url: url), at: 0)
        await wait { !log.failures.isEmpty }
        #expect(log.failures.count == 1)
        #expect(log.started.isEmpty)
        #expect(asked.withLock { $0 } == 1)
        #expect(receiver.requests.isEmpty)
    }

    @Test("A receiver that has forgotten this Mac fails the song and asks for the PIN again")
    func forgotten() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let pairing = FakePairing(allowsTransient: false)
        receiver.pairing = pairing
        let kept = try await keys(receiver)
        pairing.forget()
        let (url, _) = try writeWAV(seconds: 0.6, seed: 44)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, flags: "0x204")
        defer { p.shutdown() }
        let asked = Locked(0)
        p.pairingProvider = { kept }
        p.pairingRefused = { asked.withLock { $0 += 1 } }
        p.play(PlayableItem(url: url), at: 0)
        await wait { !log.failures.isEmpty }
        #expect(log.failures.count == 1)
        #expect(log.started.isEmpty)
        #expect(asked.withLock { $0 } == 1)
        #expect(receiver.setups.isEmpty)
        #expect(receiver.packetCount == 0)
    }

    @Test("A wrong PIN is refused as one and keeps nothing; the receiver shows a new PIN and the right one pairs")
    func wrongPIN() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let fake = FakePairing(allowsTransient: false)
        receiver.pairing = fake
        let pairing = AirPlayPINPairing(endpoint: endpoint(receiver))
        // Nothing to finish before the receiver has been asked for its PIN.
        await #expect(throws: RAOPError.closed) {
            _ = try await pairing.finish(pin: "3939", identity: AirPlayPairingIdentity(), secret: hex(srpSecret))
        }
        try await pairing.begin()
        await #expect(throws: PairingError.authentication) {
            _ = try await pairing.finish(pin: "1234", identity: AirPlayPairingIdentity(), secret: hex(srpSecret))
        }
        #expect(fake.controllers.isEmpty)
        try await pairing.begin()
        #expect(fake.pinShown == 2)
        // The PIN as typed, with a space after it.
        let kept = try await pairing.finish(pin: "3939 ", identity: AirPlayPairingIdentity(), secret: hex(srpSecret))
        #expect(kept.receiver == fake.paired)
        #expect(fake.controllers.count == 1)
        await pairing.cancel()
    }

    @Test("Which receivers get an AirPlay 2 session, where it connects, and what they show of a song")
    func choice() throws {
        let raopService = BonjourService(name: "AA0000000002@Kitchen", type: "_raop._tcp")
        let airplayService = BonjourService(name: "Kitchen", type: "_airplay._tcp")
        let homePod = try #require(AirPlayRecord.parse(serviceName: "Kitchen", txt: ["deviceid": "AA:00:00:00:00:02", "features": Self.features, "flags": "0x4"]))
        let plain = try #require(RAOPRecord.parse(serviceName: "AA0000000002@Kitchen", txt: ["et": "0,4", "cn": "0,1", "md": "0"]))
        let fairPlay = try #require(RAOPRecord.parse(serviceName: "AA0000000002@Kitchen", txt: ["et": "3,5", "cn": "0,1", "md": "0,1,2"]))
        let locked = try #require(RAOPRecord.parse(serviceName: "AA0000000002@Kitchen", txt: ["et": "3,5", "cn": "0,1", "pw": "true"]))

        // Only AirPlay 2: that is the session, at the `_airplay._tcp` service.
        let only = AirPlayDevice(deviceID: "AA0000000002", name: "Kitchen", raop: nil, airplay: homePod, airplayService: airplayService)
        #expect(only.usesAirPlay2)
        #expect(only.metadata == [0, 1, 2])
        #expect(AirPlayPlayback.endpoint(for: only, airPlay2: only.usesAirPlay2) == .service(name: "Kitchen", type: "_airplay._tcp", domain: "local.", interface: nil))
        #expect(AirPlayPlayback(device: only) != nil)
        #expect(AirPlayPINPairing(device: only) != nil)

        // AirPlay 1 as Vespertine sends it, and AirPlay 2: it stays on AirPlay 1.
        let both = AirPlayDevice(deviceID: "AA0000000002", name: "Kitchen", raop: plain, airplay: homePod, service: raopService, airplayService: airplayService)
        #expect(!both.usesAirPlay2)
        #expect(both.metadata == [0])
        #expect(AirPlayPlayback.endpoint(for: both, airPlay2: both.usesAirPlay2) == .service(name: "AA0000000002@Kitchen", type: "_raop._tcp", domain: "local.", interface: nil))

        // An AirPlay 1 record Vespertine can't send to (FairPlay only), and AirPlay 2: AirPlay 2.
        let apple = AirPlayDevice(deviceID: "AA0000000002", name: "Kitchen", raop: fairPlay, airplay: homePod, service: raopService, airplayService: airplayService)
        #expect(apple.usesAirPlay2)
        #expect(AirPlayPlayback.endpoint(for: apple, airPlay2: apple.usesAirPlay2) == .service(name: "Kitchen", type: "_airplay._tcp", domain: "local.", interface: nil))

        // A password, said either way, is not something an AirPlay 2 session can answer yet.
        let passworded = AirPlayDevice(deviceID: "AA0000000002", name: "Kitchen", raop: locked, airplay: homePod, service: raopService, airplayService: airplayService)
        #expect(!passworded.usesAirPlay2 && passworded.airPlay2Entry == nil)
        #expect(AirPlayPlayback(device: passworded) == nil)
        #expect(AirPlayPINPairing(device: passworded) == nil)

        // Neither: nothing to play to, and nowhere to pair.
        let neither = AirPlayDevice(deviceID: "AA0000000002", name: "Kitchen", raop: fairPlay, service: raopService)
        #expect(!neither.usesAirPlay2)
        #expect(AirPlayPlayback(device: neither) == nil)
        #expect(AirPlayPINPairing(device: neither) == nil)
    }

    @Test("This Mac as receivers are told of it: a made-up address of the locally administered kind, a name, a model, a version")
    func thisMac() {
        let mac = AirPlay2Sender.thisMac
        let bytes = mac.deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        #expect(bytes.count == 6)
        #expect((bytes.first ?? 0) & 0x03 == 0x02)
        #expect(!mac.name.isEmpty && !mac.model.isEmpty)
        #expect(mac.osVersion.split(separator: ".").count == 3)
        #expect(AirPlay2Sender.thisMac == mac)
    }
}
