//
// Vespertine: DSD files (DSF, DSDIFF) played by the phone itself from a share: where the DSD is in the file, the file's
// own bits as DoP frames for a DAC that takes them, PCM for everything else, and a share that lists and opens such
// files. On files made here in memory.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertineShare

/// Makes DSD, and DSF and DSDIFF files around it.
enum DSDMaker {
    /// A sine as DSD (a second-order sigma-delta modulator): bytes, the oldest bit the highest. `level`: 1 is all the
    /// bits can carry.
    static func tone(hz: Double, level: Double, seconds: Double, rate: Int = 2_822_400, phase: Double = 0) -> [UInt8] {
        let samples = Int(seconds * Double(rate)) / 16 * 16
        var bytes = [UInt8](repeating: 0, count: samples / 8)
        var v1 = 0.0, v2 = 0.0, y = 0.0
        let step = 2 * Double.pi * hz / Double(rate)
        for i in 0..<samples {
            let x = level * sin(step * Double(i) + phase)
            v1 += x - y
            v2 += v1 - y
            y = v2 >= 0 ? 1 : -1
            if y > 0 { bytes[i >> 3] |= UInt8(0x80 >> (i & 7)) }
        }
        return bytes
    }

    static func le(_ value: Int64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * Int64($0))) } }
    static func be(_ value: Int64, _ count: Int) -> [UInt8] { le(value, count).reversed() }
    static func reversed(_ byte: UInt8) -> UInt8 {
        var out: UInt8 = 0
        for bit in 0..<8 where byte & (1 << bit) != 0 { out |= 0x80 >> bit }
        return out
    }

    /// An ID3v2.3 tag of text frames.
    static func id3(_ frames: [String: String]) -> [UInt8] {
        var body: [UInt8] = []
        for (id, text) in frames.sorted(by: { $0.key < $1.key }) {
            let value = [3] + Array(text.utf8)
            body += Array(id.utf8) + be(Int64(value.count), 4) + [0, 0] + value
        }
        let size = body.count
        return Array("ID3".utf8) + [3, 0, 0, UInt8(size >> 21 & 0x7f), UInt8(size >> 14 & 0x7f), UInt8(size >> 7 & 0x7f), UInt8(size & 0x7f)] + body
    }

    /// A DSF file of these channels (each the oldest bit the highest, as DoP has them).
    static func dsf(_ planes: [[UInt8]], rate: Int = 2_822_400, lsbFirst: Bool = true, tags: [String: String] = [:]) -> Data {
        let block = 4096, count = planes[0].count
        var audio: [UInt8] = []
        for start in stride(from: 0, to: count, by: block) {
            for plane in planes {
                var piece = Array(plane[start..<min(count, start + block)])
                if lsbFirst { piece = piece.map(reversed) }
                audio += piece + [UInt8](repeating: 0, count: block - piece.count)
            }
        }
        let tag = tags.isEmpty ? [] : id3(tags)
        let audioEnd = Int64(92 + audio.count)
        var out: [UInt8] = Array("DSD ".utf8) + le(28, 8) + le(audioEnd + Int64(tag.count), 8) + le(tag.isEmpty ? 0 : audioEnd, 8)
        out += Array("fmt ".utf8) + le(52, 8) + le(1, 4) + le(0, 4) + le(planes.count == 2 ? 2 : 7, 4) + le(Int64(planes.count), 4) + le(Int64(rate), 4)
        out += le(lsbFirst ? 1 : 8, 4) + le(Int64(count) * 8, 8) + le(Int64(block), 4) + le(0, 4)
        out += Array("data".utf8) + le(Int64(12 + audio.count), 8) + audio + tag
        return Data(out)
    }

    /// A DSDIFF file of these channels. `dst`: it says its audio is packed with DST (and holds none that can be read).
    static func dff(_ planes: [[UInt8]], rate: Int = 2_822_400, dst: Bool = false, artist: String? = nil, title: String? = nil, tags: [String: String] = [:]) -> Data {
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be(Int64(body.count), 8) + body + (body.count % 2 == 1 ? [0] : []) }
        func text(_ value: String) -> [UInt8] { be(Int64(value.utf8.count), 4) + Array(value.utf8) }
        let names = ["SLFT", "SRGT", "C   ", "LFE ", "LS  ", "RS  "]
        var properties: [UInt8] = Array("SND ".utf8)
        properties += chunk("FS  ", be(Int64(rate), 4))
        properties += chunk("CHNL", be(Int64(planes.count), 2) + planes.indices.flatMap { Array(names[$0].utf8) })
        let how = dst ? "DST Encoded" : "not compressed"
        properties += chunk("CMPR", Array((dst ? "DST " : "DSD ").utf8) + [UInt8(how.utf8.count)] + Array(how.utf8))
        var audio: [UInt8] = []
        for index in 0..<planes[0].count { for plane in planes { audio.append(plane[index]) } }
        var body: [UInt8] = Array("DSD ".utf8) + chunk("FVER", [1, 5, 0, 0]) + chunk("PROP", properties)
        body += dst ? chunk("DST ", chunk("FRTE", be(75, 4) + be(75, 2))) : chunk("DSD ", audio)
        if artist != nil || title != nil {
            body += chunk("DIIN", (artist.map { chunk("DIAR", text($0)) } ?? []) + (title.map { chunk("DITI", text($0)) } ?? []))
        }
        if !tags.isEmpty { body += chunk("ID3 ", id3(tags)) }
        return Data(Array("FRM8".utf8) + be(Int64(body.count), 8) + body)
    }

    static func layout(_ file: Data, named name: String) throws -> DSDLayout {
        try #require(try CountedFile(file).tags(named: name)?.dsd)
    }

    /// Reads a whole rendering, `piece` bytes at a time.
    static func bytes(_ rendering: DSDRendering, of file: Data, piece: Int = 1 << 20) throws -> [UInt8] {
        var out: [UInt8] = []
        while Int64(out.count) < rendering.byteSize {
            let part = try rendering.read(offset: Int64(out.count), length: piece) { offset, length in
                file.subdata(in: Int(offset)..<min(file.count, Int(offset) + length))
            }
            #expect(!part.isEmpty)
            if part.isEmpty { break }
            out += part
        }
        return out
    }

    /// The 24-bit samples after the header, as the words they are: `[channel][frame]`.
    static func words(_ bytes: [UInt8], channels: Int) -> [[UInt32]] {
        let frames = (bytes.count - DSDRendering.headerSize) / (channels * 3)
        return (0..<channels).map { channel in
            (0..<frames).map { frame in
                let at = DSDRendering.headerSize + (frame * channels + channel) * 3
                return UInt32(bytes[at]) << 16 | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2])
            }
        }
    }

    /// The samples as numbers, 1 being full scale.
    static func samples(_ bytes: [UInt8], channels: Int) -> [[Double]] {
        words(bytes, channels: channels).map { $0.map { Double(Int32(bitPattern: $0 << 8) >> 8) / 8_388_608 } }
    }

    /// How strong `hz` is in `signal` (the height of a sine there).
    static func level(_ signal: ArraySlice<Double>, hz: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * hz / rate
        var re = 0.0, im = 0.0
        for (n, x) in signal.enumerated() { re += x * cos(w * Double(n)); im += x * sin(w * Double(n)) }
        return 2 * (re * re + im * im).squareRoot() / Double(signal.count)
    }
}

