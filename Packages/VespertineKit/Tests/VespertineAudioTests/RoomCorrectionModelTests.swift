//
// Vespertine — room correction records: sessions, captures and profiles survive a save and reload unchanged, older
// files are upgraded on load, newer ones are refused, and a recorded capture can't be rewritten.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room correction records")
struct RoomCorrectionModelTests {
    static let hash = String(repeating: "ab", count: 32)
    static let date = Date(timeIntervalSince1970: 1_793_000_000)

    static func stereoMap() -> RoomChannelMap {
        RoomChannelMap(entries: [.init(speaker: .left, output: 0), .init(speaker: .right, output: 1)], verified: true)
    }

    static func capture(_ speaker: RoomSpeaker = .left, position: Int = 0, sha: String = String(repeating: "cd", count: 32)) -> RoomCapture {
        RoomCapture(id: UUID(), speaker: speaker, position: position, recording: "left-0.caf", recordingSHA256: sha,
                    sampleRate: 48_000, outputSampleRate: 48_000, recordedAt: date, clockDriftPPM: 12.5, quality: .accepted)
    }

    static func session() -> RoomSession {
        RoomSession(id: UUID(), createdAt: date, deviceUID: "AppleUSBAudioEngine:FiiO:K11:1234", layout: .stereo, channelMap: stereoMap(),
                    mic: RoomMic(serial: "0000001", orientation: .towardSpeaker, calibrationSHA256: hash, sensitivityDB: -1.203),
                    target: .flat, captures: [])
    }

    @Test("A session with captures encodes and decodes to the same value")
    func sessionRoundTrip() throws {
        var s = Self.session()
        try s.add(Self.capture(.left))
        try s.add(Self.capture(.right, position: 1))
        let data = try RoomCorrectionCoding.encode(s)
        let back = try RoomCorrectionCoding.decodeSession(data)
        #expect(back == s)
        #expect(back.schemaVersion == RoomCorrectionCoding.currentSchema)
        #expect(try RoomCorrectionCoding.encode(back) == data)
    }

    @Test("A profile keeps the device, layout, channel map, microphone, target and filter version it was fitted for")
    func profileRoundTrip() throws {
        let filters = RoomFilterSet(version: 3, channels: [.left: [EQBand(kind: .peak, frequency: 62, gainDB: -4, q: 3)], .right: []])
        let p = RoomProfile(id: UUID(), name: "Desk", createdAt: Self.date, sessionID: UUID(), deviceUID: "dev", layout: .stereo,
                            channelMap: Self.stereoMap(), micSerial: "0000001", calibrationSHA256: Self.hash, target: .flat, filters: filters)
        let back = try RoomCorrectionCoding.decodeProfile(try RoomCorrectionCoding.encode(p))
        #expect(back == p)
        #expect(back.filters.version == 3)
        #expect(back.filters.channels[.left]?.first?.gainDB == -4)
    }

    @Test("A capture can't be replaced or added twice, and what is recorded stays as it was")
    func capturesAreImmutable() throws {
        var s = Self.session()
        let first = Self.capture(.left)
        try s.add(first)
        #expect(throws: RoomCorrectionError.duplicateCapture(first.id)) { try s.add(first) }
        let changed = RoomCapture(id: first.id, speaker: .left, position: 0, recording: "other.caf", recordingSHA256: String(repeating: "ee", count: 32),
                                  sampleRate: 48_000, outputSampleRate: 48_000, recordedAt: Self.date, clockDriftPPM: 0, quality: .accepted)
        #expect(throws: RoomCorrectionError.duplicateCapture(first.id)) { try s.add(changed) }
        #expect(throws: RoomCorrectionError.positionTaken(speaker: .left, position: 0)) { try s.add(Self.capture(.left, position: 0)) }
        #expect(s.captures == [first])
    }

    @Test("A capture on a speaker the layout doesn't have is refused")
    func unknownSpeaker() {
        var s = Self.session()
        #expect(throws: RoomCorrectionError.speakerNotInMap(.center)) { try s.add(Self.capture(.center)) }
    }

    @Test("A channel map must use each speaker and each output once")
    func channelMapValidation() {
        #expect(Self.stereoMap().validationError == nil)
        let twice = RoomChannelMap(entries: [.init(speaker: .left, output: 0), .init(speaker: .left, output: 1)], verified: false)
        #expect(twice.validationError == .duplicateSpeaker(.left))
        let shared = RoomChannelMap(entries: [.init(speaker: .left, output: 0), .init(speaker: .right, output: 0)], verified: false)
        #expect(shared.validationError == .duplicateOutput(0))
        #expect(RoomChannelMap(entries: [], verified: false).validationError == .emptyMap)
        #expect(RoomChannelMap(entries: [.init(speaker: .left, output: -1)], verified: false).validationError == .negativeOutput(-1))
    }

