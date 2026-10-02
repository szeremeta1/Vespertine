//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Share safety")
struct ShareSafetyTests {
    @Test("A share added read-only is never written, even when its mount allows writing")
    func readOnlyShareKeepsEditsInLibrary() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-readonly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        // The same writable folder three ways: a read-only share (e.g. Finder's read-write mount, reused),
        // a share added read-write, and a local folder (whose sources are never marked writable).
        let kinds: [(name: String, remote: String?, writable: Bool)] = [("readonly", "smb://nas/Music", false),
                                                                        ("writable", "smb://nas/Other", true),
                                                                        ("local", nil, false)]
        var files: [String: URL] = [:]
        for kind in kinds {
            let folder = dir.appendingPathComponent(kind.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("song.wav")
            try NetworkTests.writeAudio(url, seconds: 2)
            files[kind.name] = url
            try await scanner.scan(db.addSource(LibrarySource(path: folder.path, mode: .reference, remoteURL: kind.remote, isWritable: kind.writable)))
        }
        let readOnlyFile = try #require(files["readonly"])
        let original = try Data(contentsOf: readOnlyFile)
        let backups = dir.appendingPathComponent(".backups")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: backups)

        let result = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: db.allTracks())
        #expect(result.written == 2 && result.databaseOnly == 1 && result.failures.isEmpty)
        #expect(try Data(contentsOf: readOnlyFile) == original)
        #expect(try db.allTracks().allSatisfy { $0.title == "Edited" })
    }

    @Test("A corrupt MP4 atom size ends the fast tag read instead of crashing")
    func corruptAtomSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-atoms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } }
        func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64($0))) } }
        // ftyp, then an atom whose 64-bit size runs the offset past Int64.max (or is negative).
        for largeSize: UInt64 in [0x7FFF_FFFF_FFFF_FFF0, 0xFFFF_FFFF_FFFF_FFF0] {
            let bytes = be32(32) + Array("ftypM4A ".utf8) + [UInt8](repeating: 0, count: 20)
                + be32(1) + Array("moov".utf8) + be64(largeSize) + [UInt8](repeating: 0, count: 4096)
            let url = dir.appendingPathComponent("bad.m4a")
            try Data(bytes).write(to: url)
            let reads = try RemoteMetadata.makeShadow(of: url, size: Int64(bytes.count), at: dir.appendingPathComponent("shadow.m4a"))
            #expect(reads >= 1)
        }
    }
}
