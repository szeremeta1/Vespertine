//
// Vespertine — golden PCM: today's output for a fixed set of files and devices, recorded as SHA-256 hashes
// (Fixtures/golden-pcm.json). Any change to what reaches the device for these cases fails here, which is how
// "with transitions off, playback is exactly as before" is shown (docs: verification/CLAIMS.md).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The files are made here with integer arithmetic only, so they're the same bytes on every Mac. Most cases are
// bit-transparent (no resampling, no gain), and those are also checked sample by sample against the source:
// their hashes hold on any Mac. Cases with float processing (resampling, downmix, DSD→PCM, digital volume) are
// compared only on the architecture and macOS major version they were recorded on.
//
// Re-record (only after a change that is meant to change the output, and say so in the pull request):
//   VESPERTINE_GOLDEN_RECORD=1 swift test --filter GoldenPCM
//

import AVFAudio
import CoreAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio
import VespertineLibrary

// MARK: Fixtures

enum GoldenFixtures {
    /// A deterministic xorshift64* generator.
    struct Noise {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
        /// Uniform in -amplitude...amplitude.
        mutating func next(amplitude: Int64) -> Int64 {
            guard amplitude > 0 else { return 0 }
            return Int64(next() % UInt64(2 * amplitude + 1)) - amplitude
        }
    }

    /// A triangle wave of `period` frames between -amplitude and amplitude, in integers.
    static func triangle(_ n: Int, period: Int, amplitude: Int64) -> Int64 {
        let p = Int64(period), m = Int64(n % period)
        return m < p / 2 ? -amplitude + 4 * amplitude * m / p : 3 * amplitude - 4 * amplitude * m / p
    }

    /// Music-like test samples at `bits` (signed, right-aligned), per channel: two triangles and noise at about half
    /// scale, different on every channel, plus both full-scale extremes and a run of exact zeros early on.
    static func samples(frames: Int, channels: Int, bits: Int, seed: UInt64 = 1) -> [[Int32]] {
        let full = Int64(1) << (bits - 1)
        let a = full / 2
        var noise = Noise(state: 0x9E37_79B9_7F4A_7C15 ^ seed)
        var out = [[Int32]](repeating: [Int32](repeating: 0, count: frames), count: channels)
        for n in 0..<frames {
            for c in 0..<channels {
                var v = triangle(n, period: 97 + 13 * c, amplitude: a / 2) + triangle(n, period: 1009 + 31 * c, amplitude: a / 4)
                    + noise.next(amplitude: a / 8)
                switch n {
                case 100: v = -full
                case 101: v = full - 1
                case 200..<264: v = 0
                default: break
                }
                out[c][n] = Int32(v)
            }
        }
        return out
    }

