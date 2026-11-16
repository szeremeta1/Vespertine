//
// Vespertine: a DSD file as bytes the phone's player opens. The player reads a song as a file Core Audio knows, a range at
// a time; this answers those reads for a DSF or DSDIFF file with a CAF file that is never stored anywhere: each range is
// worked out from the DSD it covers, when it is asked for. Two forms:
//
// - DoP, for a DAC that passed the DoP test: the file's own DSD bits, 16 to a 24-bit sample behind the marker byte (DoP 1.1),
//   at a sixteenth of the DSD rate. Nothing is computed: the bits are only moved.
// - PCM, for everything else: the DSD filtered down to a PCM rate of its family (176.4 kHz for DSD64 unless the output runs
//   lower), 24-bit.
//
// A range is the same bytes however the reads are cut up, so a seek, a retry and a second play all get the same file.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// Plain Swift and Foundation: the tests pin it anywhere.
//

import Foundation

public struct DSDRendering: Equatable, Sendable {
    public enum Form: String, Equatable, Sendable {
        case dop
        case pcm
    }

    /// DSD silence (the idle pattern 0x69: as many ones as zeros).
    public static let silence: UInt8 = 0x69
    /// Each byte with its bits in the opposite order.
    static let reversed: [UInt8] = (0..<256).map { value in
        var out = 0
        for bit in 0..<8 where value & (1 << bit) != 0 { out |= 0x80 >> bit }
        return UInt8(out)
    }
    /// The CAF header before the samples.
    public static let headerSize = CAFHeader.size
    /// The highest PCM rate a conversion makes unless the output is said to take more (as the Mac's conversions).
    public static let defaultCeiling = 192_000.0
    /// The most of the file asked for in one read.
    static let largestFetch = 1 << 20

    public let layout: DSDLayout
    public let form: Form
    /// The rate of the samples: the DoP carrier rate, or the PCM rate.
    public let sampleRate: Double
    public let frames: Int64

    public var channels: Int { layout.channels }
    public var byteSize: Int64 { Int64(Self.headerSize) + frames * Int64(channels * 3) }

    // MARK: Choosing the form

    /// The DoP carrier rate for a DSD rate: 16 bits a frame.
    public static func carrier(dsdRate: Int) -> Double { Double(dsdRate) / 16 }

    /// The PCM rate DSD is converted to: a rate of its family (44.1 or 48 kHz times a power of two), no higher than the
    /// output's ceiling (192 kHz when it names none) and no lower than the family's base. The Mac's rule.
    public static func pcmRate(dsdRate: Int, ceiling: Double?) -> Double {
        let family = dsdRate % 44_100 == 0 ? 44_100.0 : 48_000.0
        let reach = Double(dsdRate) / 8
        let limit = min(reach, ceiling ?? defaultCeiling)
        var rate = family
        while rate * 2 <= limit + 0.5 { rate *= 2 }
        return rate
    }

    /// DSD rates the conversion handles: 64, 128, 256… times 44.1 or 48 kHz.
    public static func isRegular(dsdRate: Int) -> Bool {
        for family in [44_100, 48_000] where dsdRate % family == 0 {
            let times = dsdRate / family
            if times >= 64, times & (times - 1) == 0 { return true }
        }
        return false
    }

    /// How a file is given to the player. DoP when the output takes it up to the carrier rate `dop` (nil: it takes none),
    /// the file is stereo, and it isn't being kept in its smaller form; PCM otherwise, at `pcmRate`. nil for a file the
    /// phone doesn't play by itself.
    public static func plan(_ layout: DSDLayout, maxSampleRate: Double?, smaller: Bool = false, dop: Double? = nil) -> DSDRendering? {
        guard layout.playsHere, isRegular(dsdRate: layout.dsdRate) else { return nil }
        if let dop, !smaller, layout.channels == 2, carrier(dsdRate: layout.dsdRate) <= dop + 0.5 {
            // A whole number of marker pairs: an odd last frame is followed by one of DSD silence.
            let frames = (layout.bytesPerChannel + 1) / 2
            return DSDRendering(layout: layout, form: .dop, sampleRate: carrier(dsdRate: layout.dsdRate), frames: frames + frames % 2)
        }
        let rate = pcmRate(dsdRate: layout.dsdRate, ceiling: maxSampleRate)
        var frames = layout.bytesPerChannel
        for _ in 0..<DSDDecimator.halvings(dsdRate: layout.dsdRate, pcmRate: rate) { frames = (frames + 1) / 2 }
        return DSDRendering(layout: layout, form: .pcm, sampleRate: rate, frames: frames)
    }

