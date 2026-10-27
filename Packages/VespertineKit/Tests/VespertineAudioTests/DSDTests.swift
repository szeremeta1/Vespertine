//
// Vespertine — DSD at every rate: DoP from the raw stream (DSF and DSDIFF), and conversion to PCM.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

enum DSDFiles {
    /// A stereo A-major chord (220/277.18/329.63 Hz) through a 2nd-order sigma-delta modulator, as 1-bit
    /// streams per channel (MSB = earliest bit).
    static func modulate(rate: Double, seconds: Double) -> [[UInt8]] {
        let bits = Int(rate * seconds) / 8 * 8
        var out = [[UInt8]](repeating: [UInt8](repeating: 0, count: bits / 8), count: 2)
        var i1 = [0.0, 0.0], i2 = [0.0, 0.0]
        for n in 0..<bits {
            let t = Double(n) / rate
            let x = 0.125 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.18 * t) + sin(2 * .pi * 329.63 * t))
            for c in 0..<2 {
                let v = i2[c] >= 0 ? 1.0 : -1.0
                i1[c] += (c == 1 ? x * 0.9 : x) - v
                i2[c] += i1[c] - 2 * v
                if v > 0 { out[c][n / 8] |= UInt8(0x80 >> (n % 8)) }
            }
        }
        return out
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    private static func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

    /// `channelType`: the DSF format chunk's channel type (2 = stereo, 5 = L R C LFE, 7 = 5.1, …).
    static func writeDSF(_ planes: [[UInt8]], rate: Double, channelType: UInt32 = 2, to url: URL) throws {
        let block = 4096, perCh = planes[0].count, blocks = (perCh + block - 1) / block
        let reversed = planes.map { $0.map { b in var r: UInt8 = 0; for i in 0..<8 where b & (1 << i) != 0 { r |= 0x80 >> i }; return r } }
        var data: [UInt8] = []
        for b in 0..<blocks { for c in 0..<planes.count {
            let s = b * block, e = min(s + block, perCh)
            data += reversed[c][s..<e] + [UInt8](repeating: 0, count: block - (e - s))
        } }
        var out = Array("DSD ".utf8) + le(UInt64(28)) + le(UInt64(28 + 52 + 12 + data.count)) + le(UInt64(0))
        out += Array("fmt ".utf8) + le(UInt64(52)) + le(UInt32(1)) + le(UInt32(0)) + le(channelType) + le(UInt32(planes.count))
        out += le(UInt32(rate)) + le(UInt32(1)) + le(UInt64(perCh * 8)) + le(UInt32(block)) + le(UInt32(0))
        out += Array("data".utf8) + le(UInt64(12 + data.count)) + data
        try Data(out).write(to: url)
    }

    /// `channelIDs`: the CHNL chunk's IDs, one per plane, four characters each.
    static func writeDFF(_ planes: [[UInt8]], rate: Double, channelIDs: [String] = ["SLFT", "SRGT"], to url: URL) throws {
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be(UInt64(body.count)) + body + (body.count % 2 == 1 ? [0] : []) }
        var inter = [UInt8](repeating: 0, count: planes[0].count * planes.count)
        for i in 0..<planes[0].count { for c in 0..<planes.count { inter[i * planes.count + c] = planes[c][i] } }
        let name = Array("not compressed".utf8)
        let prop = Array("SND ".utf8) + chunk("FS  ", be(UInt32(rate))) + chunk("CHNL", be(UInt16(planes.count)) + Array(channelIDs.joined().utf8))
            + chunk("CMPR", Array("DSD ".utf8) + [UInt8(name.count)] + name + [0])
        let body = Array("DSD ".utf8) + chunk("FVER", be(UInt32(0x0105_0000))) + chunk("PROP", prop) + chunk("DSD ", inter)
        try Data(Array("FRM8".utf8) + be(UInt64(body.count)) + body).write(to: url)
    }
}

