//
// Vespertine — sending Dolby and DTS to an AV receiver untouched ("bitstream"): the compressed frames
// wrapped in IEC 61937 data bursts, carried as 16-bit stereo PCM over HDMI or S/PDIF. The receiver
// recognizes the bursts and decodes (Dolby Atmos included, when the receiver supports it).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import Foundation
import SFBAudioEngine

/// What a source can be sent as.
public enum BitstreamFormat: String, Sendable, Hashable {
    case ac3, eac3, dts

    public init?(codec: String) {
        switch codec {
        case "Dolby Digital": self = .ac3
        case "Dolby Digital Plus", DolbyAtmos.codecName: self = .eac3
        case "DTS": self = .dts
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .ac3: "Dolby Digital"
        case .eac3: "Dolby Digital Plus"
        case .dts: "DTS"
        }
    }

    /// The carrier's sample rate for a stream at `rate`: Dolby Digital Plus needs four times the rate
    /// (HDMI only); the others run at the stream's own rate.
    public func carrierRate(for rate: Double) -> Double { self == .eac3 ? rate * 4 : rate }
}

/// Why a frame can't go out in a burst. The framers check their own input rather than trust the reader: a burst
/// whose length word (Pd) claims more than it carries makes a receiver read into the next burst's preamble.
public enum BurstError: Error, Equatable, Sendable {
    /// No sync word where the frame should start.
    case noSync
    /// The bytes don't hold a whole frame (cut short, a header that doesn't parse, or bytes left over after it).
    case notAFrame
    /// The frame isn't the codec this burst carries (E-AC-3 handed to the AC-3 framer, or the other way round).
    case wrongCodec
    /// Dolby Digital Plus: the frames don't add up to six audio blocks (1536 samples).
    case blocks(Int)
    /// DTS: a frame of a length with no burst type (only 512, 1024 and 2048 samples have one).
    case samples(Int)
    /// The payload doesn't fit after the preamble within the burst's repetition period.
    case tooBig(bytes: Int, room: Int)
}

/// IEC 61937 framing.
public enum IEC61937 {
    static let pa: UInt16 = 0xF872, pb: UInt16 = 0x4E1F
    static let typeAC3: UInt16 = 1, typeEAC3: UInt16 = 21
    static let typeDTS512: UInt16 = 11, typeDTS1024: UInt16 = 12, typeDTS2048: UInt16 = 13

    /// Payload bytes that fit in a burst of `period` stereo frames, after the four preamble words.
    static func room(period: Int) -> Int { (period * 2 - 4) * 2 }

    /// One data burst of `period` stereo frames: preamble, the payload as 16-bit words, zeros.
    /// Words are big-endian pairs of payload bytes (the order the bitstream is written in);
    /// the samples go out as ordinary 16-bit PCM. Pd is the payload's length in bytes or bits, and a payload
    /// that doesn't fit whole is refused: never cut short under a Pd that claims all of it.
    static func burst(type: UInt16, payload: [UInt8], lengthInBytes: Bool, period: Int) throws(BurstError) -> [Int16] {
        guard payload.count <= room(period: period) else { throw .tooBig(bytes: payload.count, room: room(period: period)) }
        var out = [Int16](repeating: 0, count: period * 2)
        out[0] = Int16(bitPattern: pa); out[1] = Int16(bitPattern: pb)
        out[2] = Int16(bitPattern: type)
        out[3] = Int16(bitPattern: UInt16(lengthInBytes ? payload.count : payload.count * 8))
        var i = 0, w = 4
        while i < payload.count {
            let hi = UInt16(payload[i]), lo = i + 1 < payload.count ? UInt16(payload[i + 1]) : 0
            out[w] = Int16(bitPattern: hi << 8 | lo)
            i += 2; w += 1
        }
        return out
    }