@Suite struct DSDFileTests {
    private let left = DSDMaker.tone(hz: 1_000, level: 0.25, seconds: 0.05)
    private let right = DSDMaker.tone(hz: 3_000, level: 0.25, seconds: 0.05)

    @Test func aDSFFileSaysWhereItsDSDIsAndGivesItsTags() throws {
        let file = DSDMaker.dsf([left, right], tags: ["TIT2": "Lantern Street", "TPE1": "The Vesper Quartet", "TALB": "Night Rooms", "TRCK": "3/9", "TYER": "2019"])
        let counted = CountedFile(file)
        let tags = try #require(try counted.tags(named: "03 Lantern Street.DSF"))
        #expect(tags.codec == "DSD" && tags.sampleRate == 2_822_400 && tags.bitDepth == 1 && tags.channels == 2 && tags.lossless)
        #expect(abs(tags.duration - 0.05) < 1e-4)
        #expect(tags.title == "Lantern Street" && tags.artist == "The Vesper Quartet" && tags.album == "Night Rooms" && tags.track == 3 && tags.year == 2019)
        let layout = try #require(tags.dsd)
        #expect(layout.kind == .dsf && layout.dataOffset == 92 && layout.blockSize == 4096 && layout.lsbFirst && !layout.dst)
        #expect(layout.bytesPerChannel == Int64(left.count) && layout.playsHere)
        #expect(ShareCatalog.format(tags) == "DSD64")
        #expect(counted.reads <= 4, "the header, the data chunk and the tag at the end: never the audio")
    }

