//
// Vespertine: ALAC packets decode to exactly the samples encoded, with Apple's encoder and the verbatim frame.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("ALAC")
struct ALACTests {
    static func packets() -> [[Int16]] {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<704).map { _ in Int16.random(in: .min ... .max, using: &rng) }
        let silence = [Int16](repeating: 0, count: 704)
        let full = (0..<704).map { $0 % 2 == 0 ? Int16.max : Int16.min }
        let sine = (0..<704).map { i in Int16((sin(Double(i / 2) * 2 * .pi * 997 / 44_100) * 30_000).rounded()) }
        let lsb = (0..<704).map { Int16($0 % 3) - 1 }
        return [noise, silence, full, sine, lsb, sine]
    }

    @Test("The config's cookie is the fmtp, read back")
    func config() throws {
        let c = try #require(ALACConfig(fmtp: SDP.fmtp))
        #expect(c == ALACConfig())
        #expect(c.cookie.count == 24)
        #expect(Array(c.cookie.prefix(12)) == [0, 0, 0x01, 0x60, 0, 16, 40, 10, 14, 2, 0, 0xff])
        #expect(ALACConfig(fmtp: "352 0 16") == nil)
    }

    @Test("Apple's encoder: what is decoded is what was encoded, packet after packet")
    func appleRoundTrip() throws {
        let encoder = try ALACEncoder()
        let decoder = try ALACDecoder(config: try #require(ALACConfig(fmtp: SDP.fmtp)))
        for p in Self.packets() {
            let packet = try encoder.encode(p)
            #expect(packet.count > 0 && packet.count <= 1416)
            #expect(try decoder.decode(packet) == p)
        }
        // Music-like input compresses.
        #expect(try encoder.encode(Self.packets()[3]).count < 1000)
        #expect(throws: ALACError.badInput) { try encoder.encode([1, 2]) }
    }

    @Test("Verbatim frames: 1412 bytes, decoded exactly by Apple's decoder")
    func verbatimRoundTrip() throws {
        let decoder = try ALACDecoder()
        for p in Self.packets() {
            let packet = ALACVerbatim.encode(p)
            #expect(packet.count == 1412)
            #expect(try decoder.decode(packet) == p)
        }
    }
}
