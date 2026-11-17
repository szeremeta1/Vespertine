//
// Vespertine: AirPlay receivers that show a code on their screen (an Apple TV set to ask). Choosing one never paired
// with asks for the code; the code typed is traded for keys that are kept under the receiver's id, with one identity of
// this Mac for all receivers; a wrong code keeps nothing; Forget removes what was kept. No receiver is spoken to here:
// the exchange itself is a stand-in (the real one is tested in VespertineKit against the fake receiver).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAirPlay
import VespertineAudio
import VespertineUPnP
@testable import Vespertine

private final class QuietBrowser: BonjourBrowsing, @unchecked Sendable {
    var isBrowsing: Bool { false }
    func start(onChange: @escaping @Sendable ([BonjourResult]) -> Void) {}
    func stop() {}
}

@MainActor private final class Picked {
    var list: [String] = []
}

/// What the stand-in exchange was asked to do.
private struct Asked: Sendable {
    var begun: [String] = []
    var codes: [String] = []
    var identities: [AirPlayPairingIdentity] = []
    var cancelled = 0
}

@Suite("AirPlay pairing by code", .serialized) @MainActor
struct AirPlayPairingTests {
    /// What a HomePod mini advertises.
    static let features = "0x4A7FCA00,0xBC354BD0"

    private func receiver(flags: String, id: String = "AA:00:00:00:00:02") throws -> AirPlayDevice {
        let record = try #require(AirPlayRecord.parse(serviceName: "Living Room", txt: ["deviceid": id, "features": Self.features, "flags": flags]))
        return AirPlayDevice(deviceID: record.deviceID, name: record.name, raop: nil, airplay: record,
                             airplayService: BonjourService(name: record.name, type: "_airplay._tcp"))
    }

    /// Keys as a pairing gives them (their own parts aren't the app's to make: they are read from what was kept).
    private func keys(_ fill: UInt8) throws -> AirPlayPairingKeys {
        let bytes = Data(repeating: fill, count: 32).base64EncodedString()
        let text = #"{"identity":{"id":"6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F","seed":"\#(bytes)"},"receiver":{"id":"\#(bytes)","publicKey":"\#(bytes)"}}"#
        return try #require(AirPlayPairings.decode(AirPlayPairingKeys.self, text))
    }