    @Test func aDSDIFFFileSaysWhereItsDSDIsAndGivesItsTags() throws {
        let plain = DSDMaker.dff([left, right], rate: 5_644_800, artist: "The Vesper Quartet", title: "Lantern Street")
        var tags = try #require(try CountedFile(plain).tags(named: "a.dff"))
        #expect(tags.codec == "DSD" && tags.sampleRate == 5_644_800 && tags.channels == 2 && ShareCatalog.format(tags) == "DSD128")
        #expect(tags.title == "Lantern Street" && tags.artist == "The Vesper Quartet" && tags.album == nil)
        let layout = try #require(tags.dsd)
        #expect(layout.kind == .dff && layout.blockSize == 1 && !layout.lsbFirst && layout.bytesPerChannel == Int64(left.count) && layout.playsHere)
        // Where the audio starts: the bytes there are the first of each channel.
        #expect(plain[Int(layout.dataOffset)] == left[0] && plain[Int(layout.dataOffset) + 1] == right[0])
        // An ID3 tag after the audio says more, and wins.
        let tagged = DSDMaker.dff([left, right], artist: "Someone", title: "Untitled", tags: ["TIT2": "Lantern Street", "TALB": "Night Rooms", "TPOS": "2"])
        tags = try #require(try CountedFile(tagged).tags(named: "a.dff"))
        #expect(tags.title == "Lantern Street" && tags.artist == "Someone" && tags.album == "Night Rooms" && tags.disc == 2)
    }

    @Test func surroundDSDAndDSTAreFilesForTheMac() throws {
        let six = [[UInt8]](repeating: left, count: 6)
        #expect(try !DSDMaker.layout(DSDMaker.dsf(six), named: "a.dsf").playsHere)
        #expect(try !DSDMaker.layout(DSDMaker.dff(six), named: "a.dff").playsHere)
        let packed = try DSDMaker.layout(DSDMaker.dff([left, right], dst: true), named: "a.dff")
        #expect(packed.dst && !packed.playsHere)
        #expect(DSDRendering.plan(packed, maxSampleRate: nil) == nil)
        // A rate that is no DSD rate (not 64, 128… times 44.1 or 48 kHz) is left to the Mac too.
        #expect(try !DSDMaker.layout(DSDMaker.dsf([left, right], rate: 1_000_000), named: "a.dsf").playsHere)
        #expect(try DSDMaker.layout(DSDMaker.dsf([left]), named: "a.dsf").playsHere, "mono plays")
    }

    @Test func aFileThatIsNotWhatItsNameSaysIsNotRead() throws {
        #expect(try CountedFile(Data("DSD nothing here".utf8)).tags(named: "a.dsf") == nil)
        #expect(try CountedFile(Data("FRM8".utf8)).tags(named: "a.dff") == nil)
        #expect(try CountedFile(DSDMaker.dsf([left, right])).tags(named: "a.dff") == nil)
    }
}

@Suite struct DSDAsDoPFromAFileTests {
    private static let chord = DoPProbeClip.dsd()
    private static let tone = DSDMaker.tone(hz: 1_000, level: 0.25, seconds: 5)

    private func doP(_ file: Data, _ name: String) throws -> (DSDRendering, [UInt8]) {
        let rendering = try #require(DSDRendering.plan(try DSDMaker.layout(file, named: name), maxSampleRate: nil, dop: 176_400))
        return (rendering, try DSDMaker.bytes(rendering, of: file))
    }

    @Test func theFramesAreTheFilesOwnBitsInTheFormTheDoPTestSoundHas() throws {
        let (rendering, bytes) = try doP(DSDMaker.dsf([Self.chord, Self.tone]), "a.dsf")
        #expect(rendering.form == .dop && rendering.sampleRate == 176_400 && rendering.frames == 882_000)
        #expect(Int64(bytes.count) == rendering.byteSize)
        let words = DSDMaker.words(bytes, channels: 2)
        // The left channel is the DoP test's own DSD: its frames must be the test's frames, word for word.
        #expect(words[0] == DoPProbeClip.frames())
        // The right channel carries its own bits behind the same markers.
        let tone = Self.tone
        #expect(words[1] == (0..<tone.count / 2).map { DoPProbeClip.word(frame: $0, tone[2 * $0], tone[2 * $0 + 1]) })
    }

    @Test func theFileIsACAFOf24BitSamplesAtTheCarrierRate() throws {
        let (rendering, bytes) = try doP(DSDMaker.dsf([Self.chord, Self.tone]), "a.dsf")
        #expect(Array(bytes[0..<8]) == Array("caff".utf8) + [0, 1, 0, 0])
        #expect(Array(bytes[8..<12]) == Array("desc".utf8) && Array(bytes[12..<20]) == DSDMaker.be(32, 8))
        #expect(Array(bytes[20..<28]) == DSDMaker.be(Int64(bitPattern: (176_400.0).bitPattern), 8))
        #expect(Array(bytes[28..<32]) == Array("lpcm".utf8))
        // Integer and big-endian (no flags), 6 bytes and one frame a packet, 2 channels, 24 bits.
        #expect(Array(bytes[32..<52]) == [0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 24])
        #expect(Array(bytes[52..<56]) == Array("data".utf8) && Array(bytes[56..<64]) == DSDMaker.be(4 + rendering.frames * 6, 8))
        #expect(rendering.header == Array(bytes[0..<DSDRendering.headerSize]))
    }