    /// The Dolby frame at `offset` of `bytes`, which must start with a sync word and fit whole.
    private static func dolbyFrame(_ bytes: [UInt8], at offset: Int) throws(BurstError) -> DolbyFrames.Frame {
        guard offset + 2 <= bytes.count, bytes[offset] == 0x0B, bytes[offset + 1] == 0x77 else { throw .noSync }
        guard let frame = DolbyFrames.frame(in: bytes, at: offset) else { throw .notAFrame }
        return frame
    }

    /// A Dolby Digital frame: one burst per 1536-sample frame. Pd is the length in bits.
    public static func ac3Burst(_ frame: [UInt8]) throws(BurstError) -> [Int16] {
        let parsed = try dolbyFrame(frame, at: 0)
        guard !parsed.isEnhanced else { throw .wrongCodec }
        guard parsed.bytes.count == frame.count else { throw .notAFrame }
        let bsmod = UInt16(frame[5] & 0x07)
        return try burst(type: typeAC3 | bsmod << 8, payload: frame, lengthInBytes: false, period: 1536)
    }

    /// Dolby Digital Plus: frames adding up to six audio blocks (1536 samples) in one burst of 6144 stereo
    /// frames at four times the rate. Pd is the length in bytes. Each element may hold several frames back to back
    /// (an MP4 sample: the independent frame and its dependent substreams); every byte must belong to a frame.
    public static func eac3Burst(_ frames: [[UInt8]]) throws(BurstError) -> [Int16] {
        var blocks = 0
        for bytes in frames {
            var offset = 0
            repeat {
                let frame = try dolbyFrame(bytes, at: offset)
                guard frame.isEnhanced else { throw .wrongCodec }
                if frame.startsAudio { blocks += frame.blocks }
                offset += frame.bytes.count
            } while offset < bytes.count
        }
        guard blocks == 6 else { throw .blocks(blocks) }
        return try burst(type: typeEAC3, payload: frames.flatMap { $0 }, lengthInBytes: true, period: 6144)
    }

    /// A DTS core frame (16-bit big-endian form). Its length in samples (NBLKS) picks the burst type and period,
    /// and its size (FSIZE) must match the bytes given. Pd is the length in bits.
    public static func dtsBurst(_ frame: [UInt8]) throws(BurstError) -> [Int16] {
        guard frame.count >= 4, frame[0] == 0x7F, frame[1] == 0xFE, frame[2] == 0x80, frame[3] == 0x01 else { throw .noSync }
        guard frame.count >= 8 else { throw .notAFrame }
        let nblks = Int(frame[4] & 0x01) << 6 | Int(frame[5] >> 2)
        let fsize = Int(frame[5] & 0x03) << 12 | Int(frame[6]) << 4 | Int(frame[7] >> 4)
        guard fsize + 1 == frame.count else { throw .notAFrame }
        let samples = (nblks + 1) * 32
        let type: UInt16
        switch samples {
        case 512: type = typeDTS512
        case 1024: type = typeDTS1024
        case 2048: type = typeDTS2048
        default: throw .samples(samples)
        }
        return try burst(type: type, payload: frame, lengthInBytes: false, period: samples)
    }

    /// What goes out in place of a burst that can't be sent: `frames` stereo frames of zeros, so the carrier keeps
    /// its timing. A receiver plays no audio for it.
    static func silence(frames: Int) -> [Int16] { [Int16](repeating: 0, count: frames * 2) }
}

/// Splits Dolby Digital / Dolby Digital Plus elementary streams into frames.
public enum DolbyFrames {
    /// AC-3 frame sizes in 16-bit words, by frmsizecod, for 48 / 44.1 / 32 kHz.
    static let ac3Words: [[Int]] = [
        [64, 69, 96], [64, 70, 96], [80, 87, 120], [80, 88, 120], [96, 104, 144], [96, 105, 144], [112, 121, 168], [112, 122, 168],
        [128, 139, 192], [128, 140, 192], [160, 174, 240], [160, 175, 240], [192, 208, 288], [192, 209, 288], [224, 243, 336], [224, 244, 336],
        [256, 278, 384], [256, 279, 384], [320, 348, 480], [320, 349, 480], [384, 417, 576], [384, 418, 576], [448, 487, 672], [448, 488, 672],
        [512, 557, 768], [512, 558, 768], [640, 696, 960], [640, 697, 960], [768, 835, 1152], [768, 836, 1152], [896, 975, 1344], [896, 976, 1344],
        [1024, 1114, 1536], [1024, 1115, 1536], [1152, 1253, 1728], [1152, 1254, 1728], [1280, 1393, 1920], [1280, 1394, 1920],
    ]

