//
// Vespertine — where the room correction library lives: one JSON file in the app's data folder, written whole and
// kept with its previous version beside it. A file that can't be read is set aside, never overwritten, and the last
// good version is used instead.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct RoomProfileStore {
    /// What the app's preferences held before the library had a file of its own.
    public struct Legacy {
        public var profiles: Data?
        public var choices: [String: String]
        public var assignments: [String: String]

        public init(profiles: Data?, choices: [String: String], assignments: [String: String]) {
            self.profiles = profiles
            self.choices = choices
            self.assignments = assignments
        }
    }

    public struct Loaded {
        public var book: RoomProfileBook
        /// Profiles from a newer Vespertine, kept as they were.
        public var unreadable: [Any]
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var fileURL: URL { directory.appendingPathComponent("Room Profiles.json") }
    private var backupURL: URL { directory.appendingPathComponent("Room Profiles.previous.json") }

    /// The saved library, or nil when there isn't one (or none that can be read: the damaged file is set aside first).
    /// With no file at all, `legacy` is read instead.
    public func load(legacy: Legacy? = nil) -> Loaded? {
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            if let loaded = read(fileURL) { return loaded }
            setAside(fileURL)
            if let loaded = read(backupURL) { return loaded }
            return nil
        }
        if manager.fileExists(atPath: backupURL.path), let loaded = read(backupURL) { return loaded }
        guard let legacy, let data = legacy.profiles, let read = try? RoomCorrectionCoding.decodeProfilesKeepingUnreadable(data) else { return nil }
        return Loaded(book: RoomProfileBook(profiles: read.profiles, choices: legacy.choices, assignments: legacy.assignments), unreadable: read.unreadable)
    }

    /// Writes the library. The file that was there becomes the previous version (only if it can be read).
    public func save(_ book: RoomProfileBook, unreadable: [Any]) throws {
        let profiles = try RoomCorrectionCoding.encodeProfiles(book.profiles, keeping: unreadable)
        let object: [String: Any] = [
            "version": 1,
            "profiles": try JSONSerialization.jsonObject(with: profiles),
            "choices": book.choices,
            "assignments": book.assignments,
        ]
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
              object["version"] as? Int == 1,
              let profiles = object["profiles"],
              let list = try? JSONSerialization.data(withJSONObject: profiles),
              let read = try? RoomCorrectionCoding.decodeProfilesKeepingUnreadable(list) else { return nil }
        let book = RoomProfileBook(profiles: read.profiles, choices: object["choices"] as? [String: String] ?? [:],
                                   assignments: object["assignments"] as? [String: String] ?? [:])
        return Loaded(book: book, unreadable: read.unreadable)
    }

    private func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = directory.appendingPathComponent("Room Profiles.damaged-\(stamp).json")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
