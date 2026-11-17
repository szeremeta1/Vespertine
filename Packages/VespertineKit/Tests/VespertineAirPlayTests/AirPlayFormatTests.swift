//
// Vespertine: the format an AirPlay stream is sent in: its name on the wire, what a receiver says it takes, and the
// choice for a song.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("AirPlay formats")
struct AirPlayFormatTests {
    static let deep48 = AirPlayFormat(sampleRate: 48_000, bitDepth: 24)
    static let deep44 = AirPlayFormat(sampleRate: 44_100, bitDepth: 24)
    static let plain48 = AirPlayFormat(sampleRate: 48_000, bitDepth: 16)

    @Test("Each format has its own bit, and one AirPlay can't name has none")
    func names() {
        #expect(AirPlayFormat.cd.streamFormat == 0x40000)
        #expect(Self.deep44.streamFormat == 0x80000)
        #expect(Self.plain48.streamFormat == 0x100000)
        #expect(Self.deep48.streamFormat == 0x200000)
        #expect(AirPlayFormat(sampleRate: 96_000, bitDepth: 24).streamFormat == nil)
        #expect(AirPlayFormat(sampleRate: 44_100, bitDepth: 32).streamFormat == nil)
        #expect(AirPlayFormat.all == [Self.deep48, Self.deep44, Self.plain48, .cd])
    }

    @Test("A receiver's number is read bit by bit")
    func masks() {
        #expect(AirPlayFormat.accepted(mask: 0) == [])
        #expect(AirPlayFormat.accepted(mask: 0x40000) == [.cd])
        #expect(AirPlayFormat.accepted(mask: 0x3C0000) == AirPlayFormat.all)
        #expect(AirPlayFormat.accepted(mask: 0x240000) == [Self.deep48, .cd])
        // Every format an Apple TV lists for its other streams, PCM and AAC among them.
        #expect(AirPlayFormat.accepted(mask: 0x3FFFFFC) == AirPlayFormat.all)
        // Formats that aren't ALAC at these rates say nothing.
        #expect(AirPlayFormat.accepted(mask: 0x1000800) == [])
    }

    @Test("The ALAC configuration of a format differs from the 16-bit one only in depth and rate")
    func configuration() {
        #expect(AirPlayFormat.cd.alac == ALACConfig())
        let config = Self.deep48.alac
        #expect(config.bitDepth == 24)
        #expect(config.sampleRate == 48_000)
        #expect(config.frameLength == 352)
        #expect(config.channels == 2)
        #expect(Array(config.cookie.prefix(12)) == [0, 0, 0x01, 0x60, 0, 24, 40, 10, 14, 2, 0, 0xff])
        #expect(Array(config.cookie.suffix(4)) == [0, 0, 0xBB, 0x80])
    }

    @Test("A receiver that takes only 16-bit at 44.1 kHz, or says nothing, gets that for every song")
    func plainReceiver() {
        for rate in [8_000.0, 44_100, 48_000, 88_200, 96_000, 192_000, 352_800, 2_822_400] {
            for depth in [false, true] {
                #expect(AirPlayFormat.choose(sourceRate: rate, wantsDepth: depth, accepted: []) == .cd)
                #expect(AirPlayFormat.choose(sourceRate: rate, wantsDepth: depth, accepted: [.cd]) == .cd)
            }
        }
    }

    @Test("A receiver that takes everything: the song's own rate family, and 24 bits only when they hold something")
    func wideReceiver() {
        let all = AirPlayFormat.all
        #expect(AirPlayFormat.choose(sourceRate: 44_100, wantsDepth: false, accepted: all) == .cd)
        #expect(AirPlayFormat.choose(sourceRate: 44_100, wantsDepth: true, accepted: all) == Self.deep44)
        #expect(AirPlayFormat.choose(sourceRate: 48_000, wantsDepth: false, accepted: all) == Self.plain48)
        #expect(AirPlayFormat.choose(sourceRate: 48_000, wantsDepth: true, accepted: all) == Self.deep48)
        #expect(AirPlayFormat.choose(sourceRate: 96_000, wantsDepth: true, accepted: all) == Self.deep48)
        #expect(AirPlayFormat.choose(sourceRate: 192_000, wantsDepth: true, accepted: all) == Self.deep48)
        #expect(AirPlayFormat.choose(sourceRate: 88_200, wantsDepth: true, accepted: all) == Self.deep44)
        #expect(AirPlayFormat.choose(sourceRate: 176_400, wantsDepth: true, accepted: all) == Self.deep44)
        // DSD64 is a multiple of 44.1 kHz.
        #expect(AirPlayFormat.choose(sourceRate: 2_822_400, wantsDepth: true, accepted: all) == Self.deep44)
        // Neither family: 44.1 kHz, as before.
        #expect(AirPlayFormat.choose(sourceRate: 32_000, wantsDepth: true, accepted: all) == Self.deep44)
        #expect(AirPlayFormat.choose(sourceRate: 22_050, wantsDepth: false, accepted: all) == .cd)
    }