    /// Silence-tail material: the signal for the first `musicFrames`, a −70 dBFS stretch, then digital silence.
    static func silenceTail(frames: Int, musicFrames: Int, channels: Int, bits: Int, seed: UInt64) -> [[Int32]] {
        var s = samples(frames: frames, channels: channels, bits: bits, seed: seed)
        let quiet = max(1, Int64(1) << (bits - 1) / 3162)      // about −70 dBFS
        var noise = Noise(state: seed)
        let quietEnd = musicFrames + (frames - musicFrames) / 4
        for c in 0..<channels {
            for n in musicFrames..<frames { s[c][n] = n < quietEnd ? Int32(noise.next(amplitude: quiet)) : 0 }
        }
        return s
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// A WAV file. Integer samples (right-aligned) or Float32; WAVE_FORMAT_EXTENSIBLE above 16 bits or 2 channels.
    static func writeWAV(ints: [[Int32]]? = nil, floats: [[Float]]? = nil, bits: Int, rate: Int, channelMask: UInt32? = nil, to url: URL) throws {
        let channels = ints?.count ?? floats!.count
        let frames = ints?[0].count ?? floats![0].count
        let bytesPer = bits / 8
        let isFloat = floats != nil
        var data: [UInt8] = []
        data.reserveCapacity(frames * channels * bytesPer)
        for n in 0..<frames {
            for c in 0..<channels {
                if let floats { data += le(floats[c][n].bitPattern) }
                else { let v = UInt32(bitPattern: ints![c][n]); for b in 0..<bytesPer { data.append(UInt8(truncatingIfNeeded: v >> (8 * b))) } }
            }
        }
        let extensible = bits > 16 || channels > 2
        var fmt = le(UInt16(extensible ? 0xFFFE : (isFloat ? 3 : 1))) + le(UInt16(channels)) + le(UInt32(rate))
            + le(UInt32(rate * channels * bytesPer)) + le(UInt16(channels * bytesPer)) + le(UInt16(bits))
        if extensible {
            let mask = channelMask ?? (channels == 1 ? 0x4 : channels == 2 ? 0x3 : 0x3F)
            // KSDATAFORMAT_SUBTYPE_PCM / _IEEE_FLOAT: the format tag, then the fixed GUID tail.
            let guid = le(UInt16(isFloat ? 3 : 1)) + [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
            fmt += le(UInt16(22)) + le(UInt16(bits)) + le(mask) + guid
        }
        var file = Array("RIFF".utf8) + le(UInt32(4 + 8 + fmt.count + 8 + data.count)) + Array("WAVE".utf8)
        file += Array("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
        file += Array("data".utf8) + le(UInt32(data.count)) + data
        try Data(file).write(to: url)
    }

    /// DSD planes (MSB first) from a first-order sigma-delta modulator on integer triangles, a different one per channel.
    static func dsdPlanes(bits: Int, channels: Int, seed: Int) -> [[UInt8]] {
        let full: Int64 = 1 << 24
        var out = [[UInt8]](repeating: [UInt8](repeating: 0, count: bits / 8), count: channels)
        var acc = [Int64](repeating: 0, count: channels)
        for n in 0..<bits {
            for c in 0..<channels {
                let x = triangle(n, period: 2822 + 211 * c + 17 * seed, amplitude: full / 4) + triangle(n, period: 64_007 + 977 * c, amplitude: full / 8)
                let one = acc[c] >= 0
                acc[c] += x - (one ? full : -full)
                if one { out[c][n / 8] |= UInt8(0x80 >> (n % 8)) }
            }
        }
        return out
    }

    /// Splits per-channel samples at `frame`.
    static func split(_ s: [[Int32]], at frame: Int) -> ([[Int32]], [[Int32]]) {
        (s.map { Array($0[..<frame]) }, s.map { Array($0[frame...]) })
    }

    static func joined(_ parts: [[[Int32]]]) -> [[Int32]] {
        (0..<parts[0].count).map { c in parts.flatMap { $0[c] } }
    }
}

// MARK: Devices

enum GoldenDevices {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    private static func format(_ bits: Int, integer: Bool = true, mixable: Bool = true, channels: Int = 2,
                               rates: [Double] = GoldenDevices.rates) -> PhysicalFormat {
        PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: bits, isInteger: integer, isMixable: mixable, channels: channels)
    }

    private static func device(_ name: String, rates: [Double] = GoldenDevices.rates, formats: [PhysicalFormat], channels: Int = 2,
                               dop: Bool = false, bitstream: Bool = false) -> GoldenRender.Device {
        GoldenRender.Device(name: name, capabilities: DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: channels, supportsDoP: dop),
                            streamChannels: channels, bitstream: bitstream)
    }

    /// A typical USB DAC: 24-bit, 44.1 to 192 kHz.
    static let dac = device("USB DAC", formats: [format(24)])
    /// A DAC with a non-mixable 32-bit integer mode and a real 16-bit mode (integer mode, "Match 16-bit sources").
    static let integerDAC = device("Integer DAC", formats: [format(24), format(32, mixable: false), format(16)])
    /// A DAC confirmed for DoP.
    static let dopDAC = device("DoP DAC", formats: [format(24)], dop: true)
    /// Six outputs with no speaker setup: multichannel goes out discretely in standard order.
    static let sixOut = device("Six-channel interface", formats: [format(24, channels: 6)], channels: 6)
    /// An output with an AV receiver that decodes Dolby and DTS.
    static let receiver = device("Receiver", formats: [format(24), format(16)], bitstream: true)
    /// An output that only runs at 48 kHz (everything else is resampled).
    static let only48 = device("48 kHz only", rates: [48_000], formats: [format(24, rates: [48_000])])
}

// MARK: Cases

struct GoldenCase: Sendable, CustomStringConvertible {
    let name: String
    /// Bit-transparent: the hash is the same on every Mac (no float processing beyond exact conversions).
    let portable: Bool
    let summary: String
    var description: String { name }