    // MARK: The bytes

    /// The CAF header: big-endian 24-bit PCM. CAF, because its sizes are 64-bit (an hour of DSD128 as DoP is past WAV's 4 GB).
    public var header: [UInt8] { CAFHeader.bytes(sampleRate: sampleRate, channels: channels, sampleBytes: 3, float: false, frames: frames) }

    /// Up to `length` bytes of the file from `offset`; fewer only at its end. `fetch` reads a range of the DSD file.
    public func read(offset: Int64, length: Int, fetch: (Int64, Int) throws -> Data) throws -> Data {
        guard offset >= 0, offset < byteSize, length > 0 else { return Data() }
        let end = min(byteSize, offset + Int64(length))
        var out = Data(capacity: Int(end - offset))
        let head = Int64(Self.headerSize)
        if offset < head {
            let header = header
            out.append(contentsOf: header[Int(offset)..<Int(min(end, head))])
        }
        guard end > head else { return out }
        let frameBytes = Int64(channels * 3)
        let from = max(offset, head) - head, to = end - head
        let first = from / frameBytes, last = (to + frameBytes - 1) / frameBytes
        let samples = try form == .dop ? dop(first..<last, fetch) : pcm(first..<last, fetch)
        let skip = Int(from - first * frameBytes)
        out.append(contentsOf: samples[skip..<(skip + Int(to - from))])
        return out
    }

    /// Bytes `range` of every channel, the oldest bit the highest; DSD silence where the file has none (before its start,
    /// past its end).
    private func planes(_ range: Range<Int64>, _ fetch: (Int64, Int) throws -> Data) throws -> [[UInt8]] {
        let lower = min(max(range.lowerBound, 0), layout.bytesPerChannel), upper = min(max(range.upperBound, lower), layout.bytesPerChannel)
        var held: [[UInt8]] = []
        if upper > lower {
            let place = layout.fileRange(lower..<upper)
            var data = Data(capacity: place.length)
            while data.count < place.length {
                let piece = try fetch(place.offset + Int64(data.count), min(Self.largestFetch, place.length - data.count))
                if piece.isEmpty { break }
                data.append(piece)
            }
            held = layout.planes(data, lower..<upper)
        }
        let before = Int(lower - range.lowerBound), after = Int(range.upperBound - upper)
        guard before > 0 || after > 0 || held.isEmpty else { return held }
        return (0..<channels).map { channel in
            [UInt8](repeating: Self.silence, count: before) + (held.isEmpty ? [] : held[channel]) + [UInt8](repeating: Self.silence, count: after)
        }
    }

    /// One 24-bit DoP word as its three bytes: the marker (0x05 on even frames, 0xFA on odd ones), then 16 DSD bits.
    static func marker(frame: Int64) -> UInt8 { frame & 1 == 0 ? 0x05 : 0xFA }

    private func dop(_ frames: Range<Int64>, _ fetch: (Int64, Int) throws -> Data) throws -> [UInt8] {
        let planes = try planes((frames.lowerBound * 2)..<(frames.upperBound * 2), fetch)
        var out = [UInt8](repeating: 0, count: frames.count * channels * 3)
        var at = 0
        for index in 0..<frames.count {
            let marker = Self.marker(frame: frames.lowerBound + Int64(index))
            for channel in 0..<channels {
                out[at] = marker
                out[at + 1] = planes[channel][2 * index]
                out[at + 2] = planes[channel][2 * index + 1]
                at += 3
            }
        }
        return out
    }

