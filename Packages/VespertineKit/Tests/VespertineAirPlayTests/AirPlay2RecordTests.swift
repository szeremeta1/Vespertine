//
// Vespertine: what a receiver's `_airplay._tcp` record says about AirPlay 2: its features and flags read from the TXT
// record, and from them whether a session could begin and how (no PIN, or the PIN on its screen).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("AirPlay 2 records")
struct AirPlay2RecordTests {
    /// What a HomePod mini advertises.
    static let homePodFeatures = "0x4A7FCA00,0xBC354BD0"

    private func record(features: String?, flags: String? = nil) -> AirPlayRecord? {
        var txt = ["deviceid": "AA:00:00:00:00:02", "model": "AudioAccessory5,1"]
        txt["features"] = features
        txt["flags"] = flags
        return AirPlayRecord.parse(serviceName: "Kitchen", txt: txt)
    }

    @Test("Features and flags are read as bits: low half then high half, with or without 0x, in either case")
    func bits() {
        #expect(AirPlayRecord.bits("0x4A7FCA00,0xBC354BD0") == 0xBC35_4BD0_4A7F_CA00)
        #expect(AirPlayRecord.bits("0x4a7fca00, 0xbc354bd0") == 0xBC35_4BD0_4A7F_CA00)
        #expect(AirPlayRecord.bits("4A7FCA00") == 0x4A7F_CA00)
        #expect(AirPlayRecord.bits("0X4") == 4)
        #expect(AirPlayRecord.bits("0x0") == 0)
        // One part may be all 64 bits; two parts are 32 each.
        #expect(AirPlayRecord.bits("0x1C340445F8A00") == 0x1_C340_445F_8A00)
        #expect(AirPlayRecord.bits("0x1C340445F8A00,0x1") == nil)
        #expect(AirPlayRecord.bits("") == nil)
        #expect(AirPlayRecord.bits("0x") == nil)
        #expect(AirPlayRecord.bits("yes") == nil)
        #expect(AirPlayRecord.bits("0x1,") == nil)
        #expect(AirPlayRecord.bits("0x1,0x2,0x3") == nil)
        #expect(AirPlayRecord.bits("-1") == nil)
    }

    @Test("A HomePod's record: audio, pairing, and no PIN unless its flags say so")
    func homePod() throws {
        let open = try #require(record(features: Self.homePodFeatures, flags: "0x4"))
        #expect(open.features == 0xBC35_4BD0_4A7F_CA00)
        #expect(open.flags == 4)
        #expect(open.playsAudio && open.pairs)
        #expect(!open.asksForPIN && !open.asksForPassword)
        for flags in ["0x20C", "0x8", "0x200"] {
            let asking = try #require(record(features: Self.homePodFeatures, flags: flags))
            #expect(asking.asksForPIN, "flags \(flags)")
        }
        let password = try #require(record(features: Self.homePodFeatures, flags: "0x84"))
        #expect(password.asksForPassword && !password.asksForPIN)
        // No flags at all: nothing is asked for.
        let silent = try #require(record(features: Self.homePodFeatures))
        #expect(!silent.asksForPIN && !silent.asksForPassword)
    }

    @Test("Each pairing bit alone is enough; audio alone, or pairing alone, is not a receiver to play to")
    func featureBits() throws {
        for bit in [38, 43, 46, 48] {
            let value: UInt64 = 1 << UInt64(bit) | 1 << 9
            let text = String(format: "0x%X,0x%X", UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32))
            let one = try #require(record(features: text))
            #expect(one.playsAudio && one.pairs, "bit \(bit)")
        }
        let audioOnly = try #require(record(features: "0x200"))
        #expect(audioOnly.playsAudio && !audioOnly.pairs)
        let pairingOnly = try #require(record(features: "0x0,0x10000"))
        #expect(!pairingOnly.playsAudio && pairingOnly.pairs)
        let none = try #require(record(features: nil))
        #expect(none.features == nil && !none.playsAudio && !none.pairs)
        let unreadable = try #require(record(features: "lots"))
        #expect(unreadable.features == nil)
    }

    @Test("How a session would begin: open, with a PIN, or not at all")
    func entry() throws {
        func device(features: String?, flags: String? = nil) throws -> AirPlayDevice {
            AirPlayDevice(deviceID: "AA0000000002", name: "Kitchen", raop: nil, airplay: try #require(record(features: features, flags: flags)))
        }
        #expect(try device(features: Self.homePodFeatures, flags: "0x4").airPlay2Entry == .open)
        #expect(try device(features: Self.homePodFeatures).airPlay2Entry == .open)
        #expect(try device(features: Self.homePodFeatures, flags: "0x200").airPlay2Entry == .pin)
        #expect(try device(features: Self.homePodFeatures, flags: "0x8").airPlay2Entry == .pin)
        // A password is not something this sender can answer in AirPlay 2 yet.
        #expect(try device(features: Self.homePodFeatures, flags: "0x80").airPlay2Entry == nil)
        #expect(try device(features: "0x200").airPlay2Entry == nil)
        #expect(try device(features: nil).airPlay2Entry == nil)
        #expect(AirPlayDevice(deviceID: "B827EB000001", name: "moOde", raop: nil).airPlay2Entry == nil)
        // A receiver a session can begin with can be chosen; one it can't begin with can't.
        #expect(try device(features: Self.homePodFeatures).isSupported)
        #expect(try device(features: Self.homePodFeatures, flags: "0x200").isSupported)
        #expect(try device(features: Self.homePodFeatures, flags: "0x80").support == .unsupported(AirPlayDevice.airPlay2Only))
        #expect(try device(features: "0x200").isSupported == false)
    }

    @Test("Discovery keeps the AirPlay 2 service beside the AirPlay 1 one, and alone when it is the only one")
    func services() {
        let raop = BonjourResult(service: BonjourService(name: "B827EB000001@moOde", type: "_raop._tcp"), txt: ["et": "0", "cn": "0,1"])
        let both = BonjourResult(service: BonjourService(name: "moOde", type: "_airplay._tcp"), txt: ["deviceid": "B8:27:EB:00:00:01", "features": "0x200,0x10000"])
        let only = BonjourResult(service: BonjourService(name: "Kitchen", type: "_airplay._tcp"),
                                 txt: ["deviceid": "AA:00:00:00:00:02", "features": Self.homePodFeatures, "flags": "0x4"])
        let list = AirPlayDiscovery.merge([raop, both, only], excluding: nil)
        #expect(list.map(\.name) == ["Kitchen", "moOde"])
        #expect(list[0].service == nil)
        #expect(list[0].airplayService == only.service)
        #expect(list[0].airPlay2Entry == .open)
        #expect(list[1].service == raop.service)
        #expect(list[1].airplayService == both.service)
        #expect(list[1].airPlay2Entry == .open)
        #expect(list[1].isSupported)
    }
}
