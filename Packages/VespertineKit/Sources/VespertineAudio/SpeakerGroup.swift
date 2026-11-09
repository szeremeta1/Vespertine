//
// Vespertine: speaker groups: two or more outputs (a Fosi and a FiiO, say) played as one multichannel system. This is the
// saved description of a group: which outputs, which one leads the clock, which speaker is on which output channel, and
// where everything stands in the room. Nothing here touches playback.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Words the listener may read (the issues' descriptions) are plain English for now: they move into the string catalog
// together with the settings screens that show them.
//

import Foundation

/// How a stereo song is played on more than two speakers.
public enum StereoPolicy: Codable, Hashable, Sendable {
    /// Left and right only; the other speakers stay quiet. The leader's channels can stay bit-perfect.
    case frontOnly
    /// Left and right also on the back pair, at this level (dB, 0 or less).
    case mirror(trimDB: Double)
    /// Each pair of speakers plays its own stereo image of the song.
    case eachPairStereo
    /// Every speaker plays something of the song.
    case allSpeakers
}

/// What the LFE channel of a surround song becomes where the group has no subwoofer.
public enum LFEPolicy: Codable, Hashable, Sendable {
    /// Left out, as in the ITU downmix and common decoders.
    case drop
    /// Added to every speaker at this level (dB).
    case toAll(dB: Double)
    /// Added to one speaker.
    case toSpeaker(UUID)
}

/// What happens when one of the group's outputs goes away while it plays.
public enum LossPolicy: String, Codable, Hashable, Sendable {
    /// Fade out and pause.
    case pause
    /// Carry on with the outputs that are left, folding the music onto them.
    case continueOnRemaining
}

/// The room, for the drawing: width across, depth front to back, in metres.
public struct RoomOutline: Codable, Hashable, Sendable {
    public var width: Double
    public var depth: Double

    public init(width: Double, depth: Double) {
        self.width = width
        self.depth = depth
    }
}

/// The listening seat: where it is, and which way the listener faces (degrees clockwise from the room's forward).
public struct Listener: Codable, Hashable, Sendable {
    public var position: Point2D
    public var facingDegrees: Double

    public init(position: Point2D = Point2D(), facingDegrees: Double = 0) {
        self.position = position
        self.facingDegrees = facingDegrees
    }
}

public struct SpeakerGroup: Codable, Identifiable, Hashable, Sendable {
    /// The most channels a group can have across all its outputs: what the real-time path carries (`NRT_ROOM_MAX_CHANNELS`).
    public static let maxChannels = 16
    /// The widest a position may be from the room's origin, in metres. Far more than any room; it catches typos and NaN.
    public static let maxDistance = 100.0
    public static let trimRangeDB: ClosedRange<Double> = -40...12
    public static let delayTrimRangeMs: ClosedRange<Double> = 0...40
    public static let outputUIDPrefix = "vespertine-group:"

    public var schemaVersion = SpeakerGroupCoding.currentSchema
    public let id: UUID
    public var name: String
    /// The outputs, in the order of the aggregate's streams: the first member's channels come first.
    public var members: [Member]
    /// The member whose clock everything follows: its channels are never resampled, so they can stay bit-perfect.
    public var clockLeaderUID: String
    /// What plays where, and where it stands.
    public var speakers: [Speaker]
    public var listener: Listener
    /// Width and depth of the room, for the drawing only.
    public var room: RoomOutline?
    public var stereoPolicy: StereoPolicy
    public var lfePolicy: LFEPolicy
    public var onMemberLoss: LossPolicy
    /// The room profile (from the guide's geometry, or measured) that aligns this group.
    public var alignmentProfileID: UUID?
    /// Room render (`RoomRender`): songs played to fill the room from every speaker. nil: off, songs play as routed.
    public var roomRender: RoomRenderSettings?

