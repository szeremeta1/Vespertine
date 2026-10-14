//
// Vespertine — DVD-Video program streams: 2048-byte packs, NAV packs (PCI/DSI: VOBU times, VOB and cell IDs) and
// private stream 1 LPCM audio (substreams 0xA0–0xA7). The LPCM payload is de-interleaved here, including the
// grouped byte layout of 20- and 24-bit samples. Pack and PES syntax follow ISO/IEC 13818-1; the NAV pack and
// LPCM header layouts follow the open-source libdvdread / dvdauthor documentation. Vespertine's own reader.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// MARK: - LPCM format

/// A DVD-Video LPCM stream's format, from the 3-byte header every LPCM packet carries.
public struct DVDLPCMFormat: Sendable, Hashable, CustomStringConvertible {
    public var bits: Int
    public var sampleRate: Int
    public var channels: Int

    /// DVD-Video caps an LPCM stream at 6.144 Mbit/s: 16-bit up to 8 channels at 48 kHz and 4 at 96 kHz, 20-bit up
    /// to 6 / 3, 24-bit up to 5 / 2. Anything above that isn't a DVD-Video stream (a misread or damaged header).
    public static let maximumBitRate = 6_144_000

    public init(bits: Int, sampleRate: Int, channels: Int) throws {
        guard [16, 20, 24].contains(bits) else { throw DVDVideoError.unsupportedAudio(String(localized: "LPCM sample size", comment: "Why DVD audio can't be played.")) }
        guard [48_000, 96_000].contains(sampleRate) else {
            throw DVDVideoError.unsupportedAudio(String(localized: "LPCM at \(sampleRate) Hz", comment: "Why DVD audio can't be played: a sample rate DVD-Video doesn't allow."))
        }
        guard (1...8).contains(channels), bits * sampleRate * channels <= Self.maximumBitRate else {
            throw DVDVideoError.unsupportedAudio(String(localized: "\(channels)-channel \(bits)-bit LPCM at \(sampleRate / 1000) kHz exceeds DVD-Video's limit",
                                                        comment: "Why DVD audio can't be played."))
        }
        self.bits = bits
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// The header's second byte: quantization (bits 7–6), sampling frequency (5–4), channels − 1 (2–0).
    public init(header byte: UInt8) throws {
        let quantization = Int(byte >> 6), frequency = Int(byte >> 4 & 3)
        guard quantization < 3 else { throw DVDVideoError.unsupportedAudio(String(localized: "LPCM sample size", comment: "Why DVD audio can't be played.")) }
        // 44.1 kHz (2) and 32 kHz (3) are codes DVD-Video doesn't allow.
        let rate = [48_000, 96_000, 44_100, 32_000][frequency]
        try self.init(bits: [16, 20, 24][quantization], sampleRate: rate, channels: Int(byte & 7) + 1)
    }

    /// The header byte this format is written with.
    public var headerByte: UInt8 {
        UInt8([16: 0, 20: 1, 24: 2][bits]! << 6 | (sampleRate == 96_000 ? 1 : 0) << 4 | (channels - 1))
    }

    /// Sample frames in one storage unit: 20- and 24-bit samples are stored in pairs of sample frames.
    public var unitFrames: Int { bits == 16 ? 1 : 2 }
    /// Bytes in one storage unit.
    public var unitBytes: Int { unitFrames * channels * bits / 8 }
    /// An LPCM access unit (audio frame) lasts 1/600 s.
    public var framesPerAccessUnit: Int { sampleRate / 600 }
    public var description: String { "\(bits)-bit \(sampleRate / 1000) kHz \(channels) ch" }

    /// Sample frames from 90 kHz ticks; nil when the ticks don't land on a sample (not on the stream's lattice).
    func frames(ticks: Int64) -> Int64? {
        let product = ticks * Int64(sampleRate)
        return product % 90_000 == 0 ? product / 90_000 : nil
    }

    /// The sample frame nearest a 90 kHz time (ties go later).
    func nearestFrame(ticks: Int64) -> Int64 {
        let product = ticks * Int64(sampleRate) * 2 + 90_000
        return product >= 0 ? product / 180_000 : -((-product + 179_999) / 180_000)
    }

    /// De-interleaves `units` storage units into interleaved, left-justified 32-bit samples (`unitFrames × channels`
    /// per unit). 16-bit: big-endian samples, frame by frame. 20/24-bit: for each pair of frames, the upper 16 bits
    /// of every sample (frame 0's channels, then frame 1's), then the low bits in the same order: one byte each for
    /// 24-bit, one nibble each for 20-bit (high nibble first).
    public func deinterleave(_ src: UnsafePointer<UInt8>, units: Int, into out: UnsafeMutablePointer<Int32>) {
        let samples = unitFrames * channels
        var s = src, o = out
        switch bits {
        case 16:
            for _ in 0..<units * samples {
                o.pointee = Int32(bitPattern: UInt32(s[0]) << 24 | UInt32(s[1]) << 16)
                o += 1; s += 2
            }
        case 24:
            for _ in 0..<units {
                let low = s + 2 * samples
                for i in 0..<samples {
                    o[i] = Int32(bitPattern: UInt32(s[2 * i]) << 24 | UInt32(s[2 * i + 1]) << 16 | UInt32(low[i]) << 8)
                }
                o += samples; s += 3 * samples
            }
        default:    // 20
            for _ in 0..<units {
                let low = s + 2 * samples
                for i in 0..<samples {
                    let nibble = i & 1 == 0 ? low[i / 2] >> 4 : low[i / 2] & 0x0F
                    o[i] = Int32(bitPattern: UInt32(s[2 * i]) << 24 | UInt32(s[2 * i + 1]) << 16 | UInt32(nibble) << 12)
                }
                o += samples; s += 2 * samples + samples / 2
            }
        }
    }
}

// MARK: - Sectors

/// A title set's title VOBs as one run of 2048-byte sectors (the addresses the IFO and NAV packs use), read ahead.
final class DVDSectorReader {
    private struct Piece { var url: URL; var offset: UInt64; var firstSector: Int; var sectors: Int }
    private var pieces: [Piece] = []
    private var handles: [URL: FileHandle] = [:]
    let sectorCount: Int
    private var buffer: [UInt8] = []
    private var bufferStart = -1
    private static let readAhead = 128