    private func model(_ pairings: AirPlayPairings, answer: @escaping @Sendable (String) throws -> AirPlayPairingKeys,
                       reachable: Bool = true) -> (AirPlayOutputModel, Locked<Asked>) {
        let model = AirPlayOutputModel(service: AirPlayService(discovery: AirPlayDiscovery(browser: QuietBrowser(), excludedName: nil)))
        let asked = Locked(Asked())
        model.pairings = pairings
        model.passwords = .memory()
        model.pairer = AirPlayPairer(
            begin: { device in
                asked.withLock { $0.begun.append(device.deviceID) }
                if !reachable { throw RAOPError.unreachable }
            },
            finish: { code, identity in
                asked.withLock { $0.codes.append(code); $0.identities.append(identity) }
                return try answer(code)
            },
            cancel: { asked.withLock { $0.cancelled += 1 } })
        return (model, asked)
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Which receivers ask for a code, and what the output list says of them")
    func which() throws {
        let appleTV = try receiver(flags: "0x204")
        let homePod = try receiver(flags: "0x4")
        #expect(appleTV.needsPairingCode && appleTV.isSupported)
        #expect(!homePod.needsPairingCode && homePod.isSupported)
        #expect(AirPlayText.detail(appleTV) == "AIRPLAY 2 · ALAC 16/44.1 · CODE")
        #expect(AirPlayText.detail(homePod) == "AIRPLAY 2 · ALAC 16/44.1")
        // One that asks for a password can't be played to yet, and says so.
        let locked = try receiver(flags: "0x84")
        #expect(!locked.isSupported && !locked.needsPairingCode)
        #expect(AirPlayText.detail(locked) == "AIRPLAY 2 ONLY — NOT SUPPORTED YET")
        #expect(AirPlayPairings.account("AA0000000002") == "airplay-pairing-AA0000000002")
    }

    @Test("Choosing a receiver that shows a code asks for it; one already paired with, or one that shows none, is chosen at once")
    func choosing() async throws {
        let appleTV = try receiver(flags: "0x204")
        let kept = try keys(7)
        let picked = Picked()
        let (fresh, asked) = model(.memory()) { _ in kept }
        fresh.choose(appleTV) { picked.list.append($0) }
        await settle { fresh.pairingRequest != nil }
        #expect(fresh.pairingRequest == AirPlayPairingRequest(device: appleTV))
        #expect(picked.list.isEmpty)
        // Nothing is said to the receiver until the sheet is up.
        #expect(asked.withLock { $0.begun }.isEmpty)

        let pairings = AirPlayPairings.memory()
        pairings.write(kept, appleTV.deviceID)
        let (paired, _) = model(pairings) { _ in kept }
        paired.choose(appleTV) { picked.list.append($0) }
        await settle { !picked.list.isEmpty }
        #expect(picked.list == [appleTV.uid])
        #expect(paired.pairingRequest == nil)

        let homePod = try receiver(flags: "0x4", id: "AA:00:00:00:00:03")
        let (open, _) = model(.memory()) { _ in kept }
        open.choose(homePod) { picked.list.append($0) }
        #expect(picked.list == [appleTV.uid, homePod.uid])
        #expect(open.pairingRequest == nil && open.passwordRequest == nil)
    }

    @Test("The code typed pairs: the keys are kept under the receiver's id and it is chosen; a wrong code keeps nothing and asks again")
    func pairing() async throws {
        let appleTV = try receiver(flags: "0x204")
        let kept = try keys(9)
        let pairings = AirPlayPairings.memory()
        let (airPlay, asked) = model(pairings) { code in
            guard code == "3939" else { throw PairingError.authentication }
            return kept
        }
        let picked = Picked()
        airPlay.choose(appleTV) { picked.list.append($0) }
        await settle { airPlay.pairingRequest != nil }
        let shown = await airPlay.beginPairing()
        #expect(shown == nil)
        #expect(asked.withLock { $0.begun } == [appleTV.deviceID])

        let wrong = await airPlay.submit(code: "1234", select: { picked.list.append($0) })
        #expect(wrong == .wrongCode)
        #expect(pairings.read(appleTV.deviceID) == nil)
        #expect(picked.list.isEmpty)
        #expect(airPlay.pairingRequest != nil)

        let shownAgain = await airPlay.beginPairing()
        #expect(shownAgain == nil)
        let right = await airPlay.submit(code: "3939", select: { picked.list.append($0) })
        #expect(right == .paired)
        #expect(pairings.read(appleTV.deviceID) == kept)
        #expect(picked.list == [appleTV.uid])
        #expect(airPlay.pairingRequest == nil)
        // This Mac is one and the same to every receiver, every time.
        let identities = asked.withLock { $0.identities }
        #expect(identities.count == 2 && identities[0] == identities[1])
        #expect(pairings.identity() == identities[0])
        #expect(asked.withLock { $0.codes } == ["1234", "3939"])

        await airPlay.forgetPairing(for: appleTV)
        #expect(pairings.read(appleTV.deviceID) == nil)
        #expect(pairings.identity() == identities[0])
    }

    @Test("A receiver that can't be asked for its code, or refuses the pairing, says why; Cancel lets go of it and keeps nothing")
    func failing() async throws {
        let appleTV = try receiver(flags: "0x204")
        let pairings = AirPlayPairings.memory()
        let (away, asked) = model(pairings, answer: { _ in throw PairingError.tryLater(seconds: 30) }, reachable: false)
        let picked = Picked()
        away.choose(appleTV) { picked.list.append($0) }
        await settle { away.pairingRequest != nil }
        let unreachable = await away.beginPairing()
        #expect(unreachable == "it can't be reached")
        let refused = await away.submit(code: "3939", select: { picked.list.append($0) })
        #expect(refused == .failed("it asks to wait before another try"))
        #expect(pairings.read(appleTV.deviceID) == nil && picked.list.isEmpty)
        away.cancelPairing()
        #expect(away.pairingRequest == nil)
        await settle { asked.withLock { $0.cancelled } == 1 }
        #expect(asked.withLock { $0.cancelled } == 1)
        // With no sheet up, nothing is asked of any receiver.
        let nothing = await away.beginPairing()
        #expect(nothing == nil)
        #expect(asked.withLock { $0.begun } == [appleTV.deviceID])
    }

    @Test("A playback for a receiver that shows a code reads the kept keys, and asks for the code when the receiver refuses them")
    func playback() async throws {
        let appleTV = try receiver(flags: "0x204")
        let kept = try keys(5)
        let pairings = AirPlayPairings.memory()
        pairings.write(kept, appleTV.deviceID)
        let (airPlay, _) = model(pairings) { _ in kept }
        let made = try #require(airPlay.playback(for: appleTV, settings: RendererSettings(), receiverVolumeDB: -20))
        defer { made.shutdown() }
        let read = made.pairingProvider?()
        #expect(read == kept)
        made.pairingRefused?()
        await settle { airPlay.pairingRequest != nil }
        #expect(airPlay.pairingRequest == AirPlayPairingRequest(device: appleTV))
    }
}