    @Test func aDSFStoredEitherWayRoundAndADSDIFFGiveTheSameFrames() throws {
        let planes = [Array(Self.chord.prefix(20_000)), Array(Self.tone.prefix(20_000))]
        let low = try doP(DSDMaker.dsf(planes, lsbFirst: true), "a.dsf").1
        #expect(try doP(DSDMaker.dsf(planes, lsbFirst: false), "a.dsf").1 == low)
        #expect(try doP(DSDMaker.dff(planes), "a.dff").1 == low)
    }

    @Test func anOddEndIsFilledWithDSDSilenceToAWholeMarkerPair() throws {
        // 4097 bytes a channel: 2049 frames, the last half filled; then one more frame so the markers end as a pair.
        let planes = [Array(Self.chord.prefix(4_097)), Array(Self.tone.prefix(4_097))]
        let (rendering, bytes) = try doP(DSDMaker.dff(planes), "a.dff")
        #expect(rendering.frames == 2_050)
        let words = DSDMaker.words(bytes, channels: 2)
        #expect(words[0][2_048] == DoPProbeClip.word(frame: 2_048, planes[0][4_096], 0x69))
        #expect(words[0][2_049] == DoPProbeClip.word(frame: 2_049, 0x69, 0x69) && words[1][2_049] == words[0][2_049])
    }

    @Test func anyRangeIsTheSameBytesHoweverTheReadsAreCut() throws {
        let planes = [Array(Self.chord.prefix(9_000)), Array(Self.tone.prefix(9_000))]
        for file in [DSDMaker.dsf(planes), DSDMaker.dff(planes)] {
            let layout = try DSDMaker.layout(file, named: file.starts(with: Array("FRM8".utf8)) ? "a.dff" : "a.dsf")
            for rendering in [try #require(DSDRendering.plan(layout, maxSampleRate: nil, dop: 176_400)), try #require(DSDRendering.plan(layout, maxSampleRate: nil)),
                              try #require(DSDRendering.plan(layout, maxSampleRate: 48_000))] {
                let whole = try DSDMaker.bytes(rendering, of: file)
                #expect(Int64(whole.count) == rendering.byteSize)
                for piece in [1, 7, 67, 1_000, 4_099] where piece > 1 || rendering.byteSize < 30_000 {
                    #expect(try DSDMaker.bytes(rendering, of: file, piece: piece) == whole, "\(rendering.form) at \(rendering.sampleRate), \(piece) bytes a read")
                }
                // A read from the middle, as after a seek.
                let middle = try rendering.read(offset: 1_001, length: 3_333) { file.subdata(in: Int($0)..<min(file.count, Int($0) + $1)) }
                #expect(Array(middle) == Array(whole[1_001..<4_334]))
                #expect(try rendering.read(offset: rendering.byteSize, length: 10) { _, _ in Data() }.isEmpty)
            }
        }
    }

    @Test func doPIsOnlyForStereoOnAnOutputThatTakesTheCarrierRate() throws {
        let stereo = try DSDMaker.layout(DSDMaker.dsf([Array(Self.tone.prefix(8_192)), Array(Self.tone.prefix(8_192))]), named: "a.dsf")
        #expect(DSDRendering.plan(stereo, maxSampleRate: nil)?.form == .pcm, "no DAC that takes DoP: PCM")
        #expect(DSDRendering.plan(stereo, maxSampleRate: nil, dop: 176_400)?.form == .dop)
        #expect(DSDRendering.plan(stereo, maxSampleRate: nil, dop: 88_200)?.form == .pcm, "a carrier the output wasn't seen to run at")
        #expect(DSDRendering.plan(stereo, maxSampleRate: 48_000, smaller: true, dop: 176_400)?.form == .pcm, "kept in its smaller form")
        let mono = try DSDMaker.layout(DSDMaker.dsf([Array(Self.tone.prefix(8_192))]), named: "a.dsf")
        #expect(DSDRendering.plan(mono, maxSampleRate: nil, dop: 176_400)?.form == .pcm, "DoP only where each channel has an output of its own")
        // DSD128 needs 352.8 kHz.
        let fast = try DSDMaker.layout(DSDMaker.dsf([Array(Self.tone.prefix(8_192)), Array(Self.tone.prefix(8_192))], rate: 5_644_800), named: "a.dsf")
        #expect(DSDRendering.plan(fast, maxSampleRate: nil, dop: 176_400)?.form == .pcm)
        let asDoP = DSDRendering.plan(fast, maxSampleRate: nil, dop: 352_800)
        #expect(asDoP?.form == .dop && asDoP?.sampleRate == 352_800)
    }
}

