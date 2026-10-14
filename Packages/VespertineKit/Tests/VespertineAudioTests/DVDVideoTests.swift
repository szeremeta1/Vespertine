//
// Vespertine — DVD-Video LPCM: de-interleaving at every width, rate and channel count DVD-Video allows; navigation
// (titles, programs, cells) and its NAV-pack fallback; presentation-time track boundaries; menus and previews left
// out; damaged input failing clearly; VIDEO_TS lookup inside ISO 9660 and UDF images. All synthetic.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
import VespertineTestSupport
@testable import VespertineAudio

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dvd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Every combination DVD-Video allows (≤ 6.144 Mbit/s).
private let allowedFormats: [DVDFixture.Format] = [16, 20, 24].flatMap { bits in
    [48_000, 96_000].flatMap { rate in
        (1...8).compactMap { ch in bits * rate * ch <= 6_144_000 ? DVDFixture.Format(bits: bits, rate: rate, channels: ch) : nil }
    }
}

/// Decodes a whole track (or run) through the source opener as playback does, as left-justified integers.
private func decodeAll(_ url: URL, ref: DVDStreamRef, start: Int64? = nil, length: Int64? = nil) throws -> [Int32] {
    let probed = try SourceOpener.probe(url, dvd: ref)
    let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                          physicalBitDepth: 32, channels: probed.format.channels, dsdConvertedToPCM: false, reason: "")
    let decoder = try SourceOpener.decoder(for: probed, plan: plan,
                                           item: PlayableItem(url: url, regionStartFrame: start, regionFrameLength: length, dvd: ref))
    return try drain(decoder, channels: probed.format.channels)
}

private func drain(_ decoder: PCMDecoding, channels: Int, limit: Int = .max) throws -> [Int32] {
    let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 1000)!
    var out: [Int32] = []
    while out.count / channels < limit {
        try decoder.decode(into: buffer, length: AVAudioFrameCount(min(1000, limit - out.count / channels)))
        let n = Int(buffer.frameLength)
        if n == 0 { break }
        for i in 0..<n { for c in 0..<channels { out.append(Int32(Double(buffer.floatChannelData![c][i]) * 2_147_483_648)) } }
    }
    return out
}

@Suite("DVD-Video LPCM")
struct DVDVideoTests {
    // MARK: De-interleaving

    @Test("Every allowed width, rate and channel count de-interleaves exactly; formats beyond DVD-Video are refused")
    func deinterleaveMatrix() throws {
        #expect(allowedFormats.count == 2 * 8 / 1 / 2 + 6 + 3 + 5 + 2 + 4)    // 16-bit 8+4, 20-bit 6+3, 24-bit 5+2
        for f in allowedFormats {
            let frames = 322
            let samples = DVDFixture.samples(frames: frames, format: f, seed: f.channels * 7 + f.bits)
            let bytes = DVDFixture.encode(samples, format: f)
            let format = try DVDLPCMFormat(header: f.headerByte)
            #expect(format.bits == f.bits && format.sampleRate == f.rate && format.channels == f.channels)
            #expect(bytes.count == frames / format.unitFrames * format.unitBytes)
            var out = [Int32](repeating: 0, count: samples.count)
            bytes.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { format.deinterleave(src.baseAddress!, units: frames / format.unitFrames, into: $0.baseAddress!) }
            }
            #expect(out == samples, "\(format)")
        }
        for (bits, rate, ch) in [(24, 96_000, 3), (20, 96_000, 4), (16, 96_000, 5), (24, 48_000, 6), (20, 48_000, 7)] {
            #expect(throws: DVDVideoError.self) { try DVDLPCMFormat(bits: bits, sampleRate: rate, channels: ch) }
        }
        // Quantization code 3, and the 44.1 / 32 kHz codes DVD-Video doesn't allow.
        for byte: UInt8 in [0xC1, 0x21, 0x31] { #expect(throws: DVDVideoError.self) { try DVDLPCMFormat(header: byte) } }
    }

