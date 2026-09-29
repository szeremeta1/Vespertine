//
// Vespertine — original release date and label read from MP3s' ID3 frames.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

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

@Suite struct DSFDateTests {
    @Test("A DSF's release and original dates are read from the ID3 tag its header points to")
    func dsfDates() throws {
        func frame(_ id: String, _ text: String) -> [UInt8] {
            let body = [UInt8(3)] + Array(text.utf8)
            let n = body.count
            return Array(id.utf8) + [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F), 0, 0] + body
        }
        let frames = frame("TDRC", "2003-05-03") + frame("TDOR", "1973")
        let n = frames.count
        let id3 = Array("ID3".utf8) + [4, 0, 0, UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + frames
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (8 * UInt64($0)) & 0xFF) } }
        let audio = [UInt8](repeating: 0x69, count: 64)
        let pointer = UInt64(28 + audio.count)
        let file = Array("DSD ".utf8) + le64(28) + le64(pointer + UInt64(id3.count)) + le64(pointer) + audio + id3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dates-\(UUID().uuidString).dsf")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tags = ID3Extras.readDSF(url)
        #expect(tags["DATE"] == "2003-05-03")
        #expect(tags["ORIGINALDATE"] == "1973")
        #expect(MetadataReader.originalYear(tags, releaseYear: 2003) == 1973)
    }
}
