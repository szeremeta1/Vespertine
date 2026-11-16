//
// Vespertine: TLV8, the type-length-value list that HomeKit-style pairing messages are written in (pairing with HomePod,
// Apple TV and other AirPlay 2 receivers). Each item is a type byte, a length byte and up to 255 bytes; a longer value
// is cut into pieces of 255 that follow one another under the same type.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct PairingTLV: Equatable, Sendable {
    /// The item types pairing uses.
    enum Tag: UInt8, Sendable {
        case method = 0x00, identifier = 0x01, salt = 0x02, publicKey = 0x03, proof = 0x04, encryptedData = 0x05
        case state = 0x06, error = 0x07, retryDelay = 0x08, certificate = 0x09, signature = 0x0A, permissions = 0x0B
        case fragmentData = 0x0C, fragmentLast = 0x0D, flags = 0x13, separator = 0xFF
    }

    struct Item: Equatable, Sendable {
        var type: UInt8
        var value: Data
    }

    private(set) var items: [Item] = []

    init() {}

    init(_ pairs: KeyValuePairs<Tag, Data>) {
        items = pairs.map { Item(type: $0.key.rawValue, value: $0.value) }
    }

    /// nil when the bytes end inside an item.
    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        // Whether the item before was a full 255-byte piece, which one more of the same type continues.
        var open = false
        while index < bytes.count {
            guard index + 2 <= bytes.count else { return nil }
            let type = bytes[index], length = Int(bytes[index + 1])
            guard index + 2 + length <= bytes.count else { return nil }
            let value = Data(bytes[(index + 2)..<(index + 2 + length)])
            if open, let last = items.indices.last, items[last].type == type {
                items[last].value.append(value)
            } else {
                items.append(Item(type: type, value: value))
            }
            open = length == 255
            index += 2 + length
        }
    }

    mutating func append(_ tag: Tag, _ value: Data) {
        items.append(Item(type: tag.rawValue, value: value))
    }

    mutating func append(_ tag: Tag, _ value: UInt8) {
        append(tag, Data([value]))
    }

    /// The first item of this type.
    subscript(tag: Tag) -> Data? {
        items.first { $0.type == tag.rawValue }?.value
    }

    /// The first item of this type as one byte (states, methods and errors are one byte each).
    func byte(_ tag: Tag) -> UInt8? {
        guard let value = self[tag], value.count == 1 else { return nil }
        return value.first
    }

    var encoded: Data {
        var out = Data()
        for item in items {
            let bytes = [UInt8](item.value)
            if bytes.isEmpty {
                out.append(contentsOf: [item.type, 0])
                continue
            }
            var start = 0
            while start < bytes.count {
                let end = min(start + 255, bytes.count)
                out.append(contentsOf: [item.type, UInt8(end - start)])
                out.append(contentsOf: bytes[start..<end])
                start = end
            }
        }
        return out
    }
}