    @Test("The 20/24-bit byte layout, pinned by hand: sample pairs, high words first, then low bytes or nibbles")
    func groupedLayout() throws {
        // 24-bit stereo: L0 R0 L1 R1 high words, then their low bytes.
        let stereo = try DVDLPCMFormat(bits: 24, sampleRate: 96_000, channels: 2)
        let s24: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x01, 0x02, 0x03, 0x04]
        var out = [Int32](repeating: 0, count: 4)
        s24.withUnsafeBufferPointer { b in out.withUnsafeMutableBufferPointer { stereo.deinterleave(b.baseAddress!, units: 1, into: $0.baseAddress!) } }
        #expect(out.map { UInt32(bitPattern: $0) } == [0x1234_0100, 0x5678_0200, 0x9ABC_0300, 0xDEF0_0400])
        // 20-bit mono: two samples' high words, then one byte of two nibbles (earlier sample high).
        let mono = try DVDLPCMFormat(bits: 20, sampleRate: 48_000, channels: 1)
        let s20: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0xAB]
        var two = [Int32](repeating: 0, count: 2)
        s20.withUnsafeBufferPointer { b in two.withUnsafeMutableBufferPointer { mono.deinterleave(b.baseAddress!, units: 1, into: $0.baseAddress!) } }
        #expect(two.map { UInt32(bitPattern: $0) } == [0x1234_A000, 0x5678_B000])
        // 24-bit, 5 channels: a unit is two frames of five (ten high words, ten low bytes).
        let five = try DVDLPCMFormat(bits: 24, sampleRate: 48_000, channels: 5)
        #expect(five.unitBytes == 30 && five.unitFrames == 2)
        // 16-bit is plain big-endian, frame by frame.
        let s16 = try DVDLPCMFormat(bits: 16, sampleRate: 48_000, channels: 2)
        #expect(s16.unitBytes == 4 && s16.unitFrames == 1)
    }

    // MARK: Discs

    /// Two VOBs: VOB 1 with three cells whose boundaries fall between samples (audio muxed 0.3 s ahead), VOB 2 with
    /// one cell, and VOB 3: a 2-second preview at the end of the last program.
    static func sampleDisc(format: DVDFixture.Format = .init(bits: 24, rate: 96_000, channels: 2), split: Int = 0)
        -> (files: [String: [UInt8]], vob1: DVDFixture.VOB, vob2: DVDFixture.VOB, preview: DVDFixture.VOB, cells: [DVDFixture.CellLayout]) {
        let rate = Int64(format.rate)
        let vob1 = DVDFixture.VOB(vobID: 1, format: format, firstPTS: 30_000,
                                  samples: DVDFixture.samples(frames: Int(rate) * 3, format: format, seed: 1),
                                  cells: [(1, 30_000), (2, 30_000 + 90_000 + 1001), (3, 30_000 + 180_000 + 2002)], lead: 27_000)
        let vob2 = DVDFixture.VOB(vobID: 2, format: format, firstPTS: 25_000,
                                  samples: DVDFixture.samples(frames: Int(rate) + 1234 / format.channels * 2, format: format, seed: 2))
        let preview = DVDFixture.VOB(vobID: 3, format: format, firstPTS: 25_000,
                                     samples: DVDFixture.samples(frames: Int(rate) * 2, format: format, seed: 3))
        let disc = DVDFixture.disc(vobs: [vob1, vob2, preview], titles: [[[0], [1], [2], [3, 4]]], splitSectors: split)
        return (disc.files, vob1, vob2, preview, disc.cells)
    }

    @Test("A VIDEO_TS folder: chapters become tracks cut at the 90 kHz cell times, previews and menus left out, every sample exact")
    func folderDisc() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.sampleDisc(split: 300)                      // VOBs split across VTS_01_1.VOB … _7 mid-stream
        #expect(d.files.keys.filter { $0.hasPrefix("VTS_01_") && $0.hasSuffix(".VOB") }.count > 3)
        let folder = dir.appendingPathComponent("Disc/VIDEO_TS")
        try DVDFixture.writeFolder(d.files, at: folder)
        let entry = folder.appendingPathComponent("VIDEO_TS.IFO")
        let disc = try DVDVideoDisc.read(entry)
        #expect(disc.albums.count == 1 && !disc.usedNAVCells && !disc.defectiveChapters)
        let tracks = disc.tracks
        #expect(tracks.count == 4)
        // Track 2 starts at the sample nearest cell 2's start (90 000 + 1001 ticks in: 96 000 + 1067.7 → 97 068).
        #expect(tracks.map(\.startFrame) == [0, 97_068, 194_135, 0])
        #expect(tracks[0].frameCount + tracks[1].frameCount + tracks[2].frameCount == Int64(d.vob1.frames))
        #expect(tracks[3].frameCount == Int64(d.vob2.frames))
        #expect(disc.excluded.count == 1 && disc.excluded[0].cell.vobID == 3 && abs(disc.excluded[0].seconds - 2) < 1e-9)
        #expect(tracks.allSatisfy { $0.run.format.bits == 24 && $0.run.format.sampleRate == 96_000 })

        let ch = 2
        for t in tracks {
            let source = t.cells[0].vobID == 1 ? d.vob1.samples : d.vob2.samples
            let expected = Array(source[Int(t.startFrame) * ch..<Int(t.startFrame + t.frameCount) * ch])
            #expect(try decodeAll(entry, ref: t.ref, start: t.startFrame, length: t.frameCount) == expected, "track \(t.number)")
        }
        // The probe without a track opens the first track's run, as a 24/96 LPCM source.
        let inspected = try SourceInspector.inspectWithDuration(entry)
        #expect(inspected.format.codec == "LPCM" && inspected.format.bitDepth == 24 && inspected.format.encoding == .pcm)
        #expect(abs(inspected.duration - 3) < 1e-9)
    }

    @Test("Seeks land on the exact sample at the beginning, middle and end, and the tail is complete")
    func seeking() throws {
        for format in [DVDFixture.Format(bits: 24, rate: 96_000, channels: 2), .init(bits: 20, rate: 48_000, channels: 3),
                       .init(bits: 16, rate: 48_000, channels: 8)] {
            let dir = try tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let d = Self.sampleDisc(format: format)
            let folder = dir.appendingPathComponent("VIDEO_TS")
            try DVDFixture.writeFolder(d.files, at: folder)
            let entry = folder.appendingPathComponent("VIDEO_TS.IFO")
            let disc = try DVDVideoDisc.read(entry)
            let ch = format.channels
            for t in disc.tracks {
                let source = t.cells[0].vobID == 1 ? d.vob1.samples : d.vob2.samples
                let probed = try SourceOpener.probe(entry, dvd: t.ref)
                let plan = OutputPlan(mode: .pcm, deviceSampleRate: Double(format.rate), decodedSampleRate: Double(format.rate),
                                      physicalBitDepth: 32, channels: ch, dsdConvertedToPCM: false, reason: "")
                let decoder = try SourceOpener.decoder(for: probed, plan: plan,
                                                       item: PlayableItem(url: entry, regionStartFrame: t.startFrame, regionFrameLength: t.frameCount, dvd: t.ref))
                #expect(decoder.length == t.frameCount)
                for position in [Int64(0), 1, t.frameCount / 2 + 1, t.frameCount - 333, t.frameCount - 1] {
                    try decoder.seek(to: position)
                    let got = try drain(decoder, channels: ch, limit: 500)
                    let from = Int(t.startFrame + position) * ch
                    let to = Int(t.startFrame + min(t.frameCount, position + 500)) * ch
                    #expect(got == Array(source[from..<to]), "\(format) track \(t.number) at \(position)")
                }
            }
        }
    }

    @Test("Every allowed format plays through a disc, packets splitting frames and access units")
    func formatsThroughDiscs() throws {
        for f in allowedFormats {
            let dir = try tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let frames = f.rate / 10 + 2
            let vob = DVDFixture.VOB(vobID: 1, format: f, samples: DVDFixture.samples(frames: frames, format: f, seed: f.bits + f.channels),
                                     payloadBytes: 2004 - (f.channels * 3) % 7, extraAC3: true)
            let disc = DVDFixture.disc(vobs: [vob], titles: [[[0]]],
                                       audio: [(0, 0, 0, 6), (4, [16: 0, 20: 1, 24: 2][f.bits]!, f.rate == 96_000 ? 1 : 0, f.channels)])
            // Stream 1 is the LPCM one (stream 0 is AC-3): its substream is 0xA1.
            var vob1 = vob; vob1.substream = 0xA1
            var files = DVDFixture.disc(vobs: [vob1], titles: [[[0]]],
                                        audio: [(0, 0, 0, 6), (4, [16: 0, 20: 1, 24: 2][f.bits]!, f.rate == 96_000 ? 1 : 0, f.channels)]).files
            files["VTS_01_0.IFO"] = disc.files["VTS_01_0.IFO"]
            let folder = dir.appendingPathComponent("VIDEO_TS")
            try DVDFixture.writeFolder(files, at: folder)
            let entry = folder.appendingPathComponent("VIDEO_TS.IFO")
            let read = try DVDVideoDisc.read(entry)
            let t = try #require(read.tracks.first)
            #expect(t.run.stream == 1 && t.frameCount == Int64(frames), "\(f)")
            #expect(try decodeAll(entry, ref: t.ref) == vob.samples, "\(f)")
        }
    }

    @Test("A cell table that disagrees with the NAV packs is replaced by the NAV packs' cells")
    func navFallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = Self.sampleDisc()
        // The same disc, its cell table shifted by a sector (as on a re-authored copy).
        let broken = DVDFixture.disc(vobs: [base.vob1, base.vob2, base.preview], titles: [[[0], [1], [2], [3, 4]]],
                                     cellTable: { cells in cells.map { var c = $0; c.firstSector += 1; return c } })
        let folder = dir.appendingPathComponent("VIDEO_TS")
        try DVDFixture.writeFolder(broken.files, at: folder)
        let disc = try DVDVideoDisc.read(folder.appendingPathComponent("VIDEO_TS.IFO"))
        #expect(disc.usedNAVCells)
        #expect(disc.tracks.map(\.startFrame) == [0, 97_068, 194_135, 0])
        #expect(disc.tracks.map { $0.cells.map(\.firstSector) } == base.cells.prefix(4).map { [$0.firstSector] })
        #expect(disc.excluded.count == 1)
        // With no usable cell table at all the NAV packs alone give the same cells.
        let bare = DVDFixture.disc(vobs: [base.vob1, base.vob2, base.preview], titles: [[[0], [1], [2], [3, 4]]], cellTable: { _ in [] })
        try DVDFixture.writeFolder(bare.files, at: folder)
        let again = try DVDVideoDisc.read(folder.appendingPathComponent("VIDEO_TS.IFO"))
        #expect(again.usedNAVCells && again.tracks.count == 4)
    }

    @Test("Chapters that point at programs that don't exist fall back to the title's own programs")
    func defectiveChapters() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = Self.sampleDisc()
        let broken = DVDFixture.disc(vobs: [base.vob1, base.vob2, base.preview], titles: [[[0], [1], [2], [3, 4]]],
                                     chapters: [[(1, 1), (1, 2), (1, 9), (4, 1)]])
        let folder = dir.appendingPathComponent("VIDEO_TS")
        try DVDFixture.writeFolder(broken.files, at: folder)
        let disc = try DVDVideoDisc.read(folder.appendingPathComponent("VIDEO_TS.IFO"))
        #expect(disc.defectiveChapters)
        #expect(disc.tracks.count == 4 && disc.tracks.map(\.startFrame) == [0, 97_068, 194_135, 0])
    }

    @Test("A play-all title over the same cells lists each song once; cells no title plays are kept unless short")
    func duplicatesAndOrphans() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = DVDFixture.Format(bits: 16, rate: 48_000, channels: 2)
        let a = DVDFixture.VOB(vobID: 1, format: f, samples: DVDFixture.samples(frames: 48_000 * 3, format: f, seed: 4))
        let b = DVDFixture.VOB(vobID: 2, format: f, samples: DVDFixture.samples(frames: 48_000 * 3, format: f, seed: 5))
        let orphan = DVDFixture.VOB(vobID: 3, format: f, samples: DVDFixture.samples(frames: 48_000 * 2, format: f, seed: 6))
        // Title 1 plays everything as one program; titles 2 and 3 each play one song. VOB 3 is in no title.
        let disc = DVDFixture.disc(vobs: [a, b, orphan], titles: [[[0, 1]], [[0]], [[1]]])
        let folder = dir.appendingPathComponent("VIDEO_TS")
        try DVDFixture.writeFolder(disc.files, at: folder)
        let read = try DVDVideoDisc.read(folder.appendingPathComponent("VIDEO_TS.IFO"))
        #expect(read.tracks.count == 2)
        #expect(read.albums.map(\.title) == [2, 3])
        #expect(read.excluded.map(\.cell.vobID) == [3])   // 2 s: under the preview limit
    }

    // MARK: Damage

    @Test("Truncated, malformed or inconsistent streams fail with an error, never silent garbage")
    func damage() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.sampleDisc()
        let folder = dir.appendingPathComponent("VIDEO_TS")
        try DVDFixture.writeFolder(d.files, at: folder)
        let entry = folder.appendingPathComponent("VIDEO_TS.IFO")
        let disc = try DVDVideoDisc.read(entry)
        let t = disc.tracks[0]
        let vobURL = folder.appendingPathComponent("VTS_01_1.VOB")
        let good = try Data(contentsOf: vobURL)

        // A time stamp out of step with the samples before it (a lost packet).
        var lost = [UInt8](good)
        let audioSector = (t.cells[0].firstSector + 5) * 2048
        let packet = Array(lost[audioSector..<audioSector + 2048])
        #expect(packet[14...17] == [0, 0, 1, 0xBD])
        lost.replaceSubrange(audioSector + 14 + 6 + 3 + 3..<audioSector + 14 + 6 + 3 + 5, with: [0x7F, 0xFF])   // PTS bits
        try Data(lost).write(to: vobURL)
        #expect(throws: DVDVideoError.self) { _ = try decodeAll(entry, ref: t.ref) }

        // A sector that isn't an MPEG-2 pack.
        var junk = [UInt8](good)
        junk.replaceSubrange(audioSector..<audioSector + 4, with: [0xDE, 0xAD, 0xBE, 0xEF])
        try Data(junk).write(to: vobURL)
        #expect(throws: DVDVideoError.self) { _ = try decodeAll(entry, ref: t.ref) }

        // A CSS-scrambled packet.
        var scrambled = [UInt8](good)
        scrambled[audioSector + 14 + 6] |= 0x10
        try Data(scrambled).write(to: vobURL)
        #expect(throws: DVDVideoError.unsupportedAudio("encrypted (CSS) sectors")) { _ = try decodeAll(entry, ref: t.ref) }

        // The format changing mid-run.
        var changed = [UInt8](good)
        let lpcmHeader = audioSector + 14 + 6 + 3 + 5
        #expect(changed[lpcmHeader] == 0xA0)
        changed[lpcmHeader + 5] = DVDFixture.Format(bits: 16, rate: 96_000, channels: 2).headerByte
        try Data(changed).write(to: vobURL)
        #expect(throws: DVDVideoError.self) { _ = try decodeAll(entry, ref: t.ref) }

        // A truncated VOB: the cells run past the end of the file.
        try Data(good.prefix(good.count / 2)).write(to: vobURL)
        #expect(throws: DVDVideoError.self) { _ = try DVDVideoDisc.read(entry) }
        #expect(throws: (any Error).self) { _ = try decodeAll(entry, ref: disc.tracks[3].ref) }
        try good.write(to: vobURL)

        // An LPCM header at a rate DVD-Video doesn't have.
        var rate = [UInt8](good)
        for s in stride(from: 0, to: rate.count, by: 2048) where rate[s + 14 + 3] == 0xBD {
            let h = s + 14 + 6 + 3 + Int(rate[s + 14 + 6 + 2])
            if rate[h] == 0xA0 { rate[h + 5] = 0x21 }                                   // 44.1 kHz
        }
        try Data(rate).write(to: vobURL)
        #expect(throws: DVDVideoError.self) { _ = try DVDVideoDisc.read(entry) }
        try good.write(to: vobURL)

        // A damaged VIDEO_TS.IFO, and a folder with no IFO at all.
        try Data(repeating: 0, count: 4096).write(to: entry)
        #expect(throws: DVDVideoError.self) { _ = try DVDVideoDisc.read(entry) }
        #expect(throws: DVDVideoError.notDVDVideo) { _ = try DVDVideoDisc.read(dir) }
    }

    @Test("A title set with only AC-3 audio, or a DVD-Audio disc, isn't played and says why")
    func notLPCM() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.sampleDisc()
        let ac3 = DVDFixture.disc(vobs: [d.vob1], titles: [[[0]]], audio: [(0, 0, 0, 6)])
        let folder = dir.appendingPathComponent("VIDEO_TS")
        try DVDFixture.writeFolder(ac3.files, at: folder)
        #expect(throws: DVDVideoError.unsupportedAudio("AC-3 audio")) { _ = try DVDVideoDisc.read(folder.appendingPathComponent("VIDEO_TS.IFO")) }

        let image = DVDFixture.image(ac3.files, audioTS: ["AUDIO_TS.IFO": [UInt8](repeating: 1, count: 2048), "ATS_01_1.AOB": [UInt8](repeating: 2, count: 4096)])
        let iso = dir.appendingPathComponent("dvda.iso")
        try Data(image).write(to: iso)
        #expect(throws: DVDVideoError.dvdAudioOnly) { _ = try DVDVideoDisc.read(iso) }
    }

    // MARK: Images

    @Test("VIDEO_TS is found inside ISO 9660, UDF and bridge images, read in place with the same tracks as the folder")
    func images() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.sampleDisc(split: 400)
        let folder = dir.appendingPathComponent("VIDEO_TS")
        try DVDFixture.writeFolder(d.files, at: folder)
        let fromFolder = try DVDVideoDisc.read(folder.appendingPathComponent("VIDEO_TS.IFO"))
        for (name, fs, extended) in [("iso9660.iso", DVDFixture.FileSystems.iso9660, false), ("udf.iso", .udf, false),
                                     ("udf-efe.iso", .udf, true), ("bridge.iso", .both, false)] {
            let url = dir.appendingPathComponent(name)
            try Data(DVDFixture.image(d.files, fileSystems: fs, udfExtendedEntries: extended)).write(to: url)
            let volume = try DVDVideoVolume.open(url)
            #expect(volume.isImage && Set(volume.files.keys) == Set(d.files.keys), "\(name)")
            for (file, bytes) in d.files where file.hasSuffix(".IFO") { #expect(try volume.contents(of: file) == bytes, "\(name) \(file)") }
            #expect(DVDVideoDisc.isDVDVideo(url) && !SACDImage.isSACD(url))
            let disc = try DVDVideoDisc.read(url)
            #expect(disc.tracks.map(\.startFrame) == fromFolder.tracks.map(\.startFrame), "\(name)")
            #expect(disc.tracks.map(\.frameCount) == fromFolder.tracks.map(\.frameCount), "\(name)")
            let t = disc.tracks[1]
            #expect(try decodeAll(url, ref: t.ref, start: t.startFrame, length: t.frameCount)
                    == Array(d.vob1.samples[Int(t.startFrame) * 2..<Int(t.startFrame + t.frameCount) * 2]), "\(name)")
        }
        // Not a DVD: zeros, or an image whose file system has no VIDEO_TS.
        let zeros = dir.appendingPathComponent("blank.iso")
        try Data(repeating: 0, count: 600 * 2048).write(to: zeros)
        #expect(!DVDVideoDisc.isDVDVideo(zeros))
        #expect(throws: DVDVideoError.notDVDVideo) { _ = try DVDVideoDisc.read(zeros) }
        // A truncated image: its files run past the end.
        let full = DVDFixture.image(d.files)
        let cut = dir.appendingPathComponent("cut.iso")
        try Data(full.prefix(full.count - 40 * 2048)).write(to: cut)
        #expect(throws: DVDVideoError.self) { _ = try DVDVideoDisc.read(cut) }
    }

    @Test("Library locations name the run and track, and nothing else parses as one")
    func locations() {
        let ref = DVDStreamRef(titleSet: 1, stream: 0, firstSector: 800_550, lastSector: 947_221)
        let location = ref.location(path: "/m/Disc/VIDEO_TS/VIDEO_TS.IFO", track: 11)
        #expect(location == "/m/Disc/VIDEO_TS/VIDEO_TS.IFO#dvd-1-0-800550-947221-11")
        #expect(DVDStreamRef(location: location) == ref)
        for bad in ["/m/a.flac", "/m/a.flac#3", "/m/a.iso#2ch-1", "/m/a.iso#dvd-1-0-5-4-1", "/m/a.iso#dvd-0-0-1-2-1", "/m/a.iso#dvd-1-8-1-2-1", "/m/a.iso#dvd-1-0-1-2"] {
            #expect(DVDStreamRef(location: bad) == nil, "\(bad)")
        }
        #expect(SACDArea(location: location) == nil)
    }
}
