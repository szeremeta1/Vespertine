//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Import space")
struct ImportSpaceTests {
    @Test("Files on the destination's own volume are cloned, so they cost nothing")
    func sameVolumeIsFree() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("a.flac")
        try Data(count: 10).write(to: file)
        let space = ImportSpace.measure(files: [(file, 5_000_000_000)], destination: dir.appendingPathComponent("Vespertine"))
        #expect(space.bytesToCopy == 0)
        #expect(space.fits)
    }

    @Test("A destination that doesn't exist yet is measured from its nearest existing folder")
    func missingDestination() throws {
        let dir = try tempDir()
        let space = ImportSpace.measure(files: [], destination: dir.appendingPathComponent("a/b/c/Vespertine"))
        #expect(space.freeBytes != nil)
    }

    @Test("A copy must fit with the reserve to spare; unknown free space is not a reason to refuse")
    func fitsKeepsAReserve() {
        let gib: Int64 = 1 << 30
        #expect(ImportSpace(bytesToCopy: 10 * gib, freeBytes: 100 * gib).fits)
        #expect(ImportSpace(bytesToCopy: 98 * gib, freeBytes: 100 * gib).fits)
        #expect(!ImportSpace(bytesToCopy: 99 * gib, freeBytes: 100 * gib).fits)
        #expect(!ImportSpace(bytesToCopy: 100 * gib, freeBytes: 100 * gib).fits)
        #expect(ImportSpace(bytesToCopy: 500 * gib, freeBytes: nil).fits)
        #expect(ImportSpace(bytesToCopy: 0, freeBytes: gib).fits, "nothing to copy always fits")
    }

    @Test("An import copy lands whole or not at all, and never over a file that's there")
    func copiesLandWholeOrNotAtAll() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.flac"), dest = dir.appendingPathComponent("Imported/a.flac")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: source)
        try Importer.cloneOrCopy(source, to: dest)
        #expect(try Data(contentsOf: dest) == Data(repeating: 7, count: 4096))

        // Already there: refused, the file left as it was.
        try Data([1]).write(to: dest)
        #expect(throws: (any Error).self) { try Importer.cloneOrCopy(source, to: dest) }
        #expect(try Data(contentsOf: dest) == Data([1]))

        // A copy that fails leaves nothing behind, under its name or a temporary one.
        let failed = dir.appendingPathComponent("Imported/b.flac")
        #expect(throws: (any Error).self) { try Importer.cloneOrCopy(dir.appendingPathComponent("gone.flac"), to: failed) }
        #expect(!FileManager.default.fileExists(atPath: failed.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path) == ["a.flac"])
    }
}
