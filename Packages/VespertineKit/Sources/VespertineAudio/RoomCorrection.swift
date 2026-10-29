//
// Vespertine — room correction records: what was measured, with what, through which outputs, and the filters fitted from it.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A session holds the raw captures of one measurement run, kept as recorded; a profile is the filter set fitted
// from a session, and says which device, layout, channel map and microphone calibration it is valid for. Files carry a
// schema version: older ones are upgraded as they load, newer ones are refused. Nothing here touches playback.
//

import Foundation

/// A loudspeaker position, by what it is rather than by which output it is wired to.
public enum RoomSpeaker: String, Codable, CaseIterable, Sendable, Hashable {
    case left, right, center, lfe, leftSurround, rightSurround
}

/// The speaker arrangement a session measures.
public enum RoomLayout: String, Codable, CaseIterable, Sendable, Hashable {
    case stereo, surround51

    public var speakers: [RoomSpeaker] {
        switch self {
        case .stereo: [.left, .right]
        case .surround51: [.left, .right, .center, .lfe, .leftSurround, .rightSurround]
        }
    }
}

public enum RoomCorrectionError: Error, Equatable, LocalizedError {
    case emptyMap
    case duplicateSpeaker(RoomSpeaker)
    case duplicateOutput(Int)
    case negativeOutput(Int)
    case speakerNotInMap(RoomSpeaker)
    case duplicateCapture(UUID)
    case positionTaken(speaker: RoomSpeaker, position: Int)
    case newerSchema(Int)
    case missingSchema
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .emptyMap: String(localized: "No speaker is assigned to an output.")
        case .duplicateSpeaker(let s): String(localized: "The \(s.rawValue) speaker is assigned to more than one output.")
        case .duplicateOutput(let n): String(localized: "Output \(n + 1) carries more than one speaker.")
        case .negativeOutput(let n): String(localized: "Output \(n) doesn't exist.")
        case .speakerNotInMap(let s): String(localized: "The \(s.rawValue) speaker isn't part of this setup.")
        case .duplicateCapture: String(localized: "That measurement is already recorded and can't be replaced.")
        case .positionTaken(let s, let p): String(localized: "The \(s.rawValue) speaker already has a measurement at position \(p + 1).")
        case .newerSchema: String(localized: "This room correction file was saved by a newer Vespertine.")
        case .missingSchema, .unreadable: String(localized: "This room correction file couldn't be read.")
        }
    }
}

/// Which output channel of the device each speaker is on. `verified` is set only once the listener has heard
/// each speaker come out of the position it is named for; a channel count alone never makes a map verified.
public struct RoomChannelMap: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var speaker: RoomSpeaker
        public var output: Int
        public init(speaker: RoomSpeaker, output: Int) {
            self.speaker = speaker
            self.output = output
        }
    }

    public var entries: [Entry]
    public var verified: Bool

    public init(entries: [Entry], verified: Bool) {
        self.entries = entries
        self.verified = verified
    }

    /// The layout's speakers on outputs 0, 1, 2… in the standard order (L R C LFE Ls Rs). Unverified.
    public static func standard(_ layout: RoomLayout) -> RoomChannelMap {
        RoomChannelMap(entries: layout.speakers.enumerated().map { Entry(speaker: $1, output: $0) }, verified: false)
    }

    public var speakers: Set<RoomSpeaker> { Set(entries.map(\.speaker)) }

    public var validationError: RoomCorrectionError? {
        if entries.isEmpty { return .emptyMap }
        var speakers = Set<RoomSpeaker>(), outputs = Set<Int>()
        for e in entries {
            if e.output < 0 { return .negativeOutput(e.output) }
            if !speakers.insert(e.speaker).inserted { return .duplicateSpeaker(e.speaker) }
            if !outputs.insert(e.output).inserted { return .duplicateOutput(e.output) }
        }
        return nil
    }
}

/// Where the measurement microphone pointed: at the speaker (the 0° calibration file) or up (the 90° file).
public enum RoomMicOrientation: String, Codable, Sendable, Hashable {
    case towardSpeaker, upward
}

public struct RoomMic: Codable, Hashable, Sendable {
    public var serial: String
    public var orientation: RoomMicOrientation
    /// SHA-256 (hex) of the calibration file's original bytes; nil when the session predates calibration import.
    public var calibrationSHA256: String?
    /// The file's "Sens Factor", in dB, when it has one.
    public var sensitivityDB: Double?

    public init(serial: String, orientation: RoomMicOrientation, calibrationSHA256: String?, sensitivityDB: Double? = nil) {
        self.serial = serial
        self.orientation = orientation
        self.calibrationSHA256 = calibrationSHA256
        self.sensitivityDB = sensitivityDB
    }
}