@Suite("DSD at every rate")
struct DSDTests {
    private func tmp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dsd-\(UUID())-\(name)") }

    private func read(_ decoder: PCMDecoding, frames: Int) throws -> [[Float]] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192)!
        var out = [[Float]](repeating: [], count: Int(decoder.processingFormat.channelCount))
        while out[0].count < frames {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(8192, frames - out[0].count)))
            if buffer.frameLength == 0 { break }
            for c in out.indices { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
        }
        return out
    }

    private func power(_ x: ArraySlice<Float>, _ f: Double, _ rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() { let p = 2 * .pi * f * Double(i) / rate; re += Double(v) * cos(p); im += Double(v) * sin(p) }
        return (re * re + im * im) / Double(x.count * x.count)
    }

    private func dop(_ url: URL) throws -> PCMDecoding {
        let probed = try SourceOpener.probe(url)
        let carrier = FormatPlanner.dopCarrierRate(probed.format.sampleRate)
        return try SourceOpener.decoder(for: probed, plan: OutputPlan(mode: .dop, deviceSampleRate: carrier, decodedSampleRate: carrier,
                                                                      physicalBitDepth: 24, channels: 2, dsdConvertedToPCM: false, reason: ""),
                                        item: PlayableItem(url: url))
    }

    @Test("CUE offsets in DSD source frames open the right region in PCM and DoP", arguments: [false, true])
    func cueRegionUsesDecoderRate(dopMode: Bool) throws {
        let sourceRate = 2_822_400.0
        let url = tmp("cue-64.dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDFiles.writeDSF(DSDFiles.modulate(rate: sourceRate, seconds: 0.5), rate: sourceRate, to: url)
        let probed = try SourceOpener.probe(url)
        let rate = dopMode ? 176_400.0 : 352_800.0
        let plan = OutputPlan(mode: dopMode ? .dop : .pcm, deviceSampleRate: rate, decodedSampleRate: rate,
                              physicalBitDepth: 24, channels: 2, dsdConvertedToPCM: !dopMode, reason: "")
        let item = PlayableItem(url: url, regionStartFrame: Int64(sourceRate / 4), regionFrameLength: Int64(sourceRate / 4))
        let region = try SourceOpener.decoder(for: probed, plan: plan, item: item)
        #expect(region.processingFormat.sampleRate == rate)
        #expect(region.length == Int64(rate / 4))
        #expect(try read(region, frames: Int(rate / 4) + 1024)[0].count == Int(rate / 4))
    }

    @Test("A DSD CUE track deep in the file starts on the right samples (DSF and DSDIFF, PCM and DoP)", arguments: ["dsf", "dff"])
    func deepRegionIsExact(ext: String) throws {
        // Seeks into DSF and DSDIFF jump straight to the packet (vespertine_ff.c indexes it from the file layout)
        // instead of reading from the start of the file; what they land on must be what reading through gives.
        let rate = 2_822_400.0, bytes = Int(rate / 8 * 4)
        let planes = (0..<2).map { c in (0..<bytes).map { i in UInt8(truncatingIfNeeded: (i &* 2_654_435_761 &+ c &* 97 &+ (i >> 13) &* 7) >> 13) } }
        let url = tmp("deep.\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        if ext == "dsf" { try DSDFiles.writeDSF(planes, rate: rate, to: url) } else { try DSDFiles.writeDFF(planes, rate: rate, to: url) }
        let start = Int64(rate * 3.1) / 8 * 8 + 8 * 1_234 + 8   // DSD bits, not on a block boundary
        for dopMode in [false, true] {
            let probed = try SourceOpener.probe(url)
            let decoded = dopMode ? FormatPlanner.dopCarrierRate(rate) : FormatPlanner.dsdToPCMRate(rate)
            let plan = OutputPlan(mode: dopMode ? .dop : .pcm, deviceSampleRate: decoded, decodedSampleRate: decoded,
                                  physicalBitDepth: 24, channels: 2, dsdConvertedToPCM: !dopMode, reason: "")
            let region = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url, regionStartFrame: start))
            let got = try read(region, frames: 2048)
            let first = Int((Double(start) * decoded / rate).rounded())
            let whole = try read(SourceOpener.decoder(for: SourceOpener.probe(url), plan: plan, item: PlayableItem(url: url)), frames: first + 2048)
            #expect(got[0].count == 2048)
            #expect(got[0] == Array(whole[0][first..<first + 2048]) && got[1] == Array(whole[1][first..<first + 2048]), "\(ext) \(dopMode ? "DoP" : "PCM")")
        }
    }

    @Test("A real DSD CUE track opens past track one", .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_REAL_DSD_CUE_FILE"] != nil))
    func realCueRegion() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["VESPERTINE_REAL_DSD_CUE_FILE"]!)
        let start = try #require(Int64(env["VESPERTINE_REAL_DSD_CUE_START"] ?? ""))
        let length = try #require(Int64(env["VESPERTINE_REAL_DSD_CUE_LENGTH"] ?? ""))
        for dopMode in [false, true] {
            let probed = try SourceOpener.probe(url)
            let rate = dopMode ? FormatPlanner.dopCarrierRate(probed.format.sampleRate) : FormatPlanner.dsdToPCMRate(probed.format.sampleRate)
            let plan = OutputPlan(mode: dopMode ? .dop : .pcm, deviceSampleRate: rate, decodedSampleRate: rate,
                                  physicalBitDepth: 24, channels: probed.format.channels, dsdConvertedToPCM: !dopMode, reason: "")
            let region = try SourceOpener.decoder(for: probed, plan: plan,
                                                   item: PlayableItem(url: url, regionStartFrame: start, regionFrameLength: length))
            #expect(region.length > 0)
            #expect(try read(region, frames: 4096)[0].count == 4096)
        }
    }

    @Test("DoP from the raw stream carries the DSD bits exactly, with alternating markers (DSF and DSDIFF)", arguments: ["dsf", "dff"])
    func dopIsExact(ext: String) throws {
        let planes = DSDFiles.modulate(rate: 2_822_400, seconds: 0.5)
        let url = tmp("64.\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        if ext == "dsf" { try DSDFiles.writeDSF(planes, rate: 2_822_400, to: url) } else { try DSDFiles.writeDFF(planes, rate: 2_822_400, to: url) }
        let decoder = try dop(url)
        #expect(decoder.processingFormat.sampleRate == 176_400)
        let frames = try read(decoder, frames: 200_000)
        #expect(frames[0].count == planes[0].count / 2)
        for c in 0..<2 {
            for i in 0..<frames[c].count {
                let word = UInt32(bitPattern: Int32(frames[c][i] * 2_147_483_648)) >> 8
                #expect(word >> 16 == (i % 2 == 0 ? 0x05 : 0xFA))
                #expect(UInt8(word >> 8 & 0xFF) == planes[c][2 * i] && UInt8(word & 0xFF) == planes[c][2 * i + 1])
                if word & 0xFFFF != UInt32(planes[c][2 * i]) << 8 | UInt32(planes[c][2 * i + 1]) {
                    let got = word & 0xFFFF, want = UInt32(planes[c][2 * i]) << 8 | UInt32(planes[c][2 * i + 1])
                    let where_ = (0..<planes[c].count - 1).first { UInt32(planes[c][$0]) << 8 | UInt32(planes[c][$0 + 1]) == got }
                    print("DoP mismatch ch \(c) frame \(i): got \(String(got, radix: 16)) want \(String(want, radix: 16)); got matches byte offset \(where_ as Any)")
                    return
                }
            }
        }
        // Seeking lands on the requested frame, markers still in step.
        try decoder.seek(to: 12_345)
        let after = try read(decoder, frames: 2)
        let word = UInt32(bitPattern: Int32(after[0][0] * 2_147_483_648)) >> 8
        #expect(word >> 16 == 0xFA && UInt8(word >> 8 & 0xFF) == planes[0][24_690])
    }

    @Test("A DoP track that continues another one takes up its marker sequence (never two 0x05 in a row)")
    func dopMarkersContinue() throws {
        let planes = DSDFiles.modulate(rate: 2_822_400, seconds: 0.5)
        let url = tmp("64.dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDFiles.writeDSF(planes, rate: 2_822_400, to: url)
        let decoder = try #require(try dop(url) as? RawDoPDecoder)
        #expect(decoder.nextMarker == 0)
        decoder.nextMarker = 1                  // the track before ended on 0x05
        let frames = try read(decoder, frames: 4)
        for i in 0..<4 {
            let word = UInt32(bitPattern: Int32(frames[0][i] * 2_147_483_648)) >> 8
            #expect(word >> 16 == (i % 2 == 0 ? 0xFA : 0x05))
            #expect(UInt8(word >> 8 & 0xFF) == planes[0][2 * i] && UInt8(word & 0xFF) == planes[0][2 * i + 1])
        }
        #expect(decoder.nextMarker == 1)
    }

    @Test("Every DSD rate converts to PCM with the music intact", arguments: [1.0, 2, 4, 8])
    func toPCM(multiple: Double) throws {
        let rate = 2_822_400 * multiple
        let url = tmp("\(Int(multiple)).dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDFiles.writeDSF(DSDFiles.modulate(rate: rate, seconds: 0.4), rate: rate, to: url)
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.encoding == .dsd && probed.format.sampleRate == rate && probed.format.codec == "DSF")
        let pcmRate = FormatPlanner.dsdToPCMRate(rate)
        let decoder = try SourceOpener.decoder(for: probed, plan: OutputPlan(mode: .pcm, deviceSampleRate: pcmRate, decodedSampleRate: pcmRate,
                                                                             physicalBitDepth: 32, channels: 2, dsdConvertedToPCM: true, reason: ""),
                                               item: PlayableItem(url: url))
        #expect(decoder.processingFormat.sampleRate == pcmRate)
        let pcm = try read(decoder, frames: Int(pcmRate * 0.3))
        let slice = pcm[0][Int(pcmRate * 0.1)..<Int(pcmRate * 0.1) + Int(pcmRate / 20)]
        let chord = [220.0, 277.18, 329.63].map { power(slice, $0, pcmRate) }, off = [150.0, 400, 1000].map { power(slice, $0, pcmRate) }
        #expect(chord.min()! > off.max()! * 20, "chord \(chord) vs \(off)")
    }

    @Test("DSDIFF decodes to the same PCM as DSF")
    func dffMatchesDSF() throws {
        let planes = DSDFiles.modulate(rate: 5_644_800, seconds: 0.2)
        let dsf = tmp("128.dsf"), dff = tmp("128.dff")
        defer { try? FileManager.default.removeItem(at: dsf); try? FileManager.default.removeItem(at: dff) }
        try DSDFiles.writeDSF(planes, rate: 5_644_800, to: dsf)
        try DSDFiles.writeDFF(planes, rate: 5_644_800, to: dff)
        func pcm(_ url: URL) throws -> [[Float]] {
            let p = try SourceOpener.probe(url)
            let d = try SourceOpener.decoder(for: p, plan: OutputPlan(mode: .pcm, deviceSampleRate: 705_600, decodedSampleRate: 705_600, physicalBitDepth: 32,
                                                                      channels: 2, dsdConvertedToPCM: true, reason: ""), item: PlayableItem(url: url))
            return try read(d, frames: 100_000)
        }
        let a = try pcm(dsf), b = try pcm(dff)
        #expect(try SourceOpener.probe(dff).format.codec == "DSDIFF")
        #expect(a[0].count > 100_000 / 2 && a == b)
    }

    /// The speakers a multichannel DSD file's own header names, as the probe, the PCM conversion and DoP all label them.
    private func labels(_ url: URL, channels: Int) throws -> (probe: [AudioChannelLabel]?, pcm: [AudioChannelLabel], dop: [AudioChannelLabel]) {
        let p = try SourceOpener.probe(url)
        let pcmRate = FormatPlanner.dsdToPCMRate(p.format.sampleRate), carrier = FormatPlanner.dopCarrierRate(p.format.sampleRate)
        let pcm = try SourceOpener.decoder(for: p, plan: OutputPlan(mode: .pcm, deviceSampleRate: pcmRate, decodedSampleRate: pcmRate, physicalBitDepth: 32,
                                                                    channels: channels, dsdConvertedToPCM: true, reason: ""), item: PlayableItem(url: url))
        let dop = try SourceOpener.decoder(for: p, plan: OutputPlan(mode: .dop, deviceSampleRate: carrier, decodedSampleRate: carrier, physicalBitDepth: 24,
                                                                    channels: channels, dsdConvertedToPCM: false, reason: ""), item: PlayableItem(url: url))
        return (p.format.channelLabels, pcm.processingFormat.channelLayout?.channelLabels ?? [], dop.processingFormat.channelLayout?.channelLabels ?? [])
    }

    static let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center, LFE = kAudioChannelLabel_LFEScreen
    static let Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround

    // The DSF specification's channel types 3 to 7. FFmpeg's reader calls type 5 (L R C LFE) 4.0 (L R C Cs): the
    // studio evidence run heard the LFE voice labelled as a back centre.
    static let dsfTypes: [(UInt32, [AudioChannelLabel])] = [
        (3, [L, R, C]), (4, [L, R, Ls, Rs]), (5, [L, R, C, LFE]), (6, [L, R, C, Ls, Rs]), (7, [L, R, C, LFE, Ls, Rs]),
    ]
    @Test("DSF: each multichannel channel type is labelled with the speakers the specification gives it", arguments: dsfTypes)
    func dsfChannelTypes(type: UInt32, expected: [AudioChannelLabel]) throws {
        let stereo = DSDFiles.modulate(rate: 2_822_400, seconds: 0.05)
        let planes = (0..<expected.count).map { stereo[$0 % 2] }
        let url = tmp("type\(type).dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDFiles.writeDSF(planes, rate: 2_822_400, channelType: type, to: url)
        let found = try labels(url, channels: expected.count)
        #expect(found.probe == expected)
        #expect(found.pcm == expected)
        #expect(found.dop == expected)
    }

    // DSDIFF names each channel in its CHNL chunk; FFmpeg's reader knows only stereo, 5.0 and 5.1 there and calls a
    // 3.1 file (MLFT MRGT C LFE) quad (L R Ls Rs).
    static let dsdiffIDs: [([String], [AudioChannelLabel])] = [
        (["MLFT", "MRGT", "C   ", "LFE "], [L, R, C, LFE]), (["MLFT", "MRGT", "C   "], [L, R, C]),
        (["MLFT", "MRGT", "LS  ", "RS  "], [L, R, Ls, Rs]), (["MLFT", "MRGT", "C   ", "LFE ", "LS  ", "RS  "], [L, R, C, LFE, Ls, Rs]),
    ]
    @Test("DSDIFF: channels are labelled from the file's CHNL chunk", arguments: dsdiffIDs)
    func dsdiffChannelIDs(ids: [String], expected: [AudioChannelLabel]) throws {
        let stereo = DSDFiles.modulate(rate: 2_822_400, seconds: 0.05)
        let planes = (0..<ids.count).map { stereo[$0 % 2] }
        let url = tmp("\(ids.count)ch.dff")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDFiles.writeDFF(planes, rate: 2_822_400, channelIDs: ids, to: url)
        let found = try labels(url, channels: ids.count)
        #expect(found.probe == expected)
        #expect(found.pcm == expected)
        #expect(found.dop == expected)
    }
}