    static let all: [GoldenCase] = [
        .init(name: "gapless-album-flac-16-44k1", portable: true, summary: "two FLAC tracks of one album, split mid-chunk, joined gaplessly"),
        .init(name: "rate-44k1-24", portable: true, summary: "24-bit stereo WAV at 44.1 kHz"),
        .init(name: "rate-48k-24", portable: true, summary: "24-bit stereo WAV at 48 kHz"),
        .init(name: "rate-96k-24", portable: true, summary: "24-bit stereo WAV at 96 kHz"),
        .init(name: "rate-change-queue", portable: true, summary: "44.1 → 48 → 96 kHz: three device formats, reconfigured between"),
        .init(name: "mono-16-48k", portable: true, summary: "16-bit mono, sent to both channels"),
        .init(name: "surround-51-24-48k-discrete", portable: true, summary: "5.1 WAV to six discrete outputs"),
        .init(name: "surround-51-24-48k-downmix", portable: false, summary: "5.1 WAV downmixed to a stereo DAC"),
        .init(name: "int16-44k1", portable: true, summary: "16-bit stereo, zero-padded to the DAC's 24"),
        .init(name: "int16-44k1-matched", portable: true, summary: "16-bit stereo, \"Match 16-bit sources\" on a DAC with a 16-bit mode"),
        .init(name: "int32-96k-float-path", portable: true, summary: "32-bit integer WAV through the float path"),
        .init(name: "int32-96k-integer-mode", portable: true, summary: "32-bit integer WAV in integer mode (words untouched)"),
        .init(name: "float32-48k", portable: true, summary: "32-bit float WAV, including values over full scale"),
        .init(name: "dop-dsd64", portable: true, summary: "DSD64 DSF as DoP at 176.4 kHz"),
        .init(name: "dop-dsd64-gapless-pair", portable: true, summary: "two DSD64 DSF tracks joined as DoP (markers keep alternating)"),
        .init(name: "dsd64-to-pcm", portable: false, summary: "DSD64 DSF converted to PCM on a DAC without DoP"),
        .init(name: "bitstream-ac3", portable: true, summary: "Dolby Digital sent to a receiver as IEC 61937"),
        .init(name: "bitstream-dts-cd", portable: true, summary: "a DTS CD (DTS in a 16-bit WAV) sent to a receiver as stored"),
        .init(name: "cue-3-tracks-16-44k1", portable: true, summary: "one WAV split into three tracks by a CUE sheet, played in order"),
        .init(name: "silence-tail-pair", portable: true, summary: "a track ending in −70 dBFS then digital silence, then one starting silent"),
        .init(name: "replaygain-minus-6", portable: true, summary: "24/48 with −6 dB ReplayGain (applied before the ring)"),
        .init(name: "digital-volume-minus-10", portable: false, summary: "24/48 at −10 dB digital volume (gain and TPDF dither in the I/O proc)"),
        .init(name: "src-44k1-on-48k-only", portable: false, summary: "44.1 kHz on a 48 kHz-only output (resampled)"),
    ]
}

/// What a case played, and what the bit-transparent ones must have delivered.
struct GoldenRun {
    var output: GoldenRender.Output
    /// Per session: the source samples expected on the device (right-aligned at `bits`), or nil when not checked.
    var expected: [(samples: [[Int32]], bits: Int)?] = []
    var expectedFloats: [[Float]]?
}

enum GoldenCases {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-golden-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    static func wav(_ name: String, _ s: [[Int32]], bits: Int, rate: Int) throws -> URL {
        let url = file(name)
        try GoldenFixtures.writeWAV(ints: s, bits: bits, rate: rate, to: url)
        return url
    }

    static func item(_ url: URL, start: Int64? = nil, length: Int64? = nil, replayGain: Double? = nil) -> PlayableItem {
        // A fixed id: nothing in the output may depend on it, and a run is then the same every time.
        PlayableItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, url: url,
                     regionStartFrame: start, regionFrameLength: length, replayGainDB: replayGain)
    }

