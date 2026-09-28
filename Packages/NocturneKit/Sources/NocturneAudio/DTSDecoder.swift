//
// Nocturne — DTS CDs and DTS-in-WAV/FLAC: a DTS 5.1 bitstream stored as 16-bit stereo PCM.
// Played as PCM it is full-scale noise; decoded, it is the 5.1 mix.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CNocturneDTS
import Foundation
import SFBAudioEngine

enum DTSError: Error, LocalizedError {
    case unavailable, noStream, decoding, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "The DTS decoder isn't available."
        case .noStream: "No DTS audio found in this file."
        case .decoding: "The audio couldn't be decoded."
        case .unsupported(let why): "This file can't be played (\(why))."
        }
    }
}

/// Decodes the DTS stream carried in `carrier` (a 16-bit stereo PCM decoder). Positions are carrier
/// frames: a DTS CD stores each 512-sample frame in 512 carrier frames, so times, seeks and CUE
/// indexes line up with the file as written. Carrier frames before the first DTS frame are silence.
final class DTSDecoder: NSObject, PCMDecoding {
    /// The 16-bit stereo stream holding the DTS bitstream (sent untouched when bitstreaming).
    let carrier: PCMDecoding
    private var dts: OpaquePointer?
    private var carrierBuffer: AVAudioPCMBuffer?
    private var bytes: [UInt8] = []
    private var outPosition: AVAudioFramePosition = 0
    /// Silence still to be produced before decoded audio (carrier frames ahead of the next DTS frame).
    private var leadIn: AVAudioFramePosition = 0
    /// Decoded frames to drop (from the DTS frame before a seek target).
    private var discard = 0
    private var synced = false
    private var carrierDone = false
    private var format: AVAudioFormat?
    private(set) var isOpen = false
    /// Frames read from the carrier per step (16 KB of bitstream).
    private let step: AVAudioFrameCount = 4096

    init(carrier: PCMDecoding) {
        self.carrier = carrier
    }

    deinit { if let dts { ndts_destroy(dts) } }

    // MARK: Detection

