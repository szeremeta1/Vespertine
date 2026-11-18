//
// Vespertine: closing a library opened from a file, so the folder it is in can be deleted without SQLite finding its
// files gone while they are open ("vnode unlinked while in use").
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Closing a library")
struct ClosingTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-closing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func remove(_ folder: URL) {
        LibraryDatabase.closeAll(under: folder)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("A closed library can't be read: its connections are gone")
    func closeEndsTheConnections() throws {
        let root = try scratch(); defer { remove(root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
        db.close()
        #expect(throws: (any Error).self) { try db.writer.read { try Int.fetchOne($0, sql: "SELECT 1") } }
    }

    @Test("Every library in a folder is closed, at any depth, even when only its writer is still held")
    func closeAllUnderAFolder() throws {
        let root = try scratch(); defer { remove(root) }
        let elsewhere = try scratch(); defer { remove(elsewhere) }
        let top = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        // As the app's observations hold it: the writer outlives the LibraryDatabase that opened it.
        let deepWriter = try LibraryDatabase(url: root.appendingPathComponent("library/deeper/Library.sqlite")).writer
        let outside = try LibraryDatabase(url: elsewhere.appendingPathComponent("Library.sqlite"))

        // The temporary folder's path goes through a symbolic link (/var is /private/var): the folder is found either way.
        LibraryDatabase.closeAll(under: root)

        #expect(throws: (any Error).self) { try top.writer.read { try Int.fetchOne($0, sql: "SELECT 1") } }
        #expect(throws: (any Error).self) { try deepWriter.read { try Int.fetchOne($0, sql: "SELECT 1") } }
        #expect(try outside.writer.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
    }

    @Test("A folder whose name starts like another's leaves the other's libraries open")
    func aSiblingFolderIsNotInside() throws {
        let parent = try scratch(); defer { remove(parent) }
        let db = try LibraryDatabase(url: parent.appendingPathComponent("library-2/Library.sqlite"))
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("library"), withIntermediateDirectories: true)
        LibraryDatabase.closeAll(under: parent.appendingPathComponent("library"))
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
    }
}
