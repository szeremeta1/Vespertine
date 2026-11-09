//
// Vespertine: speaker groups as an output the engine can choose: finding a group's members among the connected outputs, and
// the one output they present together. Nothing here touches a device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum GroupOutput {
    public enum Resolution: Equatable, Sendable {
        /// Every member is connected and usable: the output the group presents, and the members in the group's order.
        case ready(output: OutputDevice, members: [OutputDevice])
        /// These members (by name, in the group's order) aren't connected, or have fewer channels than the group needs.
        case missing([String])
        /// A group that carries on with only its leader: that device, played as a single output.
        case single(OutputDevice)
        /// The members have no sample rate in common.
        case noCommonRate
        /// The group itself is not valid (`SpeakerGroup.issues`).
        case invalid
    }

    /// The group's members among `devices`. The output it presents has the group's UID and name, no device ID of its own (its
    /// aggregate is made when it plays), all the members' channels and the rates they all take.
    public static func resolve(_ group: SpeakerGroup, among devices: [OutputDevice]) -> Resolution {
        guard group.isValid else { return .invalid }
        var members: [OutputDevice] = [], missing: [String] = []
        for member in group.members {
            if let device = devices.first(where: { $0.uid == member.deviceUID }), device.capabilities.outputChannels >= member.channelCount {
                members.append(device)
            } else {
                missing.append(member.name)
            }
        }
        guard missing.isEmpty else { return .missing(missing) }
        let output = presented(group, members: members)
        guard !output.capabilities.sampleRates.isEmpty else { return .noCommonRate }
        return .ready(output: output, members: members)
    }

    /// The output a group presents: see `resolve`.
    static func presented(_ group: SpeakerGroup, members: [OutputDevice]) -> OutputDevice {
        OutputDevice(id: AudioObjectID(kAudioObjectUnknown), uid: group.outputUID, name: group.name, manufacturer: "", modelUID: nil,
                     transport: .aggregate, nominalSampleRate: members.first?.nominalSampleRate ?? 0,
                     capabilities: GroupCapabilities.combined(members.map(\.capabilities)), hasHardwareVolume: false, isDefault: false)
    }

    /// The UIDs of the groups that count as connected outputs: those whose members all are.
    public static func connectedUIDs(of groups: [SpeakerGroup], connected: Set<String>) -> Set<String> {
        Set(groups.filter { group in group.members.allSatisfy { connected.contains($0.deviceUID) } }.map(\.outputUID))
    }

    /// The same output: a single device by its ID, a group by its UID (its aggregate's ID changes whenever it is remade).
    static func isSameOutput(_ a: OutputDevice?, _ b: OutputDevice) -> Bool {
        guard let a else { return false }
        if isGroupOutput(a) || isGroupOutput(b) { return a.uid == b.uid }
        return a.id == b.id
    }

    public static func isGroupOutput(_ device: OutputDevice) -> Bool { device.uid.hasPrefix(SpeakerGroup.outputUIDPrefix) }

    /// Exclusive access for a group: the setting, unless a member always plays shared (the Mac's own outputs).
    static func exclusive(setting: Bool, members: [OutputDevice]) -> Bool {
        setting && !members.contains(where: \.alwaysShared)
    }
}

extension OutputDevice {
    /// This output with another device ID (a group's, once its aggregate exists).
    func with(id: AudioObjectID) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, manufacturer: manufacturer, modelUID: modelUID, transport: transport,
                     nominalSampleRate: nominalSampleRate, capabilities: capabilities, hasHardwareVolume: hasHardwareVolume, isDefault: isDefault)
    }
}

extension SpeakerGroup {
    /// The group as `chosen` now has it, played on the aggregate this group (`self`, the group a session opened, less any member lost
    /// since) was made for. The aggregate's channels keep the order and shape they were made with until the output opens again: its
    /// members in its order, each with the channels it has there, and its clock leader. A member edited to another channel count, or
    /// taken out of the group, keeps its part as it was opened; everything else of the edit (trims, positions, wiring within a DAC,
    /// policies) applies at once.
    public func asPlayed(chosen: SpeakerGroup) -> SpeakerGroup {
        var group = chosen
        var kept: Set<String> = []
        group.members = members.map { opened in
            guard let now = chosen.members.first(where: { $0.deviceUID == opened.deviceUID }), now.channelCount == opened.channelCount else { return opened }
            kept.insert(opened.deviceUID)
            return now
        }
        group.clockLeaderUID = clockLeaderUID
        group.speakers = chosen.speakers.filter { kept.contains($0.deviceUID) }
            + speakers.filter { speaker in !kept.contains(speaker.deviceUID) && members.contains { $0.deviceUID == speaker.deviceUID } }
        return group
    }
}

extension EngineSettings {
    /// The speaker group a chosen output UID names; nil for a single device's UID or when no groups are known.
    public func group(forOutputUID uid: String?) -> SpeakerGroup? {
        guard let uid, uid.hasPrefix(SpeakerGroup.outputUIDPrefix) else { return nil }
        return speakerGroups.first { $0.outputUID == uid }
    }
}