    init(extents: [DVDVideoVolume.Extent]) {
        var sector = 0
        for e in extents {
            // A VOB is whole sectors; a partial one at the end of a truncated file is never read.
            let count = Int(e.length / UInt64(DVDVideoVolume.sectorSize))
            pieces.append(Piece(url: e.url, offset: e.offset, firstSector: sector, sectors: count))
            sector += count
        }
        sectorCount = sector
    }

    deinit { handles.values.forEach { try? $0.close() } }

    private func handle(_ url: URL) throws -> FileHandle {
        if let h = handles[url] { return h }
        let h = try FileHandle(forReadingFrom: url)
        handles[url] = h
        return h
    }

    /// Sector `s`; `ahead` reads on (sequential decoding), otherwise just the one (seeks, probes).
    func sector(_ s: Int, ahead: Bool = true) throws -> ArraySlice<UInt8> {
        let size = DVDVideoVolume.sectorSize
        guard s >= 0, s < sectorCount else { throw DVDVideoError.damaged(String(localized: "sector \(s) is past the end of the VOBs", comment: "Part of “This DVD-Video is damaged (…).”")) }
        if bufferStart < 0 || s < bufferStart || (s - bufferStart + 1) * size > buffer.count {
            guard let i = pieces.lastIndex(where: { $0.firstSector <= s }), s < pieces[i].firstSector + pieces[i].sectors else {
                throw DVDVideoError.damaged("VOB")
            }
            let p = pieces[i]
            // Within one file: the read-ahead stops at its end.
            let count = ahead ? min(Self.readAhead, p.firstSector + p.sectors - s) : 1
            let h = try handle(p.url)
            try h.seek(toOffset: p.offset + UInt64(s - p.firstSector) * UInt64(size))
            let data = [UInt8](try h.read(upToCount: count * size) ?? Data())
            guard data.count >= size else { throw DVDVideoError.damaged(String(localized: "VOB is truncated", comment: "Part of “This DVD-Video is damaged (…).”")) }
            buffer = Array(data.prefix(data.count / size * size))
            bufferStart = s
        }
        let o = (s - bufferStart) * size
        return buffer[o..<o + size]
    }
}

// MARK: - Packs

/// What a NAV pack says about its VOBU.
struct DVDNav: Sendable, Hashable {
    var startPTM: Int64
    var endPTM: Int64
    var vobID: Int
    var cellID: Int
    /// Sectors from this NAV pack to the VOBU's last sector.
    var vobuEnd: Int
}

/// One LPCM packet: its header and where its audio bytes are in the sector.
struct DVDAudioPacket {
    var substream: UInt8
    var pts: Int64?
    /// The first audio frame starting in this packet, as an offset into its audio bytes; nil when none starts here.
    var firstAccessUnit: Int?
    var formatByte: UInt8
    var audio: Range<Int>
}

enum DVDPacks {
    static func damaged(_ what: String) -> DVDVideoError { .damaged(what) }

