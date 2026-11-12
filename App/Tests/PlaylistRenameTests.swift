// Vespertine: tests that a playlist can't be renamed to nothing.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Renaming a playlist") @MainActor
struct PlaylistRenameTests {
    @Test("An empty name, or one of only spaces, is ignored; a real name is taken as typed")
    func emptyNamesAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-playlist-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("database"))
        let playlist = try #require(library.createPlaylist(name: "Road Trip"))
        func name() throws -> String? { try library.database.playlists().first { $0.id == playlist.id }?.name }

        library.renamePlaylist(playlist, to: "")
        #expect(try name() == "Road Trip")
        library.renamePlaylist(playlist, to: "   ")
        #expect(try name() == "Road Trip")
        library.renamePlaylist(playlist, to: " \n\t")
        #expect(try name() == "Road Trip")

        library.renamePlaylist(playlist, to: "Night Drive")
        #expect(try name() == "Night Drive")
    }
}
