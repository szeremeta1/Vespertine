//
// Vespertine: a folder on the phone as the library sees a share: folders to list and files to read ranges of, by path.
// The folder is one the person chose in Files (on the phone, in iCloud Drive, on a drive plugged in) or the app's own;
// the music stays where it is and is read from there. Nothing here is a network: the same index, screens and player
// that an SMB share has are simply given these files instead.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// A folder's files, read where they are. What goes wrong is said in a share's terms, so everything that shows a
/// share's troubles shows a folder's: `.accessDenied` when the folder can't be opened at all (the permission to it is
/// gone), `.unreachable` when it isn't there (its drive was unplugged, it was moved or deleted), `.notFound` for one
/// file or folder inside it that is gone.
public final class FolderFiles: ShareFiles, @unchecked Sendable {
    private let lock = NSLock()
    private let locate: @Sendable () throws -> URL
    private let lost: @Sendable () -> Void
    /// The song being read (it is read in many pieces), kept open between reads.
    private var open: (path: String, handle: FileHandle)?

    /// - Parameters:
    ///   - locate: where the folder is now. Asked every time, so a folder that comes back (a drive plugged in again)
    ///     is found again; throws when the folder can't be opened any more.
    ///   - lost: the folder turned out not to be there: whatever `locate` holds on to is let go, to be found afresh.
    public init(locate: @escaping @Sendable () throws -> URL, lost: @escaping @Sendable () -> Void = {}) {
        self.locate = locate
        self.lost = lost
    }

    /// A folder at a place that doesn't move (the app's own, or a test's).
    public convenience init(at root: URL) { self.init(locate: { root }) }

    deinit { try? open?.handle.close() }

    private func root() throws -> URL {
        do { return try locate() } catch let error as SMBError { throw error } catch { throw SMBError.accessDenied }
    }

    private func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    /// A path from the top as a place under `root`; names that would step outside the folder are refused.
    private func place(_ path: String, under root: URL) throws -> URL {
        var url = root
        for name in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard name != "..", name != "." else { throw SMBError.notFound }
            url.appendPathComponent(String(name))
        }
        return url
    }

    /// Why something under `root` couldn't be read: the whole folder is gone, or only that one thing.
    private func trouble(under root: URL) -> SMBError {
        guard isFolder(root) else {
            lost()
            return .unreachable
        }
        return .notFound
    }

    /// File times to the whole second: the same number however it is written down and read back.
    private static func whole(_ date: Date?) -> Date {
        Date(timeIntervalSince1970: ((date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970).rounded(.down))
    }

    public func list(_ folder: String) throws -> [SMBEntry] {
        try lock.withLock {
            let root = try root()
            let url = try place(folder, under: root)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            } catch {
                throw trouble(under: root)
            }
            return names.compactMap { name in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path) else { return nil }
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { return nil }
                return SMBEntry(name: name, isFolder: type == .typeDirectory, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                modified: Self.whole(attributes[.modificationDate] as? Date), hidden: name.hasPrefix("."))
            }
        }
    }

    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            let root = try root()
            do {
                let handle: FileHandle
                if let open, open.path == path {
                    handle = open.handle
                } else {
                    try? open?.handle.close()
                    open = nil
                    handle = try FileHandle(forReadingFrom: try place(path, under: root))
                    open = (path, handle)
                }
                try handle.seek(toOffset: UInt64(max(0, offset)))
                return try handle.read(upToCount: max(0, length)) ?? Data()
            } catch {
                try? open?.handle.close()
                open = nil
                throw trouble(under: root)
            }
        }
    }

    public func info(_ path: String) throws -> (size: Int64, modified: Date) {
        try lock.withLock {
            let root = try root()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: try place(path, under: root).path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw trouble(under: root) }
            return ((attributes[.size] as? NSNumber)?.int64Value ?? 0, Self.whole(attributes[.modificationDate] as? Date))
        }
    }

    /// Closes the file it has open. The folder itself is not let go of here: a scan and a song may both be reading it.
    public func rest() {
        lock.withLock {
            try? open?.handle.close()
            open = nil
        }
    }
}

/// A folder the person added from Files, or the app's own folder that files opened in Vespertine are put in.
public struct SavedFolder: Codable, Sendable, Equatable, Identifiable {
    /// A share's prefix and `folder-`: a folder is opened, indexed and played as a share is, and told apart by this.
    public static let prefix = ShareMac.prefix + "folder-"
    /// The app's own folder.
    public static let ownID = prefix + "own"

    public var id: String
    public var name: String
    /// What finds the folder again and carries the permission to read it; nil for the app's own folder.
    public var bookmark: Data?
    public var addedAt: Date