    /// The NAV pack and the private-stream-1 audio packets in one sector. Throws for a sector that isn't an MPEG-2
    /// pack, or whose packets run past its end.
    static func parse(_ d: ArraySlice<UInt8>, sector: Int, substream: UInt8? = nil) throws -> (nav: DVDNav?, audio: [DVDAudioPacket]) {
        let b = d.startIndex, end = d.endIndex
        guard d.count == DVDVideoVolume.sectorSize, d[b] == 0, d[b + 1] == 0, d[b + 2] == 1, d[b + 3] == 0xBA, d[b + 4] & 0xC0 == 0x40 else {
            throw damaged(String(localized: "sector \(sector) isn't an MPEG-2 pack", comment: "Part of “This DVD-Video is damaged (…).”"))
        }
        var p = b + 14 + Int(d[b + 13] & 7)
        var nav: DVDNav?, audio: [DVDAudioPacket] = []
        var pci: (Int64, Int64)?
        while p + 6 <= end {
            guard d[p] == 0, d[p + 1] == 0, d[p + 2] == 1 else {
                // Padding with no packet header at the end of a sector is allowed only as zero stuffing.
                if d[p..<end].allSatisfy({ $0 == 0xFF || $0 == 0 }) { break }
                throw damaged(String(localized: "packet in sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”"))
            }
            let id = d[p + 3]
            if id == 0xB9 { break }                                     // program end
            let length = Int(d[p + 4]) << 8 | Int(d[p + 5])
            let body = p + 6
            guard body + length <= end else { throw damaged(String(localized: "packet in sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”")) }
            defer { p = body + length }
            if id == 0xBF, length > 0 {
                if d[body] == 0, length >= 0x15 {                       // PCI
                    pci = (Int64(be32(d, body + 1 + 12)), Int64(be32(d, body + 1 + 16)))
                } else if d[body] == 1, length >= 0x20 {                // DSI
                    nav = DVDNav(startPTM: pci?.0 ?? -1, endPTM: pci?.1 ?? -1, vobID: Int(be16(d, body + 1 + 24)),
                                 cellID: Int(d[body + 1 + 27]), vobuEnd: Int(be32(d, body + 1 + 8)))
                }
            } else if id == 0xBD, length >= 3 {
                // MPEG-2 PES header: flags, flags, header length, optional fields; then the substream.
                guard d[body] & 0xC0 == 0x80 else { throw damaged(String(localized: "packet in sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”")) }
                // Scrambled (CSS) payloads would decode as noise: refuse them.
                guard d[body] & 0x30 == 0 else {
                    throw DVDVideoError.unsupportedAudio(String(localized: "encrypted (CSS) sectors", comment: "Why DVD audio can't be played."))
                }
                let headerLength = Int(d[body + 2])
                let payload = body + 3 + headerLength
                guard payload < body + length else { continue }
                let sub = d[payload]
                guard (0xA0...0xA7).contains(sub), substream == nil || sub == substream else { continue }
                guard payload + 7 <= body + length else { throw damaged(String(localized: "LPCM header in sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”")) }
                var pts: Int64?
                if d[body + 1] & 0x80 != 0, headerLength >= 5 {
                    let o = body + 3
                    pts = Int64(d[o] >> 1 & 7) << 30 | Int64(d[o + 1]) << 22 | Int64(d[o + 2] >> 1) << 15 | Int64(d[o + 3]) << 7 | Int64(d[o + 4] >> 1)
                }
                // The pointer counts from its own last byte (header byte 3); audio begins at byte 7.
                let pointer = Int(d[payload + 2]) << 8 | Int(d[payload + 3])
                let audioStart = payload + 7, audioEnd = body + length
                let first: Int? = pointer == 0 ? nil : pointer - 4
                if let first, first < 0 || first > audioEnd - audioStart {
                    throw damaged(String(localized: "LPCM frame pointer in sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”"))
                }
                audio.append(DVDAudioPacket(substream: sub, pts: pts, firstAccessUnit: first, formatByte: d[payload + 5],
                                            audio: (audioStart - b)..<(audioEnd - b)))
            }
        }
        return (nav, audio)
    }

