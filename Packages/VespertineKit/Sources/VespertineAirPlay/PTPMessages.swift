//
// Vespertine: the messages of a PTP clock (IEEE 1588-2008, over UDP), as plain values with no networking.
//
// A receiver plays an AirPlay 2 buffered stream by a clock it shares with the sender, and that clock is PTP: the sender
// says "I am a clock" (Announce, once a second), "it is now" (Sync, eight times a second, each followed by a Follow_Up
// with the exact moment the Sync left), and answers a receiver that asks how long the network took (Delay_Req, answered
// by Delay_Resp with the moment the question arrived).
//
// Every message starts with the same 34 bytes:
//   1   the transport (high four bits: 1, as Apple's devices send) and the kind of message (low four)
//   1   the version: 2
//   2   the length of the whole message
//   1   the domain: 0
//   1   nothing
//   2   flags
//   8   a correction, in nanoseconds * 65536: always 0 here
//   4   nothing
//   8   the clock's identity, then 2 for its port number: 1
//   2   a number counted up per kind of message
//   1   the "control" field of the older version, by kind
//   1   how often such messages come, as a power of two of a second
// Moments are 6 bytes of seconds and 4 of nanoseconds.
//
// Nothing here sends anything: these are the messages, made and read back, for the clock that will use them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A moment on a PTP clock.
struct PTPTimestamp: Equatable, Sendable {
    /// 48 bits of them.
    var seconds: UInt64
    var nanoseconds: UInt32

    init(seconds: UInt64, nanoseconds: UInt32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(totalNanoseconds: UInt64) {
        seconds = totalNanoseconds / 1_000_000_000
        nanoseconds = UInt32(totalNanoseconds % 1_000_000_000)
    }

    var totalNanoseconds: UInt64 { seconds &* 1_000_000_000 &+ UInt64(nanoseconds) }

    static let length = 10

    var bytes: [UInt8] {
        RAOPPacket.be16(UInt16(truncatingIfNeeded: seconds >> 32)) + RAOPPacket.be32(UInt32(truncatingIfNeeded: seconds))
            + RAOPPacket.be32(nanoseconds)
    }

    /// From ten bytes at `at`; the caller has checked they are there.
    init(_ data: Data, at: Int) {
        seconds = UInt64(RAOPPacket.read16(data, at)) << 32 | UInt64(RAOPPacket.read32(data, at + 2))
        nanoseconds = RAOPPacket.read32(data, at + 6)
    }
}

enum PTPMessage {
    /// Where the messages that carry a moment of their own go (Sync, Delay_Req), and where the rest go.
    static let eventPort: UInt16 = 319
    static let generalPort: UInt16 = 320
    static let headerLength = 34

    enum Kind: UInt8, Sendable {
        case sync = 0x0
        case delayRequest = 0x1
        case followUp = 0x8
        case delayResponse = 0x9
        case announce = 0xB

        /// The older version's field for the same thing.
        var control: UInt8 {
            switch self {
            case .sync: 0
            case .delayRequest: 1
            case .followUp: 2
            case .delayResponse: 3
            case .announce: 5
            }
        }
    }

    /// Flags: the Sync's moment comes in a Follow_Up.
    static let twoStep: UInt16 = 0x0200
    /// Flags: the clock counts PTP time (TAI), not a time of its own.
    static let ptpTimescale: UInt16 = 0x0008
    /// How often, as powers of two of a second: an Announce every second, a Sync every eighth of one.
    static let announceInterval: Int8 = 0
    static let syncInterval: Int8 = -3
    /// What this clock says of itself: as Apple's devices do, the least a clock can claim (priority 248, class 248,
    /// accuracy unknown), so that it leads only a session where nothing better announces itself.
    static let priority: UInt8 = 248
    static let clockClass: UInt8 = 248
    static let clockAccuracy: UInt8 = 0xFE
    static let clockVariance: UInt16 = 0x436A
    /// Where the time comes from: this machine's own oscillator.
    static let internalOscillator: UInt8 = 0xA0