/// A named target curve. `version` ties a stored profile to the anchor numbers it was fitted against.
public struct RoomTarget: Codable, Hashable, Sendable {
    public var name: String
    public var version: Int
    /// Frequency (Hz) and level (dB) pairs; empty for the flat target.
    public var anchors: [Anchor]

    public struct Anchor: Codable, Hashable, Sendable {
        public var hz: Double
        public var db: Double
        public init(hz: Double, db: Double) {
            self.hz = hz
            self.db = db
        }
    }

    public init(name: String, version: Int, anchors: [Anchor] = []) {
        self.name = name
        self.version = version
        self.anchors = anchors
    }

    public static let flat = RoomTarget(name: "flat", version: 1)
}

public enum RoomCaptureQuality: String, Codable, Sendable, Hashable {
    case accepted, rejected
}

/// One recorded sweep. Every field is fixed at creation: a measurement is added to a session, never edited.
public struct RoomCapture: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let speaker: RoomSpeaker
    /// Index of the microphone position around the listening seat.
    public let position: Int
    /// The raw recording's file name inside the session folder, and its SHA-256 (hex).
    public let recording: String
    public let recordingSHA256: String
    public let sampleRate: Double
    public let outputSampleRate: Double
    public let recordedAt: Date
    /// Estimated input/output clock mismatch, in parts per million.
    public let clockDriftPPM: Double
    public let quality: RoomCaptureQuality

    public init(id: UUID, speaker: RoomSpeaker, position: Int, recording: String, recordingSHA256: String, sampleRate: Double,
                outputSampleRate: Double, recordedAt: Date, clockDriftPPM: Double, quality: RoomCaptureQuality) {
        self.id = id
        self.speaker = speaker
        self.position = position
        self.recording = recording
        self.recordingSHA256 = recordingSHA256
        self.sampleRate = sampleRate
        self.outputSampleRate = outputSampleRate
        self.recordedAt = recordedAt
        self.clockDriftPPM = clockDriftPPM
        self.quality = quality
    }
}

public struct RoomSession: Codable, Hashable, Sendable, Identifiable {
    public var schemaVersion: Int = RoomCorrectionCoding.currentSchema
    public let id: UUID
    public let createdAt: Date
    public var deviceUID: String
    public var layout: RoomLayout
    public var channelMap: RoomChannelMap
    public var mic: RoomMic
    public var target: RoomTarget
    public private(set) var captures: [RoomCapture]

    public init(id: UUID, createdAt: Date, deviceUID: String, layout: RoomLayout, channelMap: RoomChannelMap, mic: RoomMic,
                target: RoomTarget, captures: [RoomCapture] = []) {
        self.id = id
        self.createdAt = createdAt
        self.deviceUID = deviceUID
        self.layout = layout
        self.channelMap = channelMap
        self.mic = mic
        self.target = target
        self.captures = captures
    }

    /// Appends a capture. An existing capture is never replaced, and each speaker has one capture per position.
    public mutating func add(_ capture: RoomCapture) throws {
        if captures.contains(where: { $0.id == capture.id }) { throw RoomCorrectionError.duplicateCapture(capture.id) }
        if !channelMap.speakers.contains(capture.speaker) { throw RoomCorrectionError.speakerNotInMap(capture.speaker) }
        if captures.contains(where: { $0.speaker == capture.speaker && $0.position == capture.position }) {
            throw RoomCorrectionError.positionTaken(speaker: capture.speaker, position: capture.position)
        }
        captures.append(capture)
    }

    func validate() throws {
        if let error = channelMap.validationError { throw error }
        var rebuilt = RoomSession(id: id, createdAt: createdAt, deviceUID: deviceUID, layout: layout, channelMap: channelMap, mic: mic, target: target)
        for c in captures { try rebuilt.add(c) }
    }
}

/// Filters fitted per speaker. `version` counts refits so a stored profile can be told from a newer one.
public struct RoomFilterSet: Codable, Hashable, Sendable {
    public var version: Int
    public var channels: [RoomSpeaker: [EQBand]]
    /// Gain (dB, ≤ 0) applied to every channel ahead of the filters so the corrected signal keeps its headroom.
    public var preampDB: Double

    public init(version: Int, channels: [RoomSpeaker: [EQBand]], preampDB: Double = 0) {
        self.version = version
        self.channels = channels
        self.preampDB = preampDB
    }

    private enum CodingKeys: String, CodingKey { case version, channels, preampDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        channels = try c.decode([RoomSpeaker: [EQBand]].self, forKey: .channels)
        preampDB = try c.decodeIfPresent(Double.self, forKey: .preampDB) ?? 0
    }
}

