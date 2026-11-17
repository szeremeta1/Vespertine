//
// Vespertine: Apple Lossless packets of 352 stereo frames, as RAOP carries them: 16-bit at 44.1 kHz, which is all AirPlay 1
// has, and the 24-bit and 48 kHz ones an AirPlay 2 stream can name. Encoded with Apple's own encoder (AudioConverter,
// kAudioFormatAppleLossless), whose configuration must be the one announced; when it can't be had, the "verbatim" ALAC
// frame (the samples uncompressed in an ALAC element, as OwnTone sends it) is lossless by construction. The decoder is
// for the test receiver and the round-trip checks.
//
// 24-bit samples go to and from Apple's converter as three bytes each, the form its ALAC codec takes as it is, so that
// nothing stands between the samples and the codec that could change one.
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

/// The two sides of a conversion for a configuration: stereo samples of its depth (two bytes each at 16 bits, three at
/// 24), and ALAC packets of its frame length.
enum ALACStream {
    static func isSupported(_ config: ALACConfig) -> Bool {
        (config.bitDepth == 16 || config.bitDepth == 24) && config.channels == 2 && config.frameLength > 0
    }

    static func bytesPerSample(_ config: ALACConfig) -> Int { Int(config.bitDepth) / 8 }

    static func pcm(_ config: ALACConfig) -> AudioStreamBasicDescription {
        let frame = UInt32(bytesPerSample(config)) * 2
        return AudioStreamBasicDescription(mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: frame,
                                           mFramesPerPacket: 1, mBytesPerFrame: frame, mChannelsPerFrame: 2,
                                           mBitsPerChannel: UInt32(config.bitDepth), mReserved: 0)
    }

    static func alac(_ config: ALACConfig) -> AudioStreamBasicDescription {
        let flag = config.bitDepth == 24 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_16BitSourceData
        return AudioStreamBasicDescription(mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatAppleLossless, mFormatFlags: flag,
                                           mBytesPerPacket: 0, mFramesPerPacket: config.frameLength, mBytesPerFrame: 0, mChannelsPerFrame: 2,
                                           mBitsPerChannel: 0, mReserved: 0)
    }

    /// The samples as the converter takes them: little-endian, `bytesPerSample` bytes each.
    static func bytes(_ samples: [Int32], config: ALACConfig) -> Data {
        let width = bytesPerSample(config)
        var data = Data(capacity: samples.count * width)
        for sample in samples {
            let bits = UInt32(bitPattern: sample)
            for byte in 0..<width { data.append(UInt8((bits >> UInt32(8 * byte)) & 0xff)) }
        }
        return data
    }

    /// The samples the converter gave, sign-extended.
    static func samples(_ data: Data, config: ALACConfig) -> [Int32] {
        let width = bytesPerSample(config)
        let bytes = [UInt8](data)
        let unused = UInt32(32 - 8 * width)
        return (0..<(bytes.count / width)).map { index in
            var bits: UInt32 = 0
            for byte in 0..<width { bits |= UInt32(bytes[index * width + byte]) << UInt32(8 * byte) }
            return Int32(bitPattern: bits << unused) >> Int32(unused)
        }
    }

    /// Whether every sample fits the configuration's depth.
    static func fits(_ samples: [Int32], config: ALACConfig) -> Bool {
        let limit = Int32(1) << Int32(config.bitDepth - 1)
        return samples.allSatisfy { $0 >= -limit && $0 < limit }
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
    /// Bytes in one stereo frame of the samples held (when they aren't a packet).
    var bytesPerFrame = 4

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
        ioPackets.pointee = UInt32(input.count / input.bytesPerFrame)
    }
    return noErr
}

/// Apple's ALAC encoder, one packet (352 frames, unless the configuration says otherwise) at a time.
public final class ALACEncoder: @unchecked Sendable {
    public let config: ALACConfig
    private let converter: AudioConverterRef
    private let maxPacket: UInt32
    private let input = ConverterInput()

    public init(config: ALACConfig = ALACConfig()) throws {
        guard ALACStream.isSupported(config) else { throw ALACError.badInput }
        self.config = config
        let frameBytes = ALACStream.bytesPerSample(config) * 2
        var source = ALACStream.pcm(config), target = ALACStream.alac(config)
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
        // Room for a packet that didn't compress, whatever the converter says: 352 frames of 24 bits are 2112 bytes.
        maxPacket = Swift.max(max, UInt32(Int(config.frameLength) * frameBytes) + 64, 2048)
        input.bytesPerFrame = frameBytes
        // What the receiver decodes with is the SDP's configuration: the encoder must be using the same one.
        guard got == noErr, config.decodesLike(cookie: cookie) else {
            AudioConverterDispose(made)
            throw ALACError.cookieMismatch
        }
    }

    deinit { AudioConverterDispose(converter) }

    /// One ALAC packet for 352 interleaved stereo frames (704 samples) of a 16-bit configuration.
    public func encode(_ samples: [Int16]) throws -> Data {
        guard config.bitDepth == 16 else { throw ALACError.badInput }
        return try encode(samples: samples.map { Int32($0) })
    }

    /// One ALAC packet for a packet's worth of interleaved stereo frames, each sample a value of the configuration's
    /// depth (a 24-bit sample is between -8 388 608 and 8 388 607).
    public func encode(samples: [Int32]) throws -> Data {
        guard samples.count == Int(config.frameLength) * 2, ALACStream.fits(samples, config: config) else { throw ALACError.badInput }
        guard input.set(ALACStream.bytes(samples, config: config)) else { throw ALACError.badInput }
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
        encode(samples: samples.map { Int32($0) }, bitDepth: 16)
    }

    /// The same frame for samples of `bitDepth` bits (16 or 24), each written in that many bits.
    public static func encode(samples: [Int32], bitDepth: Int) -> Data {
        var w = BitWriter()
        w.write(1, bits: 3)        // ID_CPE: a channel pair
        w.write(0, bits: 4)        // element instance
        w.write(0, bits: 12)       // unused
        w.write(0, bits: 1)        // no frame size: the full 352
        w.write(0, bits: 2)        // no shifted bytes
        w.write(1, bits: 1)        // escape: not compressed
        let mask: UInt32 = bitDepth >= 32 ? .max : (UInt32(1) << UInt32(bitDepth)) - 1
        for s in samples { w.write(UInt32(bitPattern: s) & mask, bits: bitDepth) }
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
    public let config: ALACConfig
    private let converter: AudioConverterRef
    private let input = ConverterInput()

    public init(config: ALACConfig = ALACConfig()) throws {
        guard ALACStream.isSupported(config) else { throw ALACError.badInput }
        self.config = config
        var source = ALACStream.alac(config), target = ALACStream.pcm(config)
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

    /// The interleaved samples of one packet of a 16-bit configuration.
    public func decode(_ packet: Data) throws -> [Int16] {
        guard config.bitDepth == 16 else { throw ALACError.badInput }
        return try decode(samples: packet).map { Int16(truncatingIfNeeded: $0) }
    }

    /// The interleaved samples of one packet, each a value of the configuration's depth.
    public func decode(samples packet: Data) throws -> [Int32] {
        guard input.set(packet) else { throw ALACError.badInput }
        let frameBytes = ALACStream.bytesPerSample(config) * 2
        var out = Data(count: Int(config.frameLength) * frameBytes)
        var frames = config.frameLength
        let status = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, inputProc, Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == noMoreInputNow else { throw ALACError.converter(status) }
        return ALACStream.samples(Data(out.prefix(Int(frames) * frameBytes)), config: config)
    }
}