    public struct Member: Codable, Hashable, Sendable {
        public var deviceUID: String
        /// The output's name as last seen, to show while it is unplugged.
        public var name: String
        public var modelUID: String?
        /// Output channels the device has (as last seen). Every one takes a place in the aggregate, used or not.
        public var channelCount: Int
        /// Extra output latency, in frames, from a measured skew against the leader (0 until measured).
        public var extraLatencyFrames: Double
        /// How much later than the others this output's sound arrives, in ms, from a measurement (0 until measured). Held back in
        /// Vespertine as a delay on the other outputs' channels (`GroupDelay`): macOS 27 takes an aggregate's extra latency without
        /// error and ignores it.
        public var skewMs: Double
        /// What `skewMs` was measured under. A skew measured with drift correction on holds the corrector's own delay and one measured
        /// without it does not, so it only counts while the member is still run the same way (`GroupDelay.lateMs`). nil: typed in, or
        /// saved before this existed.
        public var skewContext: SkewContext?
        /// How fast this output falls behind the others while it plays, in parts per million (positive: later and later), as the wizard
        /// measured it with drift correction on (the FiiO K11 behind the Fosi ZD3 measured +13.5). 0 until measured. See `GroupRateTrim`.
        public var rateTrimPPM: Double
        /// For how long after the output starts this output keeps falling behind at `rateTrimPPM`, in seconds; nil: the default horizon
        /// (`GroupDelay.rateTrimHorizonSeconds`). The FiiO K11 behind the Fosi ZD3 crept at +11.6 ppm for the first 297.5 s and then stopped
        /// (its Core Audio clock estimate corrects itself), so a trim that ran on for 600 s would have pulled it 3.5 ms early.
        public var rateTrimSeconds: Double?
        /// Core Audio's drift correction quality for this member, 0 (cheapest) to 127 (best).
        public var driftQuality: Int

        public static let rateTrimRangePPM: ClosedRange<Double> = -200...200
        public static let rateTrimSecondsRange: ClosedRange<Double> = 1...3600

        /// How the skew was measured: whether the member was drift-corrected, at what quality, at what rate.
        public struct SkewContext: Codable, Hashable, Sendable {
            public var driftCorrected: Bool
            public var driftQuality: Int
            public var sampleRate: Double

            public init(driftCorrected: Bool, driftQuality: Int, sampleRate: Double) {
                self.driftCorrected = driftCorrected
                self.driftQuality = driftQuality
                self.sampleRate = sampleRate
            }

            /// Whether a member run with these settings is run as it was when measured. Quality only matters while it is corrected.
            public func holds(driftCorrected now: Bool, driftQuality quality: Int, sampleRate rate: Double?) -> Bool {
                driftCorrected == now && (!now || driftQuality == quality) && (rate.map { abs($0 - sampleRate) < 0.5 } ?? true)
            }
        }

        public static let defaultDriftQuality = 0x7F

        public init(deviceUID: String, name: String, modelUID: String? = nil, channelCount: Int,
                    extraLatencyFrames: Double = 0, skewMs: Double = 0, skewContext: SkewContext? = nil, rateTrimPPM: Double = 0,
                    rateTrimSeconds: Double? = nil, driftQuality: Int = Member.defaultDriftQuality) {
            self.deviceUID = deviceUID
            self.name = name
            self.modelUID = modelUID
            self.channelCount = channelCount
            self.extraLatencyFrames = extraLatencyFrames
            self.skewMs = skewMs
            self.skewContext = skewContext
            self.rateTrimPPM = rateTrimPPM
            self.rateTrimSeconds = rateTrimSeconds
            self.driftQuality = driftQuality
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deviceUID = try c.decode(String.self, forKey: .deviceUID)
            name = try c.decode(String.self, forKey: .name)
            modelUID = try c.decodeIfPresent(String.self, forKey: .modelUID)
            channelCount = try c.decode(Int.self, forKey: .channelCount)
            extraLatencyFrames = try c.decodeIfPresent(Double.self, forKey: .extraLatencyFrames) ?? 0
            skewMs = try c.decodeIfPresent(Double.self, forKey: .skewMs) ?? 0
            skewContext = try c.decodeIfPresent(SkewContext.self, forKey: .skewContext)
            rateTrimPPM = try c.decodeIfPresent(Double.self, forKey: .rateTrimPPM) ?? 0
            rateTrimSeconds = try c.decodeIfPresent(Double.self, forKey: .rateTrimSeconds)
            driftQuality = try c.decodeIfPresent(Int.self, forKey: .driftQuality) ?? Member.defaultDriftQuality
        }
    }