    static func run(_ c: GoldenCase) throws -> GoldenRun {
        typealias R = GoldenRender
        switch c.name {
        case "gapless-album-flac-16-44k1":
            let s = GoldenFixtures.samples(frames: 30_000, channels: 2, bits: 16, seed: 11)
            let (a, b) = GoldenFixtures.split(s, at: 12_345)
            var flacs: [URL] = []
            for (i, part) in [a, b].enumerated() {
                let w = try wav("album-\(i).wav", part, bits: 16, rate: 44_100)
                let f = file("album-\(i).flac")
                try AudioConverter.convert(w, to: f)
                flacs.append(f)
            }
            return GoldenRun(output: try R.render(flacs.map { item($0) }, device: GoldenDevices.dac), expected: [(s, 16)])
        case "rate-44k1-24", "rate-48k-24", "rate-96k-24":
            let rate = ["rate-44k1-24": 44_100, "rate-48k-24": 48_000, "rate-96k-24": 96_000][c.name]!
            let s = GoldenFixtures.samples(frames: rate / 4, channels: 2, bits: 24, seed: UInt64(rate))
            return GoldenRun(output: try R.render([item(try wav("\(c.name).wav", s, bits: 24, rate: rate))], device: GoldenDevices.dac),
                             expected: [(s, 24)])
        case "rate-change-queue":
            var urls: [URL] = [], expected: [(samples: [[Int32]], bits: Int)?] = []
            for rate in [44_100, 48_000, 96_000] {
                let s = GoldenFixtures.samples(frames: rate / 5, channels: 2, bits: 24, seed: UInt64(rate) + 1)
                urls.append(try wav("queue-\(rate).wav", s, bits: 24, rate: rate))
                expected.append((s, 24))
            }
            return GoldenRun(output: try R.render(urls.map { item($0) }, device: GoldenDevices.dac), expected: expected)
        case "mono-16-48k":
            let s = GoldenFixtures.samples(frames: 12_000, channels: 1, bits: 16, seed: 3)
            return GoldenRun(output: try R.render([item(try wav("mono.wav", s, bits: 16, rate: 48_000))], device: GoldenDevices.dac),
                             expected: [(s, 16)])
        case "surround-51-24-48k-discrete", "surround-51-24-48k-downmix":
            let s = GoldenFixtures.samples(frames: 12_000, channels: 6, bits: 24, seed: 51)
            let url = try wav("\(c.name).wav", s, bits: 24, rate: 48_000)
            let discrete = c.name.hasSuffix("discrete")
            return GoldenRun(output: try R.render([item(url)], device: discrete ? GoldenDevices.sixOut : GoldenDevices.dac),
                             expected: [discrete ? (s, 24) : nil])
        case "int16-44k1", "int16-44k1-matched":
            let s = GoldenFixtures.samples(frames: 20_000, channels: 2, bits: 16, seed: 16)
            let matched = c.name.hasSuffix("matched")
            var settings = R.Settings()
            settings.matchSixteenBit = matched
            let out = try R.render([item(try wav("\(c.name).wav", s, bits: 16, rate: 44_100))],
                                   device: matched ? GoldenDevices.integerDAC : GoldenDevices.dac, settings: settings)
            return GoldenRun(output: out, expected: [(s, 16)])
        case "int32-96k-float-path", "int32-96k-integer-mode":
            let s = GoldenFixtures.samples(frames: 24_000, channels: 2, bits: 32, seed: 32)
            let integer = c.name.hasSuffix("integer-mode")
            var settings = R.Settings()
            settings.integerMode = integer
            let out = try R.render([item(try wav("\(c.name).wav", s, bits: 32, rate: 96_000))],
                                   device: integer ? GoldenDevices.integerDAC : GoldenDevices.dac, settings: settings)
            return GoldenRun(output: out, expected: [integer ? (s, 32) : nil])
        case "float32-48k":
            let s = GoldenFixtures.samples(frames: 12_000, channels: 2, bits: 24, seed: 33)
            var floats = s.map { $0.map { Float($0) / Float(1 << 23) } }
            floats[0][300] = 1.5; floats[1][300] = -1.25; floats[0][301] = 0.1; floats[1][301] = .leastNonzeroMagnitude
            let url = file("float.wav")
            try GoldenFixtures.writeWAV(floats: floats, bits: 32, rate: 48_000, to: url)
            var run = GoldenRun(output: try R.render([item(url)], device: GoldenDevices.dac))
            run.expectedFloats = floats
            return run
        case "dop-dsd64", "dop-dsd64-gapless-pair", "dsd64-to-pcm":
            let count = c.name == "dop-dsd64-gapless-pair" ? 2 : 1
            var urls: [URL] = []
            for i in 0..<count {
                let url = file("\(c.name)-\(i).dsf")
                // About 0.3 s; the first is an odd number of DoP frames (16 bits each), so the second starts on an odd frame.
                let bits = 846_720 + (i == 0 ? 16 : 0)
                try DSDFiles.writeDSF(GoldenFixtures.dsdPlanes(bits: bits, channels: 2, seed: i), rate: 2_822_400, to: url)
                urls.append(url)
            }
            return GoldenRun(output: try R.render(urls.map { item($0) }, device: c.name == "dsd64-to-pcm" ? GoldenDevices.dac : GoldenDevices.dopDAC))
        case "bitstream-ac3":
            return GoldenRun(output: try R.render([item(fixture("dolby-digital-tones.ac3"))], device: GoldenDevices.receiver))
        case "bitstream-dts-cd":
            return GoldenRun(output: try R.render([item(fixture("dts-cd-tones.wav"))], device: GoldenDevices.receiver))
        case "cue-3-tracks-16-44k1":
            // 2 s of CD audio, tracks at 0, 0:00:37 and 0:01:12 (CD frames of 1/75 s).
            let s = GoldenFixtures.samples(frames: 88_200, channels: 2, bits: 16, seed: 75)
            let url = try wav("album.wav", s, bits: 16, rate: 44_100)
            let cueText = "PERFORMER \"Golden\"\nTITLE \"Golden\"\nFILE \"album.wav\" WAVE\n"
                + "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:00:37\n  TRACK 03 AUDIO\n    INDEX 01 00:01:12\n"
            let cue = CueSheet.parse(cueText)
            let entries = try #require(cue.files.first?.tracks)
            #expect(entries.count == 3)
            // As LibraryScanner splits a file by its sheet: each track runs to the next one's start, the last to the end.
            let starts = entries.map { CueSheet.sampleFrame(cdFrames: $0.startCDFrames, sampleRate: 44_100) }
            let items = starts.indices.map { i in
                item(url, start: starts[i], length: (i + 1 < starts.count ? starts[i + 1] : Int64(s[0].count)) - starts[i])
            }
            return GoldenRun(output: try R.render(items, device: GoldenDevices.dac), expected: [(s, 16)])
        case "silence-tail-pair":
            let a = GoldenFixtures.silenceTail(frames: 30_000, musicFrames: 14_000, channels: 2, bits: 24, seed: 5)
            var b = GoldenFixtures.samples(frames: 20_000, channels: 2, bits: 24, seed: 6)
            for c in 0..<2 { for n in 0..<6_000 { b[c][n] = 0 } }
            let urls = [try wav("tail-a.wav", a, bits: 24, rate: 48_000), try wav("tail-b.wav", b, bits: 24, rate: 48_000)]
            return GoldenRun(output: try R.render(urls.map { item($0) }, device: GoldenDevices.dac),
                             expected: [(GoldenFixtures.joined([a, b]), 24)])
        case "replaygain-minus-6":
            let s = GoldenFixtures.samples(frames: 12_000, channels: 2, bits: 24, seed: 66)
            return GoldenRun(output: try R.render([item(try wav("rg.wav", s, bits: 24, rate: 48_000), replayGain: -6)], device: GoldenDevices.dac))
        case "digital-volume-minus-10":
            let s = GoldenFixtures.samples(frames: 12_000, channels: 2, bits: 24, seed: 10)
            var settings = R.Settings()
            settings.digitalVolumeDB = -10
            return GoldenRun(output: try R.render([item(try wav("dv.wav", s, bits: 24, rate: 48_000))], device: GoldenDevices.dac, settings: settings))
        case "src-44k1-on-48k-only":
            let s = GoldenFixtures.samples(frames: 11_025, channels: 2, bits: 24, seed: 441)
            return GoldenRun(output: try R.render([item(try wav("src.wav", s, bits: 24, rate: 44_100))], device: GoldenDevices.only48))
        default:
            throw GoldenRender.Failure(description: "unknown case \(c.name)")
        }
    }
}

