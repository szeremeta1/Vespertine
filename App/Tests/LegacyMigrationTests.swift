import Foundation
import Testing
@testable import Vespertine

@Suite("Migration from Nocturne") @MainActor
struct LegacyMigrationTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("The library folder is copied without its share mount points, and the old folder is untouched")
    func copiesLibrary() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("Nocturne"), new = dir.appendingPathComponent("Vespertine")
        let fm = FileManager.default
        for sub in ["Artwork", "Shares/music", "Tag Backups"] {
            try fm.createDirectory(at: legacy.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("db".utf8).write(to: legacy.appendingPathComponent("Library.sqlite"))
        try Data("wal".utf8).write(to: legacy.appendingPathComponent("Library.sqlite-wal"))
        try Data("art".utf8).write(to: legacy.appendingPathComponent("Artwork/a.jpg"))

        try LegacyMigration.copyLibrary(from: legacy, to: new)

        #expect(try Data(contentsOf: new.appendingPathComponent("Library.sqlite")) == Data("db".utf8))
        #expect(try Data(contentsOf: new.appendingPathComponent("Library.sqlite-wal")) == Data("wal".utf8))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("Artwork/a.jpg").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("Shares").path))
        #expect(fm.fileExists(atPath: legacy.appendingPathComponent("Library.sqlite").path))
        #expect(fm.fileExists(atPath: legacy.appendingPathComponent("Shares/music").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("Vespertine.migrating").path))
    }

    @Test("Files already in a library-less Vespertine folder are kept")
    func keepsExistingFiles() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("Nocturne"), new = dir.appendingPathComponent("Vespertine")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appendingPathComponent("Library.sqlite"))
        try Data("x".utf8).write(to: new.appendingPathComponent("note.txt"))

        try LegacyMigration.copyLibrary(from: legacy, to: new)

        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("Library.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("note.txt").path))
    }

    @Test("Test runs and new users are left alone")
    func skipsWithoutLegacyData() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try #require(UserDefaults(suiteName: dir.appendingPathComponent("d.plist").path))
        defaults.set(dir.path, forKey: "VespertineDataDirectory")
        LegacyMigration.runIfNeeded(defaults: defaults, bundleID: "org.szeremeta.Vespertine")
        #expect(defaults.object(forKey: LegacyMigration.doneKey) == nil)
        LegacyMigration.runIfNeeded(defaults: defaults, bundleID: "com.example.other")
        #expect(defaults.object(forKey: LegacyMigration.doneKey) == nil)
    }
}
