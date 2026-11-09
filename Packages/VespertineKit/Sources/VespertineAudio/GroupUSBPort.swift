//
// Vespertine: speaker groups and USB ports. Core Audio puts the USB port's location ID into a USB device's UID
// ("AppleUSBAudioEngine:FIIO:FiiO K11:140000:2"), so the same DAC plugged into another port has another UID and a group that
// names its members by UID would wait for a device that is already there. A member that isn't found by its saved UID is looked for
// by the rest of the UID, and is taken only when exactly one present device fits: with two alike, which is which can't be known,
// so the group waits. A group that found its members this way is rewritten to their new UIDs so it stays found.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum USBDeviceUID {
    private static let transport = "AppleUSBAudioEngine"

    /// A USB device's UID without its location ID: the transport, the vendor, the model and the interface index. The same DAC has the
    /// same key on every port. nil for a UID that isn't of the form `AppleUSBAudioEngine:vendor:model:location:interface` with a hex
    /// location (any other UID, a serial number in the place of the location included, doesn't change with the port: it is matched as it is).
    public static func portIndependentKey(_ uid: String) -> String? {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == transport, !parts[1].isEmpty, !parts[2].isEmpty, !parts[4].isEmpty,
              !parts[3].isEmpty, parts[3].allSatisfy(\.isHexDigit) else { return nil }
        return [parts[0], parts[1], parts[2], parts[4]].joined(separator: ":")
    }
}

extension SpeakerGroup {
    /// The UID each member that isn't among `devices` has been found under (its saved UID to the UID now): a present device with the
    /// same port-independent key, when it is the only one and the only member looking for that key. Devices that are some member's saved
    /// UID are that member's and never taken for another.
    func usbPortMoves(amongUIDs uids: [String]) -> [String: String] {
        let present = Set(uids), saved = Set(members.map(\.deviceUID))
        var lookingFor: [String: [String]] = [:]
        for member in members where !present.contains(member.deviceUID) {
            if let key = USBDeviceUID.portIndependentKey(member.deviceUID) { lookingFor[key, default: []].append(member.deviceUID) }
        }
        guard !lookingFor.isEmpty else { return [:] }
        var candidates: [String: [String]] = [:]
        for uid in uids where !saved.contains(uid) {
            if let key = USBDeviceUID.portIndependentKey(uid), lookingFor[key] != nil { candidates[key, default: []].append(uid) }
        }
        var moves: [String: String] = [:]
        for (key, old) in lookingFor {
            if old.count == 1, let found = candidates[key], found.count == 1 { moves[old[0]] = found[0] }
        }
        return moves
    }

    /// This group with the members it found on other USB ports under their UIDs now (members, speakers, clock leader), or nil when
    /// every member is where it was or can't be told from another. Everything else, the ID the output and its room profile go by
    /// included, stays.
    public func followingUSBPorts(among devices: [OutputDevice]) -> SpeakerGroup? { followingUSBPorts(amongUIDs: devices.map(\.uid)) }

    func followingUSBPorts(amongUIDs uids: [String]) -> SpeakerGroup? {
        let moves = usbPortMoves(amongUIDs: uids)
        guard !moves.isEmpty else { return nil }
        var moved = self
        for index in moved.members.indices { moved.members[index].deviceUID = moves[moved.members[index].deviceUID] ?? moved.members[index].deviceUID }
        for index in moved.speakers.indices { moved.speakers[index].deviceUID = moves[moved.speakers[index].deviceUID] ?? moved.speakers[index].deviceUID }
        moved.clockLeaderUID = moves[clockLeaderUID] ?? clockLeaderUID
        return moved
    }
}

extension SpeakerGroupBook {
    /// Rewrites every group whose members were found on other USB ports. True when a group changed (to be saved).
    @discardableResult
    public mutating func followUSBPorts(among devices: [OutputDevice]) -> Bool {
        var changed = false
        for group in groups {
            if let moved = group.followingUSBPorts(among: devices) { upsert(moved); changed = true }
        }
        return changed
    }
}
