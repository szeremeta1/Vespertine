//
// Vespertine: formats Vespertine can't decode are listed under their name, with a badge that says so.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineLibrary

@Suite("Formats Vespertine can't decode, in the library")
struct UndecodedFormatLibraryTests {
    private func track(_ path: String, codec: String = "FLAC", channels: Int = 2, lossless: Bool = true, tags: [String: String] = [:]) -> Track {
        var t = Track.stub(path: path)
        t.codec = codec; t.channels = channels; t.isLossless = lossless; t.extraTags = tags; t.sampleRate = 96_000; t.bitDepth = 24
        return t
    }

    @Test("AC-4 and MPEG-H streams are read as tracks of their own name, lossy, with a badge that says they can't play")
    func rawStreams() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("undecoded-lib-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ac4 = dir.appendingPathComponent("Concert - 01 Opening.ac4"), mhas = dir.appendingPathComponent("Concert - 02 Reprise.mhas")
        try Data([0xAC, 0x41, 0, 0x10, 9, 9, 9, 9]).write(to: ac4)
        try Data([0xC0, 0x01, 0xA5, 0x08, 9, 9, 9, 9]).write(to: mhas)
        for (url, format) in [(ac4, UndecodedFormat.ac4), (mhas, .mpegH)] {
            let read = try MetadataReader.read(url: url, artwork: nil)
            #expect(read.codec == format.name && !read.isLossless && !read.isDSD)
            #expect(read.undecodedFormat == format)
            let mark = try #require(read.formatMark)
            #expect(mark.family == .notDecoded && mark.text == format.name.uppercased() && mark.carrier == format.note)
        }
        #expect(SourceInspector.supportedExtensions.isSuperset(of: ["ac4", "mhas"]))
    }

    @Test("MQA is told by the file's own tags, and the badge replaces Hi-Res Lossless with what Vespertine does with it")
    func mqa() {
        let mqa = track("/m/Album/01.flac", tags: ["MQAENCODER": "MQAEncode v1.1, 2.4.2+uuid", "ORIGINALSAMPLERATE": "96000"])
        #expect(mqa.undecodedFormat == .mqa)
        let mark = mqa.formatMark
        #expect(mark?.text == "MQA" && mark?.family == .notDecoded)
        #expect(mark?.carrier?.lowercased().contains("flac") == true && mark?.carrier?.lowercased().contains("not unfolded") == true)
        // The tag spelled in lower case still counts; one tag of the pair alone does not, nor does another codec.
        #expect(track("/m/a.flac", tags: ["mqaencoder": "x"]).undecodedFormat == .mqa)
        #expect(track("/m/a.flac", tags: ["ORIGINALSAMPLERATE": "96000"]).undecodedFormat == nil)
        #expect(track("/m/a.flac", codec: "ALAC", tags: ["MQAENCODER": "x"]).undecodedFormat == nil)
        #expect(track("/m/a.flac").formatMark?.text == "HI-RES LOSSLESS")
    }

    @Test("Auro-3D is told by the release's name, on surround files only")
    func auro() {
        #expect(track("/m/Concerto (Auro-3D)/01.flac", channels: 6).undecodedFormat == .auro3D)
        #expect(track("/m/Concerto/01 Auro3D mix.flac", channels: 8).formatMark?.text == "AURO-3D")
        #expect(track("/m/Concerto (Auro-3D)/01.flac", channels: 2).undecodedFormat == nil)
        #expect(track("/m/Concerto/01.flac", channels: 6).undecodedFormat == nil)
        #expect(track("/m/Concerto/01.dsf", codec: "DSF", channels: 6).formatMark?.family != .notDecoded)
    }
}