    static func be16(_ d: ArraySlice<UInt8>, _ o: Int) -> UInt16 { UInt16(d[o]) << 8 | UInt16(d[o + 1]) }
    static func be32(_ d: ArraySlice<UInt8>, _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
}

// MARK: - A run of one VOB's LPCM

/// One VOB's stretch of the title VOBs (cells with the same VOB ID, one after another) and the LPCM stream in it:
/// a continuous run of samples timed by 90 kHz PTS. Tracks are sample ranges of a run.
public struct DVDLPCMRun: Sendable, Hashable {
    public var titleSet: Int
    /// The LPCM stream number (0–7: substream 0xA0 + stream).
    public var stream: Int
    public var firstSector: Int
    public var lastSector: Int
    public var format: DVDLPCMFormat
    /// The PTS of the run's first sample.
    public var firstPTS: Int64
    /// Sample frames in the run, through the last complete one.
    public var frameCount: Int64
    /// The sector of the packet holding the first sample.
    var firstAudioSector: Int

    var substream: UInt8 { UInt8(0xA0 + stream) }

    /// The run's sample frame nearest a 90 kHz time.
    public func frame(atPTS pts: Int64) -> Int64 { max(0, min(frameCount, format.nearestFrame(ticks: pts - firstPTS))) }

    /// Reads the head and the tail of the run: its format, first sample's PTS and length. The length comes from the
    /// last packet with a time stamp plus the audio bytes after it, so nothing but the two ends is read.
    static func analyze(_ reader: DVDSectorReader, titleSet: Int, stream: Int, sectors: ClosedRange<Int>) throws -> DVDLPCMRun? {
        let sub = UInt8(0xA0 + stream)
        // Head: the first packet in which an audio frame starts, with its time stamp.
        var head: (sector: Int, pts: Int64, format: DVDLPCMFormat)?
        var s = sectors.lowerBound
        while s <= sectors.upperBound, head == nil {
            for packet in try DVDPacks.parse(try reader.sector(s), sector: s, substream: sub).audio where packet.firstAccessUnit != nil {
                guard let pts = packet.pts else { continue }
                head = (s, pts, try DVDLPCMFormat(header: packet.formatByte))
                break
            }
            s += 1
            // A run with no LPCM in its first 4 MB has none (a video-only VOB, or another audio coding).
            if head == nil, s - sectors.lowerBound > 2048 { return nil }
        }
        guard let head else { return nil }
        // Tail: back from the end, in blocks, to the last packet with a time stamp; then its audio bytes onward.
        var tail: (sector: Int, packet: Int, pts: Int64)?
        var blockEnd = sectors.upperBound
        while tail == nil, blockEnd >= head.sector {
            let blockStart = max(head.sector, blockEnd - 255)
            for t in stride(from: blockEnd, through: blockStart, by: -1) {
                let packets = try DVDPacks.parse(try reader.sector(t, ahead: false), sector: t, substream: sub).audio
                if let i = packets.lastIndex(where: { $0.pts != nil && $0.firstAccessUnit != nil }) { tail = (t, i, packets[i].pts!); break }
            }
            blockEnd = blockStart - 1
        }
        guard let tail else { return nil }
        var bytes = 0
        for t in tail.sector...sectors.upperBound {
            let data = try reader.sector(t)
            let packets = try DVDPacks.parse(data, sector: t, substream: sub).audio
            for (i, packet) in packets.enumerated() {
                guard try DVDLPCMFormat(header: packet.formatByte) == head.format else { throw formatChange(t) }
                if t == tail.sector { if i < tail.packet { continue } else if i == tail.packet { bytes += packet.audio.count - packet.firstAccessUnit!; continue } }
                bytes += packet.audio.count
            }
        }
        guard let offset = head.format.frames(ticks: tail.pts - head.pts), offset >= 0 else { throw timingError(tail.sector) }
        let units = Int64(bytes / head.format.unitBytes)
        return DVDLPCMRun(titleSet: titleSet, stream: stream, firstSector: sectors.lowerBound, lastSector: sectors.upperBound,
                          format: head.format, firstPTS: head.pts, frameCount: offset + units * Int64(head.format.unitFrames),
                          firstAudioSector: head.sector)
    }

