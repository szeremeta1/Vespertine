//
// Nocturne — original release date and label read from MP3s' ID3 frames.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import NocturneLibrary

@Suite("ID3 extras")
struct ID3ExtrasTests {
    private func synchsafe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] }
    private func be(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }

    private func frame(_ id: String, _ body: [UInt8], v4: Bool) -> [UInt8] {
        Array(id.utf8) + (v4 ? synchsafe(body.count) : be(body.count)) + [0, 0] + body
    }

    private func write(_ frames: [UInt8], version: UInt8) throws -> URL {
        let tag = Array("ID3".utf8) + [version, 0, 0] + synchsafe(frames.count) + frames
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("id3-\(UUID()).mp3")
        try Data(tag + [0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0, count: 400)).write(to: url)
        return url
    }

    @Test("ID3v2.4 (UTF-8): TDOR, TPUB and TXXX")
    func v24() throws {
        let frames = frame("TDOR", [3] + Array("1977-10-28".utf8), v4: true)
            + frame("TPUB", [3] + Array("Warner Bros.".utf8), v4: true)
            + frame("TXXX", [3] + Array("originalyear".utf8) + [0] + Array("1977".utf8), v4: true)
            + frame("TIT2", [3] + Array("Title".utf8), v4: true)
        let url = try write(frames, version: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let extra = ID3Extras.read(url)
        #expect(extra["ORIGINALDATE"] == "1977-10-28")
        #expect(extra["LABEL"] == "Warner Bros.")
        #expect(extra["ORIGINALYEAR"] == "1977")
        #expect(MetadataReader.originalYear(extra, releaseYear: 2004) == 1977)
    }

    @Test("ID3v2.3 (UTF-16 with BOM): TORY and TPUB")
    func v23() throws {
        func utf16(_ s: String) -> [UInt8] { [1, 0xFF, 0xFE] + Array(s.data(using: .utf16LittleEndian)!) }
        let frames = frame("TORY", utf16("1969"), v4: false) + frame("TPUB", utf16("Apple Records"), v4: false)
        let url = try write(frames, version: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let extra = ID3Extras.read(url)
        #expect(extra["ORIGINALYEAR"] == "1969")
        #expect(extra["LABEL"] == "Apple Records")
    }
}