@Suite struct DSDAsPCMFromAFileTests {
    @Test func thePCMRateIsOfTheDSDsFamilyAndNoHigherThanTheOutputRuns() {
        #expect(DSDRendering.pcmRate(dsdRate: 2_822_400, ceiling: nil) == 176_400)
        #expect(DSDRendering.pcmRate(dsdRate: 5_644_800, ceiling: nil) == 176_400)
        #expect(DSDRendering.pcmRate(dsdRate: 5_644_800, ceiling: 384_000) == 352_800)
        #expect(DSDRendering.pcmRate(dsdRate: 2_822_400, ceiling: 384_000) == 352_800)
        #expect(DSDRendering.pcmRate(dsdRate: 2_822_400, ceiling: 48_000) == 44_100, "AirPods and the speaker: one resample, by iOS")
        #expect(DSDRendering.pcmRate(dsdRate: 2_822_400, ceiling: 44_100) == 44_100)
        #expect(DSDRendering.pcmRate(dsdRate: 2_822_400, ceiling: 22_050) == 44_100, "never below the family's base")
        #expect(DSDRendering.pcmRate(dsdRate: 3_072_000, ceiling: nil) == 192_000 && DSDRendering.pcmRate(dsdRate: 3_072_000, ceiling: 48_000) == 48_000)
        #expect(DSDRendering.isRegular(dsdRate: 2_822_400) && DSDRendering.isRegular(dsdRate: 22_579_200) && DSDRendering.isRegular(dsdRate: 3_072_000))
        #expect(!DSDRendering.isRegular(dsdRate: 1_411_200) && !DSDRendering.isRegular(dsdRate: 2_822_401) && !DSDRendering.isRegular(dsdRate: 8_467_200))
    }

    /// A 1 kHz tone on the left and a 3 kHz one on the right, as DSD at `dsdRate`, converted for an output that runs up to `ceiling`.
    private func converted(dsdRate: Int, ceiling: Double?, dff: Bool = false) throws -> (rate: Double, planes: [[Double]]) {
        let left = DSDMaker.tone(hz: 1_000, level: 0.25, seconds: 0.25, rate: dsdRate)
        let right = DSDMaker.tone(hz: 3_000, level: 0.125, seconds: 0.25, rate: dsdRate)
        let file = dff ? DSDMaker.dff([left, right], rate: dsdRate) : DSDMaker.dsf([left, right], rate: dsdRate)
        let rendering = try #require(DSDRendering.plan(try DSDMaker.layout(file, named: dff ? "a.dff" : "a.dsf"), maxSampleRate: ceiling))
        #expect(rendering.form == .pcm)
        let planes = DSDMaker.samples(try DSDMaker.bytes(rendering, of: file), channels: 2)
        #expect(Int64(planes[0].count) == rendering.frames && abs(Double(rendering.frames) / rendering.sampleRate - 0.25) < 0.001)
        return (rendering.sampleRate, planes)
    }

    @Test(arguments: [(2_822_400, nil, 176_400.0), (2_822_400, 48_000.0, 44_100.0), (2_822_400, 384_000.0, 352_800.0), (5_644_800, nil, 176_400.0),
                      (11_289_600, 96_000.0, 88_200.0), (3_072_000, 48_000.0, 48_000.0)] as [(Int, Double?, Double)])
    func aToneComesOutAsThatToneAtTheMacsLevel(dsdRate: Int, ceiling: Double?, expected: Double) throws {
        let (rate, planes) = try converted(dsdRate: dsdRate, ceiling: ceiling)
        #expect(rate == expected)
        // The middle of it, a whole number of cycles of both tones: away from where the song starts and ends.
        let from = Int(0.05 * rate), count = Int(0.15 * rate)
        let left = planes[0][from..<(from + count)], right = planes[1][from..<(from + count)]
        // +6 dB: a quarter of what DSD can carry is half of full scale.
        #expect(abs(DSDMaker.level(left, hz: 1_000, rate: rate) - 0.5) < 0.002)
        #expect(abs(DSDMaker.level(right, hz: 3_000, rate: rate) - 0.25) < 0.002)
        // Each channel is its own: nothing of the other's tone in it.
        #expect(DSDMaker.level(left, hz: 3_000, rate: rate) < 0.0005 && DSDMaker.level(right, hz: 1_000, rate: rate) < 0.0005)
        #expect(abs(left.reduce(0, +) / Double(count)) < 0.0005, "no offset")
    }