    public struct Frame: Sendable {
        public var bytes: [UInt8]
        public var isEnhanced: Bool
        /// Audio blocks (256 samples each): 6 for AC-3; 1, 2, 3 or 6 for E-AC-3.
        public var blocks: Int
        public var sampleRate: Double
        /// E-AC-3 dependent substream (strmtyp 1): extra channels for the independent frame before it, same audio blocks.
        public var isDependent = false
        /// E-AC-3 substream ID (0 for AC-3).
        public var substream = 0
        /// Starts a new stretch of audio: an independent frame of substream 0 (every AC-3 frame).
        var startsAudio: Bool { !isDependent && substream == 0 }
    }

    /// The frame starting at `offset`, or nil if there's no valid frame header there.
    public static func frame(in data: [UInt8], at offset: Int) -> Frame? {
        guard offset + 6 <= data.count, data[offset] == 0x0B, data[offset + 1] == 0x77 else { return nil }
        let bsid = data[offset + 5] >> 3
        if bsid <= 10 {
            let fscod = Int(data[offset + 4] >> 6), frmsizecod = Int(data[offset + 4] & 0x3F)
            guard fscod < 3, frmsizecod < ac3Words.count else { return nil }
            let size = ac3Words[frmsizecod][fscod] * 2
            guard offset + size <= data.count else { return nil }
            return Frame(bytes: Array(data[offset..<(offset + size)]), isEnhanced: false, blocks: 6,
                         sampleRate: [48_000, 44_100, 32_000][fscod])
        } else if bsid <= 16 {
            let frmsiz = (Int(data[offset + 2] & 0x07) << 8) | Int(data[offset + 3])
            let size = (frmsiz + 1) * 2
            let fscod = Int(data[offset + 4] >> 6)
            let numblkscod = Int(data[offset + 4] >> 4) & 0x03
            let blocks = fscod == 3 ? 6 : [1, 2, 3, 6][numblkscod]
            let rate: Double = fscod == 3 ? [24_000, 22_050, 16_000, 48_000][numblkscod] : [48_000, 44_100, 32_000][fscod]
            guard offset + size <= data.count else { return nil }
            return Frame(bytes: Array(data[offset..<(offset + size)]), isEnhanced: true, blocks: blocks, sampleRate: rate,
                         isDependent: data[offset + 2] >> 6 == 1, substream: Int(data[offset + 2] >> 3) & 0x07)
        }
        return nil
    }

    /// All frames in an elementary stream (skipping anything that isn't a frame).
    public static func frames(in data: [UInt8]) -> [Frame] {
        var out: [Frame] = [], i = 0
        while i + 6 <= data.count {
            if let f = frame(in: data, at: i) { out.append(f); i += f.bytes.count } else { i += 1 }
        }
        return out
    }
}

enum BitstreamPacker {
    /// Dolby Digital Plus frames grouped into bursts of six audio blocks (1536 samples), as `EAC3Grouper` does.
    static func eac3Groups(_ frames: [DolbyFrames.Frame]) -> [[DolbyFrames.Frame]] {
        var grouper = EAC3Grouper(), groups: [[DolbyFrames.Frame]] = []
        for f in frames { if let g = grouper.add(f) { groups.append(g) } }
        if let g = grouper.finish() { groups.append(g) }
        return groups
    }
}

/// Collects Dolby Digital Plus frames into bursts of six audio blocks. Only frames that start audio (independent,
/// substream 0) add blocks; the dependent and other substreams that follow one belong to the same blocks and go in its
/// burst. A burst is complete once it holds six blocks and the next frame starting audio arrives (or the stream ends).
struct EAC3Grouper {
    private var frames: [DolbyFrames.Frame] = []
    private var blocks = 0

