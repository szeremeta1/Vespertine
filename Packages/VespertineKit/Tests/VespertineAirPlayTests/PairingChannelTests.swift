//
// Vespertine: the sealed channel that follows pairing: frames of at most 1024 bytes, each with its length, its sealed
// bytes and a tag, counted per direction. Checked against frames made with the `cryptography` library, and against a
// second channel holding the same keys the other way round (the receiver's end).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineAirPlay

private let twoFrames = "1f0065c32c5efdc288224e66101164af4fe8b8d5acc2e07a1926a2bf5b1edb0aaef6cc1bc786d72b0aeb57f22b57033a350600e427996d190452d453e51394d28bffe4e4d67a619310"

@Suite("AirPlay pairing sealed channel")
struct PairingChannelTests {
    let keys = PairingChannelKeys.control(secret: hex(srpKey))
    /// The receiver's end: it reads with the key this end writes with.
    var far: PairingChannelKeys { PairingChannelKeys(write: keys.read, read: keys.write) }

    @Test("Frames are the length, the sealed bytes and the tag, numbered from zero, as an independent implementation makes them")
    func frames() throws {
        var channel = PairingChannel(keys: keys)
        let first = try channel.seal(Data("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8))
        let second = try channel.seal(Data("second".utf8))
        #expect(first + second == hex(twoFrames))
        #expect(first.count == 2 + 31 + 16 && first.prefix(2) == Data([31, 0]))
        let nothing = try channel.seal(Data())
        #expect(nothing.isEmpty)
        var receiver = PairingChannel(keys: far)
        let plain = try receiver.open(hex(twoFrames))
        #expect(plain == Data("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\nsecond".utf8))
    }

    @Test("A long message is cut into frames of 1024, and comes back whole however the bytes arrive")
    func longMessage() throws {
        let message = Data((0..<2500).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        var sender = PairingChannel(keys: keys)
        let sealed = try sender.seal(message)
        #expect(sealed.count == 2500 + 3 * 18)
        // 1024 is 0x0400, and the last frame holds the 452 left over (0x01C4).
        #expect(Array(sealed.prefix(2)) == [0x00, 0x04])
        #expect(Array(sealed.suffix(452 + 18).prefix(2)) == [0xC4, 0x01])

        var atOnce = PairingChannel(keys: far)
        let whole = try atOnce.open(sealed)
        #expect(whole == message)

        var dribbled = PairingChannel(keys: far)
        var got = Data()
        var offset = 0
        for size in [1, 1, 700, 341, 0, 1500, 10_000] {
            let piece = Data(Array(sealed).dropFirst(offset).prefix(size))
            offset += piece.count
            got.append(try dribbled.open(piece))
        }
        #expect(got == message)
        // Nothing is given out before a frame is whole.
        var early = PairingChannel(keys: far)
        let short = try early.open(Data(Array(sealed).prefix(1041)))
        #expect(short.isEmpty)
        let rest = try early.open(Data(Array(sealed).dropFirst(1041).prefix(1)))
        #expect(rest == Data(Array(message).prefix(1024)))
    }

    @Test("Both directions run at once with their own keys and counts")
    func bothWays() throws {
        var near = PairingChannel(keys: keys), other = PairingChannel(keys: far)
        for round in 0..<5 {
            let ask = Data("ask \(round)".utf8), answer = Data("answer \(round)".utf8)
            let there = try other.open(try near.seal(ask))
            let back = try near.open(try other.seal(answer))
            #expect(there == ask && back == answer)
        }
    }

    @Test("A frame that was changed, replayed, skipped, sealed with the other key or too long is refused")
    func refusals() throws {
        var sender = PairingChannel(keys: keys)
        let first = try sender.seal(Data("one".utf8)), second = try sender.seal(Data("two".utf8))

        var changed = PairingChannel(keys: far)
        var damaged = first
        damaged[4] ^= 1
        #expect(throws: PairingError.notAuthentic) { try changed.open(damaged) }
        // The length is part of what is sealed.
        var shorter = PairingChannel(keys: far)
        var cut = Array(first)
        cut[0] = 2
        cut.removeLast()
        #expect(throws: PairingError.notAuthentic) { try shorter.open(Data(cut)) }

        var replayed = PairingChannel(keys: far)
        _ = try replayed.open(first)
        #expect(throws: PairingError.notAuthentic) { try replayed.open(first) }
        var skipped = PairingChannel(keys: far)
        #expect(throws: PairingError.notAuthentic) { try skipped.open(second) }
        // This end's own frames don't open at this end.
        var own = PairingChannel(keys: keys)
        #expect(throws: PairingError.notAuthentic) { try own.open(first) }
        var long = PairingChannel(keys: far)
        #expect(throws: PairingError.malformed) { try long.open(Data([0x01, 0x04]) + Data(repeating: 0, count: 2000)) }
    }
}
