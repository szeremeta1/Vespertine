//
// Vespertine: protocol version 2, the stream channel's wire format: version negotiation, the stream commands and replies,
// and the binary frame a ranged read is answered with.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try RemoteProtocol.encoder().encode(value)
    return try RemoteProtocol.decoder().decode(T.self, from: data)
}

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try RemoteProtocol.encoder().encode(value), as: UTF8.self)
}

private let fiveOne = StreamFormat(codec: "FLAC", container: "flac", sampleRate: 48_000, bitDepth: 24, channels: 6,
                                   channelLabels: [1, 2, 3, 4, 5, 6], lossless: true)

@Suite struct VersionNegotiation {
    @Test func thisBuildSpeaksVersionTwoAndStillUnderstandsOne() {
        #expect(RemoteProtocol.version == 2)
        #expect(RemoteProtocol.minimumVersion == 1)
        #expect(RemoteProtocol.streamVersion == 2)
    }

    @Test func aVersionOnePhoneIsServedAsAVersionOneRemote() {
        // An old phone says protocolVersion 1 and nothing else: it keeps working as a remote, with no streaming.
        #expect(RemoteProtocol.negotiate(baseline: 1, highest: nil) == 1)
    }

    @Test func aVersionTwoPhoneGetsStreaming() {
        // It says baseline 1 (so an old Mac accepts the hello) and its highest, 2.
        #expect(RemoteProtocol.negotiate(baseline: 1, highest: 2) == 2)
    }

    @Test func aNewerPhoneIsServedAtTheMacsVersion() {
        #expect(RemoteProtocol.negotiate(baseline: 1, highest: 5) == RemoteProtocol.version)
    }

    @Test func aPhoneThatNeedsANewerMacIsRefused() {
        // Its baseline is above what this Mac speaks: neither side can meet in the middle.
        #expect(RemoteProtocol.negotiate(baseline: 3, highest: 4) == nil)
        #expect(RemoteProtocol.negotiate(baseline: 0, highest: nil) == nil)
    }

    @Test func helloKeepsItsVersionOneShapeAndAddsTheHighestVersion() throws {
        let hello = ClientMessage(id: 1, command: .hello(device: "d", name: "Phone", protocolVersion: 1, highestProtocolVersion: 2))
        #expect(try json(hello) == #"{"command":{"hello":{"device":"d","highestProtocolVersion":2,"name":"Phone","protocolVersion":1}},"id":1}"#)
        #expect(try roundTrip(hello) == hello)
    }

    @Test func aVersionOneHelloStillDecodes() throws {
        let old = #"{"id":1,"command":{"hello":{"device":"d","name":"Phone","protocolVersion":1}}}"#
        let message = try RemoteProtocol.decoder().decode(ClientMessage.self, from: Data(old.utf8))
        #expect(message.command == .hello(device: "d", name: "Phone", protocolVersion: 1, highestProtocolVersion: nil))
    }

    @Test func aHelloWithoutAHighestVersionEncodesAsVersionOneDid() throws {
        // What an old Mac reads is exactly what it always read.
        let hello = ClientMessage(id: 1, command: .hello(device: "d", name: "Phone", protocolVersion: 1))
        #expect(try json(hello) == #"{"command":{"hello":{"device":"d","name":"Phone","protocolVersion":1}},"id":1}"#)
    }
}

