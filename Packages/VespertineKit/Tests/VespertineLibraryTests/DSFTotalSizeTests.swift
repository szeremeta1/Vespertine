//
// Vespertine — a DSF whose header total-size field is larger than the file still joins the library.
// Retagging tools can rewrite the ID3 tag without fixing that field; the tag reader (TagLib) then calls the
// file "not a valid DSD Stream file" and the scanner skips it, although the audio and the tag are fine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("DSF with a wrong header total size")
struct DSFTotalSizeTests {
    private func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(v >> (8 * UInt64($0)) & 0xFF) } }

    private func frame(_ id: String, _ text: String) -> [UInt8] {
        let body = [UInt8(3)] + Array(text.utf8)
        let n = body.count
        return Array(id.utf8) + [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F), 0, 0] + body
    }

    /// A 5-channel DSD64 file (DSD, fmt and data chunks, ID3v2.4 tag at the end) whose header claims
    /// `totalSizeError` more bytes than the file has.
    private func makeDSF(totalSizeError: UInt64) throws -> URL {
        let channels: UInt64 = 5, block = 4096
        let audio = [UInt8](repeating: 0x69, count: block * Int(channels))     // one block per channel
        let frames = frame("TIT2", "Symphony no. 5") + frame("TPE1", "Ludwig van Beethoven") + frame("TALB", "Symphonies nos. 5 & 7")
            + frame("TDRC", "2018")
        let n = frames.count
        let id3 = Array("ID3".utf8) + [4, 0, 0, UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + frames
        let metadata = UInt64(28 + 52 + 12 + audio.count)
        let total = metadata + UInt64(id3.count)
        let fmt = Array("fmt ".utf8) + le(52, 8) + le(1, 4) + le(0, 4) + le(6, 4) + le(channels, 4) + le(2_822_400, 4)
            + le(1, 4) + le(UInt64(block * 8), 8) + le(UInt64(block), 4) + le(0, 4)
        let data = Array("data".utf8) + le(UInt64(12 + audio.count), 8)
        let file = Array("DSD ".utf8) + le(28, 8) + le(total + totalSizeError, 8) + le(metadata, 8) + fmt + data + audio + id3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("total-\(UUID().uuidString).dsf")
        try Data(file).write(to: url)
        return url
    }

    @Test("A well-formed DSF is read (the fixture is a real DSF)")
    func wellFormed() throws {
        let url = try makeDSF(totalSizeError: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try MetadataReader.read(url: url, artwork: nil)
        #expect(track.title == "Symphony no. 5" && track.artist == "Ludwig van Beethoven" && track.album == "Symphonies nos. 5 & 7")
        #expect(track.isDSD && track.channels == 5 && track.sampleRate == 2_822_400)
    }

    @Test("A header total-size field larger than the file is tolerated, and the file is left as it was")
    func totalSizeTooLarge() throws {
        let url = try makeDSF(totalSizeError: 7_736)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        let track = try MetadataReader.read(url: url, artwork: nil)
        #expect(track.title == "Symphony no. 5" && track.artist == "Ludwig van Beethoven" && track.album == "Symphonies nos. 5 & 7")
        #expect(track.releaseDate == "2018")
        #expect(track.isDSD && track.channels == 5 && track.sampleRate == 2_822_400)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("A file that is not a DSF at all still fails")
    func garbageStillFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).dsf")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try MetadataReader.read(url: url, artwork: nil) }
    }
}
