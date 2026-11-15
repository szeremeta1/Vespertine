//
// Vespertine: AirPlay receivers' Bonjour records, and which ones phase 1 can send to.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("RAOP records")
struct RAOPRecordTests {
    /// What shairport-sync 4.x/5.x (moOde) publishes on `_raop._tcp`.
    static let shairport: [String: String] = ["cn": "0,1", "da": "true", "et": "0,1", "ft": "0x1C340405F4A00", "md": "0,1,2", "am": "Shairport Sync",
                                              "sf": "0x4", "tp": "UDP", "vn": "65537", "vs": "366.0", "ss": "16", "sr": "44100", "ch": "2"]

    @Test("moOde's shairport-sync: id and name from the service name, unencrypted ALAC")
    func shairportSync() throws {
        let r = try #require(RAOPRecord.parse(serviceName: "B827EB12ab34@moOde Living Room", txt: Self.shairport))
        #expect(r.deviceID == "B827EB12AB34")
        #expect(r.name == "moOde Living Room")
        #expect(r.encryptions == [0, 1])
        #expect(r.codecs == [0, 1])
        #expect(r.metadata == [0, 1, 2])
        #expect(r.model == "Shairport Sync")
        #expect(r.version == "366.0")
        let device = AirPlayDevice(deviceID: r.deviceID, name: r.name, raop: r)
        #expect(device.support == .supported(.none))
        #expect(device.uid == "raop:B827EB12AB34")
        #expect(AirPlayDevice.isAirPlayUID(device.uid))
        #expect(!AirPlayDevice.isAirPlayUID("upnp:uuid:1"))
    }

    @Test("An AirPort Express that wants RSA gets the encrypted session")
    func airPortExpress() throws {
        let r = try #require(RAOPRecord.parse(serviceName: "0019E3AABBCC@AirPort", txt: ["et": "1", "cn": "0,1", "ss": "16", "sr": "44100", "ch": "2", "tp": "TCP,UDP", "am": "AirPort4,107"]))
        #expect(AirPlayDevice(deviceID: r.deviceID, name: r.name, raop: r).support == .supported(.rsa))
    }

    @Test("FairPlay/MFi-only receivers and AirPlay 2-only devices are listed as not supported yet")
    func unsupported() throws {
        let fp = try #require(RAOPRecord.parse(serviceName: "AABBCCDDEEFF@TV", txt: ["et": "3,5", "cn": "1"]))
        #expect(AirPlayDevice(deviceID: fp.deviceID, name: fp.name, raop: fp).support == .unsupported(AirPlayDevice.airPlay2Only))
        let ap2 = try #require(AirPlayRecord.parse(serviceName: "Kitchen", txt: ["deviceid": "AA:BB:CC:DD:EE:01", "model": "AudioAccessory5,1"]))
        #expect(ap2.deviceID == "AABBCCDDEE01")
        #expect(AirPlayDevice(deviceID: ap2.deviceID, name: ap2.name, raop: nil, airplay: ap2).support == .unsupported(AirPlayDevice.airPlay2Only))
    }

    @Test("A password, another sample size or no ALAC is not supported")
    func otherLimits() throws {
        func support(_ txt: [String: String]) throws -> AirPlayDevice.Support {
            let r = try #require(RAOPRecord.parse(serviceName: "AABBCCDDEEFF@X", txt: txt))
            return AirPlayDevice(deviceID: r.deviceID, name: r.name, raop: r).support
        }
        #expect(try support(["et": "0", "pw": "true"]) != .supported(.none))
        #expect(try support(["et": "0", "ss": "24"]) == .unsupported(AirPlayDevice.formatUnsupported))
        #expect(try support(["et": "0", "cn": "0,2"]) == .unsupported(AirPlayDevice.formatUnsupported))
        #expect(try support(["et": "0", "tp": "TCP"]) == .unsupported(AirPlayDevice.formatUnsupported))
        // HomePods and Apple TVs list 0 among FairPlay types: best effort, sent unencrypted.
        #expect(try support(["et": "0,3,5", "cn": "0,1,2,3", "pw": "false"]) == .supported(.none))
        // Nothing stated: the old defaults (PCM and ALAC, no encryption).
        #expect(try support([:]) == .supported(.none))
    }

    @Test("Names without a MAC aren't RAOP services")
    func malformed() {
        #expect(RAOPRecord.parse(serviceName: "Living Room", txt: [:]) == nil)
        #expect(RAOPRecord.parse(serviceName: "zz@Living Room", txt: [:]) == nil)
        #expect(RAOPRecord.parse(serviceName: "AABB@", txt: [:]) == nil)
    }
}