public struct RoomProfile: Codable, Hashable, Sendable, Identifiable {
    public var schemaVersion: Int = RoomCorrectionCoding.currentSchema
    public let id: UUID
    public var name: String
    public let createdAt: Date
    /// The session the filters were fitted from.
    public let sessionID: UUID
    public var deviceUID: String
    public var layout: RoomLayout
    public var channelMap: RoomChannelMap
    public var micSerial: String
    public var calibrationSHA256: String?
    public var target: RoomTarget
    public var filters: RoomFilterSet
    /// The measured response per speaker the filters were fitted to (positions averaged), so the filters can be
    /// refitted to another target or range and the before/after drawn. nil in profiles that didn't keep it.
    public var measured: [RoomSpeaker: RoomCurve]?
    /// The options the filters were fitted with.
    public var designOptions: RoomFilterDesignOptions?

    public init(id: UUID, name: String, createdAt: Date, sessionID: UUID, deviceUID: String, layout: RoomLayout, channelMap: RoomChannelMap,
                micSerial: String, calibrationSHA256: String?, target: RoomTarget, filters: RoomFilterSet) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.deviceUID = deviceUID
        self.layout = layout
        self.channelMap = channelMap
        self.micSerial = micSerial
        self.calibrationSHA256 = calibrationSHA256
        self.target = target
        self.filters = filters
    }

    /// A profile is valid for the device, layout and wiring it was measured on, and for nothing else.
    public func applies(deviceUID: String, layout: RoomLayout, channelMap: RoomChannelMap) -> Bool {
        self.deviceUID == deviceUID && self.layout == layout && Set(self.channelMap.entries) == Set(channelMap.entries)
    }
}

public enum RoomCorrectionCoding {
    /// Bump when the stored shape changes, and add the step that upgrades the previous one to `migrate`.
    public static let currentSchema = 2

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(_ session: RoomSession) throws -> Data { try encoder.encode(session) }
    public static func encode(_ profile: RoomProfile) throws -> Data { try encoder.encode(profile) }

    /// A list of profiles (the app's saved set): each element is a profile as `encode` writes it.
    public static func encodeProfiles(_ profiles: [RoomProfile]) throws -> Data {
        let objects = try profiles.map { try JSONSerialization.jsonObject(with: encode($0)) }
        return try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    }

    /// Reads `encodeProfiles` output. Profiles that can't be read (or are from a newer Vespertine) are left out.
    public static func decodeProfiles(_ data: Data) throws -> [RoomProfile] {
        guard let objects = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw RoomCorrectionError.unreadable }
        return objects.compactMap { object in
            (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? decodeProfile($0) }
        }
    }

    public static func decodeSession(_ data: Data) throws -> RoomSession {
        let upgraded = try migrate(data, kind: .session)
        guard let session = try? decoder.decode(RoomSession.self, from: upgraded) else { throw RoomCorrectionError.unreadable }
        try session.validate()
        return session
    }

    public static func decodeProfile(_ data: Data) throws -> RoomProfile {
        let upgraded = try migrate(data, kind: .profile)
        guard let profile = try? decoder.decode(RoomProfile.self, from: upgraded) else { throw RoomCorrectionError.unreadable }
        if let error = profile.channelMap.validationError { throw error }
        return profile
    }

    private enum Kind { case session, profile }

    /// Rewrites an older file's JSON as the current schema. Schema 1 was the first draft: a flat microphone serial and
    /// orientation ("0" or "90"), and the channel order as a list of speaker names.
    private static func migrate(_ data: Data, kind: Kind) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw RoomCorrectionError.unreadable }
        guard let version = object["schemaVersion"] as? Int else { throw RoomCorrectionError.missingSchema }
        if version > currentSchema { throw RoomCorrectionError.newerSchema(version) }
        guard version < currentSchema else { return data }
        if version == 1 {
            if let channels = object["channels"] as? [String] {
                let entries = channels.enumerated().map { ["speaker": $1, "output": $0] as [String: Any] }
                object["channelMap"] = ["entries": entries, "verified": false] as [String: Any]
                object["channels"] = nil
            }
            if kind == .session {
                var mic: [String: Any] = ["serial": object["micSerial"] ?? "", "orientation": (object["micOrientation"] as? String) == "90" ? "upward" : "towardSpeaker"]
                if let hash = object["calibrationSHA256"] { mic["calibrationSHA256"] = hash }
                object["mic"] = mic
                object["micSerial"] = nil
                object["micOrientation"] = nil
                object["calibrationSHA256"] = nil
                if let name = object["target"] as? String { object["target"] = ["name": name, "version": 1, "anchors": []] as [String: Any] }
            }
        }
        object["schemaVersion"] = currentSchema
        guard let out = try? JSONSerialization.data(withJSONObject: object) else { throw RoomCorrectionError.unreadable }
        return out
    }
}
