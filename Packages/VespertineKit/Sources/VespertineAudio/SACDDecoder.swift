//
// Vespertine — SACD image playback: an area's audio frames (plain DSD or DST, which is decoded to DSD here),
// handed on as raw DSD for DoP (RawDoPDecoder) or converted to PCM by FFmpeg's DSD decoder, the same path
// DSDIFF files take.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineDTS
import Foundation
import SFBAudioEngine

/// Reads an area's audio sectors in order and hands back whole frames (1/75 s each), with their time codes.
///
/// Every audio sector starts with a header: how many packets it holds, how many frames start in it, and whether
/// they are DST-compressed. Each packet says whether a frame starts with it, what it holds (audio, supplementary
/// data, padding) and how long it is; each frame start has a time code. A frame's audio is its packets in order.
/// Only whole frames are handed back: a DST frame with all the packets it declares, a plain one with exactly its
/// DSD. A frame cut short by a damaged sector is left out, and plays as silence (`SACDSource`).
final class SACDFrameReader {
    struct Frame {
        var timecode: Int
        var data: [UInt8]
        var isDST: Bool
    }

    private let handle: FileHandle
    let area: SACDImage.Area
    /// The next sector to parse.
    private var sector: Int
    private var building: Frame?
    /// Audio packets still to come for the frame being built (DST frames say how many they have).
    private var packetsLeft = 0
    /// Frames ready, in order.
    private var ready: [Frame] = []
    /// Sectors read ahead in one go (64 KB).
    private var buffer: [UInt8] = []
    private var bufferStart = -1
    private static let readAhead = 32

