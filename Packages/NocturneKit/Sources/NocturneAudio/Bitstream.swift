//
// Nocturne — sending Dolby and DTS to an AV receiver untouched ("bitstream"): the compressed frames
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

/// IEC 61937 framing.
public enum IEC61937 {
    static let pa: UInt16 = 0xF872, pb: UInt16 = 0x4E1F
    static let typeAC3: UInt16 = 1, typeEAC3: UInt16 = 21
    static let typeDTS512: UInt16 = 11, typeDTS1024: UInt16 = 12, typeDTS2048: UInt16 = 13

    /// One data burst of `period` stereo frames: preamble, the payload as 16-bit words, zeros.
    /// Words are big-endian pairs of payload bytes (the order the bitstream is written in);
    /// the samples go out as ordinary 16-bit PCM.
    static func burst(type: UInt16, lengthCode: UInt16, payload: [UInt8], period: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: period * 2)
        out[0] = Int16(bitPattern: pa); out[1] = Int16(bitPattern: pb)
        out[2] = Int16(bitPattern: type); out[3] = Int16(bitPattern: lengthCode)
        var i = 0, w = 4
        while i < payload.count, w < out.count {
            let hi = UInt16(payload[i]), lo = i + 1 < payload.count ? UInt16(payload[i + 1]) : 0
            out[w] = Int16(bitPattern: hi << 8 | lo)
            i += 2; w += 1
        }
        return out
    }

    /// A Dolby Digital frame: one burst per 1536-sample frame. Pd is the length in bits.
    public static func ac3Burst(_ frame: [UInt8]) -> [Int16] {
        let bsmod = frame.count > 5 ? UInt16(frame[5] & 0x07) : 0
        return burst(type: typeAC3 | bsmod << 8, lengthCode: UInt16(truncatingIfNeeded: frame.count * 8), payload: frame, period: 1536)
    }

    /// Dolby Digital Plus: frames adding up to six audio blocks (1536 samples) in one burst of 6144 stereo
    /// frames at four times the rate. Pd is the length in bytes.
    public static func eac3Burst(_ frames: [[UInt8]]) -> [Int16] {
        let payload = frames.flatMap { $0 }
        return burst(type: typeEAC3, lengthCode: UInt16(truncatingIfNeeded: payload.count), payload: payload, period: 6144)
    }

    /// A DTS core frame of `samples` samples (512, 1024 or 2048). Pd is the length in bits.
    public static func dtsBurst(_ frame: [UInt8], samples: Int) -> [Int16] {
        let type = samples == 512 ? typeDTS512 : samples == 1024 ? typeDTS1024 : typeDTS2048
        return burst(type: type, lengthCode: UInt16(truncatingIfNeeded: frame.count * 8), payload: frame, period: samples)
    }
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
            return Frame(bytes: Array(data[offset..<(offset + size)]), isEnhanced: true, blocks: blocks, sampleRate: rate)
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
    /// Dolby Digital Plus frames grouped into bursts of six audio blocks (1536 samples).
    static func eac3Groups(_ frames: [DolbyFrames.Frame]) -> [[DolbyFrames.Frame]] {
        var groups: [[DolbyFrames.Frame]] = [], current: [DolbyFrames.Frame] = [], blocks = 0
        for f in frames {
            current.append(f); blocks += f.blocks
            if blocks >= 6 { groups.append(current); current = []; blocks = 0 }
        }
        return groups
    }
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
    private let frameBytes: Int
    private let samplesPerFrame: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let head = [UInt8](try handle.read(upToCount: 65_536) ?? Data())
        guard let start = (0..<max(0, head.count - 6)).first(where: { DolbyFrames.frame(in: head, at: $0) != nil }),
              let first = DolbyFrames.frame(in: head, at: start) else { throw SourceOpenerError.unsupported(url) }
        sampleRate = first.sampleRate
        isEnhanced = first.isEnhanced
        frameBytes = first.bytes.count
        samplesPerFrame = first.blocks * 256
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Dolby streams are constant bit rate: frames × samples per frame.
        totalSamples = Int64(max(0, size - Int64(start))) / Int64(frameBytes) * Int64(samplesPerFrame)
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
        let frame = max(0, sample) / Int64(samplesPerFrame)
        try handle.seek(toOffset: UInt64(frame) * UInt64(frameBytes))
        buffer.removeAll(); eof = false
        return frame * Int64(samplesPerFrame)
    }
}

/// Dolby Digital (Plus) in MP4 / M4A: frames from AVFoundation, untouched.
final class MP4DolbySource: DolbyFrameSource, @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: [[UInt8]] = []
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
            var total = 0; var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: total)
            var offset = 0
            for i in 0..<count {
                let size = CMSampleBufferGetSampleSize(sb, at: i)
                guard size > 0, offset + size <= total else { break }
                pending.append(Array(bytes[offset..<(offset + size)]))
                offset += size
            }
        }
        let bytes = pending.removeFirst()
        return DolbyFrames.frame(in: bytes, at: 0) ?? DolbyFrames.Frame(bytes: bytes, isEnhanced: isEnhanced, blocks: 6, sampleRate: sampleRate)
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
final class BitstreamDecoder: NSObject, PCMDecoding {
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
        pendingSamples.removeAll(); done = false
        position_ = start * ratio
        // Land on the exact carrier frame (bursts are silent after their payload, so this is safe).
        let skip = Int(frame - position_)
        if skip > 0 {
            while pendingSamples.count < skip * 2, !done { try refill() }
            let n = min(skip, pendingSamples.count / 2)
            pendingSamples.removeFirst(n * 2); position_ += AVAudioFramePosition(n)
        }
    }

    private var eac3Group: [DolbyFrames.Frame] = []

    private func refill() throws {
        guard let frame = try source.next() else {
            if !eac3Group.isEmpty { pendingSamples += IEC61937.eac3Burst(eac3Group.map(\.bytes)); eac3Group.removeAll() }
            done = true
            return
        }
        if format == .ac3 {
            pendingSamples += IEC61937.ac3Burst(frame.bytes)
        } else {
            eac3Group.append(frame)
            if eac3Group.reduce(0, { $0 + $1.blocks }) >= 6 {
                pendingSamples += IEC61937.eac3Burst(eac3Group.map(\.bytes)); eac3Group.removeAll()
            }
        }
    }
}
