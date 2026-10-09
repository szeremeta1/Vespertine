//
// Vespertine — SACD images: the table of contents and text, both areas, DST, DoP and PCM matching DSDIFF bit for
// bit, gapless track boundaries, seeking. Every image here is synthesized (VespertineTestSupport).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineDTS
import Foundation
import SFBAudioEngine
import Testing
import VespertineTestSupport
@testable import VespertineAudio

/// One image for the whole suite: a plain-DSD stereo area and a DST 5.1 area with the same three tracks (4, 3 + a
/// 1-frame pause, and 3 frames), plus DSDIFF files of the same DSD.
enum SACDSample {
    static let frames = 11
    static let perFrame = Int64(SACDFixture.frameBytes) * 8
    static let tracks = [
        SACDFixture.TrackSpec(title: "Prélude", performer: "Ana Ruiz", composer: "J. Vesper", isrc: "USXYZ0300001", frames: 4),
        SACDFixture.TrackSpec(title: "Nocturne in Blue", frames: 3, pauseAfter: 1),
        SACDFixture.TrackSpec(title: "Coda", performer: "The Vesper Quartet", frames: 3),
    ]

    struct Files: Sendable { var iso: URL; var stereoDFF: URL; var surroundDFF: URL; var stereo: [[UInt8]]; var surround: [[UInt8]] }

    static let files: Files = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sacd-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stereo = SACDFixture.modulate(channels: 2, frames: frames)
        let surround = SACDFixture.modulate(channels: 6, frames: frames, seed: 7)
        let files = Files(iso: dir.appendingPathComponent("Night Studies.iso"), stereoDFF: dir.appendingPathComponent("stereo.dff"),
                          surroundDFF: dir.appendingPathComponent("surround.dff"), stereo: stereo, surround: surround)
        try! SACDFixture.write(to: files.iso,
                               stereo: .init(channels: 2, dst: false, planes: stereo, tracks: tracks),
                               multichannel: .init(channels: 6, dst: true, planes: surround, tracks: tracks, uncompressedFrames: [5]))
        try! DSDIFFFixture.write(stereo, to: files.stereoDFF)
        try! DSDIFFFixture.write(surround, to: files.surroundDFF)
        return files
    }()
}

