//
// Vespertine: formats nothing here decodes are named, not failed on: AC-4 and MPEG-H say so when played; MQA and
// Auro-3D play as the PCM they hold, and the signal path says that.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Formats Vespertine can't decode")
struct UndecodedFormatTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("undecoded-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(body.count + 8)
        return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + Array(type.utf8) + body
    }

    /// A minimal MP4: a sound track whose sample description holds one entry of `entry`, the movie box before or after the media data.
    func mp4(entry: String, handler: String = "soun", movieLast: Bool = false) -> Data {
        let sampleEntry = box(entry, [UInt8](repeating: 0, count: 28))
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + sampleEntry)
        let hdlr = box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
        let trak = box("trak", box("mdia", hdlr + box("minf", box("stbl", stsd))))
        let moov = box("moov", trak), mdat = box("mdat", [UInt8](repeating: 0xAB, count: 64))
        let ftyp = box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0] + Array("M4A mp42".utf8))
        return Data(ftyp + (movieLast ? mdat + moov : moov + mdat))
    }

    static let entries: [(entry: String, expected: UndecodedFormat, movieLast: Bool)] =
        [("ac-4", UndecodedFormat.ac4), ("mha1", UndecodedFormat.mpegH), ("mhm1", UndecodedFormat.mpegH),
         ("mha2", UndecodedFormat.mpegH), ("mhm2", UndecodedFormat.mpegH)].flatMap { (e: (String, UndecodedFormat)) in
            [false, true].map { (entry: e.0, expected: e.1, movieLast: $0) }
        }

    @Test("AC-4 and MPEG-H in an MP4, by the sample entry, wherever the movie box is", arguments: entries)
    func mp4Entries(c: (entry: String, expected: UndecodedFormat, movieLast: Bool)) throws {
        let (entry, expected, movieLast) = c
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.m4a")
        try mp4(entry: entry, movieLast: movieLast).write(to: url)
        #expect(UndecodedFormat.undecodable(at: url) == expected)
        #expect(throws: SourceOpenerError.self) { try SourceOpener.probe(url) }
        do { _ = try SourceOpener.probe(url) } catch SourceOpenerError.undecodable(let format, _) { #expect(format == expected) }
    }

    @Test("Ordinary MP4 audio, and a non-sound track, are not claimed")
    func mp4Ordinary() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (entry, handler) in [("mp4a", "soun"), ("alac", "soun"), ("ec-3", "soun"), ("ac-4", "vide")] {
            let url = dir.appendingPathComponent("\(entry)-\(handler).m4a")
            try mp4(entry: entry, handler: handler).write(to: url)
            #expect(UndecodedFormat.undecodable(at: url) == nil, "\(entry) \(handler)")
        }
        #expect(UndecodedFormat.undecodable(at: ContainerFormatTests.fixture("gapless.m4a")) == nil)
        #expect(UndecodedFormat.undecodable(at: ContainerFormatTests.fixture("xhe-stereo.m4a")) == nil)
    }

    @Test("A box whose 64-bit size runs past the largest offset ends the walk, not the app")
    func mp4HugeLargesize() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // size 1: the real size follows as 64 bits, here 0xFFFFFFFFFFFFFFF0 (a damaged or crafted file).
        let damaged: [UInt8] = [0, 0, 0, 1] + Array("free".utf8) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0]
        let url = dir.appendingPathComponent("damaged.m4a")
        try (mp4(entry: "ac-4") + Data(damaged)).write(to: url)
        #expect(UndecodedFormat.undecodable(at: url) == .ac4)
        let first = dir.appendingPathComponent("damaged-first.m4a")
        let plain = mp4(entry: "ac-4")
        try (plain.prefix(24) + Data(damaged) + plain.dropFirst(24)).write(to: first)     // right after ftyp
        #expect(UndecodedFormat.undecodable(at: first) == nil)
    }

    @Test("A raw AC-4 or MPEG-H stream is named, and played with a plain reason, not a vague failure")
    func rawStreams() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ac4 = dir.appendingPathComponent("x.ac4"), mhas = dir.appendingPathComponent("x.mhas"), junk = dir.appendingPathComponent("y.ac4")
        try Data([0xAC, 0x40, 0x00, 0x20, 1, 2, 3, 4]).write(to: ac4)
        try Data([0xC0, 0x01, 0xA5, 0x08, 1, 2, 3, 4]).write(to: mhas)
        try Data("not a stream at all".utf8).write(to: junk)
        #expect(SourceOpener.supportedExtensions.isSuperset(of: ["ac4", "mhas"]))
        #expect(SourceInspector.untaggedExtensions.isSuperset(of: ["ac4", "mhas"]))
        for (url, expected) in [(ac4, UndecodedFormat.ac4), (mhas, .mpegH)] {
            do { _ = try SourceOpener.probe(url); Issue.record("\(url.lastPathComponent) opened") }
            catch let error as SourceOpenerError {
                guard case .undecodable(let format, _) = error else { Issue.record("\(error)"); continue }
                #expect(format == expected)
                #expect(error.localizedDescription == expected.failure)
                #expect(error.localizedDescription.contains(expected.name) && error.localizedDescription.contains("can't be played"))
            }
        }
        #expect(UndecodedFormat.undecodable(at: junk) == nil)
    }

    @Test("MQA by its tags: plays as the FLAC it is, and the signal path says it wasn't unfolded")
    func mqaByTags() throws {
        let url = ContainerFormatTests.fixture("mqa-tagged.flac")
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.codec == "FLAC" && probed.format.encoding == .pcm && probed.format.bitDepth == 24)
        #expect(probed.decoderName.contains("MQA") && probed.decoderName.lowercased().contains("not unfolded"), "\(probed.decoderName)")
        // It still decodes as the FLAC it contains.
        let reference = try ContainerFormatTests.decode("stereo24.flac").audio
        #expect(try ContainerFormatTests.decode("mqa-tagged.flac").audio == reference)
    }

    @Test("MQA by the synchronisation word in the audio of an untagged file")
    func mqaBySync() throws {
        let probed = try SourceOpener.probe(ContainerFormatTests.fixture("mqa-sync.flac"))
        #expect(probed.decoderName.contains("MQA"), "\(probed.decoderName)")
        let audio = try ContainerFormatTests.decode("mqa-sync.flac").audio
        #expect(audio[0].count == 12_288)
    }

    @Test("An ordinary 24-bit FLAC is not taken for MQA, nor a plain FLAC for anything")
    func notMQA() throws {
        for name in ["stereo24.flac", "surround16.flac", "flac-stereo.mka"] {
            let probed = try SourceOpener.probe(ContainerFormatTests.fixture(name))
            #expect(!probed.decoderName.contains("MQA") && !probed.decoderName.contains("Auro"), "\(name): \(probed.decoderName)")
        }
        let zeros = [Int32](repeating: 0, count: 5_000)
        #expect(!UndecodedFormat.hasMQASync(left: zeros, right: zeros))
        // The word, once, in bit 16 of left XOR right.
        var right = zeros
        for (i, bit) in String(0xBE0498C88, radix: 2).paddedTo36().enumerated() where bit == "1" { right[1_000 + i] = 1 << 16 }
        #expect(UndecodedFormat.hasMQASync(left: zeros, right: right))
        // One bit wrong, or the same bits in bit 15, is not it.
        var wrong = right; wrong[1_000] = 0
        #expect(!UndecodedFormat.hasMQASync(left: zeros, right: wrong))
        #expect(!UndecodedFormat.hasMQASync(left: zeros, right: right.map { $0 >> 1 }))
    }

    @Test("Auro-3D by the release's name, on surround files only")
    func auroByName() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Concerto (Auro-3D 9.1)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let surround = folder.appendingPathComponent("01 Allegro.flac"), stereo = folder.appendingPathComponent("02 Stereo.flac")
        try FileManager.default.copyItem(at: ContainerFormatTests.fixture("surround16.flac"), to: surround)
        try FileManager.default.copyItem(at: ContainerFormatTests.fixture("stereo24.flac"), to: stereo)
        let named = try SourceOpener.probe(surround)
        #expect(named.format.codec == "FLAC" && named.format.channels == 6)
        #expect(named.decoderName.contains("Auro-3D"), "\(named.decoderName)")
        #expect(!(try SourceOpener.probe(stereo)).decoderName.contains("Auro"))
        #expect(UndecodedFormat.isAuro3DByName(["Auro3D"], channels: 8) && UndecodedFormat.isAuro3DByName(["AURO 3D"], channels: 6))
        #expect(!UndecodedFormat.isAuro3DByName(["Aurora"], channels: 6) && !UndecodedFormat.isAuro3DByName(["Auro-3D"], channels: 2))
    }
}

private extension String {
    func paddedTo36() -> String { String(repeating: "0", count: max(0, 36 - count)) + self }
}