    init(url: URL, area: SACDImage.Area) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.area = area
        sector = area.firstSector
    }

    deinit { try? handle.close() }

    /// Sector `s`, from the read-ahead buffer. `ahead` reads the sectors after it too (sequential reading); a
    /// seek's probes read one at a time.
    private func load(_ s: Int, ahead: Bool = true) throws -> ArraySlice<UInt8>? {
        let size = SACDImage.sectorSize
        if bufferStart < 0 || s < bufferStart || (s - bufferStart + 1) * size > buffer.count {
            let count = ahead ? min(Self.readAhead, area.lastSector - s + 1) : 1
            guard count > 0 else { return nil }
            buffer = try SACDImage.sectors(handle, s, count, area.layout)
            bufferStart = s
            guard buffer.count >= size else { return nil }
        }
        let o = (s - bufferStart) * size
        return buffer[o..<o + size]
    }

    /// The time code of the first frame starting in sector `s` or after it; nil if none does.
    private func firstStart(from s: Int) throws -> Int? {
        for s in s...max(s, area.lastSector) {
            guard let data = try load(s, ahead: false) else { return nil }
            let b = data.startIndex
            let packets = Int(data[b] >> 5), starts = Int(data[b] >> 2 & 7)
            let o = b + 1 + 2 * packets
            if starts > 0, o + 3 <= data.endIndex {
                return (Int(data[o]) * 60 + Int(data[o + 1])) * SACDImage.framesPerSecond + Int(data[o + 2])
            }
        }
        return nil
    }

    /// Positions the reader so the next frame it returns is the one with time code `timecode` (or the first after it).
    func seek(toFrame timecode: Int) throws {
        // The sectors' first frame starts only grow: find the last sector whose first start is at or before the frame.
        var lo = area.firstSector, hi = area.lastSector
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            if let start = try firstStart(from: mid), start <= timecode { lo = mid } else { hi = mid - 1 }
        }
        sector = lo
        building = nil
        packetsLeft = 0
        ready.removeAll()
        while let frame = try peek(), frame.timecode < timecode { ready.removeFirst() }
    }

    private func peek() throws -> Frame? {
        while ready.isEmpty {
            guard sector <= area.lastSector, let data = try load(sector) else {
                building = nil      // the end of the area: a frame still being built is incomplete
                return nil
            }
            sector += 1
            parse(data)
        }
        return ready.first
    }

    func next() throws -> Frame? {
        guard let frame = try peek() else { return nil }
        ready.removeFirst()
        return frame
    }

    private func parse(_ data: ArraySlice<UInt8>) {
        let b = data.startIndex
        let packets = Int(data[b] >> 5), starts = Int(data[b] >> 2 & 7), dst = data[b] & 1 == 1
        var p = b + 1
        var infos: [(length: Int, type: Int, frameStart: Bool)] = []
        for _ in 0..<packets {
            infos.append((Int(data[p] & 7) << 8 | Int(data[p + 1]), Int(data[p] >> 3 & 7), data[p] & 0x80 != 0))
            p += 2
        }
        // At most 7 packets of at most 2045 bytes: anything else is a damaged sector.
        guard packets <= 7, infos.allSatisfy({ $0.length <= 2045 }) else { building = nil; return }
        var timecodes: [(timecode: Int, packets: Int)] = []
        for _ in 0..<starts {
            guard p + 3 <= data.endIndex else { return }
            let tc = (Int(data[p]) * 60 + Int(data[p + 1])) * SACDImage.framesPerSecond + Int(data[p + 2])
            timecodes.append((tc, dst && p + 4 <= data.endIndex ? Int(data[p + 3] >> 2 & 0x1F) : 0))
            p += dst ? 4 : 3
        }
        var nextStart = 0
        let plainSize = area.frameBytes * area.channels
        for packet in infos {
            guard p + packet.length <= data.endIndex else { building = nil; return }   // a damaged sector
            defer { p += packet.length }
            guard packet.type == 2 else { continue }       // supplementary data, padding
            if packet.frameStart {
                // A frame still being built never got all of its audio.
                let tc = nextStart < timecodes.count ? timecodes[nextStart].timecode : (building?.timecode ?? -1) + 1
                packetsLeft = nextStart < timecodes.count ? timecodes[nextStart].packets : 0
                nextStart += 1
                building = Frame(timecode: tc, data: [], isDST: dst)
                building?.data.reserveCapacity(dst ? 8192 : plainSize)
            }
            guard building != nil else { continue }        // the tail of a frame that started before a seek
            building!.data.append(contentsOf: data[p..<p + packet.length])
            packetsLeft -= 1
            // Complete: a DST frame once all its packets are in, a plain one at its full size.
            if (building!.isDST && packetsLeft == 0) || (!building!.isDST && building!.data.count == plainSize) {
                ready.append(building!)
                building = nil
            } else if packetsLeft < 0 && building!.isDST || building!.data.count > (building!.isDST ? 1 << 16 : plainSize) {
                building = nil                              // more than the frame declared, or longer than any frame: damage
            }
        }
    }
}

/// Raw DSD from an SACD area, between two frames (a track): one byte per channel per position, decoded from DST
/// when the area is compressed. Damaged frames play as DSD silence, and are counted (`concealedFrames`), so the
/// signal path doesn't claim them bit-perfect.
final class SACDSource: RawDSDSource {
    let url: URL
    let area: SACDImage.Area
    /// The frames this source covers, in the area's time code.
    let frames: Range<Int>
    private let reader: SACDFrameReader
    private let dst: OpaquePointer?
    /// The current frame, decoded: frameBytes bytes per channel, interleaved by channel.
    private var frame: [UInt8]
    private var frameIndex: Int
    private var offset: Int
    private var loaded = false
    private var badInARow = 0
    private(set) var isOpen = true
    /// Frames played as silence because they were missing or damaged in the image.
    private(set) var concealedFrames = 0

