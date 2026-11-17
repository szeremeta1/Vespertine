//
// Vespertine: what an AirPlay 2 session says once pairing has sealed the connection, as plain values with no networking.
//
// - Two SETUP requests, each a binary property list: the first describes this Mac and how the receiver may ask it the
//   time, and is answered with the port of the "event" connection the receiver wants opened; the second describes the
//   audio (lossless ALAC, 44.1 kHz, 16-bit stereo, 352 frames a packet, played as it arrives) and is answered with the
//   receiver's audio and control ports.
// - The keys of that event connection and of the audio, both from the session's secret.
// - The audio packet: the RTP header in the clear, the audio sealed with ChaCha20-Poly1305 (the header's time and
//   source authenticated with it), the 16-byte tag, and the 8 bytes of nonce the packet was sealed with.
//
// Field names and values are the ones AirPlay 2 senders use, as OwnTone (GPL-2.0-or-later) and pyatv (MIT) record them.
// None of their code is included.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

/// This Mac as an AirPlay 2 receiver is told of it.
struct AirPlay2Sender: Equatable, Sendable {
    /// Six bytes written like a network address ("AA:BB:CC:DD:EE:FF"): made once and kept, not the Mac's real one.
    var deviceID: String
    var name: String
    var model: String
    var osVersion: String

    /// The AirPlay version senders of this kind give.
    static let sourceVersion = "690.7.1"

    /// A device ID from six bytes.
    static func deviceID(_ bytes: [UInt8]) -> String {
        bytes.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

enum AirPlay2Message {
    static let contentType = "application/x-apple-binary-plist"
    /// Realtime audio (the receiver plays it as it arrives), which is also the RTP payload type.
    static let realtime = 0x60
    /// ALAC, 44.1 kHz, 16-bit, stereo.
    static let alacFormat = 0x40000
    /// Compression type: ALAC.
    static let alac = 2
    /// The least and most the receiver may hold before it plays, in frames.
    static let latencyMin = 11_025
    static let latencyMax = 88_200

    /// The first SETUP: who is sending, and that the receiver asks the time of `timingPort` (NTP, as in AirPlay 1).
    static func sessionSetup(sender: AirPlay2Sender, sessionUUID: UUID, timingPort: UInt16) -> Data {
        encode([
            "deviceID": sender.deviceID,
            "macAddress": sender.deviceID,
            "sessionUUID": sessionUUID.uuidString,
            "timingPort": Int(timingPort),
            "timingProtocol": "NTP",
            "name": sender.name,
            "model": sender.model,
            "osName": "macOS",
            "osVersion": sender.osVersion,
            "sourceVersion": AirPlay2Sender.sourceVersion,
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "senderSupportsRelay": false,
            "statsCollectionEnabled": false,
        ])
    }

    /// The port of the event connection, from the first SETUP's answer.
    static func eventPort(in reply: Data) -> UInt16? {
        port(decode(reply)?["eventPort"])
    }

    /// The second SETUP: one stream of audio. `key`: 32 bytes the packets are sealed with. `connectionID`: a number
    /// for this stream. `format`: what the packets hold; one AirPlay has no name for is announced as 16-bit at 44.1 kHz.
    static func streamSetup(controlPort: UInt16, key: Data, connectionID: UInt32, format: AirPlayFormat = .cd) -> Data {
        let named = format.streamFormat == nil ? AirPlayFormat.cd : format
        let stream: [String: Any] = [
            "type": realtime,
            "audioFormat": named.streamFormat ?? alacFormat,
            "ct": alac,
            "audioMode": "default",
            "controlPort": Int(controlPort),
            "isMedia": true,
            "latencyMin": named.latencyMin,
            "latencyMax": Int(named.latencyFrames),
            "shk": key,
            "spf": RAOPTiming.framesPerPacket,
            "sr": named.sampleRate,
            "supportsDynamicStreamID": false,
            "streamConnectionID": Int(connectionID),
        ]
        return encode(["streams": [stream]])
    }

    /// The receiver's audio and control ports, from the second SETUP's answer.
    static func streamPorts(in reply: Data) -> (data: UInt16, control: UInt16)? {
        guard let streams = decode(reply)?["streams"] as? [[String: Any]], let stream = streams.first,
              let data = port(stream["dataPort"]), let control = port(stream["controlPort"]) else { return nil }
        return (data, control)
    }

    static func encode(_ values: [String: Any]) -> Data {
        // Strings, numbers, booleans and bytes only: this can't fail.
        (try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)) ?? Data()
    }

    static func decode(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func port(_ value: Any?) -> UInt16? {
        guard let number = value as? Int, number > 0, number <= Int(UInt16.max) else { return nil }
        return UInt16(number)
    }
}

extension PairingChannelKeys {
    /// The event connection's. The receiver is the one that speaks on it, and the keys are named from its side: what
    /// the Mac sends there is sealed with the "read" key, and what it receives with the "write" key.
    static func events(secret: Data) -> PairingChannelKeys {
        PairingChannelKeys(write: PairingCrypto.key(secret: secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
                           read: PairingCrypto.key(secret: secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
    }
}

enum AirPlay2Audio {
    static let keyLength = 32
    static let headerLength = 12
    static let nonceLength = 8

    /// The key the audio is sealed with: the first 32 bytes of the session's secret (which is 32 bytes after
    /// pair-verify and 64 after pairing without a PIN). nil for a secret too short to be one.
    static func key(secret: Data) -> Data? {
        secret.count >= keyLength ? Data(secret.prefix(keyLength)) : nil
    }

    /// One audio packet. `counter`: how many packets this session has sealed before this one; never the same twice under
    /// one key (a packet sent again is the same bytes again, not sealed anew).
    static func packet(seq: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data, first: Bool, key: SymmetricKey, counter: UInt64) throws -> Data {
        let header = RAOPPacket.audio(seq: seq, timestamp: timestamp, ssrc: ssrc, payload: Data(), first: first)
        let nonce = PairingCrypto.nonce(counter: counter)
        var packet = Data(capacity: headerLength + payload.count + PairingCrypto.tagLength + nonceLength)
        packet.append(header)
        packet.append(try PairingCrypto.seal(payload, key: key, nonce: nonce, authenticating: Data(header.suffix(8))))
        packet.append(nonce.suffix(nonceLength))
        return packet
    }

    /// A packet as a receiver reads it: nil unless it is whole and opens with `key`.
    static func open(_ packet: Data, key: SymmetricKey) -> (seq: UInt16, timestamp: UInt32, first: Bool, payload: Data)? {
        let bytes = Data(packet)
        guard bytes.count >= headerLength + PairingCrypto.tagLength + nonceLength, bytes[0] == 0x80, bytes[1] & 0x7f == UInt8(AirPlay2Message.realtime) else {
            return nil
        }
        let header = Data(bytes.prefix(headerLength))
        let sealed = bytes.subdata(in: headerLength..<(bytes.count - nonceLength))
        guard let payload = try? PairingCrypto.open(sealed, key: key, nonce: Data(bytes.suffix(nonceLength)), authenticating: Data(header.suffix(8))) else {
            return nil
        }
        return (RAOPPacket.read16(header, 2), RAOPPacket.read32(header, 4), bytes[1] & 0x80 != 0, payload)
    }
}