    @Test func atCDRateWhatIsLeftBesideTheToneIsFarBelowIt() throws {
        // At 44.1 kHz everything above 22 kHz, where DSD keeps its noise, has to be gone: what is left beside the tone
        // is the little noise DSD64 has in the band that can be heard (this modulator: about 80 dB down).
        let (rate, planes) = try converted(dsdRate: 2_822_400, ceiling: 44_100)
        let from = Int(0.05 * rate), count = Int(0.15 * rate)
        let left = planes[0][from..<(from + count)]
        let tone = DSDMaker.level(left, hz: 1_000, rate: rate)
        let power = left.reduce(0) { $0 + $1 * $1 } / Double(count)
        let rest = max(0, power - tone * tone / 2).squareRoot()
        #expect(rest < 0.5 * 0.001, "more than 60 dB under the tone")
    }

    @Test func theTwoKindsOfFileConvertToTheSameSamples() throws {
        #expect(try converted(dsdRate: 2_822_400, ceiling: nil, dff: true).planes == converted(dsdRate: 2_822_400, ceiling: nil).planes)
    }

    @Test func dsdSilenceIsSilenceAndWhatIsLouderThanFullScaleIsHeldThere() throws {
        let quiet = [UInt8](repeating: 0x69, count: 16_384)
        let loud = [UInt8](repeating: 0xFF, count: 16_384)
        let file = DSDMaker.dsf([quiet, loud])
        let rendering = try #require(DSDRendering.plan(try DSDMaker.layout(file, named: "a.dsf"), maxSampleRate: nil))
        let words = DSDMaker.words(try DSDMaker.bytes(rendering, of: file), channels: 2)
        let middle = 2_000..<6_000
        #expect(words[0][middle].allSatisfy { abs(Int32(bitPattern: $0 << 8) >> 8) < 256 }, "within 90 dB of nothing")
        #expect(words[1][middle].allSatisfy { $0 == 0x7F_FFFF }, "all ones is twice full scale after the +6 dB: held, not wrapped")
        #expect(words[1][0] != 0x7F_FFFF || words[1][1] != 0, "it rises from the silence before the song")
    }
}

/// A share with a DSD album on it.
private func dsdShare() -> (share: FakeShare, files: [String: Data]) {
    let share = FakeShare()
    let left = DSDMaker.tone(hz: 1_000, level: 0.25, seconds: 0.05), right = DSDMaker.tone(hz: 3_000, level: 0.25, seconds: 0.05)
    func tags(_ title: String, _ track: String) -> [String: String] {
        ["TIT2": title, "TPE1": "The Vesper Quartet", "TALB": "Night Rooms", "TRCK": track]
    }
    let files = [
        "Night Rooms/01 Lantern Street.dsf": DSDMaker.dsf([left, right], tags: tags("Lantern Street", "1")),
        "Night Rooms/02 Late Tram.dff": DSDMaker.dff([right, left], tags: tags("Late Tram", "2")),
        "Night Rooms/03 Surround.dsf": DSDMaker.dsf([[UInt8]](repeating: left, count: 6), tags: tags("Surround", "3")),
        "Night Rooms/04 Packed.dff": DSDMaker.dff([left, right], dst: true),
        "Night Rooms/05 Broken.dsf": Data("DSD ".utf8),
    ]
    for (path, data) in files { share.put(path, data) }
    return (share, files)
}

@Suite struct DSDOnAShareTests {
    @Test func aScanListsTheDSDFilesThePhonePlaysAndCountsTheOnesThatNeedTheMac() throws {
        let library = try ShareScanner.scan(dsdShare().share)
        #expect(library.songs.map(\.fileName) == ["01 Lantern Street.dsf", "02 Late Tram.dff"])
        #expect(library.needTheMac == 2, "surround DSD and DST")
        #expect(library.needs == ["surroundDSD": 1, "dst": 1])
        #expect(library.unreadable == 1)
        let catalog = ShareCatalog(library)
        let album = try #require(catalog.albums.first)
        #expect(album.summary.title == "Night Rooms" && album.summary.artist == "The Vesper Quartet" && album.summary.format == "DSD64")
        #expect(album.summary.dsd && album.summary.hiRes && !album.summary.multichannel)
        #expect(catalog.allTracks.map(\.title) == ["Lantern Street", "Late Tram"] && catalog.allTracks.allSatisfy { $0.format == "DSD64" })
    }