@Suite struct StreamMessages {
    @Test func commandsKeepTheirShape() throws {
        #expect(try json(ClientMessage(id: 7, command: .streamOpen(id: 42, maxSampleRate: 48_000)))
                == #"{"command":{"streamOpen":{"id":42,"maxSampleRate":48000}},"id":7}"#)
        // Asking for the smaller form is an extra word an older Mac never sees unless it is asked for.
        #expect(try json(ClientMessage(id: 7, command: .streamOpen(id: 42, maxSampleRate: 48_000, smaller: true)))
                == #"{"command":{"streamOpen":{"id":42,"maxSampleRate":48000,"smaller":true}},"id":7}"#)
        let old = try RemoteProtocol.decoder().decode(ClientMessage.self, from: Data(#"{"command":{"streamOpen":{"id":42,"maxSampleRate":48000}},"id":7}"#.utf8))
        #expect(old.command == .streamOpen(id: 42, maxSampleRate: 48_000, smaller: nil))
        #expect(try json(ClientMessage(id: 8, command: .streamRead(stream: 3, offset: 1_048_576, length: 524_288)))
                == #"{"command":{"streamRead":{"length":524288,"offset":1048576,"stream":3}},"id":8}"#)
        #expect(try json(ClientMessage(id: 9, command: .streamClose(stream: 3))) == #"{"command":{"streamClose":{"stream":3}},"id":9}"#)
    }

    @Test func everyStreamCommandSurvivesTheWire() throws {
        let commands: [RemoteCommand] = [
            .streamInfo(ids: [1, 2, 3], maxSampleRate: nil),
            .streamInfo(ids: [], maxSampleRate: 96_000),
            .streamOpen(id: 9, maxSampleRate: nil),
            .streamRead(stream: 1, offset: Int64(Int32.max) + 10, length: 1),
            .streamClose(stream: 1),
        ]
        for command in commands { #expect(try roundTrip(ClientMessage(id: 1, command: command)).command == command) }
    }

    @Test func descriptorsAndInfoSurviveTheWire() throws {
        let descriptor = StreamDescriptor(stream: 4, kind: .flac, byteSize: 123_456_789, format: fiveOne, frames: 9_000_000,
                                          tag: "9f2c", chunkSize: RemoteProtocol.defaultChunkSize)
        #expect(try roundTrip(ServerMessage.reply(id: 1, result: .streamOpened(descriptor))) == .reply(id: 1, result: .streamOpened(descriptor)))
        #expect(try roundTrip(ServerMessage.reply(id: 2, result: .streamPreparing(progress: 0.25))) == .reply(id: 2, result: .streamPreparing(progress: 0.25)))
        #expect(try roundTrip(ServerMessage.reply(id: 2, result: .streamPreparing(progress: nil))) == .reply(id: 2, result: .streamPreparing(progress: nil)))

        let info = StreamInfo(id: 42, streamable: true, kind: .flac, source: StreamFormat(codec: "DSD", container: "dsf", sampleRate: 2_822_400, bitDepth: 1, channels: 6,
                                                                                            channelLabels: nil, lossless: true),
                              delivered: fiveOne, macOnlyReason: nil, byteSize: nil, totalFrames: 12_000_000,
                              replayGain: ReplayGain(trackGain: -3.5, trackPeak: 0.9, albumGain: -4, albumPeak: 0.95), encoderDelay: nil, endPadding: nil)
        #expect(try roundTrip(ServerMessage.reply(id: 3, result: .streamInfo(items: [info]))) == .reply(id: 3, result: .streamInfo(items: [info])))
    }

    @Test func theMacSayingItsStreamsAreClosedSurvivesTheWire() throws {
        #expect(try roundTrip(ServerMessage.streamsClosed(reason: "Not here.")) == .streamsClosed(reason: "Not here."))
        #expect(try roundTrip(ServerMessage.streamsClosed(reason: nil)) == .streamsClosed(reason: nil))
        // What an older phone already knows keeps its shape beside it.
        #expect(try json(ServerMessage.goodbye(reason: .serverStopped)) == #"{"goodbye":{"reason":"serverStopped"}}"#)
    }

    @Test func aMacOnlyTrackSaysWhy() throws {
        let info = StreamInfo(id: 1, streamable: false, kind: nil, source: fiveOne, delivered: nil,
                              macOnlyReason: "More than 8 channels", byteSize: nil, totalFrames: nil, replayGain: nil, encoderDelay: nil, endPadding: nil)
        let back = try roundTrip(info)
        #expect(!back.streamable && back.kind == nil && back.macOnlyReason == "More than 8 channels")
    }
}

@Suite struct StreamFrames {
    @Test func aFrameRoundTripsItsFieldsAndPayload() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        let frame = StreamFrame(request: 77, stream: 3, offset: 5_000_000_000, endOfStream: false, payload: payload)
        let wire = frame.encoded()
        #expect(wire.count == StreamFrame.headerSize + 1000)
        #expect(StreamFrame(decoding: wire) == frame)
    }

    @Test func theEndOfTheStreamIsAFlagNotALength() throws {
        let last = StreamFrame(request: 1, stream: 1, offset: 10, endOfStream: true, payload: Data([1, 2, 3]))
        #expect(StreamFrame(decoding: last.encoded())?.endOfStream == true)
        let empty = StreamFrame(request: 2, stream: 1, offset: 13, endOfStream: true, payload: Data())
        #expect(StreamFrame(decoding: empty.encoded()) == empty)
    }

    @Test func integersAreBigEndian() {
        let wire = StreamFrame(request: 0x0102_0304, stream: 0x0A0B_0C0D, offset: 0x1112_1314_1516_1718, endOfStream: true, payload: Data([0xFF])).encoded()
        #expect(Array(wire) == [0x01, 0x01, 0x02, 0x03, 0x04, 0x0A, 0x0B, 0x0C, 0x0D,
                                0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x01, 0xFF])
    }

    @Test func aFrameIsTellableFromJSONAtTheFirstByte() throws {
        let json = try RemoteProtocol.encoder().encode(ClientMessage(id: 1, command: .next))
        #expect(!StreamFrame.isFrame(json))
        #expect(StreamFrame.isFrame(StreamFrame(request: 1, stream: 1, offset: 0, endOfStream: false, payload: Data([9])).encoded()))
        #expect(!StreamFrame.isFrame(Data()))
    }

    @Test func damagedFramesAreRefusedNotGuessedAt() {
        #expect(StreamFrame(decoding: Data()) == nil)
        #expect(StreamFrame(decoding: Data([StreamFrame.magic, 0, 0])) == nil, "shorter than a header")
        var wire = StreamFrame(request: 1, stream: 1, offset: 0, endOfStream: false, payload: Data([1])).encoded()
        wire[0] = 0x7B // '{': a JSON message
        #expect(StreamFrame(decoding: wire) == nil)
        wire[0] = StreamFrame.magic
        wire[17] = 0b1000_0000 // a flag this version doesn't know
        #expect(StreamFrame(decoding: wire) == nil)
    }

    @Test func aChunkFitsInsideTheMessageLimit() {
        #expect(RemoteProtocol.maximumChunk + StreamFrame.headerSize <= RemoteProtocol.maximumMessageSize)
        #expect(RemoteProtocol.defaultChunkSize <= RemoteProtocol.maximumChunk)
    }
}