    static func formatChange(_ sector: Int) -> DVDVideoError {
        .damaged(String(localized: "LPCM format changes within a VOB at sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”"))
    }
    static func timingError(_ sector: Int) -> DVDVideoError {
        .damaged(String(localized: "LPCM time stamp out of step at sector \(sector)", comment: "Part of “This DVD-Video is damaged (…).”"))
    }
}

/// A run's samples in order, as interleaved left-justified 32-bit integers. Every time stamp is checked against the
/// samples before it, so a gap, an overlap or a format change in the stream is an error, never silent garbage.
/// Seeks find the packet by time stamp (a binary search over sectors) and land on the exact sample.
final class DVDLPCMReader {
    let run: DVDLPCMRun
    private let reader: DVDSectorReader
    /// The next sector to read.
    private var sector: Int
    /// Audio bytes read but not yet converted; `pendingStart` is the frame of their first byte.
    private var pending: [UInt8] = []
    private var pendingOffset = 0
    private var pendingStart: Int64 = 0
    /// Frames to drop from the front (a seek into the middle of a unit or an access unit).
    private var discard: Int64 = 0
    private(set) var position: Int64 = 0
    private var started = false

    init(reader: DVDSectorReader, run: DVDLPCMRun) {
        self.reader = reader
        self.run = run
        sector = run.firstAudioSector
    }

    private var format: DVDLPCMFormat { run.format }

    /// Pulls packets until `bytes` audio bytes are pending or the run ends.
    private func fill(_ bytes: Int) throws {
        while pending.count - pendingOffset < bytes, sector <= run.lastSector {
            let s = sector
            sector += 1
            for packet in try DVDPacks.parse(try reader.sector(s), sector: s, substream: run.substream).audio {
                guard try DVDLPCMFormat(header: packet.formatByte) == format else { throw DVDLPCMRun.formatChange(s) }
                var range = packet.audio
                if !started {
                    // The first packet read after a seek or at the start: from its first access unit, at its PTS.
                    guard let first = packet.firstAccessUnit, let pts = packet.pts else { continue }
                    guard let frame = format.frames(ticks: pts - run.firstPTS) else { throw DVDLPCMRun.timingError(s) }
                    started = true
                    pendingStart = frame
                    range = (range.lowerBound + first)..<range.upperBound
                } else if let first = packet.firstAccessUnit, let pts = packet.pts {
                    // Every time stamp must match the samples counted so far.
                    let before = pending.count - pendingOffset + first
                    guard before % format.unitBytes == 0, let frame = format.frames(ticks: pts - run.firstPTS),
                          frame == pendingStart + Int64(before / format.unitBytes * format.unitFrames)
                    else { throw DVDLPCMRun.timingError(s) }
                }
                let data = try reader.sector(s)
                if pendingOffset > 0, pendingOffset == pending.count { pending.removeAll(keepingCapacity: true); pendingOffset = 0 }
                pending.append(contentsOf: data[data.startIndex + range.lowerBound..<data.startIndex + range.upperBound])
            }
        }
    }

