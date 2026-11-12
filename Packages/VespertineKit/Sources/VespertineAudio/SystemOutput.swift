//
// Vespertine: Mac Sound Output (beta): a speaker group as an output every app on the Mac can play to. The pure part: what the
// user chose per group, the layout the output shows, how what other apps play is put onto the group's speakers, and when a
// stereo source is told apart from a surround one. Nothing here touches a device.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The output itself is Vespertine's audio driver (Driver/VespertineSound); Vespertine's helper reads it and plays it through the
// speaker-group engine (`SystemOutputSession`). The app hands the helper what it needs in one file (`SystemOutputSnapshot`), so the
// helper never reads the app's settings and runs the same with the app quit.
//

import CoreAudio
import Foundation

/// What stereo from other apps (a browser, most video) does on a group with more than two speakers.
public enum SystemOutputStereo: String, Codable, CaseIterable, Sendable {
    /// As the group's own stereo policy says (the same as music in Vespertine).
    case asGroup
    /// Extended stereo, as a receiver's "all channel stereo": left and right on every speaker of their side.
    case extended
    /// Upmixed to 5.1 (Vespertine's Spatialize stereo upmixer: a centre from what both sides share, the surrounds from the
    /// ambience), then placed on the group's speakers by where they stand.
    case upmix
}

/// The channel layout the output shows other apps: what they send.
public enum SystemOutputLayout: String, Codable, CaseIterable, Sendable {
    /// From the group's speakers (a quad shows 5.1, so films send six channels; see `automatic(for:)`).
    case automatic
    case stereo
    case quad
    case surround51
    case surround71
    case surround714
    case surround916

    /// The output's channels, in order. nil for `automatic` (see `resolved(for:)`).
    public var labels: [AudioChannelLabel]? {
        let front: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        let bed51 = front + [kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let bed71 = bed51 + [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        switch self {
        case .automatic: return nil
        case .stereo: return front
        case .quad: return front + [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        case .surround51: return bed51
        case .surround71: return bed71
        case .surround714:
            return bed71 + [kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight,
                            kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]
        case .surround916:
            return bed71 + [kAudioChannelLabel_LeftWide, kAudioChannelLabel_RightWide,
                            kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight,
                            kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_RightTopMiddle,
                            kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]
        }
    }

    /// The layout `automatic` stands for on `group`: the smallest film layout that has a channel for every kind of speaker the group
    /// has. Two speakers: stereo. Anything more is at least 5.1, so films send their own centre and LFE and the group places them
    /// (a quad has no centre speaker: the centre is put between the front pair). Heights: 7.1.4, or 9.1.6 with wides or top middles.
    public static func automatic(for group: SpeakerGroup) -> SystemOutputLayout {
        let roles = Set(group.speakers.map(\.role))
        if roles.count <= 2 && !roles.contains(where: { $0 != .frontLeft && $0 != .frontRight && $0 != .center }) { return .stereo }
        let heights = roles.filter(\.isHeight)
        let wides = roles.contains(.wideLeft) || roles.contains(.wideRight)
        if wides || roles.contains(.topMiddleLeft) || roles.contains(.topMiddleRight) { return .surround916 }
        if !heights.isEmpty { return .surround714 }
        if roles.contains(.backLeft) || roles.contains(.backRight) || roles.contains(.backCenter) {
            // Back speakers alongside side ones: 7.1. A quad's rear pair named "back" is still 5.1's surrounds.
            if roles.contains(.sideLeft) || roles.contains(.sideRight) { return .surround71 }
        }
        return .surround51
    }

    public func resolved(for group: SpeakerGroup) -> SystemOutputLayout {
        self == .automatic ? Self.automatic(for: group) : self
    }
}

/// What the user chose for one group. Off by default: nothing is published until they turn it on.
public struct SystemOutputChoice: Codable, Hashable, Sendable {
    public var published: Bool
    public var layout: SystemOutputLayout
    public var stereo: SystemOutputStereo

    public init(published: Bool = false, layout: SystemOutputLayout = .automatic, stereo: SystemOutputStereo = .asGroup) {
        self.published = published
        self.layout = layout
        self.stereo = stereo
    }
}

/// One published group as the helper plays it: everything it needs, so it reads nothing else of the app's.
public struct SystemOutputEntry: Codable, Hashable, Sendable {
    public var group: SpeakerGroup
    public var choice: SystemOutputChoice
    /// The room correction chosen for the group's output (the speaker delays and trims are added by `GroupDelay.chain`).
    public var room: RoomCorrectionPlayback?
    /// Hold the DACs (exclusive access), as Vespertine's own setting says.
    public var exclusive: Bool
    public var upmix: UpmixSettings

    public init(group: SpeakerGroup, choice: SystemOutputChoice, room: RoomCorrectionPlayback? = nil, exclusive: Bool = false,
                upmix: UpmixSettings = UpmixSettings()) {
        self.group = group
        self.choice = choice
        self.room = room
        self.exclusive = exclusive
        self.upmix = upmix
    }

    /// The output's UID: stable for the group, so macOS keeps remembering it as the chosen output.
    public var deviceUID: String { SystemOutput.deviceUID(groupID: group.id) }
    public var captureUID: String { SystemOutput.captureUID(deviceUID: deviceUID) }
    /// The output's channels, in order.
    public var labels: [AudioChannelLabel] { choice.layout.resolved(for: group).labels ?? [kAudioChannelLabel_Left, kAudioChannelLabel_Right] }
}

/// What the app hands the helper: the published groups.
public struct SystemOutputSnapshot: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var entries: [SystemOutputEntry]
    /// Show the helper's item in the menu bar (off by default).
    public var menuBarItem: Bool

    public init(entries: [SystemOutputEntry], menuBarItem: Bool = false) {
        version = Self.currentVersion
        self.entries = entries
        self.menuBarItem = menuBarItem
    }

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent("Mac Sound Output.json") }

    /// Where the app and the helper meet: a folder of its own in Application Support, so the helper finds it without being told.
    /// Development builds (`development`) have their own, as they have their own library.
    public static func directory(development: Bool) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(development ? "Vespertine Dev Mac Sound Output" : "Vespertine Mac Sound Output", isDirectory: true)
    }