// MARK: The record

struct GoldenRecord: Codable {
    struct Entry: Codable {
        var sha256: String
        var portable: Bool
        var sessions: [String]
        var summary: String
    }
    /// Where the platform-dependent hashes were recorded: "<arch> macOS <major>".
    var recordedOn: String
    var cases: [String: Entry]

    static var environment: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "\(arch) macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    }

    static let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden-pcm.json")

    static func load() throws -> GoldenRecord {
        try JSONDecoder().decode(GoldenRecord.self, from: Data(contentsOf: Bundle.module.url(forResource: "golden-pcm", withExtension: "json", subdirectory: "Fixtures")!))
    }

    static let recording = ProcessInfo.processInfo.environment["VESPERTINE_GOLDEN_RECORD"] == "1"
    static let recorded = Locked([String: Entry]())
}

// MARK: Tests

@Suite("Golden PCM", .serialized)
struct GoldenPCMTests {
    /// Checks the device words of a bit-transparent session against the source samples.
    private func check(_ session: GoldenRender.SessionOutput, against expected: [[Int32]], bits: Int, name: String) {
        let channels = expected.count, out = session.streamChannels
        #expect(session.frames == expected[0].count, "\(name): \(session.frames) frames on the device, \(expected[0].count) in the source")
        var wrong = 0, first: Int?
        for f in 0..<min(session.frames, expected[0].count) {
            for c in 0..<out {
                let from = channels == 1 && c == 1 ? 0 : c          // vespertine_rt.c source_channel: mono to both
                let word = session.words[f * out + c]
                let ok: Bool
                if session.integerMode {
                    ok = from < channels && word == UInt32(bitPattern: expected[from][f] << Int32(32 - bits))
                } else {
                    ok = from < channels ? Float(bitPattern: word) == Float(expected[from][f]) / Float(1 << (bits - 1)) : word == 0
                }
                if !ok { wrong += 1; if first == nil { first = f } }
            }
        }
        #expect(wrong == 0, "\(name): \(wrong) samples differ from the source, the first at frame \(first ?? -1)")
    }