    /// A clock's identity from a 6-byte address, as EUI-64: FF FE in the middle.
    static func identity(address: [UInt8]) -> UInt64 {
        let a = address.count == 6 ? address : [0, 0, 0, 0, 0, 0]
        let bytes = [a[0], a[1], a[2], 0xFF, 0xFE, a[3], a[4], a[5]]
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func be64(_ v: UInt64) -> [UInt8] { RAOPPacket.be32(UInt32(truncatingIfNeeded: v >> 32)) + RAOPPacket.be32(UInt32(truncatingIfNeeded: v)) }

    static func header(_ kind: Kind, length: Int, flags: UInt16, clock: UInt64, sequence: UInt16, interval: Int8) -> Data {
        var d = Data([0x10 | kind.rawValue, 0x02])
        d += RAOPPacket.be16(UInt16(length)) + [0, 0] + RAOPPacket.be16(flags)
        d += [UInt8](repeating: 0, count: 12)
        d += be64(clock) + RAOPPacket.be16(1) + RAOPPacket.be16(sequence)
        d += [kind.control, UInt8(bitPattern: interval)]
        return d
    }

    /// "I am a clock, and my own master": sent to the general port.
    static func announce(clock: UInt64, sequence: UInt16) -> Data {
        var d = header(.announce, length: headerLength + 30, flags: ptpTimescale, clock: clock, sequence: sequence, interval: announceInterval)
        d += PTPTimestamp(seconds: 0, nanoseconds: 0).bytes
        d += RAOPPacket.be16(37)                    // seconds between TAI and UTC
        d += [0, priority, clockClass, clockAccuracy] + RAOPPacket.be16(clockVariance) + [priority]
        d += be64(clock)                            // the grandmaster: this clock
        d += RAOPPacket.be16(0)                     // steps removed from it: none
        d += [internalOscillator]
        return d
    }

    /// "It is now": sent to the event port, its moment left at zero for the Follow_Up to say.
    static func sync(clock: UInt64, sequence: UInt16) -> Data {
        var d = header(.sync, length: headerLength + 10, flags: twoStep | ptpTimescale, clock: clock, sequence: sequence, interval: syncInterval)
        d += PTPTimestamp(seconds: 0, nanoseconds: 0).bytes
        return d
    }

    /// "The Sync numbered `sequence` left at `sent`": sent to the general port.
    static func followUp(clock: UInt64, sequence: UInt16, sent: PTPTimestamp) -> Data {
        var d = header(.followUp, length: headerLength + 10, flags: ptpTimescale, clock: clock, sequence: sequence, interval: syncInterval)
        d += sent.bytes
        return d
    }

    /// The answer to a Delay_Req: its number, who asked, and the moment it arrived. Sent to the general port.
    static func delayResponse(clock: UInt64, to request: Request, received: PTPTimestamp) -> Data {
        var d = header(.delayResponse, length: headerLength + 20, flags: ptpTimescale, clock: clock, sequence: request.sequence, interval: 0)
        d += received.bytes
        d += be64(request.clock) + RAOPPacket.be16(request.port)
        return d
    }

    /// Who asked, and with what number.
    struct Request: Equatable, Sendable {
        var clock: UInt64
        var port: UInt16
        var sequence: UInt16
    }

    /// A Delay_Req as it arrives, nil for anything else.
    static func delayRequest(_ data: Data) -> Request? {
        guard let read = read(data), read.kind == .delayRequest else { return nil }
        return Request(clock: read.clock, port: read.port, sequence: read.sequence)
    }

    /// What every message says, and the moment it carries (the first ten bytes after the header). nil unless it is a
    /// whole version 2 message of a kind known here, as long as it says it is.
    static func read(_ data: Data) -> (kind: Kind, flags: UInt16, clock: UInt64, port: UInt16, sequence: UInt16, time: PTPTimestamp, body: Data)? {
        let bytes = Data(data)
        guard bytes.count >= headerLength + PTPTimestamp.length, bytes[1] & 0x0F == 2, let kind = Kind(rawValue: bytes[0] & 0x0F),
              Int(RAOPPacket.read16(bytes, 2)) <= bytes.count, Int(RAOPPacket.read16(bytes, 2)) >= headerLength + PTPTimestamp.length else { return nil }
        let length = Int(RAOPPacket.read16(bytes, 2))
        return (kind, RAOPPacket.read16(bytes, 6), RAOPPacket.read64(bytes, 20), RAOPPacket.read16(bytes, 28), RAOPPacket.read16(bytes, 30),
                PTPTimestamp(bytes, at: headerLength), bytes.subdata(in: headerLength..<length))
    }
}
