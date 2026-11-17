//
// Vespertine: the audio of an AirPlay 2 buffered stream. Where a realtime stream is datagrams the receiver plays as they
// come, a buffered stream is one TCP connection the sender fills ahead of time, and the receiver plays each block at the
// moment the sender names. It is the only kind of stream an Apple TV takes 24-bit or 48 kHz audio on.
//
// Each block on the connection, as Shairport Sync reads it:
//   2 bytes   the length of the whole block, these two bytes included
//   4 bytes   0x80, then the block's number (23 bits, counted up from the stream's first)
//   4 bytes   the timestamp of its first frame, in frames of the stream
//   4 bytes   what the audio is (`AirPlay2Buffered.Kind`), where a realtime packet has its source's number
//   n bytes   one packet of audio, sealed (ChaCha20-Poly1305) with the stream's key, the 16-byte tag after it;
//             the 8 bytes before (timestamp and kind) are authenticated with it
//   8 bytes   the nonce's last 8 bytes: how many blocks were sealed before this one
//
// Nothing here sends anything: this is the block, made and read back, for the session that will use it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

enum AirPlay2Buffered {
    /// The stream type a SETUP names for a buffered stream (a realtime one is 96).
    static let streamType = 103
    static let lengthLength = 2
    static let headerLength = 12
    static let nonceLength = 8
    /// Block numbers wrap at 23 bits.
    static let sequenceMask: UInt32 = 0x7F_FFFF

    /// What a block's audio is, as the receiver is told in every block. Only what Vespertine can make: Apple Lossless.
    enum Kind: UInt32, CaseIterable, Sendable {
        /// ALAC, 24-bit stereo at 48 kHz, 352 frames to a block.
        case alac48000Deep = 0x1500_0000

        var format: AirPlayFormat {
            switch self {
            case .alac48000Deep: AirPlayFormat(sampleRate: 48_000, bitDepth: 24)
            }
        }

        /// The kind for a format, nil for one no buffered stream of ours carries.
        init?(format: AirPlayFormat) {
            guard let kind = Kind.allCases.first(where: { $0.format == format }) else { return nil }
            self = kind
        }
    }

    /// One block, ready to write to the connection. `counter`: how many blocks this stream has sealed before this one;
    /// never the same twice under one key. Throws for audio too long for a block's 16-bit length.
    static func block(sequence: UInt32, timestamp: UInt32, kind: Kind, payload: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        let length = lengthLength + headerLength + payload.count + PairingCrypto.tagLength + nonceLength
        guard length <= Int(UInt16.max) else { throw PairingCrypto.Failure.malformed }
        var header = Data(RAOPPacket.be32(0x8000_0000 | (sequence & sequenceMask)))
        header += RAOPPacket.be32(timestamp) + RAOPPacket.be32(kind.rawValue)
        let nonce = PairingCrypto.nonce(counter: counter)
        var block = Data(capacity: length)
        block.append(contentsOf: RAOPPacket.be16(UInt16(length)))
        block.append(header)
        block.append(try PairingCrypto.seal(payload, key: key, nonce: nonce, authenticating: Data(header.suffix(8))))
        block.append(nonce.suffix(nonceLength))
        return block
    }

    /// A block as a receiver reads it, its two length bytes included: nil unless it is whole, says its own length, and
    /// opens with `key`. `kind` is the number as sent, which may be one this sender never makes.
    static func open(_ block: Data, key: SymmetricKey) -> (sequence: UInt32, timestamp: UInt32, kind: UInt32, payload: Data)? {
        let bytes = Data(block)
        guard bytes.count >= lengthLength + headerLength + PairingCrypto.tagLength + nonceLength,
              Int(RAOPPacket.read16(bytes, 0)) == bytes.count, bytes[lengthLength] == 0x80 else { return nil }
        let header = bytes.subdata(in: lengthLength..<(lengthLength + headerLength))
        let sealed = bytes.subdata(in: (lengthLength + headerLength)..<(bytes.count - nonceLength))
        guard let payload = try? PairingCrypto.open(sealed, key: key, nonce: Data(bytes.suffix(nonceLength)), authenticating: Data(header.suffix(8))) else {
            return nil
        }
        return (RAOPPacket.read32(header, 0) & sequenceMask, RAOPPacket.read32(header, 4), RAOPPacket.read32(header, 8), payload)
    }

    /// The whole blocks at the front of what has arrived on the connection so far, and how many bytes they took; the
    /// rest is a block still arriving. nil when the bytes can't be blocks (a length shorter than a block can be): the
    /// connection is of no more use.
    static func split(_ arrived: Data) -> (blocks: [Data], used: Int)? {
        let bytes = Data(arrived)
        var blocks: [Data] = []
        var at = 0
        while bytes.count - at >= lengthLength {
            let length = Int(RAOPPacket.read16(bytes, at))
            guard length >= lengthLength + headerLength + PairingCrypto.tagLength + nonceLength else { return nil }
            guard bytes.count - at >= length else { break }
            blocks.append(bytes.subdata(in: at..<(at + length)))
            at += length
        }
        return (blocks, at)
    }
}
