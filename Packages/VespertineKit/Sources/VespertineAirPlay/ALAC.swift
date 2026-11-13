//
// Vespertine: Apple Lossless packets of 352 frames, 16-bit stereo at 44.1 kHz, as RAOP carries them. Encoded with Apple's own
// encoder (AudioConverter, kAudioFormatAppleLossless), whose configuration must be the one the SDP announces; when it can't
// be had, the "verbatim" ALAC frame (the samples uncompressed in an ALAC element, as OwnTone sends it) is lossless by
// construction. The decoder is for the test receiver and the round-trip checks.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AudioToolbox
import Foundation

public enum ALACError: Error, Equatable { case converter(OSStatus), cookieMismatch, badInput }

/// The ALAC configuration RAOP uses (the SDP fmtp: 352 0 16 40 10 14 2 255 0 0 44100) and its 24-byte magic cookie.
public struct ALACConfig: Sendable, Equatable {
    public var frameLength: UInt32 = 352
    public var bitDepth: UInt8 = 16
    public var pb: UInt8 = 40
    public var mb: UInt8 = 10
    public var kb: UInt8 = 14
    public var channels: UInt8 = 2
    public var maxRun: UInt16 = 255
    public var maxFrameBytes: UInt32 = 0
    public var avgBitRate: UInt32 = 0
    public var sampleRate: UInt32 = 44_100

    public init() {}

    /// From an SDP fmtp value.
    public init?(fmtp: String) {
        let v = fmtp.split(separator: " ").compactMap { UInt32($0) }
        guard v.count == 11 else { return nil }
        frameLength = v[0]; bitDepth = UInt8(v[2]); pb = UInt8(v[3]); mb = UInt8(v[4]); kb = UInt8(v[5]); channels = UInt8(v[6])
        maxRun = UInt16(v[7]); maxFrameBytes = v[8]; avgBitRate = v[9]; sampleRate = v[10]
    }

    /// ALACSpecificConfig, big-endian.
    public var cookie: Data {
        var d = Data(RAOPPacket.be32(frameLength))
        d += [0, bitDepth, pb, mb, kb, channels]
        d += RAOPPacket.be16(maxRun) + RAOPPacket.be32(maxFrameBytes) + RAOPPacket.be32(avgBitRate) + RAOPPacket.be32(sampleRate)
        return d
    }

    /// The fields that decide how a packet decodes match (frame bytes and bit rate are only hints).
    func decodesLike(cookie other: Data) -> Bool {
        let mine = cookie
        guard other.count >= 24 else { return false }
        let o = Data(other.prefix(24))
        return mine.prefix(12) == o.prefix(12) && mine.suffix(4) == o.subdata(in: 20..<24)
    }
}

enum PCM16 {
    static func format(channels: UInt32 = 2) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2 * channels,
                                    mFramesPerPacket: 1, mBytesPerFrame: 2 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
    }

    static func alac() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatAppleLossless, mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
                                    mBytesPerPacket: 0, mFramesPerPacket: 352, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    }
}

/// The input proc's state: one packet of samples, handed over once.
private final class ConverterInput {
    static let capacity = 16 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    var count = 0
    let packet = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    var given = false
    var isPacketized = false

    deinit {
        buffer.deallocate()
        packet.deallocate()
    }

    /// Holds `data` for the next call (at most `capacity` bytes).
    func set(_ data: Data) -> Bool {
        guard data.count <= Self.capacity else { return false }
        data.withUnsafeBytes { if let base = $0.baseAddress { buffer.copyMemory(from: base, byteCount: data.count) } }
        count = data.count
        given = false
        return true
    }
}

/// Status the input proc returns when it has nothing more for this call (not the end of the stream).
private let noMoreInputNow: OSStatus = 0x6E6F6D6F   // 'nomo'

private let inputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDescriptions, user in
    let input = Unmanaged<ConverterInput>.fromOpaque(user!).takeUnretainedValue()
    guard !input.given else {
        ioPackets.pointee = 0
        ioData.pointee.mBuffers.mDataByteSize = 0
        ioData.pointee.mBuffers.mData = nil
        return noMoreInputNow
    }
    input.given = true
    ioData.pointee.mBuffers.mData = input.buffer
    ioData.pointee.mBuffers.mDataByteSize = UInt32(input.count)
    if input.isPacketized {
        ioPackets.pointee = 1
        input.packet.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(input.count))
        outDescriptions?.pointee = input.packet
    } else {
        ioData.pointee.mBuffers.mNumberChannels = 2
        ioPackets.pointee = UInt32(input.count / 4)
    }
    return noErr
}