    @Test func theIndexKeepsWhereTheDSDIsBetweenLaunches() throws {
        let library = try ShareScanner.scan(dsdShare().share)
        let again = try JSONDecoder().decode(ShareLibrary.self, from: JSONEncoder().encode(library))
        #expect(again == library && again.songs.allSatisfy { $0.tags.dsd != nil })
        // An index written before DSD files were listed still reads.
        let old = Data(#"{"songs":[{"id":3,"path":"a.flac","size":10,"modified":0,"tags":{"codec":"FLAC","sampleRate":44100,"bitDepth":16,"channels":2,"duration":1}}],"covers":{},"needTheMac":1,"unreadable":0}"#.utf8)
        #expect(try JSONDecoder().decode(ShareLibrary.self, from: old).songs.first?.tags.dsd == nil)
        // And one written before the reasons were kept: the count alone.
        let before = try JSONDecoder().decode(ShareLibrary.self, from: old)
        #expect(before.needTheMac == 1 && before.needs.isEmpty && before.needsByKind.isEmpty)
    }
}

@MainActor
@Suite struct DSDFromAShareTests {
    private func opened() async throws -> (mac: ShareMac, files: [String: Data], song: Int64) {
        let (share, files) = dsdShare()
        let store = ShareStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("share-dsd-\(UUID().uuidString)", isDirectory: true))
        let mac = ShareMac(id: "share-test", name: "Studio NAS", files: share, playback: share, store: store, now: { FakeShare.day })
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { !mac.isScanning })
        guard case .songs(let items, _) = try await mac.request(.songs(offset: 0, limit: 10), timeout: .seconds(1)) else { throw RemoteLinkError.closed }
        return (mac, files, try #require(items.first { $0.title == "Lantern Street" }?.id))
    }

    private func open(_ mac: ShareMac, _ song: Int64, maxSampleRate: Double? = nil, smaller: Bool? = nil, dop: Double? = nil) async throws -> StreamDescriptor {
        guard case .streamOpened(let descriptor) = try await mac.request(.streamOpen(id: song, maxSampleRate: maxSampleRate, smaller: smaller, dop: dop), timeout: .seconds(1)) else {
            throw RemoteLinkError.closed
        }
        return descriptor
    }

    private func whole(_ mac: ShareMac, _ descriptor: StreamDescriptor) async throws -> [UInt8] {
        var out: [UInt8] = []
        while Int64(out.count) < descriptor.byteSize {
            let frame = try await mac.read(stream: descriptor.stream, offset: Int64(out.count), length: 10_000, timeout: .seconds(1))
            #expect(frame.endOfStream == (Int64(out.count + frame.payload.count) >= descriptor.byteSize))
            guard !frame.payload.isEmpty else { break }
            out += frame.payload
        }
        return out
    }

    @Test func forADACThatTakesDoPADSDSongOpensAsItsOwnBits() async throws {
        let (mac, files, song) = try await opened()
        let descriptor = try await open(mac, song, dop: 768_000)
        #expect(descriptor.dsdRate == 2_822_400 && descriptor.kind == .pcm)
        #expect(descriptor.format == StreamFormat(codec: "PCM", container: "caf", sampleRate: 176_400, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true))
        let file = try #require(files["Night Rooms/01 Lantern Street.dsf"])
        let rendering = try #require(DSDRendering.plan(try DSDMaker.layout(file, named: "a.dsf"), maxSampleRate: nil, dop: 768_000))
        #expect(descriptor.byteSize == rendering.byteSize && descriptor.frames == rendering.frames)
        #expect(try await whole(mac, descriptor) == DSDMaker.bytes(rendering, of: file))
    }

    @Test func forAnyOtherOutputItOpensAsPCMNoHigherThanTheOutputRuns() async throws {
        let (mac, files, song) = try await opened()
        let file = try #require(files["Night Rooms/01 Lantern Street.dsf"])
        let layout = try DSDMaker.layout(file, named: "a.dsf")
        let plain = try await open(mac, song)
        #expect(plain.dsdRate == nil && plain.kind == .pcm && plain.format.sampleRate == 176_400 && plain.format.container == "caf" && plain.format.bitDepth == 24)
        #expect(try await whole(mac, plain) == DSDMaker.bytes(try #require(DSDRendering.plan(layout, maxSampleRate: nil)), of: file))
        let airPods = try await open(mac, song, maxSampleRate: 48_000)
        #expect(airPods.dsdRate == nil && airPods.format.sampleRate == 44_100)
        #expect(try await whole(mac, airPods) == DSDMaker.bytes(try #require(DSDRendering.plan(layout, maxSampleRate: 48_000)), of: file))
        // Kept in its smaller form: never DoP, even for a DAC that takes it.
        let kept = try await open(mac, song, maxSampleRate: 48_000, smaller: true, dop: 768_000)
        #expect(kept.dsdRate == nil && kept.format.sampleRate == 44_100)
    }