@Suite("SACD images")
struct SACDTests {
    private func plan(_ mode: OutputPlan.Mode, channels: Int) -> OutputPlan {
        let rate = mode == .dop ? FormatPlanner.dopCarrierRate(SACDFixture.rate) : FormatPlanner.dsdToPCMRate(SACDFixture.rate)
        return OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: mode == .dop ? 24 : 32,
                          channels: channels, dsdConvertedToPCM: mode == .pcm, reason: "")
    }

    private func decoder(_ url: URL, _ mode: OutputPlan.Mode, area: SACDArea? = nil, track: Int? = nil) throws -> PCMDecoding {
        let probed = try SourceOpener.probe(url, area: area)
        var item = PlayableItem(url: url, sacdArea: area)
        if let track {
            let t = try #require(probed.sacd?.tracks[track - 1])
            item = PlayableItem(url: url, regionStartFrame: Int64(t.startFrame) * SACDSample.perFrame,
                                regionFrameLength: Int64(t.frameCount) * SACDSample.perFrame, sacdArea: area)
        }
        return try SourceOpener.decoder(for: probed, plan: plan(mode, channels: probed.format.channels), item: item)
    }

    private func read(_ decoder: PCMDecoding, frames: Int = .max) throws -> [[Float]] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        var out = [[Float]](repeating: [], count: Int(decoder.processingFormat.channelCount))
        while out[0].count < frames {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(4096, frames - out[0].count)))
            if buffer.frameLength == 0 { break }
            for c in out.indices { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
        }
        return out
    }

    /// DoP frames back to their 24-bit words.
    private func words(_ x: [Float]) -> [UInt32] { x.map { UInt32(bitPattern: Int32($0 * 2_147_483_648)) >> 8 } }

    @Test("Reads the Master TOC, both areas, the track list and the disc's text")
    func tableOfContents() throws {
        let image = try SACDImage.read(SACDSample.files.iso)
        #expect(image.albumTitle == "Night Studies" && image.albumArtist == "The Vesper Quartet")
        #expect(image.albumPublisher == "Fixture Records" && image.catalogNumber == "FXR-1001")
        #expect(image.genre == "Jazz" && image.releaseDate == "2003-03-01" && image.discNumber == nil)
        let stereo = try #require(image.area(.stereo)), surround = try #require(image.area(.multichannel))
        #expect(stereo.channels == 2 && !stereo.isDST && stereo.sampleRate == 2_822_400)
        #expect(surround.channels == 6 && surround.isDST)
        for area in [stereo, surround] {
            #expect(area.tracks.map(\.title) == ["Prélude", "Nocturne in Blue", "Coda"])
            // The pause after track 2 stays with it: the tracks join without a gap.
            #expect(area.tracks.map(\.startFrame) == [0, 4, 8] && area.tracks.map(\.frameCount) == [4, 4, 3])
            #expect(area.frameRange == 0..<11)
        }
        let first = stereo.tracks[0]
        #expect(first.performer == "Ana Ruiz" && first.composer == "J. Vesper" && first.isrc == "USXYZ0300001" && first.genre == "Rock")
        #expect(stereo.tracks[1].performer == nil && stereo.tracks[2].performer == "The Vesper Quartet")
        #expect(stereo.copyright == "(P) 2003 Fixture Records")
        #expect(try SourceInspector.inspectWithDuration(SACDSample.files.iso).duration == 11.0 / 75)
    }

    @Test("DST frames decode to exactly the DSD they were made from: plain and Rice-coded tables, shared filters, half probability, stored frames")
    func dstFrames() throws {
        for channels in [2, 5, 6] {
            let planes = SACDFixture.modulate(channels: channels, frames: 1, seed: Double(channels))
            var dsd = [UInt8](repeating: 0, count: SACDFixture.frameBytes * channels)
            for i in 0..<SACDFixture.frameBytes { for c in 0..<channels { dsd[i * channels + c] = planes[c][i] } }
            let encoder = DSTEncoder(planes: planes)
            let decoder = try #require(ndst_create(Int32(channels), Int32(SACDFixture.frameBytes)))
            defer { ndst_destroy(decoder) }
            func decode(_ frame: [UInt8]) -> (Bool, [UInt8]) {
                var out = [UInt8](repeating: 0, count: dsd.count)
                let ok = frame.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { ndst_decode(decoder, src.baseAddress!, Int32(src.count), $0.baseAddress!) }
                }
                return (ok, out)
            }
            for variant in 0..<3 {
                let frame = encoder.encode(dsd, variant: variant)
                #expect(frame.count < dsd.count, "\(channels) channels: DST should shrink the frame")
                #expect(decode(frame) == (true, dsd), "\(channels) channels, variant \(variant)")
            }
            #expect(decode(DSTEncoder.uncompressed(dsd)) == (true, dsd))
            // A frame the decoder can't make sense of (here: a segmentation DST doesn't use) is reported, and plays as
            // DSD silence rather than noise. (DST has no checksum: damage elsewhere decodes to wrong bits, unnoticed.)
            var damaged = encoder.encode(dsd, variant: 0)
            damaged[0] = 0x80
            #expect(decode(damaged) == (false, [UInt8](repeating: 0x69, count: dsd.count)))
        }
    }

    @Test("Library locations name the area; other files and disc images aren't SACDs")
    func locationsAndOtherImages() throws {
        #expect(SACDArea(location: "/m/a.iso#2ch-3") == .stereo && SACDArea(location: "/m/a#b.iso#mch-12") == .multichannel)
        #expect(SACDArea(location: "/m/a.flac#3") == nil && SACDArea(location: "/m/a.flac") == nil && SACDArea(location: "/m/x#2ch-") == nil)
        #expect(SACDArea.location(path: "/m/a.iso", area: .multichannel, track: 2) == "/m/a.iso#mch-2")
        let dvd = FileManager.default.temporaryDirectory.appendingPathComponent("dvd-\(UUID()).iso")
        defer { try? FileManager.default.removeItem(at: dvd) }
        try Data(repeating: 0x20, count: 600 * 2048).write(to: dvd)
        #expect(!SACDImage.isSACD(dvd))
        #expect(throws: SACDError.self) { try SourceOpener.probe(dvd) }
        #expect(SACDImage.isSACD(SACDSample.files.iso))
    }

    @Test("DoP from the plain-DSD stereo area is bit for bit the DoP of the same DSD in a DSDIFF file")
    func stereoDoPMatchesDSDIFF() throws {
        let iso = try read(try decoder(SACDSample.files.iso, .dop))
        let dff = try read(try RawDoPDecoder(url: SACDSample.files.stereoDFF))
        #expect(iso[0].count == SACDSample.frames * SACDFixture.frameBytes / 2)
        #expect(iso.map(words) == dff.map(words))
        // A track on its own: the same frames as that stretch of the file.
        let second = try read(try decoder(SACDSample.files.iso, .dop, area: .stereo, track: 2))
        let start = 4 * SACDFixture.frameBytes / 2, count = 4 * SACDFixture.frameBytes / 2
        #expect(second[0].count == count)
        #expect(second.map(words) == dff.map { words(Array($0[start..<start + count])) })
    }

    @Test("The DST 5.1 area decodes to the exact DSD, each channel in its place (L R C LFE Ls Rs)")
    func surroundDST() throws {
        let decoder = try decoder(SACDSample.files.iso, .dop, area: .multichannel)
        #expect(decoder.processingFormat.channelLayout?.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        let probed = try SourceOpener.probe(SACDSample.files.iso, area: .multichannel)
        #expect(probed.format.channels == 6 && probed.format.codec == "SACD" && probed.decoderName.contains("DST"))
        #expect(probed.format.channelLabels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
        let dop = try read(decoder)
        for c in 0..<6 {
            let planes = SACDSample.files.surround[c]
            let got = words(dop[c]).flatMap { [UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
            #expect(got == planes, "channel \(c)")
        }
        let dff = try read(try RawDoPDecoder(url: SACDSample.files.surroundDFF))
        #expect(dop.map(words) == dff.map(words))
    }

    @Test("DSD to PCM is bit for bit DSDIFF's, in both areas")
    func pcmMatchesDSDIFF() throws {
        for (area, dffURL) in [(SACDArea.stereo, SACDSample.files.stereoDFF), (.multichannel, SACDSample.files.surroundDFF)] {
            let iso = try read(try decoder(SACDSample.files.iso, .pcm, area: area))
            let dffProbe = try SourceOpener.probe(dffURL)
            let dff = try read(try SourceOpener.decoder(for: dffProbe, plan: plan(.pcm, channels: dffProbe.format.channels), item: PlayableItem(url: dffURL)))
            #expect(iso[0].count == SACDSample.frames * SACDFixture.frameBytes)
            #expect(iso.count == dff.count && iso == dff, "\(area)")
        }
    }

    @Test("Tracks join without a gap: played one after another, they are the area played straight through")
    func gapless() throws {
        for area in SACDArea.allCases {
            let whole = try read(try decoder(SACDSample.files.iso, .pcm, area: area))
            var joined = [[Float]](repeating: [], count: whole.count)
            for track in 1...3 {
                let part = try read(try decoder(SACDSample.files.iso, .pcm, area: area, track: track))
                for c in joined.indices { joined[c] += part[c] }
            }
            #expect(joined == whole, "\(area) PCM")
            let wholeDoP = try read(try decoder(SACDSample.files.iso, .dop, area: area)).map { words($0).map { $0 & 0xFFFF } }
            var joinedDoP = [[UInt32]](repeating: [], count: whole.count)
            for track in 1...3 {
                let part = try read(try decoder(SACDSample.files.iso, .dop, area: area, track: track))
                for c in joinedDoP.indices { joinedDoP[c] += words(part[c]).map { $0 & 0xFFFF } }
            }
            #expect(joinedDoP == wholeDoP, "\(area) DoP")
        }
    }

    @Test("Seeking lands exactly where asked, inside a track and across frames")
    func seeking() throws {
        let whole = try read(try decoder(SACDSample.files.iso, .pcm, area: .multichannel))
        let pcm = try decoder(SACDSample.files.iso, .pcm, area: .multichannel, track: 2)
        #expect(pcm.length == 4 * Int64(SACDFixture.frameBytes))
        for target in [7_000, 100, 4704 * 3 + 5] {
            try pcm.seek(to: AVAudioFramePosition(target))
            #expect(pcm.position == AVAudioFramePosition(target))
            let got = try read(pcm, frames: 1500)
            let from = 4 * SACDFixture.frameBytes + target
            #expect(got.indices.allSatisfy { got[$0] == Array(whole[$0][from..<min(from + 1500, 8 * SACDFixture.frameBytes)]) }, "PCM seek to \(target)")
        }
        let dop = try decoder(SACDSample.files.iso, .dop, area: .multichannel, track: 3)
        try dop.seek(to: 3_001)
        let after = try read(dop, frames: 2)
        let planes = SACDSample.files.surround[4], at = 8 * SACDFixture.frameBytes + 2 * 3_001
        #expect(words(after[4]).map { $0 & 0xFFFF } == [UInt32(planes[at]) << 8 | UInt32(planes[at + 1]), UInt32(planes[at + 2]) << 8 | UInt32(planes[at + 3])])
        #expect(words(after[4])[0] >> 16 == 0xFA)   // frame 3 001 is odd: its marker is 0xFA
    }
}

/// What two real discs (stereo and DST 5.1 areas, checked against sacd_extract) and a code review taught, with
/// synthesized images: damaged and unusual images open, play and report what they can, and never crash.
@Suite("SACD images: real-disc layout and damage")
struct SACDDamageTests {
    private static func dir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sacd-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dop(_ url: URL, area: SACDArea? = nil, track: Int? = nil) throws -> PCMDecoding {
        let probed = try SourceOpener.probe(url, area: area)
        let a = try #require(probed.sacd)
        var item = PlayableItem(url: url, sacdArea: area)
        if let track {
            let t = a.tracks[track - 1]
            item = PlayableItem(url: url, regionStartFrame: Int64(t.startFrame) * a.samplesPerFrame,
                                regionFrameLength: Int64(t.frameCount) * a.samplesPerFrame, sacdArea: area)
        }
        let rate = FormatPlanner.dopCarrierRate(SACDFixture.rate)
        let plan = OutputPlan(mode: .dop, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: 24,
                              channels: a.channels, dsdConvertedToPCM: false, reason: "")
        return try SourceOpener.decoder(for: probed, plan: plan, item: item)
    }

    /// Every DSD byte a DoP decoder carries, per channel.
    private func dsd(_ decoder: PCMDecoding) throws -> [[UInt8]] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        var out = [[UInt8]](repeating: [], count: Int(decoder.processingFormat.channelCount))
        while true {
            try decoder.decode(into: buffer, length: 4096)
            if buffer.frameLength == 0 { break }
            for c in out.indices {
                for i in 0..<Int(buffer.frameLength) {
                    let w = UInt32(bitPattern: Int32(buffer.floatChannelData![c][i] * 2_147_483_648)) >> 8
                    out[c] += [UInt8(w >> 8 & 0xFF), UInt8(w & 0xFF)]
                }
            }
        }
        return out
    }

    private func frames(_ planes: [[UInt8]], _ range: Range<Int>) -> [[UInt8]] {
        planes.map { Array($0[range.lowerBound * SACDFixture.frameBytes..<range.upperBound * SACDFixture.frameBytes]) }
    }

    /// File offsets of every copy of a TOC sector (by its signature) in a plain image.
    private func sectors(_ url: URL, _ signature: String) throws -> [Int] {
        let data = try Data(contentsOf: url)
        return stride(from: 0, to: data.count, by: 2048).filter { data[$0..<$0 + 8].elementsEqual(signature.utf8) }
    }

    private func patch(_ url: URL, at offset: Int, _ bytes: [UInt8]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(bytes))
    }

    /// The file offset of the frame information (time code + DST packet count) of the frame with time code `tc`.
    private func frameInfo(_ url: URL, area: SACDImage.Area, timecode tc: Int) throws -> Int {
        let data = [UInt8](try Data(contentsOf: url))
        for s in area.firstSector...area.lastSector {
            let o = s * 2048, packets = Int(data[o] >> 5), starts = Int(data[o] >> 2 & 7)
            for k in 0..<starts {
                let f = o + 1 + 2 * packets + 4 * k
                if (Int(data[f]) * 60 + Int(data[f + 1])) * 75 + Int(data[f + 2]) == tc { return f }
            }
        }
        throw SACDError.damaged("no frame \(tc)")
    }

    @Test("As on real discs: time codes from 00:00:00 with the first track later, the area TOC's copy right after the last audio sector, DST stereo, minutes rolling over")
    func realDiscLayout() throws {
        let dir = Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("disc.iso")
        let stereo = SACDFixture.modulate(channels: 2, frames: 8, seed: 3), surround = SACDFixture.modulate(channels: 6, frames: 7, seed: 5)
        let tracks = [SACDFixture.TrackSpec(title: "One", frames: 3), SACDFixture.TrackSpec(title: "Two", frames: 3)]
        try SACDFixture.write(to: url, stereo: .init(channels: 2, dst: true, planes: stereo, tracks: tracks, leadIn: 2),
                              multichannel: .init(channels: 6, dst: true, planes: surround, tracks: tracks, firstFrame: 4497, leadIn: 1))
        let image = try SACDImage.read(url)
        let s = try #require(image.area(.stereo)), m = try #require(image.area(.multichannel))
        // The TOC's track starts are the frames' own time codes: track 1 starts after the lead-in.
        #expect(s.isDST && s.tracks.map(\.startFrame) == [2, 5] && s.frameRange == 2..<8)
        #expect(m.tracks.map(\.startFrame) == [4498, 4501] && m.frameRange == 4498..<4504)
        // The last audio sector belongs to the area (the area's TOC copy follows it).
        #expect(try sectors(url, "TWOCHTOC").contains((s.lastSector + 1) * 2048))
        #expect(try dsd(try dop(url, area: .stereo, track: 1)) == frames(stereo, 2..<5))
        #expect(try dsd(try dop(url, area: .stereo, track: 2)) == frames(stereo, 5..<8))
        #expect(try dsd(try dop(url, area: .multichannel)) == frames(surround, 1..<7))
        // Into 01:00:00 (frame 4500) by a seek.
        let second = try dop(url, area: .multichannel, track: 1)
        try second.seek(to: AVAudioFramePosition(2 * SACDFixture.frameBytes / 2 + 7))
        let tail = try dsd(second)
        #expect(tail == surround.map { Array($0[3 * SACDFixture.frameBytes + 14..<4 * SACDFixture.frameBytes]) })
    }

    @Test("A frame missing a packet, or cut off at the end of the area, plays as silence and is counted; the frames around it are untouched")
    func incompleteFrames() throws {
        let dir = Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("damaged.iso")
        let planes = SACDFixture.modulate(channels: 2, frames: 5, seed: 9)
        try SACDFixture.write(to: url, stereo: .init(channels: 2, dst: true, planes: planes, tracks: [.init(title: "One", frames: 5)]))
        let area = try #require(try SACDImage.read(url).area(.stereo))
        // Frames 2 and 4 (the last) declare one packet more than the image has.
        for tc in [2, 4] {
            let info = try frameInfo(url, area: area, timecode: tc)
            let byte = try FileHandle(forReadingFrom: url).readSlice(at: info + 3)
            try patch(url, at: info + 3, [byte &+ 4])
        }
        let decoder = try dop(url)
        let got = try dsd(decoder)
        let silence = [UInt8](repeating: 0x69, count: SACDFixture.frameBytes)
        var expected = frames(planes, 0..<5)
        for c in 0..<2 { for f in [2, 4] { expected[c].replaceSubrange(f * SACDFixture.frameBytes..<(f + 1) * SACDFixture.frameBytes, with: silence) } }
        #expect(got == expected)
        #expect((decoder as? ConcealingDecoder)?.concealedFrames == 2)

        // The signal path then stops claiming bit-perfect.
        let source = SourceFormat(encoding: .dsd, codec: "SACD", sampleRate: SACDFixture.rate, bitDepth: 1, channels: 2)
        let plan = OutputPlan(mode: .dop, deviceSampleRate: 176_400, decodedSampleRate: 176_400, physicalBitDepth: 24, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        var path = SignalPath(source: source, decoderName: "SACD image", plan: plan,
                              applied: AppliedFormat(sampleRate: 176_400, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2,
                                                     exclusive: true, bufferFrames: 512),
                              deviceName: "DAC", deviceUID: "DAC",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .hardware)
        #expect(path.isBitPerfect && path.statusLine == "NATIVE DSD · DoP")
        path.concealedFrames = 2
        #expect(!path.isBitPerfect && path.statusLine == "DAMAGED FRAMES SILENCED")
    }

    @Test("DST frames that can't be whole or valid are reported, not decoded: short stored frames, tables past the end, unread code, coefficients that would overflow")
    func invalidDSTFrames() throws {
        let channels = 2, total = SACDFixture.frameBytes * channels
        let planes = SACDFixture.modulate(channels: channels, frames: 1, seed: 11)
        var dsd = [UInt8](repeating: 0, count: total)
        for i in 0..<SACDFixture.frameBytes { for c in 0..<channels { dsd[i * channels + c] = planes[c][i] } }
        let decoder = try #require(ndst_create(Int32(channels), Int32(SACDFixture.frameBytes)))
        defer { ndst_destroy(decoder) }
        func decode(_ frame: [UInt8]) -> Bool {
            var out = [UInt8](repeating: 0, count: total)
            return frame.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { ndst_decode(decoder, src.baseAddress!, Int32(src.count), $0.baseAddress!) } }
        }
        let coded = DSTEncoder(planes: planes).encode(dsd, variant: 1)
        #expect(decode(coded) && decode(DSTEncoder.uncompressed(dsd)))
        #expect(!decode([0x00, 0x12]))                                   // a stored frame with 1 byte of 9408
        #expect(!decode(Array(DSTEncoder.uncompressed(dsd).dropLast())))
        #expect(!decode(Array(coded.prefix(3))))                         // its tables run past the end
        #expect(!decode(coded + [UInt8](repeating: 0, count: 8)))        // more than 7 bits of code left unread

        // A Rice-coded filter whose prediction grows each coefficient until it would overflow a 32-bit int
        // (prediction method 1, two zeros, a residual of 2^22, then zeros): out of range at once.
        var bits: [Bool] = []
        func put(_ v: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append(v >> i & 1 == 1) } }
        put(1, 1); put(7, 3); put(1, 1); put(1, 1); put(0, 2)              // DST; one segment; one filter, one table
        put(127, 7); put(1, 1); put(1, 2); put(0, 9); put(0, 9); put(7, 3) // 128 coefficients, method 1, k = 7
        bits += [Bool](repeating: false, count: 1 << 15); put(1, 1); put(0, 7); put(0, 1)   // 2^22
        for _ in 3..<128 { put(1, 1); put(0, 7) }
        put(0, 6); put(0, 1); put(0, 7); put(0, 1)
        var frame = [UInt8](repeating: 0, count: (bits.count + 7) / 8 + 64)
        for (i, b) in bits.enumerated() where b { frame[i / 8] |= 0x80 >> (i % 8) }
        #expect(!decode(frame))
    }

    @Test("Track times that contradict themselves make that area unreadable, not a crash; a damaged area TOC falls back to its copy")
    func damagedTrackTimes() throws {
        let dir = Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("times.iso")
        let tracks = [SACDFixture.TrackSpec(title: "One", frames: 2), SACDFixture.TrackSpec(title: "Two", frames: 2)]
        func write() throws {
            try SACDFixture.write(to: url, stereo: .init(channels: 2, dst: false, planes: SACDFixture.modulate(channels: 2, frames: 7), tracks: tracks, leadIn: 3),
                                  multichannel: .init(channels: 6, dst: false, planes: SACDFixture.modulate(channels: 6, frames: 4), tracks: tracks))
        }
        // The stereo area's track list, in its TOC and the TOC's copy: track 2 starts before track 1 (so the area would
        // end before it starts), at 00:60:00 or at 00:00:75.
        for start: [UInt8] in [[0, 0, 0], [0, 60, 0], [0, 0, 75]] {
            try write()
            let lists = try sectors(url, "SACDTRL2")
            #expect(lists.count == 4)
            for list in lists.prefix(2) { try patch(url, at: list + 8 + 4, start) }
            let image = try SACDImage.read(url)
            #expect(image.areas.map(\.kind) == [.multichannel], "\(start)")
            #expect(try SourceInspector.inspectWithDuration(url).duration == 4.0 / 75)
        }
        // Only the first copy damaged: the copy after the audio is read instead.
        try write()
        try patch(url, at: try sectors(url, "SACDTRL2")[0] + 8 + 4, [0, 0, 1])
        #expect(try SACDImage.read(url).area(.stereo)?.tracks.map(\.startFrame) == [3, 5])
        // A last track longer than the area's playing time ends with the area.
        try write()
        for list in try sectors(url, "SACDTRL2").prefix(2) { try patch(url, at: list + 8 + 1020 + 4, [9, 0, 0]) }
        #expect(try SACDImage.read(url).area(.stereo)?.tracks.map(\.frameCount) == [2, 2])
    }

    @Test("A Master TOC whose areas can't be read gives way to a copy that can")
    func masterTOCCopies() throws {
        let dir = Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("copies.iso")
        let tracks = [SACDFixture.TrackSpec(title: "One", frames: 2)]
        func write() throws {
            try SACDFixture.write(to: url, stereo: .init(channels: 2, dst: false, planes: SACDFixture.modulate(channels: 2, frames: 2), tracks: tracks),
                                  multichannel: .init(channels: 6, dst: true, planes: SACDFixture.modulate(channels: 6, frames: 2), tracks: tracks))
        }
        let primary = SACDFixture.masterTOCOffset(copy: 0)
        // No area addresses at all, then the multichannel area's (and its copy's) pointing at audio, then an unknown version.
        let audio: [UInt8] = [0, 0, 2, 0x30, 0, 0, 2, 0x30]
        for (offset, bytes) in [(64, [UInt8](repeating: 0, count: 24)), (72, audio), (8, [9])] {
            try write()
            try patch(url, at: primary + offset, bytes)
            #expect(try SACDImage.read(url).areas.map(\.kind) == [.stereo, .multichannel], "offset \(offset)")
        }
        // Every copy damaged the same way: what can be read is.
        try write()
        for copy in 0..<3 { try patch(url, at: SACDFixture.masterTOCOffset(copy: copy) + 72, audio) }
        #expect(try SACDImage.read(url).areas.map(\.kind) == [.stereo])
        for copy in 0..<3 { try patch(url, at: SACDFixture.masterTOCOffset(copy: copy) + 64, [UInt8](repeating: 0, count: 24)) }
        #expect(throws: SACDError.self) { try SACDImage.read(url) }
    }

    @Test("Images of 2064-byte raw sectors read and play exactly like plain ones")
    func rawSectorImages() throws {
        let dir = Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.iso"), raw = dir.appendingPathComponent("raw.iso")
        let tracks = [SACDFixture.TrackSpec(title: "One", frames: 2), SACDFixture.TrackSpec(title: "Two", frames: 2)]
        let stereo = SACDFixture.modulate(channels: 2, frames: 5, seed: 2), surround = SACDFixture.modulate(channels: 6, frames: 4, seed: 4)
        for (url, isRaw) in [(plain, false), (raw, true)] {
            try SACDFixture.write(to: url, stereo: .init(channels: 2, dst: false, planes: stereo, tracks: tracks, leadIn: 1),
                                  multichannel: .init(channels: 6, dst: true, planes: surround, tracks: tracks), rawSectors: isRaw)
        }
        #expect(try Data(contentsOf: raw).count == (try Data(contentsOf: plain).count) / 2048 * 2064)
        #expect(SACDImage.isSACD(raw))
        let a = try SACDImage.read(plain), b = try SACDImage.read(raw)
        #expect(b.albumTitle == a.albumTitle && b.areas.map(\.layout) == [.raw, .raw])
        #expect(b.areas.map { [$0.firstSector, $0.lastSector] } == a.areas.map { [$0.firstSector, $0.lastSector] })
        #expect(b.areas.map(\.tracks) == a.areas.map(\.tracks))
        #expect(try dsd(try dop(raw, area: .stereo, track: 2)) == frames(stereo, 3..<5))
        #expect(try dsd(try dop(raw, area: .multichannel)) == surround)
    }
}

private extension FileHandle {
    func readSlice(at offset: Int) throws -> UInt8 {
        try seek(toOffset: UInt64(offset))
        return try read(upToCount: 1)?.first ?? 0
    }
}