    private func pcm(_ frames: Range<Int64>, _ fetch: (Int64, Int) throws -> Data) throws -> [UInt8] {
        let decimator = DSDDecimator.shared(dsdRate: layout.dsdRate, pcmRate: sampleRate)
        let need = decimator.bytesNeeded(for: frames)
        let planes = try planes(need, fetch)
        var out = [UInt8](repeating: 0, count: frames.count * channels * 3)
        for channel in 0..<channels {
            let samples = decimator.convert(planes[channel], frames: frames, length: layout.bytesPerChannel)
            var at = channel * 3
            for sample in samples {
                let value = Int32(max(-8_388_608, min(8_388_607, (sample * 8_388_608).rounded())))
                out[at] = UInt8(truncatingIfNeeded: value >> 16)
                out[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
                out[at + 2] = UInt8(truncatingIfNeeded: value)
                at += channels * 3
            }
        }
        return out
    }
}

/// DSD to PCM: a low-pass filter over the DSD bits that gives one sample for every eight of them, then as many halvings
/// of the rate as the PCM rate needs, each behind a low-pass filter of its own. All of them are linear-phase FIR filters
/// (Kaiser windows, 110 dB down past the band where a fold would land on what can be heard), so a sample depends only on
/// the DSD around its own moment: any stretch of the song can be worked out by itself.
///
/// The level is the Mac's: +6 dB, the SACD convention (a full-scale sine in DSD is half of what the bits could carry), with
/// anything louder held at full scale.
final class DSDDecimator: Sendable {
    /// How far down the filters' stopbands are, in dB.
    static let attenuation = 110.0
    /// DSD bytes the first filter spans (eight taps each).
    static let firstSpan = 24
    static let gain = 2.0

    /// 256 sums for each byte the first filter spans: what that byte adds to a sample, for each value it can have.
    private let table: [Double]
    /// The halving filters, in the order they run. Each has an odd number of taps.
    let halves: [[Double]]

    static func halvings(dsdRate: Int, pcmRate: Double) -> Int {
        var count = 0
        var rate = Double(dsdRate) / 8
        while rate > pcmRate + 0.5, count < 16 { rate /= 2; count += 1 }
        return count
    }

    /// The band kept flat for a PCM rate: all that can be heard, and twice that where the rate has the room.
    static func kept(pcmRate: Double) -> Double { pcmRate > 100_000 ? 40_000 : 20_000 }

