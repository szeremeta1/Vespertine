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

    /// Packets of 24-bit samples that try the edges: noise over the whole range, silence, both extremes, a tone, the
    /// lowest bit alone.
    static func deepPackets() -> [[Int32]] {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<704).map { _ in Int32.random(in: -8_388_608...8_388_607, using: &rng) }
        let silence = [Int32](repeating: 0, count: 704)
        let full = (0..<704).map { $0 % 2 == 0 ? Int32(8_388_607) : Int32(-8_388_608) }
        let sine = (0..<704).map { i in Int32((sin(Double(i / 2) * 2 * .pi * 997 / 48_000) * 8_000_000).rounded()) }
        let lsb = (0..<704).map { Int32($0 % 3) - 1 }
        return [noise, silence, full, sine, lsb, sine]
    }

    @Test("24-bit and 48 kHz: Apple's encoder gives back every sample, in each format a stream can name",
          arguments: AirPlayFormat.all)
    func formatsRoundTrip(format: AirPlayFormat) throws {
        let encoder = try ALACEncoder(config: format.alac)
        let decoder = try ALACDecoder(config: format.alac)
        let limit = Int32(1) << Int32(format.bitDepth - 1)
        for deep in Self.deepPackets() {
            // The same shapes at this depth: a 16-bit format gets the top 16 bits.
            let p = format.bitDepth == 24 ? deep : deep.map { $0 >> 8 }
            let packet = try encoder.encode(samples: p)
            #expect(packet.count > 0)
            #expect(packet.count <= 352 * 2 * format.bitDepth / 8 + 16)
            let back = try decoder.decode(samples: packet)
            #expect(back == p)
        }
        #expect(throws: ALACError.badInput) { try encoder.encode(samples: [1, 2]) }
        var tooLoud = [Int32](repeating: 0, count: 704)
        tooLoud[5] = limit
        #expect(throws: ALACError.badInput) { try encoder.encode(samples: tooLoud) }
    }

    @Test("24-bit verbatim frames: 2116 bytes, decoded exactly by Apple's decoder")
    func deepVerbatimRoundTrip() throws {
        let format = AirPlayFormat(sampleRate: 48_000, bitDepth: 24)
        let decoder = try ALACDecoder(config: format.alac)
        for p in Self.deepPackets() {
            let packet = ALACVerbatim.encode(samples: p, bitDepth: 24)
            #expect(packet.count == 2116)
            let back = try decoder.decode(samples: packet)
            #expect(back == p)
        }
    }

    @Test("A 16-bit encoder refuses what only a 24-bit one takes, and the other way round")
    func depthIsKept() throws {
        let deep = try ALACEncoder(config: AirPlayFormat(sampleRate: 44_100, bitDepth: 24).alac)
        #expect(throws: ALACError.badInput) { try deep.encode([Int16](repeating: 0, count: 704)) }
        let deepDecoder = try ALACDecoder(config: AirPlayFormat(sampleRate: 44_100, bitDepth: 24).alac)
        let packet = try deep.encode(samples: [Int32](repeating: 0, count: 704))
        #expect(throws: ALACError.badInput) { let _: [Int16] = try deepDecoder.decode(packet) }
        var odd = ALACConfig()
        odd.bitDepth = 20
        #expect(throws: ALACError.badInput) { _ = try ALACEncoder(config: odd) }
        #expect(throws: ALACError.badInput) { _ = try ALACDecoder(config: odd) }
    }
}