    @Test func theFormsOfOneSongAreNeverTakenForEachOther() async throws {
        // The phone names a stream's file by the first 16 characters of its tag, and reuses a file of the right size:
        // the DoP form and the 176.4 kHz PCM form of a song are the same size.
        let (mac, _, song) = try await opened()
        let asDoP = try await open(mac, song, dop: 768_000), asPCM = try await open(mac, song), lower = try await open(mac, song, maxSampleRate: 48_000)
        #expect(asDoP.byteSize == asPCM.byteSize)
        #expect(Set([asDoP, asPCM, lower].map { String($0.tag.prefix(16)) }).count == 3)
        #expect(try await open(mac, song, dop: 768_000).tag == asDoP.tag, "and the same form is the same file again")
    }

    @Test func whatASongWouldArriveAsIsSaidBeforeItIsOpened() async throws {
        let (mac, _, song) = try await opened()
        guard case .streamInfo(let items) = try await mac.request(.streamInfo(ids: [song], maxSampleRate: 48_000), timeout: .seconds(1)) else { throw RemoteLinkError.closed }
        let info = try #require(items.first)
        #expect(info.streamable && info.kind == .pcm && info.macOnlyReason == nil)
        #expect(info.source.codec == "DSD" && info.source.sampleRate == 2_822_400 && info.source.container == "dsf")
        #expect(info.delivered?.sampleRate == 44_100 && info.delivered?.container == "caf")
    }
}

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AVFAudio

/// Bytes in memory, read as the player reads a song.
private final class MemorySource: ByteSource, @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    var byteSize: Int64 { Int64(data.count) }
    var isComplete: Bool { true }
    func read(at offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, offset < byteSize, length > 0 else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
    }
    func interruptReads() {}
}

@Suite struct DSDThroughThePlayersDecoderTests {
    /// Decodes a whole rendering with the decoder the player uses, back to 24-bit words.
    private func decoded(_ rendering: DSDRendering, of file: Data) throws -> [[UInt32]] {
        let bytes = Data(try DSDMaker.bytes(rendering, of: file))
        let format = StreamFormat(codec: "PCM", container: "caf", sampleRate: rendering.sampleRate, bitDepth: 24, channels: rendering.channels, channelLabels: nil, lossless: true)
        let decoder = try StreamDecoder(source: MemorySource(bytes), format: format)
        #expect(decoder.length == rendering.frames && decoder.processingFormat.sampleRate == rendering.sampleRate)
        #expect(decoder.fileFormat.mBitsPerChannel == 24 && decoder.fileFormat.mChannelsPerFrame == UInt32(rendering.channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8_192))
        var out = [[UInt32]](repeating: [], count: rendering.channels)
        while true {
            let read = try decoder.read(into: buffer)
            if read == 0 { break }
            let planes = try #require(buffer.floatChannelData)
            for channel in 0..<rendering.channels {
                // What a 24-bit output makes of the float sample.
                out[channel] += (0..<read).map { UInt32(bitPattern: Int32((planes[channel][$0] * 8_388_608).rounded())) & 0xFF_FFFF }
            }
        }
        return out
    }

    @Test func theDecoderThePlayerUsesGivesBackEveryDoPFrameExactly() throws {
        let chord = Array(DoPProbeClip.dsd().prefix(200_000)), tone = DSDMaker.tone(hz: 1_000, level: 0.25, seconds: 0.6)
        let file = DSDMaker.dsf([chord, Array(tone.prefix(200_000))])
        let rendering = try #require(DSDRendering.plan(try DSDMaker.layout(file, named: "a.dsf"), maxSampleRate: nil, dop: 176_400))
        let words = try decoded(rendering, of: file)
        #expect(words[0] == Array(DoPProbeClip.frames().prefix(100_000)))
        #expect(words == DSDMaker.words(try DSDMaker.bytes(rendering, of: file), channels: 2))
    }

    @Test func thePCMFormDecodesToTheSamplesThatWereMade() throws {
        let tone = DSDMaker.tone(hz: 1_000, level: 0.25, seconds: 0.1)
        let file = DSDMaker.dff([tone, tone])
        let rendering = try #require(DSDRendering.plan(try DSDMaker.layout(file, named: "a.dff"), maxSampleRate: 48_000))
        #expect(try decoded(rendering, of: file) == DSDMaker.words(try DSDMaker.bytes(rendering, of: file), channels: 2))
    }
}
#endif