    /// Whether the first frames of this 16-bit stereo lossless PCM decoder hold a DTS bitstream.
    /// Leaves the decoder at frame 0.
    static func carriesDTS(_ decoder: PCMDecoding) -> Bool {
        let asbd = decoder.processingFormat.streamDescription.pointee
        guard decoder.processingFormat.channelCount == 2, asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              decoder.decodingIsLossless, decoder.sourceFormat.streamDescription.pointee.mBitsPerChannel <= 16 || asbd.mBitsPerChannel <= 16
        else { return false }
        let rate = decoder.processingFormat.sampleRate
        guard rate == 44_100 || rate == 48_000 else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192) else { return false }
        defer { try? decoder.seek(to: 0) }
        guard (try? decoder.decode(into: buffer, length: 8192)) != nil, buffer.frameLength > 0 else { return false }
        let words = interleavedWords(buffer)
        return words.withUnsafeBufferPointer { ndts_find_sync($0.baseAddress!, Int64($0.count)) >= 0 }
    }

    /// The buffer's samples as 16-bit little-endian words, interleaved (the bitstream as stored).
    static func interleavedWords(_ buffer: AVAudioPCMBuffer) -> [UInt8] {
        let n = Int(buffer.frameLength), ch = Int(buffer.format.channelCount)
        let asbd = buffer.format.streamDescription.pointee
        var out = [UInt8](repeating: 0, count: n * ch * 2)
        func put(_ i: Int, _ v: Int16) { out[2 * i] = UInt8(truncatingIfNeeded: v); out[2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8) }
        let interleaved = buffer.format.isInterleaved
        if let data = buffer.int16ChannelData {
            for f in 0..<n { for c in 0..<ch { put(f * ch + c, interleaved ? data[0][f * ch + c] : data[c][f]) } }
        } else if let data = buffer.int32ChannelData {
            // 16-bit samples in 32-bit containers: aligned high unless the format says otherwise.
            let high = asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 || asbd.mBitsPerChannel == 32
            let shift: Int32 = high ? 16 : 0
            for f in 0..<n { for c in 0..<ch {
                let v = interleaved ? data[0][f * ch + c] : data[c][f]
                put(f * ch + c, Int16(truncatingIfNeeded: v >> shift))
            } }
        }
        return out
    }

    // MARK: AudioDecoding

    var inputSource: InputSource { carrier.inputSource }
    var sourceFormat: AVAudioFormat {
        var asbd = AudioStreamBasicDescription(mSampleRate: processingFormat.sampleRate, mFormatID: 0x6474_7320 /* 'dts ' */,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 512, mBytesPerFrame: 0,
                                               mChannelsPerFrame: processingFormat.channelCount, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd, channelLayout: processingFormat.channelLayout) ?? processingFormat
    }
    var processingFormat: AVAudioFormat { format ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)! }
    var decodingIsLossless: Bool { false }
    var properties: [AudioDecodingPropertiesKey: Any] { [:] }
    var supportsSeeking: Bool { carrier.supportsSeeking }
    var position: AVAudioFramePosition { outPosition }
    var length: AVAudioFramePosition { carrier.length }

    func open() throws {
        guard !isOpen else { return }
        if !carrier.isOpen { try carrier.open() }
        guard let d = ndts_create() else { throw DTSError.unavailable }
        dts = d
        carrierBuffer = AVAudioPCMBuffer(pcmFormat: carrier.processingFormat, frameCapacity: step)
        try carrier.seek(to: 0)
        reset(at: 0)
        // Decode until the stream's layout is known.
        while ndts_channels(d) == 0, !carrierDone { try pump() }
        let channels = Int(ndts_channels(d)), rate = Double(ndts_sample_rate(d))
        guard channels > 0, rate > 0 else { throw DTSError.noStream }
        format = Self.format(rate: rate, channels: channels, mask: ndts_channel_mask(d))
        try carrier.seek(to: 0)
        reset(at: 0)
        isOpen = true
    }

    func close() throws {
        if let dts { ndts_destroy(dts) }
        dts = nil
        isOpen = false
        try carrier.close()
    }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { throw DTSError.decoding }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard let dts, let planes = buffer.floatChannelData else { throw DTSError.decoding }
        let want = Int(min(length, buffer.frameCapacity))
        let channels = Int(ndts_channels(dts))
        var filled = 0
        while filled < want {
            if leadIn > 0 {
                let n = min(Int(leadIn), want - filled)
                for c in 0..<channels { (planes[c] + filled).update(repeating: 0, count: n) }
                filled += n; leadIn -= AVAudioFramePosition(n)
                continue
            }
            if discard > 0 {
                if ndts_available(dts) == 0 { if carrierDone { break }; try pump(); continue }
                discard -= Int(ndts_skip(dts, Int32(discard)))
                continue
            }
            if ndts_available(dts) == 0 {
                if carrierDone { break }
                try pump()
                continue
            }
            var targets = (0..<channels).map { planes[$0] + filled }
            filled += Int(targets.withUnsafeMutableBufferPointer { ptrs in
                ptrs.withMemoryRebound(to: UnsafeMutablePointer<Float>.self) { ndts_read(dts, $0.baseAddress!, Int32(want - filled)) }
            })
        }
        // Never run past the carrier: its length is the track's length.
        let remaining = max(0, Int(self.length - outPosition))
        buffer.frameLength = AVAudioFrameCount(min(filled, remaining))
        outPosition += AVAudioFramePosition(buffer.frameLength)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        guard dts != nil else { throw DTSError.decoding }
        let target = max(0, min(frame, length))
        // Start a little early so the DTS frame containing the target is found.
        let start = max(0, target - 2048)
        try carrier.seek(to: start)
        reset(at: start)
        // Read until the first DTS frame after `start` is found; decoded audio starts there.
        while !synced, !carrierDone { try pump() }
        let first = syncedAt
        if target < first {
            leadIn = first - target
            discard = 0
        } else {
            leadIn = 0
            discard = Int(target - first)
        }
        outPosition = target
    }

    // MARK: Internals

    /// Carrier frame where decoding (re)started at the first DTS frame found.
    private var syncedAt: AVAudioFramePosition = 0
    private var carrierPosition: AVAudioFramePosition = 0

    private func reset(at carrierFrame: AVAudioFramePosition) {
        if let dts { ndts_reset(dts) }
        carrierPosition = carrierFrame
        outPosition = carrierFrame
        synced = false
        carrierDone = false
        leadIn = 0
        discard = 0
        syncedAt = carrierFrame
    }

    /// Reads the next carrier chunk and feeds its bitstream to the decoder.
    private func pump() throws {
        guard let dts, let buffer = carrierBuffer else { throw DTSError.decoding }
        try carrier.decode(into: buffer, length: step)
        let n = Int(buffer.frameLength)
        if n == 0 {
            carrierDone = true
            ndts_finish(dts)
            return
        }
        var words = Self.interleavedWords(buffer)
        var from = 0
        if !synced {
            let at = words.withUnsafeBufferPointer { Int(ndts_find_sync($0.baseAddress!, Int64($0.count))) }
            if at < 0 {
                // No DTS frame here: these carrier frames are silence.
                carrierPosition += AVAudioFramePosition(n)
                if outPosition == syncedAt { leadIn += AVAudioFramePosition(n) }
                syncedAt = carrierPosition
                return
            }
            synced = true
            from = at - at % 4
            syncedAt = carrierPosition + AVAudioFramePosition(from / 4)
            if outPosition < syncedAt, leadIn == 0 { leadIn = syncedAt - outPosition }
        }
        carrierPosition += AVAudioFramePosition(n)
        if from > 0 { words.removeFirst(from) }
        let ok = words.withUnsafeBufferPointer { ndts_feed(dts, $0.baseAddress!, Int32($0.count)) }
        if !ok { throw DTSError.decoding }
    }

    /// Float32 non-interleaved at the stream's rate, with the stream's own channel order.
    static func format(rate: Double, channels: Int, mask: UInt64) -> AVAudioFormat {
        let labels: [(bit: Int, label: AudioChannelLabel)] = [
            (0, kAudioChannelLabel_Left), (1, kAudioChannelLabel_Right), (2, kAudioChannelLabel_Center),
            (3, kAudioChannelLabel_LFEScreen), (4, kAudioChannelLabel_RearSurroundLeft), (5, kAudioChannelLabel_RearSurroundRight),
            (6, kAudioChannelLabel_LeftCenter), (7, kAudioChannelLabel_RightCenter), (8, kAudioChannelLabel_CenterSurround),
            (9, kAudioChannelLabel_LeftSurround), (10, kAudioChannelLabel_RightSurround),
        ]
        var present = labels.filter { mask & (1 << UInt64($0.bit)) != 0 }
        // 5.1 "back" (no side pair): its back pair are the surrounds.
        if mask & (1 << 9) == 0 {
            present = present.map { $0.bit == 4 ? (4, kAudioChannelLabel_LeftSurround) : $0.bit == 5 ? (5, kAudioChannelLabel_RightSurround) : $0 }
        }
        let layout: AVAudioChannelLayout
        if present.count == channels, channels > 0 {
            let size = MemoryLayout<AudioChannelLayout>.size + (channels - 1) * MemoryLayout<AudioChannelDescription>.size
            let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            let acl = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
            acl.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            acl.pointee.mChannelBitmap = []
            acl.pointee.mNumberChannelDescriptions = UInt32(channels)
            let descriptions = UnsafeMutableAudioChannelDescriptionPointer(acl)
            for (i, entry) in present.enumerated() {
                descriptions[i] = AudioChannelDescription(mChannelLabel: entry.label, mChannelFlags: [], mCoordinates: (0, 0, 0))
            }
            layout = AVAudioChannelLayout(layout: acl)
        } else {
            layout = ChannelLayouts.layout(channels: channels) ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
        }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }
}

/// The channel descriptions following an AudioChannelLayout header.
private func UnsafeMutableAudioChannelDescriptionPointer(_ layout: UnsafeMutablePointer<AudioChannelLayout>) -> UnsafeMutablePointer<AudioChannelDescription> {
    UnsafeMutableRawPointer(layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
        .assumingMemoryBound(to: AudioChannelDescription.self)
}