    public init(id: String = SavedFolder.newID(), name: String, bookmark: Data?, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.addedAt = addedAt
    }

    public static func newID() -> String { prefix + UUID().uuidString.lowercased() }

    public var isOwn: Bool { id == Self.ownID }
}

/// The folders added, kept in a file on the phone (a bookmark is no secret: it only works for this app on this device).
public struct FolderShelf: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> [SavedFolder] {
        ((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SavedFolder].self, from: $0) } ?? []).sorted { $0.addedAt < $1.addedAt }
    }

    @discardableResult
    public func save(_ folders: [SavedFolder]) -> Bool {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(folders) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Adds the folder, or replaces the one with its ID.
    public func upsert(_ folder: SavedFolder) {
        save(load().filter { $0.id != folder.id } + [folder])
    }

    public func remove(id: String) {
        save(load().filter { $0.id != id })
    }
}

/// Putting a single file opened in Vespertine ("Open in", the share sheet) into the app's own folder, where it is
/// indexed and played like any other. The file is copied: what another app hands over is often gone a moment later.
public enum OpenedFiles {
    public enum Outcome: Equatable, Sendable {
        /// Now in the folder under this name.
        case added(String)
        /// Not a kind of file the phone opens itself.
        case notPlayable
        case failed
    }

    /// Copies `file` into `folder`. A file already there with the same name and size is taken to be the same one and
    /// replaced; with another size, the new one gets a number after its name. A file the system left in the folder's
    /// own `Inbox` is moved rather than copied.
    public static func take(_ file: URL, into folder: URL) -> Outcome {
        let name = file.lastPathComponent
        guard SongTagReader.playable.contains(SongTagReader.fileExtension(name)), !name.hasPrefix(".") else { return .notPlayable }
        let manager = FileManager.default
        func size(_ url: URL) -> Int64? { ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value }
        guard let incoming = size(file) else { return .failed }
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Already in the folder (opened from Files, where the app's folder shows): it is played where it is.
        let base = folder.resolvingSymlinksInPath().path, place = file.resolvingSymlinksInPath().path
        let inbox = base + "/Inbox"
        if place.hasPrefix(base + "/"), !place.hasPrefix(inbox + "/") { return .added(String(place.dropFirst(base.count + 1))) }

        let type = "." + (name.split(separator: ".").last.map(String.init) ?? "")
        let stem = String(name.dropLast(type.count))
        var target = folder.appendingPathComponent(name)
        var number = 2
        while let existing = size(target) {
            if existing == incoming {
                try? manager.removeItem(at: target)
                break
            }
            target = folder.appendingPathComponent("\(stem) \(number)\(type)")
            number += 1
        }
        do {
            if place.hasPrefix(inbox + "/") {
                try manager.moveItem(at: file, to: target)
            } else {
                try manager.copyItem(at: file, to: target)
            }
        } catch {
            return .failed
        }
        return .added(target.lastPathComponent)
    }

    /// Whether the folder holds anything a person put there (the system's own `Inbox` and hidden files aside).
    public static func holdsAnything(_ folder: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { !$0.hasPrefix(".") && $0 != "Inbox" }
    }
}

#if canImport(Darwin)
/// Finds a folder again from its bookmark and holds the permission to read it for as long as it is in use. One of
/// these serves everything that reads the folder (the scan and the player), so the permission is taken once.
public final class FolderAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let bookmark: Data
    private var held: (url: URL, scoped: Bool)?
    /// The bookmark was out of date and a fresh one was made: keep it in place of the old.
    private let refreshed: @Sendable (Data) -> Void

    public init(bookmark: Data, refreshed: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.bookmark = bookmark
        self.refreshed = refreshed
    }

    /// A bookmark for a folder just chosen in the picker. nil when the system won't give one.
    public static func bookmark(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where the folder is now. Throws `SMBError.accessDenied` when the bookmark no longer leads anywhere: the folder
    /// has to be chosen again.
    public func url() throws -> URL {
        try lock.withLock {
            if let held { return held.url }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                throw SMBError.accessDenied
            }
            held = (url, url.startAccessingSecurityScopedResource())
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { refreshed(fresh) }
            return url
        }
    }

    /// Gives the permission back; the folder is found afresh the next time it is asked for.
    public func letGo() {
        lock.withLock {
            if let held, held.scoped { held.url.stopAccessingSecurityScopedResource() }
            held = nil
        }
    }

    deinit { if let held, held.scoped { held.url.stopAccessingSecurityScopedResource() } }
}
#endif
