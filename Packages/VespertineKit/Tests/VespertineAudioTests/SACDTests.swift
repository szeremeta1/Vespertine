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