    /// Converted frames not yet handed out (interleaved), from `readyOffset` on.
    private var ready: [Int32] = []
    private var readyOffset = 0

    /// Converts up to `units` storage units of pending audio into `ready`, dropping frames still to be discarded and
    /// anything past the run's last frame.
    private func convert(units wanted: Int) throws {
        let channels = format.channels, unitFrames = format.unitFrames, unitBytes = format.unitBytes
        try fill(wanted * unitBytes)
        let units = min(wanted, (pending.count - pendingOffset) / unitBytes)
        guard units > 0 else {
            // The run ended before its last time-stamped frame said it would.
            throw DVDVideoError.damaged(String(localized: "LPCM ends early", comment: "Part of “This DVD-Video is damaged (…).”"))
        }
        ready.removeAll(keepingCapacity: true)
        readyOffset = 0
        var unit = [Int32](repeating: 0, count: unitFrames * channels)
        pending.withUnsafeBufferPointer { src in
            var s = src.baseAddress! + pendingOffset
            for _ in 0..<units {
                unit.withUnsafeMutableBufferPointer { format.deinterleave(s, units: 1, into: $0.baseAddress!) }
                s += unitBytes
                for f in 0..<unitFrames where pendingStart + Int64(f) < run.frameCount {
                    if discard > 0 { discard -= 1; continue }
                    ready.append(contentsOf: unit[f * channels..<(f + 1) * channels])
                }
                pendingStart += Int64(unitFrames)
            }
        }
        pendingOffset += units * unitBytes
    }

    /// Up to `frames` frames into `out` (interleaved, channels × frames). Returns the frames written; 0 at the end.
    func read(into out: UnsafeMutablePointer<Int32>, frames: Int) throws -> Int {
        let channels = format.channels
        var written = 0
        while written < frames, position < run.frameCount {
            if readyOffset == ready.count {
                let need = Int64(frames - written) + discard
                let units = Int((min(need, run.frameCount - pendingStart) + Int64(format.unitFrames) - 1) / Int64(format.unitFrames))
                try convert(units: max(1, min(units, 1 << 16)))
                continue
            }
            let n = min(frames - written, (ready.count - readyOffset) / channels)
            ready.withUnsafeBufferPointer { (out + written * channels).update(from: $0.baseAddress! + readyOffset, count: n * channels) }
            readyOffset += n * channels
            written += n
            position += Int64(n)
        }
        return written
    }

    /// The first packet at or after sector `s` in which an access unit starts with a time stamp: its frame.
    private func probe(_ s: Int) throws -> (sector: Int, frame: Int64)? {
        var t = s
        while t <= run.lastSector, t - s < 4096 {
            for packet in try DVDPacks.parse(try reader.sector(t, ahead: false), sector: t, substream: run.substream).audio {
                if packet.firstAccessUnit != nil, let pts = packet.pts {
                    guard let frame = format.frames(ticks: pts - run.firstPTS) else { throw DVDLPCMRun.timingError(t) }
                    return (t, frame)
                }
            }
            t += 1
        }
        return nil
    }

    /// Positions the reader at frame `target` of the run.
    func seek(to target: Int64) throws {
        let target = max(0, min(target, run.frameCount))
        if target == position, started || target == 0 { return }
        var lo = run.firstAudioSector, hi = run.lastSector
        var best: (sector: Int, frame: Int64) = (run.firstAudioSector, 0)
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            if let p = try probe(mid), p.frame <= target { lo = mid; best = p } else { hi = mid - 1 }
        }
        if lo == run.firstAudioSector { best = (run.firstAudioSector, 0) }
        sector = best.sector
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
        ready.removeAll(keepingCapacity: true)
        readyOffset = 0
        started = false
        try fill(1)
        // The access unit found may start after a frame or two of an earlier unit's group: drop up to the target.
        guard pendingStart <= target else { throw DVDLPCMRun.timingError(best.sector) }
        discard = target - pendingStart
        position = target
    }
}