    /// Adds a frame; returns a finished burst's frames when this frame starts the next one.
    mutating func add(_ frame: DolbyFrames.Frame) -> [DolbyFrames.Frame]? {
        var done: [DolbyFrames.Frame]?
        if frame.startsAudio {
            if blocks >= 6 { done = frames; frames = []; blocks = 0 }
            blocks += frame.blocks
        }
        frames.append(frame)
        return done
    }

    /// The end of the stream: whatever is left, as a last burst.
    mutating func finish() -> [DolbyFrames.Frame]? {
        defer { reset() }
        return frames.isEmpty ? nil : frames
    }

    mutating func reset() { frames = []; blocks = 0 }
}

/// Where compressed Dolby frames come from: an elementary stream file, or the audio track of an MP4.
protocol DolbyFrameSource: AnyObject {
    /// Next frame, or nil at the end.
    func next() throws -> DolbyFrames.Frame?
    /// Positions so that `next()` returns the frame containing audio sample `sample` (of the stream).
    /// Returns the first sample of that frame.
    func seek(toSample sample: Int64) throws -> Int64
    var totalSamples: Int64 { get }
    var sampleRate: Double { get }
    var isEnhanced: Bool { get }
}

/// `.ac3` / `.ec3` files: frames read straight from the file.
final class ElementaryDolbySource: DolbyFrameSource {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var fileOffset: UInt64 = 0
    private var eof = false
    let sampleRate: Double
    let isEnhanced: Bool
    let totalSamples: Int64
    private let start: UInt64
    /// Bytes from one frame starting audio to the next (dependent and other substreams included), and its samples.
    private let unitBytes: Int
    private let samplesPerUnit: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let head = [UInt8](try handle.read(upToCount: 65_536) ?? Data())
        guard let start = (0..<max(0, head.count - 6)).first(where: { DolbyFrames.frame(in: head, at: $0)?.startsAudio == true }),
              let first = DolbyFrames.frame(in: head, at: start) else { throw SourceOpenerError.unsupported(url) }
        sampleRate = first.sampleRate
        isEnhanced = first.isEnhanced
        // A unit is the first frame and any substreams after it, up to the next frame starting audio (sizes can alternate
        // between an independent frame and its dependent one).
        var unit = first.bytes.count
        while let f = DolbyFrames.frame(in: head, at: start + unit), !f.startsAudio { unit += f.bytes.count }
        unitBytes = unit
        samplesPerUnit = first.blocks * 256
        self.start = UInt64(start)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Dolby streams are constant bit rate: units × samples per unit.
        totalSamples = Int64(max(0, size - Int64(start))) / Int64(unitBytes) * Int64(samplesPerUnit)
        try handle.seek(toOffset: UInt64(start))
        fileOffset = UInt64(start)
    }

    deinit { try? handle.close() }

    func next() throws -> DolbyFrames.Frame? {
        while true {
            if let f = DolbyFrames.frame(in: buffer, at: 0) { buffer.removeFirst(f.bytes.count); return f }
            if buffer.count >= 2, !(buffer[0] == 0x0B && buffer[1] == 0x77), buffer.count > 4096 || eof {
                // Resync: drop to the next sync word.
                if let i = (1..<buffer.count - 1).first(where: { buffer[$0] == 0x0B && buffer[$0 + 1] == 0x77 }) { buffer.removeFirst(i) }
                else { buffer.removeAll() }
                continue
            }
            if eof { return nil }
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { eof = true } else { buffer += chunk; fileOffset += UInt64(chunk.count) }
        }
    }

    func seek(toSample sample: Int64) throws -> Int64 {
        let unit = max(0, sample) / Int64(samplesPerUnit)
        try handle.seek(toOffset: start + UInt64(unit) * UInt64(unitBytes))
        buffer.removeAll(); eof = false
        return unit * Int64(samplesPerUnit)
    }
}