/// Apple's ALAC encoder, one 352-frame packet at a time.
public final class ALACEncoder: @unchecked Sendable {
    private let converter: AudioConverterRef
    private let maxPacket: UInt32
    private let input = ConverterInput()

    public init(config: ALACConfig = ALACConfig()) throws {
        var source = PCM16.format(), target = PCM16.alac()
        var made: AudioConverterRef?
        let status = AudioConverterNew(&source, &target, &made)
        guard status == noErr, let made else { throw ALACError.converter(status) }
        converter = made
        var size: UInt32 = 0
        AudioConverterGetPropertyInfo(made, kAudioConverterCompressionMagicCookie, &size, nil)
        var cookie = Data(count: Int(size))
        let got = cookie.withUnsafeMutableBytes { AudioConverterGetProperty(made, kAudioConverterCompressionMagicCookie, &size, $0.baseAddress!) }
        var max: UInt32 = 0, maxSize = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(made, kAudioConverterPropertyMaximumOutputPacketSize, &maxSize, &max)
        maxPacket = Swift.max(max, 2048)
        // What the receiver decodes with is the SDP's configuration: the encoder must be using the same one.
        guard got == noErr, config.decodesLike(cookie: cookie) else {
            AudioConverterDispose(made)
            throw ALACError.cookieMismatch
        }
    }

    deinit { AudioConverterDispose(converter) }

    /// One ALAC packet for 352 interleaved stereo frames (704 samples).
    public func encode(_ samples: [Int16]) throws -> Data {
        guard samples.count == 704 else { throw ALACError.badInput }
        _ = input.set(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        var out = Data(count: Int(maxPacket))
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: maxPacket, mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, inputProc, Unmanaged.passUnretained(input).toOpaque(), &packets, &list, &description)
        }
        guard status == noErr || status == noMoreInputNow, packets == 1 else { throw ALACError.converter(status) }
        return out.prefix(Int(description.mDataByteSize))
    }
}

/// The uncompressed ("escape") ALAC frame: stereo element, no shift, the samples big-endian, the end tag.
public enum ALACVerbatim {
    public static func encode(_ samples: [Int16]) -> Data {
        var w = BitWriter()
        w.write(1, bits: 3)        // ID_CPE: a channel pair
        w.write(0, bits: 4)        // element instance
        w.write(0, bits: 12)       // unused
        w.write(0, bits: 1)        // no frame size: the full 352
        w.write(0, bits: 2)        // no shifted bytes
        w.write(1, bits: 1)        // escape: not compressed
        for s in samples { w.write(UInt32(UInt16(bitPattern: s)), bits: 16) }
        w.write(7, bits: 3)        // ID_END
        return w.data
    }

    struct BitWriter {
        var data = Data()
        var used = 0   // bits used in the last byte (0 = start a new one)
        mutating func write(_ value: UInt32, bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if used == 0 { data.append(0) }
                if (value >> UInt32(i)) & 1 == 1 { data[data.count - 1] |= UInt8(0x80 >> used) }
                used = (used + 1) % 8
            }
        }
    }
}

/// Apple's ALAC decoder, for the configuration an SDP announces.
public final class ALACDecoder: @unchecked Sendable {
    private let converter: AudioConverterRef
    private let input = ConverterInput()

    public init(config: ALACConfig = ALACConfig()) throws {
        var source = PCM16.alac(), target = PCM16.format()
        source.mFramesPerPacket = config.frameLength
        var made: AudioConverterRef?
        let status = AudioConverterNew(&source, &target, &made)
        guard status == noErr, let made else { throw ALACError.converter(status) }
        converter = made
        let cookie = config.cookie
        let set = cookie.withUnsafeBytes { AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!) }
        guard set == noErr else { AudioConverterDispose(made); throw ALACError.converter(set) }
        input.isPacketized = true
    }

    deinit { AudioConverterDispose(converter) }

    /// The interleaved samples of one packet.
    public func decode(_ packet: Data) throws -> [Int16] {
        guard input.set(packet) else { throw ALACError.badInput }
        var out = [Int16](repeating: 0, count: 352 * 2)
        var frames: UInt32 = 352
        let status = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, inputProc, Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == noMoreInputNow else { throw ALACError.converter(status) }
        return Array(out.prefix(Int(frames) * 2))
    }
}
