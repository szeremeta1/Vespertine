//
// Vespertine — where the speaker groups live: one JSON file in the app's data folder, written whole and kept with its
// previous version beside it. A file that can't be read is set aside, never overwritten, and the last good version is used
// instead. Groups from a newer Vespertine are kept as they were and written back with the rest. (The same rules as the
// room correction library.)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The list of groups the app holds, in the order the listener sees them.
public struct SpeakerGroupBook: Equatable, Sendable {
    public private(set) var groups: [SpeakerGroup]

    public init(groups: [SpeakerGroup] = []) { self.groups = groups }

    public func group(_ id: UUID) -> SpeakerGroup? { groups.first { $0.id == id } }

    /// The group an output UID (`SpeakerGroup.outputUID`) names; nil for a device's UID.
    public func group(outputUID uid: String) -> SpeakerGroup? {
        SpeakerGroup.groupID(fromOutputUID: uid).flatMap(group)
    }

    /// Adds the group, or replaces the one with the same id where it stands.
    public mutating func upsert(_ group: SpeakerGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group } else { groups.append(group) }
    }

    public mutating func remove(_ id: UUID) { groups.removeAll { $0.id == id } }

    /// A copy of a group, added after the others: a new id (so a new output with settings of its own), new speaker ids,
    /// "copy" in its name, and no alignment profile (that one belongs to the original).
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> SpeakerGroup? {
        guard let original = group(id) else { return nil }
        let speakers = original.speakers.map { s in
            SpeakerGroup.Speaker(id: UUID(), role: s.role, deviceUID: s.deviceUID, channel: s.channel, position: s.position, height: s.height,
                                 trimDB: s.trimDB, delayTrimMs: s.delayTrimMs, invertPolarity: s.invertPolarity)
        }
        let copy = SpeakerGroup(name: availableName(original.name + " copy"), members: original.members, clockLeaderUID: original.clockLeaderUID,
                                speakers: speakers, listener: original.listener, room: original.room, stereoPolicy: original.stereoPolicy,
                                lfePolicy: original.lfePolicy, onMemberLoss: original.onMemberLoss, alignmentProfileID: nil)
        groups.append(copy)
        return copy
    }

    /// The name, or the name with the first number from 2 that no group has taken ("Dorm", "Dorm 2", "Dorm 3").
    public func availableName(_ wanted: String) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Speaker group" : base
        let taken = Set(groups.map(\.name))
        if !taken.contains(name) { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}

public struct SpeakerGroupStore {
    public struct Loaded {
        public var groups: [SpeakerGroup]
        /// Groups this version couldn't read (a newer Vespertine's, or damaged), kept as they were.
        public var unreadable: [Any]
    }

    public static let fileVersion = 1

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var fileURL: URL { directory.appendingPathComponent("Speaker Groups.json") }
    private var backupURL: URL { directory.appendingPathComponent("Speaker Groups.previous.json") }

    /// The saved groups, or nil when there are none (or none that can be read: the damaged file is set aside first).
    public func load() -> Loaded? {
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            if let loaded = read(fileURL) { return loaded }
            setAside(fileURL)
            return read(backupURL)
        }
        if manager.fileExists(atPath: backupURL.path) { return read(backupURL) }
        return nil
    }

    /// Writes the groups. The file that was there becomes the previous version (only if it can be read).
    public func save(_ groups: [SpeakerGroup], unreadable: [Any]) throws {
        var objects = try groups.map { try JSONSerialization.jsonObject(with: SpeakerGroupCoding.encode($0)) }
        objects.append(contentsOf: unreadable)
        let object: [String: Any] = ["version": Self.fileVersion, "groups": objects]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if read(fileURL) != nil {
            try? manager.removeItem(at: backupURL)
            try? manager.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func read(_ url: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["version"] as? Int == Self.fileVersion,
              let list = object["groups"] as? [Any] else { return nil }
        var groups: [SpeakerGroup] = [], unreadable: [Any] = []
        for item in list {
            if let bytes = try? JSONSerialization.data(withJSONObject: item), let group = try? SpeakerGroupCoding.decode(bytes) {
                groups.append(group)
            } else {
                unreadable.append(item)
            }
        }
        return Loaded(groups: groups, unreadable: unreadable)
    }

    private func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = directory.appendingPathComponent("Speaker Groups.damaged-\(stamp).json")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