    @Test("Today's output, byte for byte", arguments: GoldenCase.all)
    func golden(_ c: GoldenCase) throws {
        let run = try GoldenCases.run(c)
        let output = run.output
        #expect(!output.sessions.isEmpty && output.sessions.allSatisfy { $0.frames > 0 }, "\(c.name): nothing reached the device")
        // The bit-transparent cases: every sample is the source's, so the hash is of the right thing.
        if !run.expected.isEmpty {
            #expect(run.expected.count == output.sessions.count, "\(c.name): \(output.sessions.count) device formats, \(run.expected.count) expected")
            for (session, expected) in zip(output.sessions, run.expected) {
                if let expected { check(session, against: expected.samples, bits: expected.bits, name: c.name) }
            }
        }
        if let floats = run.expectedFloats, let session = output.sessions.first {
            let words = floats[0].indices.flatMap { f in floats.indices.map { floats[$0][f].bitPattern } }
            #expect(session.words == words, "\(c.name): float samples changed on the way")
        }
        let entry = GoldenRecord.Entry(sha256: output.sha256, portable: c.portable, sessions: output.sessions.map { $0.header.trimmingCharacters(in: .newlines) },
                                       summary: c.summary)
        if GoldenRecord.recording {
            GoldenRecord.recorded.withLock { $0[c.name] = entry }
            return
        }
        let record = try GoldenRecord.load()
        let stored = try #require(record.cases[c.name], "\(c.name) has no recorded hash (VESPERTINE_GOLDEN_RECORD=1 to record)")
        #expect(stored.sessions == entry.sessions, "\(c.name): device formats changed")
        if c.portable || record.recordedOn == GoldenRecord.environment {
            #expect(stored.sha256 == entry.sha256, "\(c.name): output changed (\(entry.sha256), recorded \(stored.sha256))")
        } else {
            print("Golden PCM: \(c.name) uses float processing recorded on \(record.recordedOn); not compared on \(GoldenRecord.environment)")
        }
    }

    @Test("Every case is recorded, and nothing else", .enabled(if: !GoldenRecord.recording))
    func complete() throws {
        let record = try GoldenRecord.load()
        #expect(Set(record.cases.keys) == Set(GoldenCase.all.map(\.name)))
        #expect(record.cases.values.allSatisfy { $0.sha256.count == 64 })
    }

    @Test("Rendering twice gives the same bytes")
    func deterministic() throws {
        for c in GoldenCase.all where ["gapless-album-flac-16-44k1", "dop-dsd64-gapless-pair", "digital-volume-minus-10", "src-44k1-on-48k-only"].contains(c.name) {
            #expect(try GoldenCases.run(c).output.sha256 == GoldenCases.run(c).output.sha256, "\(c.name)")
        }
    }

    /// Writes Fixtures/golden-pcm.json when recording (runs after the cases: the suite is serialized).
    @Test("Record", .enabled(if: GoldenRecord.recording))
    func writeRecord() throws {
        for c in GoldenCase.all where GoldenRecord.recorded.withLock({ $0[c.name] == nil }) { try golden(c) }
        let record = GoldenRecord(recordedOn: GoldenRecord.environment, cases: GoldenRecord.recorded.withLock { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: GoldenRecord.sourceURL)
        print("Golden PCM: recorded \(record.cases.count) cases on \(record.recordedOn) to \(GoldenRecord.sourceURL.path)")
    }
}
