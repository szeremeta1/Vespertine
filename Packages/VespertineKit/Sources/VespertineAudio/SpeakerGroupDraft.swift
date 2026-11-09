//
// Vespertine: speaker groups: making one. Which outputs may join and why the others may not, the order and the clock leader of the
// ones chosen, and the group that comes out. Plain data, so the sheet that shows it is a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The words are plain English for now, outside the string catalog (see SpeakerGroup.swift).
//

import Foundation

public struct GroupCandidate: Equatable, Sendable, Identifiable {
    public enum Eligibility: Equatable, Sendable {
        case ok
        /// May join, with a note to show.
        case warning(String)
        /// May not join, and why.
        case refused(String)
    }

    public var uid: String
    public var name: String
    public var channels: Int
    public var transport: Transport
    public var eligibility: Eligibility
    public var id: String { uid }

    public init(uid: String, name: String, channels: Int, transport: Transport, eligibility: Eligibility) {
        self.uid = uid
        self.name = name
        self.channels = channels
        self.transport = transport
        self.eligibility = eligibility
    }

    public var isSelectable: Bool {
        if case .refused = eligibility { return false }
        return true
    }
}

public enum GroupCandidates {
    /// Whether an output may join a group, and the reason when it may not.
    public static func candidate(for device: OutputDevice) -> GroupCandidate {
        let channels = device.capabilities.outputChannels
        let eligibility: GroupCandidate.Eligibility
        switch device.transport {
        case _ where channels < 1:
            eligibility = .refused(String(localized: "It has no output channels."))
        case .bluetooth, .bluetoothLE, .airPlay:
            eligibility = .refused(String(localized: "It adds 100 ms or more of delay that changes, so it can't be kept in step with the others."))
        case .aggregate:
            eligibility = .refused(String(localized: "It is already a combined output."))
        case .virtual:
            eligibility = .refused(String(localized: "It is a software device, not a speaker output."))
        case .builtIn:
            eligibility = .warning(String(localized: "macOS processes this output, so it is never bit-perfect."))
        case .unknown:
            eligibility = .warning(String(localized: "This kind of connection hasn't been tested with groups."))
        case .usb, .hdmi, .displayPort, .thunderbolt, .pci, .fireWire:
            eligibility = .ok
        }
        return GroupCandidate(uid: device.uid, name: device.name, channels: channels, transport: device.transport, eligibility: eligibility)
    }

    /// The outputs to offer, what may join first, each part by name. Groups themselves are not outputs to combine.
    public static func list(from devices: [OutputDevice]) -> [GroupCandidate] {
        let all = devices.filter { !$0.uid.hasPrefix(SpeakerGroup.outputUIDPrefix) }.map(candidate(for:))
        func order(_ a: GroupCandidate, _ b: GroupCandidate) -> Bool {
            if a.isSelectable != b.isSelectable { return a.isSelectable }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return all.sorted(by: order)
    }
}

/// A group being made: the outputs chosen (in the order of the aggregate's streams), the clock leader and the name.
public struct SpeakerGroupDraft: Equatable, Sendable {
    public var name: String
    public private(set) var chosen: [GroupCandidate] = []
    public private(set) var leaderUID: String?

    public init(name: String = "") { self.name = name }

    /// One plain sentence for the clock leader picker.
    public static let leaderExplanation = String(localized: "Your other DACs follow this one's clock. Its channels can be bit-perfect; the others are resampled by a few millionths to stay in step.")

    public func isChosen(_ uid: String) -> Bool { chosen.contains { $0.uid == uid } }

    /// Chooses the output, or takes it out again. An output that may not join cannot be chosen. The first chosen leads until another
    /// is picked, and the first one left leads when the leader is taken out.
    public mutating func toggle(_ candidate: GroupCandidate) {
        if let index = chosen.firstIndex(where: { $0.uid == candidate.uid }) {
            chosen.remove(at: index)
        } else if candidate.isSelectable {
            chosen.append(candidate)
        }
        if leaderUID == nil || !isChosen(leaderUID!) { leaderUID = chosen.first?.uid }
    }

    public mutating func setLeader(_ uid: String) {
        if isChosen(uid) { leaderUID = uid }
    }

    /// Moves a chosen output one place earlier (-1) or later (1) in the order of the streams.
    public mutating func move(_ uid: String, by step: Int) {
        guard let index = chosen.firstIndex(where: { $0.uid == uid }) else { return }
        let target = index + (step < 0 ? -1 : 1)
        guard chosen.indices.contains(target) else { return }
        chosen.swapAt(index, target)
    }

    public var totalChannels: Int { chosen.reduce(0) { $0 + $1.channels } }

    /// What stops the group from being made, in sentences; empty when it can be.
    public var problems: [String] {
        var found: [String] = []
        if chosen.count < 2 { found.append(String(localized: "Choose at least two outputs.")) }
        if totalChannels > SpeakerGroup.maxChannels {
            found.append(String(localized: "The outputs add up to \(totalChannels) channels; a group can have \(SpeakerGroup.maxChannels)."))
        }
        return found
    }

    public var canCreate: Bool { problems.isEmpty }

    /// The problems worth showing now: nothing is said about too few outputs before the first one is chosen.
    public var problemsWhileChoosing: [String] { chosen.isEmpty ? [] : problems }

    /// The group: members in the chosen order with all their channels, the clock leader, no speakers placed yet.
    public func makeGroup(id: UUID = UUID()) -> SpeakerGroup? {
        guard canCreate, let leaderUID else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeakerGroup(id: id, name: trimmed.isEmpty ? String(localized: "Speaker group", comment: "The name a new speaker group gets when none was typed.") : trimmed,
                            members: chosen.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: $0.channels) },
                            clockLeaderUID: leaderUID)
    }
}