    public struct Speaker: Codable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public var role: SpeakerRole
        /// The member output this speaker is wired to, and the channel on it (0 is the first).
        public var deviceUID: String
        public var channel: Int
        public var position: Point2D
        /// Metres above the listener's ears, for ceiling speakers.
        public var height: Double?
        /// Level trim in dB, on top of what the position gives.
        public var trimDB: Double
        /// Extra delay in milliseconds, on top of what the position gives.
        public var delayTrimMs: Double
        public var invertPolarity: Bool

        public init(id: UUID = UUID(), role: SpeakerRole, deviceUID: String, channel: Int, position: Point2D, height: Double? = nil,
                    trimDB: Double = 0, delayTrimMs: Double = 0, invertPolarity: Bool = false) {
            self.id = id
            self.role = role
            self.deviceUID = deviceUID
            self.channel = channel
            self.position = position
            self.height = height
            self.trimDB = trimDB
            self.delayTrimMs = delayTrimMs
            self.invertPolarity = invertPolarity
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            role = try c.decode(SpeakerRole.self, forKey: .role)
            deviceUID = try c.decode(String.self, forKey: .deviceUID)
            channel = try c.decode(Int.self, forKey: .channel)
            position = try c.decode(Point2D.self, forKey: .position)
            height = try c.decodeIfPresent(Double.self, forKey: .height)
            trimDB = try c.decodeIfPresent(Double.self, forKey: .trimDB) ?? 0
            delayTrimMs = try c.decodeIfPresent(Double.self, forKey: .delayTrimMs) ?? 0
            invertPolarity = try c.decodeIfPresent(Bool.self, forKey: .invertPolarity) ?? false
        }
    }

    public init(id: UUID = UUID(), name: String, members: [Member], clockLeaderUID: String, speakers: [Speaker] = [],
                listener: Listener = Listener(), room: RoomOutline? = nil, stereoPolicy: StereoPolicy = .frontOnly,
                lfePolicy: LFEPolicy = .drop, onMemberLoss: LossPolicy = .pause, alignmentProfileID: UUID? = nil,
                roomRender: RoomRenderSettings? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.clockLeaderUID = clockLeaderUID
        self.speakers = speakers
        self.listener = listener
        self.room = room
        self.stereoPolicy = stereoPolicy
        self.lfePolicy = lfePolicy
        self.onMemberLoss = onMemberLoss
        self.alignmentProfileID = alignmentProfileID
        self.roomRender = roomRender
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        members = try c.decode([Member].self, forKey: .members)
        clockLeaderUID = try c.decode(String.self, forKey: .clockLeaderUID)
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        listener = try c.decodeIfPresent(Listener.self, forKey: .listener) ?? Listener()
        room = try c.decodeIfPresent(RoomOutline.self, forKey: .room)
        stereoPolicy = try c.decodeIfPresent(StereoPolicy.self, forKey: .stereoPolicy) ?? .frontOnly
        lfePolicy = try c.decodeIfPresent(LFEPolicy.self, forKey: .lfePolicy) ?? .drop
        onMemberLoss = try c.decodeIfPresent(LossPolicy.self, forKey: .onMemberLoss) ?? .pause
        alignmentProfileID = try c.decodeIfPresent(UUID.self, forKey: .alignmentProfileID)
        roomRender = try c.decodeIfPresent(RoomRenderSettings.self, forKey: .roomRender)
    }

    // MARK: Identity

    /// The UID this group has as an output. Settings that belong to an output (volume, room profile, equalizer) key on it,
    /// as they do on a device's UID.
    public var outputUID: String { Self.outputUIDPrefix + id.uuidString.lowercased() }

    /// The group an output UID names; nil for a device's UID or a malformed one.
    public static func groupID(fromOutputUID uid: String) -> UUID? {
        guard uid.hasPrefix(outputUIDPrefix) else { return nil }
        return UUID(uuidString: String(uid.dropFirst(outputUIDPrefix.count)))
    }

    // MARK: Channel map

    /// Output channels across all the members: what the aggregate offers, used or not.
    public var totalChannels: Int { members.reduce(0) { $0 + max($1.channelCount, 0) } }

    /// Where a member's first channel sits among the aggregate's channels; nil for a UID that is not a member.
    public func channelOffset(ofMember uid: String) -> Int? {
        var offset = 0
        for member in members {
            if member.deviceUID == uid { return offset }
            offset += max(member.channelCount, 0)
        }
        return nil
    }

    /// The aggregate channel each role is heard on. Speakers on a device or channel that does not exist are left out.
    public var aggregateChannels: [SpeakerRole: Int] {
        var map: [SpeakerRole: Int] = [:]
        for speaker in speakers {
            guard let member = members.first(where: { $0.deviceUID == speaker.deviceUID }), speaker.channel >= 0, speaker.channel < member.channelCount,
                  let offset = channelOffset(ofMember: speaker.deviceUID) else { continue }
            map[speaker.role] = offset + speaker.channel
        }
        return map
    }

    /// The role heard on each aggregate channel, in channel order; nil where no speaker is connected.
    public var rolesByAggregateChannel: [SpeakerRole?] {
        var roles = [SpeakerRole?](repeating: nil, count: totalChannels)
        for (role, channel) in aggregateChannels where channel < roles.count { roles[channel] = role }
        return roles
    }

    // MARK: Validation

    public enum Issue: Hashable, Sendable, CustomStringConvertible {
        case emptyName
        case tooFewMembers
        case duplicateMember(String)
        case leaderNotAMember(String)
        case tooManyChannels(Int)
        case channelCountInvalid(String)
        case driftQualityInvalid(String)
        case skewInvalid(String)
        case rateTrimInvalid(String)
        case rateTrimSecondsInvalid(String)
        case speakerOnUnknownDevice(UUID)
        case channelOutOfRange(UUID)
        case channelShared(device: String, channel: Int)
        case roleRepeated(SpeakerRole)
        case positionInvalid(UUID)
        case speakerAtListener(UUID)
        case trimInvalid(UUID)
        case listenerInvalid
        case roomInvalid

        public var description: String {
            switch self {
            case .emptyName: String(localized: "The group needs a name.")
            case .tooFewMembers: String(localized: "A group needs at least two outputs.")
            case .duplicateMember(let uid): String(localized: "The output \(uid) is in the group twice.")
            case .leaderNotAMember(let uid): String(localized: "The clock leader \(uid) is not one of the group's outputs.")
            case .tooManyChannels(let n): String(localized: "The outputs add up to \(n) channels; a group can have \(SpeakerGroup.maxChannels).")
            case .channelCountInvalid(let uid): String(localized: "The output \(uid) has no valid channel count.")
            case .driftQualityInvalid(let uid): String(localized: "The drift correction quality of \(uid) must be between 0 and 127.")
            case .skewInvalid(let uid): String(localized: "The measured delay of \(uid) must be between 0 and \(Int(SpeakerGroup.delayTrimRangeMs.upperBound)) ms.")
            case .rateTrimInvalid(let uid): String(localized: "The measured drift of \(uid) must be between \(Int(SpeakerGroup.Member.rateTrimRangePPM.lowerBound)) and \(Int(SpeakerGroup.Member.rateTrimRangePPM.upperBound)) parts per million.")
            case .rateTrimSecondsInvalid(let uid): String(localized: "How long \(uid) drifts must be between \(Int(SpeakerGroup.Member.rateTrimSecondsRange.lowerBound)) and \(Int(SpeakerGroup.Member.rateTrimSecondsRange.upperBound)) seconds.")
            case .speakerOnUnknownDevice: String(localized: "A speaker is on an output that is not in the group.")
            case .channelOutOfRange: String(localized: "A speaker is on an output channel its device does not have.")
            case .channelShared(let device, let channel): String(localized: "Two speakers are on channel \(channel + 1) of \(device).")
            case .roleRepeated(let role): String(localized: "The \(role.rawValue) speaker is in the group twice.")
            case .positionInvalid: String(localized: "A speaker's position is not a position in a room.")
            case .speakerAtListener: String(localized: "A speaker is at the listener's seat.")
            case .trimInvalid: String(localized: "A speaker's level or delay trim is out of range.")
            case .listenerInvalid: String(localized: "The listener's seat is not a position in a room.")
            case .roomInvalid: String(localized: "The room's size is not a size.")
            }
        }
    }

    /// What is wrong with this group, in a stable order; empty when it can be played.
    public var issues: [Issue] {
        var found: [Issue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.emptyName) }
        if members.count < 2 { found.append(.tooFewMembers) }
        var seen = Set<String>()
        for member in members {
            if !seen.insert(member.deviceUID).inserted { found.append(.duplicateMember(member.deviceUID)) }
            if member.channelCount < 1 { found.append(.channelCountInvalid(member.deviceUID)) }
            if !(0...127).contains(member.driftQuality) { found.append(.driftQualityInvalid(member.deviceUID)) }
            if !Self.delayTrimRangeMs.contains(member.skewMs) { found.append(.skewInvalid(member.deviceUID)) }
            if !Member.rateTrimRangePPM.contains(member.rateTrimPPM) { found.append(.rateTrimInvalid(member.deviceUID)) }
            if let seconds = member.rateTrimSeconds, !Member.rateTrimSecondsRange.contains(seconds) { found.append(.rateTrimSecondsInvalid(member.deviceUID)) }
        }
        if !members.contains(where: { $0.deviceUID == clockLeaderUID }) { found.append(.leaderNotAMember(clockLeaderUID)) }
        if totalChannels > Self.maxChannels { found.append(.tooManyChannels(totalChannels)) }

        var roles = Set<SpeakerRole>(), wired = Set<String>()
        for speaker in speakers {
            if let member = members.first(where: { $0.deviceUID == speaker.deviceUID }) {
                if speaker.channel < 0 || speaker.channel >= member.channelCount {
                    found.append(.channelOutOfRange(speaker.id))
                } else if !wired.insert("\(speaker.deviceUID)\u{0}\(speaker.channel)").inserted {
                    let issue = Issue.channelShared(device: speaker.deviceUID, channel: speaker.channel)
                    if !found.contains(issue) { found.append(issue) }
                }
            } else {
                found.append(.speakerOnUnknownDevice(speaker.id))
            }
            if !roles.insert(speaker.role).inserted { found.append(.roleRepeated(speaker.role)) }
            if !Self.isPlace(speaker.position) || !(speaker.height?.isFinite ?? true) {
                found.append(.positionInvalid(speaker.id))
            } else if speaker.position == listener.position {
                found.append(.speakerAtListener(speaker.id))
            }
            if !Self.trimRangeDB.contains(speaker.trimDB) || !Self.delayTrimRangeMs.contains(speaker.delayTrimMs) { found.append(.trimInvalid(speaker.id)) }
        }
        if !Self.isPlace(listener.position) || !listener.facingDegrees.isFinite { found.append(.listenerInvalid) }
        if let room, !(room.width > 0 && room.depth > 0 && room.width <= Self.maxDistance * 2 && room.depth <= Self.maxDistance * 2) { found.append(.roomInvalid) }
        return found
    }

    public var isValid: Bool { issues.isEmpty }

    private static func isPlace(_ point: Point2D) -> Bool {
        point.isFinite && abs(point.x) <= maxDistance && abs(point.y) <= maxDistance
    }
}

public enum SpeakerGroupError: Error, Equatable, LocalizedError {
    case newerSchema(Int)
    case missingSchema
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .newerSchema: String(localized: "This speaker group was saved by a newer Vespertine.")
        case .missingSchema, .unreadable: String(localized: "This speaker group couldn't be read.")
        }
    }
}

/// Reads and writes one group as JSON. A file carries a schema version: a newer one is refused (and kept as it is by the
/// store), and the keys a later version adds fall back to their defaults when an older file lacks them.
public enum SpeakerGroupCoding {
    public static let currentSchema = 1

    public static func encode(_ group: SpeakerGroup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(group)
    }

    public static func decode(_ data: Data) throws -> SpeakerGroup {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SpeakerGroupError.unreadable }
        guard let version = object["schemaVersion"] as? Int else { throw SpeakerGroupError.missingSchema }
        if version > currentSchema { throw SpeakerGroupError.newerSchema(version) }
        guard let group = try? JSONDecoder().decode(SpeakerGroup.self, from: data) else { throw SpeakerGroupError.unreadable }
        return group
    }
}