    @Test("A receiver that takes some: the rate is kept where it can be, and 16-bit at 44.1 kHz is always there to fall to")
    func partialReceiver() {
        // 48 kHz only at 24 bits: a 16-bit 48 kHz song is sent in it (nothing is lost) and not resampled.
        #expect(AirPlayFormat.choose(sourceRate: 48_000, wantsDepth: false, accepted: [Self.deep48]) == Self.deep48)
        // 24 bits only at 44.1 kHz: a 96 kHz song keeps its depth there.
        #expect(AirPlayFormat.choose(sourceRate: 96_000, wantsDepth: true, accepted: [Self.deep44]) == Self.deep44)
        // A 16-bit 48 kHz song that must go at 44.1 kHz is resampled: 24 bits hold what that makes.
        #expect(AirPlayFormat.choose(sourceRate: 48_000, wantsDepth: false, accepted: [Self.deep44]) == Self.deep44)
        #expect(AirPlayFormat.choose(sourceRate: 96_000, wantsDepth: false, accepted: [Self.deep44]) == Self.deep44)
        // 48 kHz at 16 bits only: a 24-bit 48 kHz song keeps its rate.
        #expect(AirPlayFormat.choose(sourceRate: 48_000, wantsDepth: true, accepted: [Self.plain48]) == Self.plain48)
        // Nothing at 44.1 kHz but the format every receiver takes.
        #expect(AirPlayFormat.choose(sourceRate: 44_100, wantsDepth: true, accepted: [Self.deep48, Self.plain48]) == .cd)
    }

    @Test("What /info says a realtime stream takes is read, and an answer that doesn't say is not taken as 'nothing'")
    func info() {
        let apple: [String: Any] = ["audioFormats": [
            ["type": 100, "audioInputFormats": 0x3FFFFFC, "audioOutputFormats": 0x3FFFFFC],
            ["type": 96, "audioInputFormats": 0x240000, "audioOutputFormats": 0x40000],
        ]]
        #expect(AirPlay2Message.acceptedFormats(info: AirPlay2Message.encode(apple)) == [Self.deep48, .cd])
        let none: [String: Any] = ["audioFormats": [["type": 96, "audioInputFormats": 0x1000000]]]
        #expect(AirPlay2Message.acceptedFormats(info: AirPlay2Message.encode(none)) == [])
        let otherStreams: [String: Any] = ["audioFormats": [["type": 100, "audioInputFormats": 0x3FFFFFC]]]
        #expect(AirPlay2Message.acceptedFormats(info: AirPlay2Message.encode(otherStreams)) == nil)
        #expect(AirPlay2Message.acceptedFormats(info: AirPlay2Message.encode(["name": "Kitchen"])) == nil)
        #expect(AirPlay2Message.acceptedFormats(info: Data("not a property list".utf8)) == nil)
        #expect(AirPlay2Message.acceptedFormats(info: Data()) == nil)
    }

    @Test("The stream SETUP names the format and its rate; without one it is 16-bit at 44.1 kHz as before")
    func streamSetup() throws {
        let key = Data(repeating: 7, count: 32)
        func stream(_ body: Data) throws -> [String: Any] {
            let said = try #require(AirPlay2Message.decode(body))
            let streams = try #require(said["streams"] as? [[String: Any]])
            return try #require(streams.first)
        }
        let plain = try stream(AirPlay2Message.streamSetup(controlPort: 6_001, key: key, connectionID: 1))
        #expect(plain["audioFormat"] as? Int == 0x40000)
        #expect(plain["sr"] as? Int == 44_100)
        let deep = try stream(AirPlay2Message.streamSetup(controlPort: 6_001, key: key, connectionID: 1, format: Self.deep48))
        #expect(deep["audioFormat"] as? Int == 0x200000)
        #expect(deep["sr"] as? Int == 48_000)
        #expect(deep["ct"] as? Int == 2)
        #expect(deep["spf"] as? Int == 352)
        let unnamed = try stream(AirPlay2Message.streamSetup(controlPort: 6_001, key: key, connectionID: 1,
                                                             format: AirPlayFormat(sampleRate: 96_000, bitDepth: 24)))
        #expect(unnamed["audioFormat"] as? Int == 0x40000)
        #expect(unnamed["sr"] as? Int == 44_100)
    }

    @Test("A wish is plain when no receiver could do better than 16-bit at 44.1 kHz for it")
    func wishes() {
        #expect(AirPlayWish(sourceRate: 44_100, wantsDepth: false).isPlain)
        #expect(AirPlayWish(sourceRate: 22_050, wantsDepth: false).isPlain)
        #expect(!AirPlayWish(sourceRate: 44_100, wantsDepth: true).isPlain)
        #expect(!AirPlayWish(sourceRate: 48_000, wantsDepth: false).isPlain)
        #expect(!AirPlayWish(sourceRate: 96_000, wantsDepth: true).isPlain)
        #expect(AirPlayWish(sourceRate: 96_000, wantsDepth: true).format(accepted: []) == .cd)
        #expect(AirPlayWish(sourceRate: 96_000, wantsDepth: true).format(accepted: AirPlayFormat.all) == Self.deep48)
    }

    @Test("The two seconds behind, the sync packet's share of them and the least held, in frames of each rate")
    func latency() {
        #expect(AirPlayFormat.cd.latencyFrames == RAOPTiming.latencyFrames)
        #expect(AirPlayFormat.cd.syncLatencyFrames == RAOPTiming.syncLatencyFrames)
        #expect(AirPlayFormat.cd.latencyMin == 11_025)
        #expect(Self.deep48.latencyFrames == 96_000)
        #expect(Self.deep48.syncLatencyFrames == 84_000)
        #expect(Self.deep48.latencyMin == 12_000)
        let sync = RAOPPacket.sync(rtpNow: 100_000, ntp: 0, first: false, latency: Self.deep48.syncLatencyFrames)
        #expect(RAOPPacket.read32(sync, 4) == 16_000)
        #expect(RAOPPacket.read32(sync, 16) == 100_000)
        #expect(RAOPPacket.read32(RAOPPacket.sync(rtpNow: 100_000, ntp: 0, first: false), 4) == 22_825)
    }
}