    init(url: URL, area: SACDImage.Area, frames: Range<Int>) throws {
        self.url = url
        self.area = area
        self.frames = frames
        reader = try SACDFrameReader(url: url, area: area)
        if area.isDST {
            guard let d = ndst_create(Int32(area.channels), Int32(area.frameBytes)) else { throw SACDError.damaged("DST") }
            dst = d
        } else {
            dst = nil
        }
        frame = [UInt8](repeating: 0x69, count: area.frameBytes * area.channels)
        frameIndex = frames.lowerBound
        offset = 0
        try reader.seek(toFrame: frames.lowerBound)
    }

    deinit { if let dst { ndst_destroy(dst) } }

    var channelCount: Int { area.channels }
    var dsdRate: Double { area.sampleRate }
    var dsdLength: Int64 { Int64(frames.count) * Int64(area.frameBytes) }
    var dsdPosition: Int64 { Int64(frameIndex - frames.lowerBound) * Int64(area.frameBytes) + Int64(offset) }
    var inputSource: InputSource { (try? InputSource(for: url)) ?? InputSource(data: Data()) }
    func close() throws { isOpen = false }

    /// Decodes the frame at `frameIndex` into `frame`. A frame missing from the image (a damaged rip) is silence.
    private func load() throws {
        loaded = true
        var found: SACDFrameReader.Frame?
        while let f = try reader.next() {
            if f.timecode < frameIndex { continue }
            found = f
            break
        }
        guard let f = found, f.timecode == frameIndex else {
            if let f = found { try reader.seek(toFrame: f.timecode) }   // a gap: keep the frame after it for later
            frame.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress!, 0x69, $0.count) }
            return try conceal()
        }
        if f.isDST, let dst {
            let ok = f.data.withUnsafeBufferPointer { src in
                frame.withUnsafeMutableBufferPointer { ndst_decode(dst, src.baseAddress!, Int32(src.count), $0.baseAddress!) }
            }
            if ok { badInARow = 0 } else { try conceal() }
        } else if !f.isDST, f.data.count == frame.count {
            frame = f.data
            badInARow = 0
        } else {
            frame.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress!, 0x69, $0.count) }
            try conceal()
        }
    }

    /// A few damaged frames play as silence; a long run of them means the image can't be read.
    private func conceal() throws {
        concealedFrames += 1
        badInARow += 1
        if badInARow > 32 { throw SACDError.damaged("audio frames") }
    }

    /// Reads up to `bytes` bytes per channel, interleaved by channel. Returns bytes per channel, 0 at the end.
    func readInterleaved(into out: UnsafeMutablePointer<UInt8>, bytes: Int) throws -> Int {
        let channels = area.channels, size = area.frameBytes
        var written = 0
        while written < bytes, frameIndex < frames.upperBound {
            if !loaded { try load() }
            let n = min(bytes - written, size - offset)
            frame.withUnsafeBufferPointer { src in
                (out + written * channels).update(from: src.baseAddress! + offset * channels, count: n * channels)
            }
            written += n
            offset += n
            if offset == size { offset = 0; frameIndex += 1; loaded = false }
        }
        return written
    }

    func readDSD(into planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
        let channels = area.channels, size = area.frameBytes
        var written = 0
        while written < bytes, frameIndex < frames.upperBound {
            if !loaded { try load() }
            let n = min(bytes - written, size - offset)
            frame.withUnsafeBufferPointer { src in
                for c in 0..<channels {
                    let plane = planes[c] + written
                    var s = src.baseAddress! + offset * channels + c
                    for i in 0..<n { plane[i] = s.pointee; s += channels }
                }
            }
            written += n
            offset += n
            if offset == size { offset = 0; frameIndex += 1; loaded = false }
        }
        return written
    }

    func seekDSD(to position: Int64) throws {
        let position = max(0, min(position, dsdLength))
        let target = frames.lowerBound + Int(position / Int64(area.frameBytes))
        // Within the frame in hand, or at the next one in line, the reader is already where it needs to be.
        if target != frameIndex {
            try reader.seek(toFrame: target)
            frameIndex = target
            loaded = false
        }
        offset = Int(position % Int64(area.frameBytes))
    }
}