    /// nil for a missing or unreadable file (the helper then publishes nothing).
    public static func read(from url: URL) -> SystemOutputSnapshot? {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(SystemOutputSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum SystemOutput {
    /// Every output the driver shows has a UID starting with this.
    public static let uidPrefix = "org.szeremeta.vespertine.sound."
    /// The driver's bundle ID (VESPERTINE_SOUND_BUNDLE_ID in the driver).
    public static let driverBundleID = "org.szeremeta.vespertine.sound"
    /// The driver's custom property holding the published outputs ('vcfg').
    public static let configurationSelector: AudioObjectPropertySelector = 0x7663_6667
    /// At most this many outputs, and channels on each (the driver's and the group engine's limits).
    public static let maxOutputs = 8
    public static let maxChannels = 16
    /// How often the helper refreshes what it published; the driver takes an output away after 20 s without.
    public static let refreshSeconds: TimeInterval = 5

    public static func deviceUID(groupID: UUID) -> String { uidPrefix + groupID.uuidString.lowercased() }
    public static func captureUID(deviceUID: String) -> String { deviceUID + ".capture" }
    public static func isSystemOutputUID(_ uid: String) -> Bool { uid.hasPrefix(uidPrefix) }

    /// The driver's configuration for `entries`: what `SystemOutputDriver.publish` sets. `latency`: frames to report for each
    /// output UID (what the helper measured once it plays; 0 before).
    public static func driverConfiguration(_ entries: [SystemOutputEntry], latency: [String: Int] = [:]) -> [[String: Any]] {
        entries.prefix(maxOutputs).map { entry in
            let labels = Array(entry.labels.prefix(maxChannels))
            return [
                "uid": entry.deviceUID,
                "name": entry.group.name,
                "channels": labels.count,
                "labels": labels.map { Int($0) },
                "latency": max(0, latency[entry.deviceUID] ?? 0),
            ]
        }
    }
}

// MARK: - Routing what other apps play

/// Whether what arrives is a stereo source played on the output's front pair, or uses the other channels too.
public enum SystemOutputContent: Equatable, Sendable {
    case stereo
    case multichannel
}

public enum SystemOutputRouting {
    /// The gain matrix (`gains[out * inputs + in]`, group channels by output channels) that puts what arrives on the output's
    /// `input` channels onto `group`, for `content`. For stereo content under `upmix` this is the matrix of the 5.1 the upmixer
    /// makes (six inputs), not of the output's channels. nil when the group has nowhere to put it.
    public static func matrix(input: [AudioChannelLabel], group: SpeakerGroup, content: SystemOutputContent, stereo: SystemOutputStereo) -> [Float]? {
        guard let router = router(input: input, group: group, content: content, stereo: stereo) else { return nil }
        let sources = sourceChannels(input: input, content: content, stereo: stereo)
        let inputs = content == .stereo && stereo == .upmix ? StereoUpmixer.outputChannels : input.count
        var gains = [Float](repeating: 0, count: group.totalChannels * inputs)
        for output in 0..<group.totalChannels {
            for tap in router.matrixRow(output) where tap.source < sources.count {
                gains[output * inputs + sources[tap.source]] += tap.gain
            }
        }
        return gains
    }

    /// The router for `content`: the output's own channels for a surround source; the front pair (by the stereo choice) for stereo;
    /// the upmixer's 5.1 for stereo under `upmix`.
    public static func router(input: [AudioChannelLabel], group: SpeakerGroup, content: SystemOutputContent, stereo: SystemOutputStereo) -> PositionRouter? {
        switch (content, stereo) {
        case (.multichannel, _):
            return PositionRouter(source: input, group: group)
        case (.stereo, .upmix):
            return PositionRouter(source: StereoUpmixer.outputLabels, group: group)
        case (.stereo, .asGroup):
            return PositionRouter(source: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], group: group)
        case (.stereo, .extended):
            var extended = group
            extended.stereoPolicy = .allSpeakers
            return PositionRouter(source: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], group: extended)
        }
    }

    /// For each of the router's source channels, the matrix column it reads.
    static func sourceChannels(input: [AudioChannelLabel], content: SystemOutputContent, stereo: SystemOutputStereo) -> [Int] {
        switch (content, stereo) {
        case (.multichannel, _): return Array(input.indices)
        case (.stereo, .upmix): return Array(0..<StereoUpmixer.outputChannels)
        case (.stereo, _): return [frontPair(input).left, frontPair(input).right]
        }
    }

    /// Where the output's left and right are (where macOS puts stereo).
    public static func frontPair(_ input: [AudioChannelLabel]) -> (left: Int, right: Int) {
        let left = input.firstIndex(of: kAudioChannelLabel_Left) ?? 0
        let right = input.firstIndex(of: kAudioChannelLabel_Right) ?? min(1, max(input.count - 1, 0))
        return (left, right)
    }
}

// MARK: - Telling stereo from surround

/// macOS plays a stereo source on a surround output's front pair and leaves the rest silent, so the output's channels alone can't
/// say whether a film or a browser is playing. The peaks can: the other channels stay silent under stereo. Surround is taken at
/// once (any sound off the front pair); stereo only after the other channels have been silent for a while, longer once surround
/// was heard, so a quiet stretch of a film doesn't flip its surrounds to the stereo treatment.
public struct SystemOutputContentDetector: Sendable {
    /// Below this (−80 dBFS) a channel counts as silent.
    public static let silence: Float = 0.000_1
    /// Silence off the front pair needed before stereo is assumed: at the start, and after surround was heard.
    public static let stereoAfter: Double = 0.75
    public static let stereoAfterSurround: Double = 8