    private static let made = Made()
    private final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String: DSDDecimator] = [:]
        func get(_ dsdRate: Int, _ pcmRate: Double) -> DSDDecimator {
            let key = "\(dsdRate)/\(Int(pcmRate))"
            return lock.withLock {
                if let have = all[key] { return have }
                let new = DSDDecimator(dsdRate: dsdRate, pcmRate: pcmRate)
                all[key] = new
                return new
            }
        }
    }

    static func shared(dsdRate: Int, pcmRate: Double) -> DSDDecimator { made.get(dsdRate, pcmRate) }

    init(dsdRate: Int, pcmRate: Double) {
        let kept = Self.kept(pcmRate: pcmRate)
        let taps = Self.firstSpan * 8
        // The first filter: flat to `kept`, down by the width its length allows after that; far below the first fold.
        let width = (Self.attenuation - 7.95) / (14.36 * Double(taps))
        let first = Self.lowpass(taps: taps, cutoff: kept / Double(dsdRate) + width / 2).map { $0 * Self.gain }
        var table = [Double](repeating: 0, count: Self.firstSpan * 256)
        for byte in 0..<Self.firstSpan {
            for value in 0..<256 {
                var sum = 0.0
                for bit in 0..<8 { sum += value & (0x80 >> bit) != 0 ? first[byte * 8 + bit] : -first[byte * 8 + bit] }
                table[byte * 256 + value] = sum
            }
        }
        self.table = table
        // Each halving: flat to `kept`, down where a fold would land on it.
        var halves: [[Double]] = []
        var rate = Double(dsdRate) / 8
        for _ in 0..<Self.halvings(dsdRate: dsdRate, pcmRate: pcmRate) {
            let out = rate / 2
            let transition = (out - 2 * kept) / rate
            let count = Int(((Self.attenuation - 7.95) / (14.36 * transition)).rounded(.up)) | 1
            halves.append(Self.lowpass(taps: count + 2, cutoff: 0.25))
            rate = out
        }
        self.halves = halves
    }

    /// A Kaiser-windowed low-pass filter; `cutoff` in cycles a sample. Its taps add up to one.
    static func lowpass(taps: Int, cutoff: Double) -> [Double] {
        let beta = 0.1102 * (attenuation - 8.7)
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > sum * 1e-18 {
                term *= (x / 2 / k) * (x / 2 / k)
                sum += term
                k += 1
            }
            return sum
        }
        let middle = Double(taps - 1) / 2
        var out = (0..<taps).map { index -> Double in
            let t = Double(index) - middle
            let ideal = t == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * t) / (Double.pi * t)
            let x = middle > 0 ? t / middle : 0
            return ideal * bessel(beta * (1 - x * x).squareRoot()) / bessel(beta)
        }
        let sum = out.reduce(0, +)
        for index in out.indices { out[index] /= sum }
        return out
    }

    /// The DSD bytes (of one channel) that PCM frames `frames` are worked out from. May start before 0 and end past the
    /// file's end: silence there.
    func bytesNeeded(for frames: Range<Int64>) -> Range<Int64> {
        let first = firstStage(for: frames)
        return (first.lowerBound - Int64(Self.firstSpan / 2))..<(first.upperBound + Int64(Self.firstSpan / 2))
    }

    /// The samples of each stage that `frames` (of the last one) need, the first stage's first.
    private func stages(for frames: Range<Int64>) -> [Range<Int64>] {
        var ranges = [frames]
        for taps in halves.reversed() {
            let reach = Int64(taps.count / 2), out = ranges[0]
            ranges.insert((2 * out.lowerBound - reach)..<(2 * (out.upperBound - 1) + reach + 1), at: 0)
        }
        return ranges
    }

    private func firstStage(for frames: Range<Int64>) -> Range<Int64> { stages(for: frames)[0] }

    /// PCM frames `frames` of one channel. `bytes`: that channel's DSD bytes `bytesNeeded(for: frames)`. `length`: how
    /// many bytes the channel has in all (samples before the song's start and past its end are silence).
    func convert(_ bytes: [UInt8], frames: Range<Int64>, length: Int64) -> [Double] {
        guard !frames.isEmpty else { return [] }
        let ranges = stages(for: frames)
        let span = Self.firstSpan
        var range = ranges[0]
        var current = [Double](repeating: 0, count: range.count)
        bytes.withUnsafeBufferPointer { bytes in
            table.withUnsafeBufferPointer { table in
                current.withUnsafeMutableBufferPointer { out in
                    for index in 0..<out.count {
                        let sample = range.lowerBound + Int64(index)
                        guard sample >= 0, sample < length else { continue }
                        var sum = 0.0
                        for byte in 0..<span { sum += table[byte * 256 + Int(bytes[index + byte])] }
                        out[index] = sum
                    }
                }
            }
        }
        var size = length
        for (stage, taps) in halves.enumerated() {
            let next = ranges[stage + 1]
            size = (size + 1) / 2
            var halved = [Double](repeating: 0, count: next.count)
            current.withUnsafeBufferPointer { input in
                taps.withUnsafeBufferPointer { taps in
                    halved.withUnsafeMutableBufferPointer { out in
                        for index in 0..<out.count {
                            let sample = next.lowerBound + Int64(index)
                            guard sample >= 0, sample < size else { continue }
                            var sum = 0.0
                            let base = 2 * index
                            for tap in 0..<taps.count { sum += taps[tap] * input[base + tap] }
                            out[index] = sum
                        }
                    }
                }
            }
            current = halved
            range = next
        }
        return current
    }
}