/// Dolby Digital (Plus) in MP4 / M4A: frames from AVFoundation, untouched.
final class MP4DolbySource: DolbyFrameSource, @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: [[UInt8]] = []
    /// Audio blocks in the last sample that parsed: a damaged sample is assumed to hold as many.
    private var lastBlocks = 6
    let sampleRate: Double
    let isEnhanced: Bool
    let totalSamples: Int64

    init(url: URL) throws {
        asset = AVURLAsset(url: url)
        struct Loaded: @unchecked Sendable { var track: AVAssetTrack?; var duration: CMTime; var asbd: AudioStreamBasicDescription? }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loaded: Loaded?
        Task.detached { [asset] in
            let track = try? await asset.loadTracks(withMediaType: .audio).first
            let duration = (try? await asset.load(.duration)) ?? .zero
            let desc = try? await track?.load(.formatDescriptions).first
            loaded = Loaded(track: track, duration: duration, asbd: desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
            done.signal()
        }
        done.wait()
        guard let info = loaded, let track = info.track, let asbd = info.asbd,
              asbd.mFormatID == kAudioFormatAC3 || asbd.mFormatID == kAudioFormatEnhancedAC3 else { throw SourceOpenerError.unsupported(url) }
        self.track = track
        sampleRate = asbd.mSampleRate
        isEnhanced = asbd.mFormatID == kAudioFormatEnhancedAC3
        totalSamples = Int64(CMTimeGetSeconds(info.duration) * asbd.mSampleRate)
        _ = try seek(toSample: 0)
    }

    func next() throws -> DolbyFrames.Frame? {
        while pending.isEmpty {
            guard let sb = output?.copyNextSampleBuffer() else { return nil }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let count = CMSampleBufferGetNumSamples(sb)
            // Copied out rather than read through the first block's pointer: a block buffer can be several
            // non-contiguous pieces, and reading `total` bytes from the first one would run past it.
            let total = CMBlockBufferGetDataLength(block)
            guard total > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: total)
            guard bytes.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) })
                    == kCMBlockBufferNoErr else { continue }
            var offset = 0
            for i in 0..<count {
                let size = CMSampleBufferGetSampleSize(sb, at: i)
                guard size > 0, offset + size <= total else { break }
                pending.append(Array(bytes[offset..<(offset + size)]))
                offset += size
            }
        }
        // The whole sample goes out: an MP4 sample is one stretch of audio, the independent frame and any dependent
        // substreams after it, so the first header gives its blocks and rate. A sample that doesn't parse keeps its
        // place in time (as many blocks as the last good one); the framer refuses it and its burst plays as silence.
        let bytes = pending.removeFirst()
        guard var frame = DolbyFrames.frame(in: bytes, at: 0) else {
            return DolbyFrames.Frame(bytes: bytes, isEnhanced: isEnhanced, blocks: lastBlocks, sampleRate: sampleRate)
        }
        frame.bytes = bytes
        lastBlocks = frame.blocks
        return frame
    }

    func seek(toSample sample: Int64) throws -> Int64 {
        reader?.cancelReading()
        pending.removeAll()
        let frame = max(0, sample) / 1536 * 1536
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(value: frame, timescale: CMTimeScale(sampleRate)), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SourceOpenerError.unsupported(asset.url) }
        self.reader = reader; self.output = output
        return frame
    }
}

/// Produces the IEC 61937 carrier (16-bit stereo) for a Dolby source. Positions are carrier frames.
/// A burst the framer refuses (a damaged frame, or a payload too big for its burst) goes out as silence of the
/// same length, and is counted in `concealedFrames`. So does the last Dolby Digital Plus burst of a stream when it
/// holds fewer than six audio blocks, which isn't counted: the stream simply ends there.
final class BitstreamDecoder: NSObject, PCMDecoding, ConcealingDecoder {
    private let source: DolbyFrameSource
    private let url: URL
    private var pendingSamples: [Int16] = []    // interleaved carrier samples not yet delivered
    private var position_: AVAudioFramePosition = 0
    private var done = false
    /// Carrier frames per stream sample (4 for Dolby Digital Plus).
    private let ratio: Int64
    let format: BitstreamFormat
    private(set) var isOpen = false
    private let outFormat: AVAudioFormat
    /// Bursts sent as silence because the framer refused them.
    private(set) var concealedFrames = 0