/// One stretch of an SACD area (a track, or the whole area) converted to PCM at the DSD rate / 8 by FFmpeg's
/// DSD decoder, as DSDIFF files are. Seeks start a frame early and drop it, so the converter's filter is primed
/// with the music before the seek point: a track that follows another comes out exactly as if the area had
/// been converted in one piece.
final class SACDPCMDecoder: NSObject, PCMDecoding, ConcealingDecoder {
    private let source: SACDSource
    /// Frames of DSD before the stretch this decoder plays, read only to prime the filter.
    private let leadIn: Int64
    private var converter: OpaquePointer?
    private let format: AVAudioFormat
    private var frame: AVAudioFramePosition = 0
    private var scratch: [UInt8] = []

    init(url: URL, area: SACDImage.Area, frames: Range<Int>) throws {
        let first = area.frameRange.lowerBound
        let start = frames.lowerBound > first ? frames.lowerBound - 1 : frames.lowerBound
        source = try SACDSource(url: url, area: area, frames: start..<frames.upperBound)
        leadIn = Int64(frames.lowerBound - start) * Int64(area.frameBytes)
        format = SACDPCMDecoder.format(rate: area.sampleRate / 8, channels: area.channels)
        super.init()
        try seek(to: 0)
    }

    deinit { if let converter { nff_dsd_converter_destroy(converter) } }

    static func format(rate: Double, channels: Int) -> AVAudioFormat {
        if channels > 2, let layout = ChannelLayouts.layout(channels: channels) {
            return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
    }

    var inputSource: InputSource { source.inputSource }
    var sourceFormat: AVAudioFormat { format }
    var processingFormat: AVAudioFormat { format }
    var decodingIsLossless: Bool { false }
    var properties: [AudioDecodingPropertiesKey: Any] { [:] }
    var isOpen: Bool { source.isOpen }
    var supportsSeeking: Bool { true }
    var position: AVAudioFramePosition { frame }
    var length: AVAudioFramePosition { source.dsdLength - leadIn }
    var concealedFrames: Int { source.concealedFrames }
    func open() throws {}
    func close() throws { try source.close() }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard let out = buffer.floatChannelData else { throw DTSError.decoding }
        let want = Int(min(length, buffer.frameCapacity))
        let got = try convert(want, into: (0..<source.channelCount).map { out[$0] })
        buffer.frameLength = AVAudioFrameCount(got)
        frame += AVAudioFramePosition(got)
    }

    /// One PCM frame per DSD byte.
    private func convert(_ count: Int, into planes: [UnsafeMutablePointer<Float>]) throws -> Int {
        guard let converter else { throw DTSError.decoding }
        let channels = source.channelCount
        if scratch.count < count * channels { scratch = [UInt8](repeating: 0, count: count * channels) }
        let got = try scratch.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: count) }
        guard got > 0 else { return 0 }
        let n = scratch.withUnsafeBufferPointer { src in
            planes.withUnsafeBufferPointer { nff_dsd_convert(converter, src.baseAddress!, Int32(got), $0.baseAddress!) }
        }
        guard n == got else { throw DTSError.decoding }
        return got
    }

    func seek(to target: AVAudioFramePosition) throws {
        let target = max(0, min(target, length))
        // Prime a fresh filter with up to a frame of the music before the target.
        let prime = min(Int64(source.area.frameBytes), leadIn + target)
        if let converter { nff_dsd_converter_destroy(converter) }
        converter = nff_dsd_converter_create(Int32(source.channelCount), Int32(source.dsdRate / 8))
        guard converter != nil else { throw DTSError.unsupported("DSD converter") }
        try source.seekDSD(to: leadIn + target - prime)
        if prime > 0 {
            let sink = (0..<source.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Int(prime)) }
            defer { sink.forEach { $0.deallocate() } }
            _ = try convert(Int(prime), into: sink)
        }
        frame = target
    }
}
