//
// Vespertine — DSD inside WavPack (.wv). libwavpack opens such a file as the DSD bitstream itself, so the bytes go
// to DoP, or through the shared DSD-to-PCM converter, exactly as stored. SFBAudioEngine's WavPack decoder doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SFBAudioEngine
import CVespertineWavPack

/// The stream behind a libwavpack context: a `PlaybackFile` (so a track on a network share reads from its cache) and
/// its position, which `PlaybackFile` keeps to itself.
private final class WavPackReader {
    let file: PlaybackFile
    let size: Int64
    var position: Int64 = 0
    init(url: URL) throws {
        file = try PlaybackFile(forReadingFrom: url)
        size = Int64(try file.seekToEnd())
        try file.seek(toOffset: 0)
    }
    func seek(to target: Int64) -> Bool {
        guard target >= 0, target <= size, (try? file.seek(toOffset: UInt64(target))) != nil else { return false }
        position = target
        return true
    }
}

/// A WavPack file holding DSD, read as the 1-bit stream: one byte per channel per eight bits, most significant bit
/// first (libwavpack puts every source, DSF's LSB-first included, in that order).
final class WavPackDSDSource: InterleavedDSDSource {
    let url: URL
    private let reader: WavPackReader
    private let streamReader: UnsafeMutablePointer<WavpackStreamReader64>
    private var context: OpaquePointer?
    let channelCount: Int
    let dsdRate: Double
    /// Bytes per channel.
    let dsdLength: Int64
    /// The speakers libwavpack reports as a WAVE channel mask (0 when the file names none).
    let channelMask: UInt32
    private(set) var isOpen = true
    private var position: Int64 = 0
    private var scratch: [Int32] = []

    /// nil for a WavPack file that isn't DSD (the PCM decoder takes it); throws for one that can't be read.
    init?(url: URL) throws {
        let box = try WavPackReader(url: url)
        let streamReader = UnsafeMutablePointer<WavpackStreamReader64>.allocate(capacity: 1)
        streamReader.initialize(to: WavpackStreamReader64(
            read_bytes: { id, data, count in
                let box = Unmanaged<WavPackReader>.fromOpaque(id!).takeUnretainedValue()
                var got = 0
                while got < Int(count) {
                    guard let chunk = try? box.file.read(upToCount: Int(count) - got), !chunk.isEmpty else { break }
                    chunk.copyBytes(to: (data!).assumingMemoryBound(to: UInt8.self) + got, count: chunk.count)
                    got += chunk.count
                }
                box.position += Int64(got)
                return Int32(got)
            },
            write_bytes: nil,
            get_pos: { id in Unmanaged<WavPackReader>.fromOpaque(id!).takeUnretainedValue().position },
            set_pos_abs: { id, pos in Unmanaged<WavPackReader>.fromOpaque(id!).takeUnretainedValue().seek(to: pos) ? 0 : -1 },
            set_pos_rel: { id, delta, mode in
                let box = Unmanaged<WavPackReader>.fromOpaque(id!).takeUnretainedValue()
                let base = mode == SEEK_SET ? 0 : mode == SEEK_CUR ? box.position : box.size
                return box.seek(to: base + delta) ? 0 : -1
            },
            push_back_byte: { id, byte in
                let box = Unmanaged<WavPackReader>.fromOpaque(id!).takeUnretainedValue()
                return box.seek(to: box.position - 1) ? byte : -1
            },
            get_length: { id in Unmanaged<WavPackReader>.fromOpaque(id!).takeUnretainedValue().size },
            can_seek: { _ in 1 },
            truncate_here: nil,
            close: { _ in 0 }))
        var error = [CChar](repeating: 0, count: 80)
        let id = Unmanaged.passUnretained(box).toOpaque()
        guard let opened = vtwv_WavpackOpenFileInputEx64(streamReader, id, nil, &error, Int32(OPEN_DSD_NATIVE | OPEN_ALT_TYPES), 0) else {
            streamReader.deallocate(); try? box.file.close()
            // A WavPack file that isn't DSD opens fine in this mode, so this is a damaged or unsupported one.
            throw DTSError.unsupported(String(cString: error))
        }
        // In native mode a PCM file opens too: DSD is the one whose native rate is eight times its "sample" rate.
        let byteRate = vtwv_WavpackGetSampleRate(opened), nativeRate = vtwv_WavpackGetNativeSampleRate(opened)
        guard byteRate > 0, nativeRate == byteRate * 8 else {
            _ = vtwv_WavpackCloseFile(opened); streamReader.deallocate(); try? box.file.close()
            return nil
        }
        let channels = Int(vtwv_WavpackGetNumChannels(opened)), length = vtwv_WavpackGetNumSamples64(opened)
        guard channels > 0, length >= 0 else {
            _ = vtwv_WavpackCloseFile(opened); streamReader.deallocate(); try? box.file.close()
            throw DTSError.unsupported(String(localized: "channels", comment: "Why a file can't be played, in “This file can't be played (…).”"))
        }
        self.url = url
        reader = box
        self.streamReader = streamReader
        context = opened
        channelCount = channels
        dsdRate = Double(nativeRate)
        dsdLength = length
        channelMask = UInt32(truncatingIfNeeded: vtwv_WavpackGetChannelMask(opened))
    }