    public private(set) var content: SystemOutputContent
    private let front: Set<Int>
    private let channels: Int
    private var quiet: Double = 0
    private var heardSurround = false

    /// `input`: the output's channels. A stereo output is always stereo.
    public init(input: [AudioChannelLabel]) {
        let pair = SystemOutputRouting.frontPair(input)
        front = [pair.left, pair.right]
        channels = input.count
        content = .stereo
    }

    /// Takes the peaks of the last `seconds` (one per output channel); true when the content changed.
    public mutating func update(peaks: [Float], seconds: Double) -> Bool {
        guard channels > 2 else { return false }
        let others = peaks.indices.filter { !front.contains($0) && $0 < channels }.map { peaks[$0] }.max() ?? 0
        if others > Self.silence {
            quiet = 0
            heardSurround = true
            if content != .multichannel { content = .multichannel; return true }
            return false
        }
        let fronts = front.compactMap { peaks.indices.contains($0) ? peaks[$0] : nil }.max() ?? 0
        // Silence everywhere says nothing: keep what was playing.
        guard fronts > Self.silence else { return false }
        quiet += max(seconds, 0)
        if content == .multichannel && quiet >= (heardSurround ? Self.stereoAfterSurround : Self.stereoAfter) {
            content = .stereo
            return true
        }
        return false
    }
}
