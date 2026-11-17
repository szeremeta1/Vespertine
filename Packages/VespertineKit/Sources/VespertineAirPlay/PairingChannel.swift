//
// Vespertine: the sealed channel a paired AirPlay 2 receiver (HomePod, Apple TV) speaks over once pairing is done. The
// same connection carries on, but everything on it is cut into frames of at most 1024 bytes, each sealed with
// ChaCha20-Poly1305: two bytes of length (least significant first, and authenticated with the frame), the sealed bytes,
// and a 16-byte tag. Each direction has its own key and counts its own frames; the count is the nonce, so a frame
// that is replayed, dropped or out of order doesn't open.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

struct PairingChannel: Sendable {
    /// The most plain bytes one frame carries.
    static let frameLength = 1024

    private let keys: PairingChannelKeys
    private var written: UInt64 = 0
    private var read: UInt64 = 0
    /// Received bytes that don't make a whole frame yet.
    private var pending: [UInt8] = []

    init(keys: PairingChannelKeys) {
        self.keys = keys
    }

    /// `plain` as frames, ready to send. Nothing to send gives nothing.
    mutating func seal(_ plain: Data) throws -> Data {
        let bytes = [UInt8](plain)
        var out = Data(capacity: bytes.count + (bytes.count / Self.frameLength + 1) * (2 + PairingCrypto.tagLength))
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.frameLength, bytes.count)
            let length = Data([UInt8((end - start) & 0xFF), UInt8((end - start) >> 8)])
            out.append(length)
            out.append(try PairingCrypto.seal(Data(bytes[start..<end]), key: keys.write, nonce: PairingCrypto.nonce(counter: written), authenticating: length))
            written += 1
            start = end
        }
        return out
    }

    /// What has arrived, added to what was waiting: the plain bytes of every frame that is now whole (none, if the first
    /// is still short). A frame that doesn't open throws, and the connection is then of no more use.
    mutating func open(_ received: Data) throws -> Data {
        pending.append(contentsOf: received)
        var out = Data()
        var start = 0
        defer { pending.removeFirst(start) }
        while pending.count - start >= 2 {
            let count = Int(pending[start]) | Int(pending[start + 1]) << 8
            guard count <= Self.frameLength else { throw PairingError.malformed }
            let end = start + 2 + count + PairingCrypto.tagLength
            guard end <= pending.count else { break }
            let length = Data(pending[start..<(start + 2)])
            guard let plain = try? PairingCrypto.open(Data(pending[(start + 2)..<end]), key: keys.read, nonce: PairingCrypto.nonce(counter: read),
                                                      authenticating: length) else { throw PairingError.notAuthentic }
            out.append(plain)
            read += 1
            start = end
        }
        return out
    }
}
