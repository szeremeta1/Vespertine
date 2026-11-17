//
// Vespertine: the PTP clock's messages, byte for byte against the layout of IEEE 1588-2008, and read back.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("PTP clock messages")
struct PTPMessagesTests {
    let clock = PTPMessage.identity(address: [0x02, 0x1A, 0xFF, 0x00, 0x9C, 0x07])

    @Test("A clock's identity is its address with FF FE in the middle")
    func identity() {
        #expect(clock == 0x021A_FFFF_FE00_9C07)
        #expect(PTPMessage.identity(address: []) == 0x0000_00FF_FE00_0000)
    }

    @Test("A moment is 6 bytes of seconds and 4 of nanoseconds, and comes back whole")
    func timestamps() {
        let t = PTPTimestamp(totalNanoseconds: 1_763_400_000_123_456_789)
        #expect(t == PTPTimestamp(seconds: 1_763_400_000, nanoseconds: 123_456_789))
        #expect(t.totalNanoseconds == 1_763_400_000_123_456_789)
        #expect(Data(t.bytes) == hex("0000691b5940075bcd15"))
        #expect(PTPTimestamp(Data(t.bytes), at: 0) == t)
        // Seconds past 32 bits, read from the middle of a longer buffer.
        let far = PTPTimestamp(seconds: 0x0123_4567_89AB, nanoseconds: 999_999_999)
        #expect(Data(far.bytes) == hex("0123456789ab3b9ac9ff"))
        let inside = (Data([9, 9, 9]) + Data(far.bytes)).dropFirst(1)
        #expect(PTPTimestamp(inside, at: 2) == far)
    }

    @Test("Announce: this clock, its own master, claiming the least")
    func announce() throws {
        let message = PTPMessage.announce(clock: clock, sequence: 0x0102)
        #expect(message == hex("1b02004000000008000000000000000000000000021afffffe009c0700010102050000000000000000000000002500f8f8fe436af8021afffffe009c070000a0"))
        #expect(message.count == 64)
        let read = try #require(PTPMessage.read(message))
        #expect(read.kind == .announce)
        #expect(read.clock == clock)
        #expect(read.port == 1)
        #expect(read.sequence == 0x0102)
        #expect(read.flags == 0x0008)
        #expect(read.body.count == 30)
    }

    @Test("Sync carries no moment of its own; the Follow_Up with the same number says when it left")
    func syncAndFollowUp() throws {
        let sync = PTPMessage.sync(clock: clock, sequence: 7)
        #expect(sync == hex("1002002c00000208000000000000000000000000021afffffe009c070001000700fd00000000000000000000"))
        let sent = PTPTimestamp(seconds: 1_763_400_000, nanoseconds: 123_456_789)
        let follow = PTPMessage.followUp(clock: clock, sequence: 7, sent: sent)
        #expect(follow == hex("1802002c00000008000000000000000000000000021afffffe009c070001000702fd0000691b5940075bcd15"))
        let read = try #require(PTPMessage.read(follow))
        #expect(read.kind == .followUp)
        #expect(read.sequence == 7)
        #expect(read.time == sent)
        #expect(PTPMessage.read(sync)?.flags == 0x0208)
        #expect(PTPMessage.read(sync)?.time == PTPTimestamp(seconds: 0, nanoseconds: 0))
    }

    @Test("A Delay_Req is read for who asked and its number, and the answer says both back with the moment it arrived")
    func delay() throws {
        // As a receiver would send it: its own clock and port, number 0x0BB8.
        let asked = hex("1102002c00000408000000000000000000000000f01898fffe12345680010bb8017f00000000000000000000")
        let request = try #require(PTPMessage.delayRequest(asked))
        #expect(request == PTPMessage.Request(clock: 0xF018_98FF_FE12_3456, port: 0x8001, sequence: 0x0BB8))
        let received = PTPTimestamp(seconds: 1_763_400_001, nanoseconds: 5)
        let answer = PTPMessage.delayResponse(clock: clock, to: request, received: received)
        #expect(answer == hex("1902003600000008000000000000000000000000021afffffe009c0700010bb803000000691b594100000005f01898fffe1234568001"))
        let read = try #require(PTPMessage.read(answer))
        #expect(read.kind == .delayResponse)
        #expect(read.time == received)
        #expect(read.body.suffix(10) == hex("f01898fffe1234568001"))
        // Only a Delay_Req is one.
        #expect(PTPMessage.delayRequest(PTPMessage.sync(clock: clock, sequence: 1)) == nil)
        #expect(PTPMessage.delayRequest(answer) == nil)
    }

    @Test("What isn't a whole version 2 message of a known kind is not read")
    func malformed() {
        let sync = PTPMessage.sync(clock: clock, sequence: 1)
        #expect(PTPMessage.read(sync) != nil)
        #expect(PTPMessage.read(Data()) == nil)
        #expect(PTPMessage.read(sync.dropLast()) == nil)
        var version = sync
        version[1] = 0x01
        #expect(PTPMessage.read(version) == nil)
        var kind = sync
        kind[0] = 0x1C          // signalling: not handled here
        #expect(PTPMessage.read(kind) == nil)
        var long = sync
        long[3] = 0x2D          // says it is one byte longer than it is
        #expect(PTPMessage.read(long) == nil)
        var short = sync
        short[3] = 0x22         // says it is a header and nothing more
        #expect(PTPMessage.read(short) == nil)
        // Bytes after the message's own length are someone else's, and are left out.
        #expect(PTPMessage.read(sync + Data([1, 2, 3]))?.body.count == 10)
        // Read from the middle of a longer buffer.
        #expect(PTPMessage.read((Data([7]) + sync).dropFirst())?.kind == .sync)
    }
}