    init(url: URL, source: DolbyFrameSource) {
        self.url = url
        self.source = source
        format = source.isEnhanced ? .eac3 : .ac3
        ratio = source.isEnhanced ? 4 : 1
        outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.carrierRate(for: source.sampleRate), channels: 2, interleaved: true)!
    }

    static func open(url: URL) throws -> BitstreamDecoder {
        let ext = url.pathExtension.lowercased()
        let source: DolbyFrameSource = SourceOpener.dolbyExtensions.contains(ext) ? try ElementaryDolbySource(url: url) : try MP4DolbySource(url: url)
        let d = BitstreamDecoder(url: url, source: source)
        try d.open()
        return d
    }

    var inputSource: InputSource { (try? InputSource(for: url)) ?? InputSource(data: Data()) }
    var sourceFormat: AVAudioFormat { outFormat }
    var processingFormat: AVAudioFormat { outFormat }
    var decodingIsLossless: Bool { true }     // the frames arrive untouched
    var properties: [AudioDecodingPropertiesKey: Any] { [:] }
    var supportsSeeking: Bool { true }
    var position: AVAudioFramePosition { position_ }
    var length: AVAudioFramePosition { source.totalSamples * ratio }

    func open() throws { isOpen = true }
    func close() throws { isOpen = false }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        let want = Int(min(length, buffer.frameCapacity))
        while pendingSamples.count < want * 2, !done { try refill() }
        let n = min(want, pendingSamples.count / 2)
        if let out = buffer.int16ChannelData?[0] {
            pendingSamples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: n * 2) }
        }
        pendingSamples.removeFirst(n * 2)
        buffer.frameLength = AVAudioFrameCount(n)
        position_ += AVAudioFramePosition(n)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        let sample = max(0, frame) / ratio
        let start = try source.seek(toSample: sample)
        pendingSamples.removeAll(); eac3Group.reset(); done = false
        position_ = start * ratio
        // Land on the exact carrier frame (bursts are silent after their payload, so this is safe).
        let skip = Int(frame - position_)
        if skip > 0 {
            while pendingSamples.count < skip * 2, !done { try refill() }
            let n = min(skip, pendingSamples.count / 2)
            pendingSamples.removeFirst(n * 2); position_ += AVAudioFramePosition(n)
        }
    }

    private var eac3Group = EAC3Grouper()

    private func refill() throws {
        guard let frame = try source.next() else {
            if let group = eac3Group.finish() { pendingSamples += eac3Carrier(group, last: true) }
            done = true
            return
        }
        if format == .ac3 {
            do throws(BurstError) { pendingSamples += try IEC61937.ac3Burst(frame.bytes) }
            catch { pendingSamples += IEC61937.silence(frames: 1536); concealedFrames += 1 }
        } else if let group = eac3Group.add(frame) {
            pendingSamples += eac3Carrier(group, last: false)
        }
    }

    /// One Dolby Digital Plus group's burst, or silence for as long as its audio blocks last (four carrier frames per
    /// sample) if the framer refuses it. A short last group is expected at the end of a stream and not counted.
    private func eac3Carrier(_ group: [DolbyFrames.Frame], last: Bool) -> [Int16] {
        do throws(BurstError) { return try IEC61937.eac3Burst(group.map(\.bytes)) }
        catch {
            let blocks = group.filter(\.startsAudio).reduce(0) { $0 + $1.blocks }
            if !(last && error == .blocks(blocks) && blocks < 6) { concealedFrames += 1 }
            return IEC61937.silence(frames: blocks * 256 * Int(ratio))
        }
    }
}
