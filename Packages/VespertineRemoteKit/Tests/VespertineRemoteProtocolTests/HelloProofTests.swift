//
// Vespertine: a hello must come from the device it names.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

@Suite struct HelloProofs {
    private let mac = "6F1C2B0E-0000-4000-8000-00000000AAAA"
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    @Test func aPhoneWithItsOwnKeyIsLetInAndCountsAsProved() {
        let proof = HelloProof.make(key: keyA, serverID: mac, device: "phone-a")
        #expect(proof.count == 32)
        #expect(HelloProof.verdict(proof: proof, key: keyA, serverID: mac, device: "phone-a", provedBefore: false) == .admitted(proved: true))
        #expect(HelloProof.verdict(proof: proof, key: keyA, serverID: mac, device: "phone-a", provedBefore: true) == .admitted(proved: true))
    }

    /// The listener accepts every paired phone's key, so phone A's connection gets through TLS; saying hello as phone B
    /// must not work with anything A can make.
    @Test func onePairedPhoneCannotSignInAsAnother() {
        let madeWithItsOwnKey = HelloProof.make(key: keyA, serverID: mac, device: "phone-b")
        #expect(HelloProof.verdict(proof: madeWithItsOwnKey, key: keyB, serverID: mac, device: "phone-b", provedBefore: true) == .refused)
        #expect(HelloProof.verdict(proof: madeWithItsOwnKey, key: keyB, serverID: mac, device: "phone-b", provedBefore: false) == .refused)
        let itsOwnProof = HelloProof.make(key: keyA, serverID: mac, device: "phone-a")
        #expect(HelloProof.verdict(proof: itsOwnProof, key: keyB, serverID: mac, device: "phone-b", provedBefore: true) == .refused)
        // And sending none stops working once the real phone B has proved itself.
        #expect(HelloProof.verdict(proof: nil, key: keyB, serverID: mac, device: "phone-b", provedBefore: true) == .refused)
    }

    @Test func aPhoneAppFromBeforeTheProofIsStillLetIn() {
        #expect(HelloProof.verdict(proof: nil, key: keyA, serverID: mac, device: "phone-a", provedBefore: false) == .admitted(proved: false))
    }

    @Test func aProofIsForOneMacAndOneDevice() {
        let proof = HelloProof.make(key: keyA, serverID: mac, device: "phone-a")
        #expect(proof != HelloProof.make(key: keyA, serverID: "another-mac", device: "phone-a"))
        #expect(proof != HelloProof.make(key: keyA, serverID: mac, device: "phone-c"))
        #expect(HelloProof.verdict(proof: proof, key: keyA, serverID: "another-mac", device: "phone-a", provedBefore: false) == .refused)
    }

    @Test func aProofOfTheWrongLengthIsRefused() {
        let proof = HelloProof.make(key: keyA, serverID: mac, device: "phone-a")
        #expect(HelloProof.verdict(proof: proof.prefix(31), key: keyA, serverID: mac, device: "phone-a", provedBefore: false) == .refused)
        #expect(HelloProof.verdict(proof: Data(), key: keyA, serverID: mac, device: "phone-a", provedBefore: false) == .refused)
        #expect(HelloProof.verdict(proof: proof + [0], key: keyA, serverID: mac, device: "phone-a", provedBefore: false) == .refused)
    }

    /// A Mac from before the proof decodes a hello that carries one (it ignores the field), and a hello without one is
    /// byte for byte what it always was.
    @Test func theProofRidesInHelloWithoutChangingItsOldShape() throws {
        let proof = Data([1, 2, 3])
        let hello = ClientMessage(id: 1, command: .hello(device: "d", name: "Phone", protocolVersion: 1, highestProtocolVersion: 2, proof: proof))
        let text = String(decoding: try RemoteProtocol.encoder().encode(hello), as: UTF8.self)
        #expect(text == #"{"command":{"hello":{"device":"d","highestProtocolVersion":2,"name":"Phone","proof":"AQID","protocolVersion":1}},"id":1}"#)
        #expect(try RemoteProtocol.decoder().decode(ClientMessage.self, from: Data(text.utf8)) == hello)
        let old = #"{"id":1,"command":{"hello":{"device":"d","name":"Phone","protocolVersion":1,"highestProtocolVersion":2}}}"#
        #expect(try RemoteProtocol.decoder().decode(ClientMessage.self, from: Data(old.utf8)).command
                == .hello(device: "d", name: "Phone", protocolVersion: 1, highestProtocolVersion: 2, proof: nil))
    }
}
