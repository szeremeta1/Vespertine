//
// Vespertine: the bytes of a RAOP session: RTP audio, sync, timing, retransmission, DMAP, SDP and RTSP.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("RAOP packets")
struct RAOPPacketTests {
    @Test("Audio: version 2, payload type 96, the marker on the first; seq, rtptime, SSRC big-endian")
    func audio() throws {
        let p = RAOPPacket.audio(seq: 0x1234, timestamp: 0xA0B0C0D0, ssrc: 0x01020304, payload: Data([9, 8, 7]), first: true)
        #expect(Array(p) == [0x80, 0xE0, 0x12, 0x34, 0xA0, 0xB0, 0xC0, 0xD0, 1, 2, 3, 4, 9, 8, 7])
        let parsed = try #require(RAOPPacket.parseAudio(p))
        #expect(parsed.seq == 0x1234 && parsed.timestamp == 0xA0B0C0D0 && parsed.payload == Data([9, 8, 7]))
        #expect(RAOPPacket.audio(seq: 1, timestamp: 2, ssrc: 3, payload: Data(), first: false)[1] == 0x60)
        // A resent packet carries the original after a 4-byte header.
        let resent = RAOPPacket.resend(p)
        #expect(Array(resent.prefix(4)) == [0x80, 0xD6, 0x00, 0x01])
        #expect(RAOPPacket.parseAudio(resent.dropFirst(4)) != nil)
    }

    @Test("Sync: 0x90 first then 0x80, type 0xD4, 7; rtptime less latency, NTP, rtptime")
    func sync() throws {
        let p = RAOPPacket.sync(rtpNow: 100_000, ntp: 0x0102030405060708, first: true)
        #expect(p.count == 20)
        #expect(Array(p.prefix(4)) == [0x90, 0xD4, 0x00, 0x07])
        let s = try #require(RAOPPacket.parseSync(p))
        #expect(s.rtp == 100_000 && s.rtpLessLatency == 100_000 - 77_175 && s.ntp == 0x0102030405060708)
        #expect(RAOPPacket.sync(rtpNow: 10, ntp: 0, first: false)[0] == 0x80)
        // Wraps like the RTP clock does.
        #expect(RAOPPacket.parseSync(RAOPPacket.sync(rtpNow: 5, ntp: 0, first: false))?.rtpLessLatency == 5 &- 77_175)
    }

    @Test("Timing: the reply echoes the request's transmit time as reference")
    func timing() throws {
        let request = RAOPPacket.timingRequest(transmit: 0xAABBCCDD11223344)
        #expect(request.count == 32)
        let reply = try #require(RAOPPacket.timingReply(request: request, receive: 5, transmit: 6))
        #expect(reply.count == 32 && reply[0] == 0x80 && reply[1] == 0xD3)
        let t = try #require(RAOPPacket.parseTimingReply(reply))
        #expect(t.reference == 0xAABBCCDD11223344 && t.receive == 5 && t.transmit == 6)
        #expect(RAOPPacket.timingReply(request: Data([0x80, 0xD4]) + Data(count: 30), receive: 0, transmit: 0) == nil)
    }

    @Test("Resend requests")
    func resend() {
        let r = RAOPPacket.resendRequest(seq: 65_535, count: 3)
        #expect(RAOPPacket.parseResendRequest(r)! == (65_535, 3))
        #expect(RAOPPacket.parseResendRequest(Data([0x80, 0xD4, 0, 0, 0, 0, 0, 0])) == nil)
    }

    @Test("The NTP clock runs forward at one second a second")
    func clock() async throws {
        let a = NTPClock.now()
        try await Task.sleep(for: .milliseconds(100))
        let b = NTPClock.now()
        let seconds = Double(b - a) / 4_294_967_296
        #expect(seconds > 0.09 && seconds < 0.5)
        #expect(a >> 32 > 3_900_000_000)   // a date after 2023
    }

    @Test("Volume: 0…1 linear over −30…0 dB, silence −144; a dot whatever the locale")
    func volume() {
        #expect(RAOPVolume.decibels(level: 1) == 0)
        #expect(RAOPVolume.decibels(level: 0.5) == -15)
        #expect(RAOPVolume.decibels(level: 0) == -144)
        #expect(RAOPVolume.parameter(decibels: -15.25) == "volume: -15.250000\r\n")
    }

    @Test("DMAP: an mlit with title, artist and album")
    func dmap() {
        let d = DMAP.item(title: "Só", artist: "A", album: nil)
        #expect(Array(d.prefix(4)) == Array("mlit".utf8))
        let tags = DMAP.parse(d)
        #expect(tags["minm"] == Data("Só".utf8))
        #expect(tags["asar"] == Data("A".utf8))
        #expect(tags["asal"] == nil)
    }

    @Test("SDP: ALAC 352/16/44100/2; keys only when encrypted, base64 without padding")
    func sdp() {
        let plain = SDP.announce(sessionID: 7, local: "10.0.0.2", remote: "10.0.0.9")
        #expect(plain.contains("a=rtpmap:96 AppleLossless\r\n"))
        #expect(plain.contains("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r\n"))
        #expect(plain.contains("o=iTunes 7 0 IN IP4 10.0.0.2\r\n") && plain.contains("c=IN IP4 10.0.0.9\r\n"))
        #expect(!plain.contains("rsaaeskey"))
        let enc = SDP.announce(sessionID: 7, local: "a", remote: "b", rsaAESKey: Data([1, 2, 3, 4]), aesIV: Data(repeating: 0xff, count: 16))
        let attributes = SDP.attributes(enc)
        #expect(attributes["fmtp"] == SDP.fmtp)
        #expect(attributes["rsaaeskey"] == "AQIDBA")
        #expect(SDP.base64(attributes["aesiv"]!) == Data(repeating: 0xff, count: 16))
    }

    @Test("RTSP: requests and answers round trip, bodies by Content-Length, bytes arriving in pieces")
    func rtsp() throws {
        let request = RTSPMessage.request("ANNOUNCE", "rtsp://10.0.0.2/1", headers: [("CSeq", "2"), ("Content-Type", "application/sdp")], body: Data("v=0\r\n".utf8))
        let bytes = request.encoded() + RTSPMessage.response(200, headers: [("CSeq", "2"), ("Session", "ABC")]).encoded()
        var parser = RTSPParser()
        var got: [RTSPMessage] = []
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            parser.append(bytes.subdata(in: chunk..<min(chunk + 7, bytes.count)))
            while let m = try parser.next() { got.append(m) }
        }
        #expect(got.count == 2)
        #expect(got[0].method == "ANNOUNCE" && got[0].url == "rtsp://10.0.0.2/1" && got[0].body == Data("v=0\r\n".utf8))
        #expect(got[0]["content-type"] == "application/sdp")
        #expect(got[1].status == 200 && got[1]["session"] == "ABC")
        var bad = RTSPParser()
        bad.append(Data("RTSP/1.0 x\r\n\r\n".utf8))
        #expect(throws: RTSPParseError.self) { try bad.next() }
    }

    @Test("SETUP transport: asked with our ports, answered with the receiver's")
    func transport() {
        #expect(RAOPTransport.request(control: 6001, timing: 6002) == "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=6001;timing_port=6002")
        #expect(RAOPTransport.parse("RTP/AVP/UDP;unicast;mode=record;server_port=6000;control_port=6001;timing_port=6002") == RAOPTransport(server: 6000, control: 6001, timing: 6002))
        #expect(RAOPTransport.parse("RTP/AVP/UDP;unicast;server_port=6000") == nil)
    }
}