    deinit { try? close(); streamReader.deallocate() }

    var inputSource: InputSource { (try? InputSource(for: url)) ?? InputSource(data: Data()) }

    func close() throws {
        guard isOpen else { return }
        isOpen = false
        if let context { _ = vtwv_WavpackCloseFile(context) }
        context = nil
        try? reader.file.close()
    }

    /// Tag items (APEv2) by name, for the library; WavPack keeps them at the end of the file.
    static func tags(of url: URL) -> [String: String] {
        guard let source = try? WavPackDSDSource(url: url), let context = source.context else { return [:] }
        var out: [String: String] = [:]
        for index in 0..<Int(vtwv_WavpackGetNumTagItems(context)) {
            var name = [CChar](repeating: 0, count: 64)
            guard vtwv_WavpackGetTagItemIndexed(context, Int32(index), &name, 64) > 0 else { continue }
            let key = String(cString: name)
            let length = vtwv_WavpackGetTagItem(context, key, nil, 0)
            guard length > 0 else { continue }
            var value = [CChar](repeating: 0, count: Int(length) + 1)
            guard vtwv_WavpackGetTagItem(context, key, &value, Int32(value.count)) > 0 else { continue }
            out[key] = String(cString: value)
        }
        return out
    }

    /// Reads `bytes` bytes per channel (fewer at the end), interleaved by channel as libwavpack hands them over.
    func readInterleaved(into out: UnsafeMutablePointer<UInt8>, bytes: Int) throws -> Int {
        guard isOpen, let context, bytes >= 0 else { throw DTSError.decoding }
        let channels = channelCount
        var written = 0
        while written < bytes, position < dsdLength {
            let want = min(bytes - written, 16384, Int(dsdLength - position))
            if scratch.count < want * channels { scratch = [Int32](repeating: 0, count: want * channels) }
            let got = Int(vtwv_WavpackUnpackSamples(context, &scratch, UInt32(want)))
            // Fewer samples than the header promised is a damaged or truncated file, not an early end of track.
            guard got > 0, vtwv_WavpackGetNumErrors(context) == 0 else { throw DTSError.decoding }
            for i in 0..<got * channels { out[written * channels + i] = UInt8(truncatingIfNeeded: scratch[i]) }
            written += got; position += Int64(got)
        }
        return written
    }

    func readDSD(into planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
        var data = [UInt8](repeating: 0, count: max(0, bytes) * channelCount)
        let n = try data.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return 0 }
            return try readInterleaved(into: base, bytes: bytes)
        }
        for c in 0..<channelCount { for i in 0..<n { planes[c][i] = data[i * channelCount + c] } }
        return n
    }

    func seekDSD(to target: Int64) throws {
        guard isOpen, let context else { throw DTSError.decoding }
        let clamped = min(max(0, target), dsdLength)
        // Seeking to the very end is allowed (nothing left to read); libwavpack refuses it.
        if clamped < dsdLength { guard vtwv_WavpackSeekSample64(context, clamped) != 0 else { throw DTSError.decoding } }
        position = clamped
    }
}