    @Test("A map is never trusted as verified just because it came from a count: the 5.1 default is unverified")
    func defaultMaps() {
        let m = RoomChannelMap.standard(.surround51)
        #expect(m.entries.map(\.speaker) == [.left, .right, .center, .lfe, .leftSurround, .rightSurround])
        #expect(m.entries.map(\.output) == [0, 1, 2, 3, 4, 5])
        #expect(!m.verified)
        #expect(m.validationError == nil)
    }

    @Test("A schema 1 session (flat microphone fields, channels as a list) loads as the current schema")
    func migrateV1Session() throws {
        let id = UUID()
        let json = """
        {"schemaVersion":1,"id":"\(id.uuidString)","createdAt":"2026-10-25T10:00:00Z","deviceUID":"dev","layout":"stereo",
         "channels":["left","right"],"micSerial":"0000001","micOrientation":"0","captures":[],"target":"flat"}
        """
        let s = try RoomCorrectionCoding.decodeSession(Data(json.utf8))
        #expect(s.schemaVersion == RoomCorrectionCoding.currentSchema)
        #expect(s.id == id)
        #expect(s.channelMap.entries == [.init(speaker: .left, output: 0), .init(speaker: .right, output: 1)])
        #expect(!s.channelMap.verified)
        #expect(s.mic.serial == "0000001" && s.mic.orientation == .towardSpeaker)
        #expect(s.mic.calibrationSHA256 == nil)
        #expect(s.target == .flat)
    }

    @Test("A schema 1 microphone orientation of 90 means the microphone points up")
    func migrateV1Orientation() throws {
        let json = """
        {"schemaVersion":1,"id":"\(UUID().uuidString)","createdAt":"2026-10-25T10:00:00Z","deviceUID":"dev","layout":"stereo",
         "channels":["left","right"],"micSerial":"0000001","micOrientation":"90","captures":[],"target":"flat"}
        """
        #expect(try RoomCorrectionCoding.decodeSession(Data(json.utf8)).mic.orientation == .upward)
    }

    @Test("Files from a newer Vespertine, or with no version, are refused instead of guessed at")
    func versionGuards() {
        let future = Data(#"{"schemaVersion":99}"#.utf8)
        #expect(throws: RoomCorrectionError.newerSchema(99)) { try RoomCorrectionCoding.decodeSession(future) }
        #expect(throws: RoomCorrectionError.newerSchema(99)) { try RoomCorrectionCoding.decodeProfile(future) }
        #expect(throws: RoomCorrectionError.missingSchema) { try RoomCorrectionCoding.decodeSession(Data("{}".utf8)) }
        #expect(throws: RoomCorrectionError.unreadable) { try RoomCorrectionCoding.decodeSession(Data("nope".utf8)) }
    }

    @Test("A capture list that breaks the rules is refused on load too")
    func loadValidates() throws {
        var s = Self.session()
        let c = Self.capture(.left)
        try s.add(c)
        var data = try RoomCorrectionCoding.encode(s)
        // Duplicate the capture inside the file by hand.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let captures = try #require(object["captures"] as? [Any])
        object["captures"] = captures + captures
        data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RoomCorrectionError.duplicateCapture(c.id)) { try RoomCorrectionCoding.decodeSession(data) }
    }

    @Test("A profile applies only to the device, layout and microphone calibration it was made with")
    func profileMatching() {
        let p = RoomProfile(id: UUID(), name: "Desk", createdAt: Self.date, sessionID: UUID(), deviceUID: "dev", layout: .stereo,
                            channelMap: Self.stereoMap(), micSerial: "0000001", calibrationSHA256: Self.hash, target: .flat, filters: RoomFilterSet(version: 1, channels: [:]))
        #expect(p.applies(deviceUID: "dev", layout: .stereo, channelMap: Self.stereoMap()))
        #expect(!p.applies(deviceUID: "other", layout: .stereo, channelMap: Self.stereoMap()))
        #expect(!p.applies(deviceUID: "dev", layout: .surround51, channelMap: Self.stereoMap()))
        let swapped = RoomChannelMap(entries: [.init(speaker: .left, output: 1), .init(speaker: .right, output: 0)], verified: true)
        #expect(!p.applies(deviceUID: "dev", layout: .stereo, channelMap: swapped))
    }
}
