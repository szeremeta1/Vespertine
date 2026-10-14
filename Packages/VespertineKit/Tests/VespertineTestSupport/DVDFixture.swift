//
// Vespertine — synthetic DVD-Video discs for tests: LPCM payloads at every width (with the 20/24-bit grouped
// layout written independently of the decoder), program streams of NAV packs, LPCM packets (PTS, first-access-unit
// pointers, frames split across packets), video and padding packets, VMG/VTS IFOs, and ISO 9660 / UDF images.
// Everything is generated; no disc audio.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum DVDFixture {
    public static let sector = 2048

    // MARK: LPCM

    public struct Format: Sendable, Hashable {
        public var bits: Int, rate: Int, channels: Int
        public init(bits: Int, rate: Int, channels: Int) { self.bits = bits; self.rate = rate; self.channels = channels }
        public var headerByte: UInt8 { UInt8([16: 0, 20: 1, 24: 2][bits]! << 6 | (rate == 96_000 ? 1 : 0) << 4 | (channels - 1)) }
        public var frameBytes: Int { channels * bits / 8 }
        /// 1/600 s of audio.
        public var accessUnitBytes: Int { rate / 600 * channels * bits / 8 }
    }

    /// A distinct, deterministic sample for every frame and channel, using every bit of the width (left-justified
    /// in 32 bits, low bits zero).
    public static func samples(frames: Int, format: Format, seed: Int = 1) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(frames * format.channels)
        var x = UInt32(truncatingIfNeeded: 0x9E37_79B9 &* UInt32(seed))
        let mask: UInt32 = format.bits == 16 ? 0xFFFF_0000 : format.bits == 20 ? 0xFFFF_F000 : 0xFFFF_FF00
        for f in 0..<frames {
            for c in 0..<format.channels {
                x = x &* 1_664_525 &+ 1_013_904_223
                // A slow tone per channel plus noise in every bit, so channel swaps and byte swaps both show.
                let tone = Int32(sin(Double(f) * Double(c + 1) * 0.01) * 1_000_000_000)
                out.append(Int32(bitPattern: (UInt32(bitPattern: tone) ^ (x & 0x00FF_FFFF)) & mask))
            }
        }
        return out
    }

    /// Encodes interleaved left-justified samples as DVD-Video LPCM bytes. 16-bit: big-endian frame by frame.
    /// 20/24-bit: per pair of frames, the high 16 bits of every sample (frame 0's channels, then frame 1's), then the
    /// low byte (24) or nibble (20, two per byte, earlier sample in the high nibble) of each in the same order.
    public static func encode(_ samples: [Int32], format: Format) -> [UInt8] {
        let ch = format.channels
        var out: [UInt8] = []
        if format.bits == 16 {
            for s in samples { let u = UInt32(bitPattern: s); out += [UInt8(u >> 24), UInt8(u >> 16 & 0xFF)] }
            return out
        }
        precondition(samples.count % (2 * ch) == 0, "20/24-bit LPCM is stored in pairs of frames")
        var i = 0
        while i < samples.count {
            let group = samples[i..<i + 2 * ch].map { UInt32(bitPattern: $0) }
            for u in group { out += [UInt8(u >> 24), UInt8(u >> 16 & 0xFF)] }
            if format.bits == 24 {
                for u in group { out.append(UInt8(u >> 8 & 0xFF)) }
            } else {
                var k = 0
                while k < group.count { out.append(UInt8((group[k] >> 12 & 0xF) << 4 | (group[k + 1] >> 12 & 0xF))); k += 2 }
            }
            i += 2 * ch
        }
        return out
    }

    // MARK: Program streams

    /// One VOB: a continuous LPCM stream and the cells it's divided into by presentation time.
    public struct VOB: Sendable {
        public var vobID: Int
        public var format: Format
        public var firstPTS: Int64
        public var samples: [Int32]
        /// Each cell's ID and start time (90 kHz); the first starts at `firstPTS`.
        public var cells: [(id: Int, startPTM: Int64)]
        /// Audio is multiplexed this many ticks ahead of the video it plays with (packets of a cell's first moments
        /// sit at the end of the cell before).
        public var lead: Int64
        public var payloadBytes: Int
        public var packetsPerVOBU: Int
        /// The LPCM substream (0xA0 + n) and an optional second audio substream of another coding to skip.
        public var substream: UInt8
        public var extraAC3: Bool
        public init(vobID: Int, format: Format, firstPTS: Int64 = 30_000, samples: [Int32], cells: [(id: Int, startPTM: Int64)]? = nil,
                    lead: Int64 = 0, payloadBytes: Int = 2004, packetsPerVOBU: Int = 12, substream: UInt8 = 0xA0, extraAC3: Bool = false) {
            self.vobID = vobID; self.format = format; self.firstPTS = firstPTS; self.samples = samples
            self.cells = cells ?? [(1, firstPTS)]; self.lead = lead; self.payloadBytes = payloadBytes
            self.packetsPerVOBU = packetsPerVOBU; self.substream = substream; self.extraAC3 = extraAC3
        }
        public var frames: Int { samples.count / format.channels }
        public var endPTS: Int64 { firstPTS + Int64(frames) * 90_000 / Int64(format.rate) }
    }

    /// Where a cell ended up.
    public struct CellLayout: Sendable, Hashable {
        public var vobID: Int, cellID: Int, firstSector: Int, lastSector: Int, startPTM: Int64, endPTM: Int64
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func pts(_ v: Int64) -> [UInt8] {
        [UInt8(0x21 | (v >> 29 & 0x0E)), UInt8(v >> 22 & 0xFF), UInt8(0x01 | (v >> 14 & 0xFE)), UInt8(v >> 7 & 0xFF), UInt8(0x01 | (v << 1 & 0xFE))]
    }

    static func packHeader() -> [UInt8] { [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8] }

    /// Pads a sector's packets to 2048 bytes with a padding packet.
    static func finish(_ s: [UInt8]) -> [UInt8] {
        var s = s
        let left = sector - s.count
        precondition(left >= 0)
        if left >= 6 { s += [0, 0, 1, 0xBE] + be16(left - 6) + [UInt8](repeating: 0xFF, count: left - 6) }
        else { s += [UInt8](repeating: 0xFF, count: left) }   // only possible when the packet had no room: never here
        return s
    }

    static func navSector(sPTM: Int64, ePTM: Int64, vobID: Int, cellID: Int, vobuEnd: Int, lbn: Int) -> [UInt8] {
        var s = packHeader()
        s += [0, 0, 1, 0xBB, 0, 18] + [UInt8](repeating: 0x80, count: 18)        // system header
        var pci = [UInt8](repeating: 0, count: 0x3D4)
        pci[0] = 0
        pci.replaceSubrange(1..<5, with: be32(lbn))
        pci.replaceSubrange(13..<17, with: be32(Int(sPTM)))
        pci.replaceSubrange(17..<21, with: be32(Int(ePTM)))
        s += [0, 0, 1, 0xBF] + be16(pci.count) + pci
        var dsi = [UInt8](repeating: 0, count: 0x3FA)
        dsi[0] = 1
        dsi.replaceSubrange(5..<9, with: be32(lbn))
        dsi.replaceSubrange(9..<13, with: be32(vobuEnd))
        dsi.replaceSubrange(25..<27, with: be16(vobID))
        dsi[28] = UInt8(cellID)
        s += [0, 0, 1, 0xBF] + be16(dsi.count) + dsi
        precondition(s.count == sector)
        return s
    }

    static func audioSector(payload: [UInt8], pts: Int64?, pointer: Int, format: Format, frameNumber: Int, substream: UInt8) -> [UInt8] {
        var s = packHeader()
        let header: [UInt8] = pts.map { [0x81, 0x80, 5] + Self.pts($0) } ?? [0x81, 0x00, 0]
        let lpcm: [UInt8] = [substream, pts == nil ? 0 : 1] + be16(pointer) + [UInt8(frameNumber & 0x1F), format.headerByte, 0x80]
        let body = header + lpcm + payload
        s += [0, 0, 1, 0xBD] + be16(body.count) + body
        return finish(s)
    }

    static func videoSector() -> [UInt8] {
        var s = packHeader()
        let body: [UInt8] = [0x81, 0x00, 0] + [UInt8](repeating: 0x55, count: 1200)
        s += [0, 0, 1, 0xE0] + be16(body.count) + body
        return finish(s)
    }

    static func ac3Sector() -> [UInt8] {
        var s = packHeader()
        let body: [UInt8] = [0x81, 0x00, 0, 0x80, 1, 0, 1] + [UInt8](repeating: 0x0B, count: 600)
        s += [0, 0, 1, 0xBD] + be16(body.count) + body
        return finish(s)
    }

    /// The VOBs one after another as title-VOB sectors, and where each cell landed.
    public static func titleVOBs(_ vobs: [VOB], startSector: Int = 0) -> (bytes: [UInt8], cells: [CellLayout]) {
        var out: [UInt8] = []
        var layout: [CellLayout] = []
        for vob in vobs {
            let bytes = encode(vob.samples, format: vob.format)
            let au = vob.format.accessUnitBytes, frameBytes = vob.format.frameBytes
            // Packets: (payload, pts, pointer, time of the packet's first byte).
            var packets: [(payload: [UInt8], pts: Int64?, pointer: Int, time: Int64, frameNumber: Int)] = []
            var o = 0
            while o < bytes.count {
                let n = min(vob.payloadBytes, bytes.count - o)
                // The first access unit starting in [o, o + n).
                let firstAU = o % au == 0 ? o : (o / au + 1) * au
                let starts = firstAU < o + n
                let pts: Int64? = starts ? vob.firstPTS + Int64(firstAU / au) * 150 : nil
                let pointer = starts ? firstAU - o + 4 : 0
                let time = vob.firstPTS + Int64(o / frameBytes) * 90_000 / Int64(vob.format.rate)
                packets.append((Array(bytes[o..<o + n]), pts, pointer, time, firstAU / au))
                o += n
            }
            // Cell of each packet: by time minus the lead.
            let ends = vob.cells.dropFirst().map(\.startPTM) + [vob.endPTS + 1]
            var byCell = [[Int]](repeating: [], count: vob.cells.count)
            for (i, p) in packets.enumerated() {
                let t = p.time - vob.lead
                let k = vob.cells.indices.last { vob.cells[$0].startPTM <= t } ?? 0
                byCell[k].append(i)
            }
            for (k, cell) in vob.cells.enumerated() {
                let first = startSector + out.count / sector
                let list = byCell[k]
                var chunks: [[Int]] = stride(from: 0, to: max(list.count, 1), by: vob.packetsPerVOBU).map { Array(list[$0..<min($0 + vob.packetsPerVOBU, list.count)]) }
                if chunks.isEmpty { chunks = [[]] }
                let cellEnd = ends[k]
                for (v, chunk) in chunks.enumerated() {
                    let lbn = startSector + out.count / sector
                    // A video sector and (when asked) an AC-3 sector in every VOBU, between the NAV pack and the audio.
                    let extra = 1 + (vob.extraAC3 ? 1 : 0)
                    let sPTM = v == 0 ? cell.startPTM : cell.startPTM + Int64(v) * 3003
                    let ePTM = v == chunks.count - 1 ? cellEnd : cell.startPTM + Int64(v + 1) * 3003
                    out += navSector(sPTM: sPTM, ePTM: ePTM, vobID: vob.vobID, cellID: cell.id, vobuEnd: chunk.count + extra, lbn: lbn)
                    out += videoSector()
                    if vob.extraAC3 { out += ac3Sector() }
                    for i in chunk {
                        let p = packets[i]
                        out += audioSector(payload: p.payload, pts: p.pts, pointer: p.pointer, format: vob.format,
                                           frameNumber: p.frameNumber, substream: vob.substream)
                    }
                }
                layout.append(CellLayout(vobID: vob.vobID, cellID: cell.id, firstSector: first,
                                         lastSector: startSector + out.count / sector - 1, startPTM: cell.startPTM, endPTM: cellEnd))
            }
        }
        return (out, layout)
    }

    // MARK: IFOs

    public struct PGC: Sendable {
        public var titleEntry: Int?
        /// Each program's first cell (1-based).
        public var programs: [Int]
        public var cells: [CellLayout]
        public init(titleEntry: Int?, programs: [Int], cells: [CellLayout]) { self.titleEntry = titleEntry; self.programs = programs; self.cells = cells }
    }

    public static func vmg(titles: [(titleSet: Int, titleSetTitle: Int, chapters: Int)], titleSets: Int) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 2 * sector)
        d.replaceSubrange(0..<12, with: Array("DVDVIDEO-VMG".utf8))
        d.replaceSubrange(0x3E..<0x40, with: be16(titleSets))
        d.replaceSubrange(0xC4..<0xC8, with: be32(1))
        var t = be16(titles.count) + [0, 0] + be32(8 + 12 * titles.count - 1)
        for title in titles {
            t += [0x3C, 1] + be16(title.chapters) + [0, 0, UInt8(title.titleSet), UInt8(title.titleSetTitle)] + be32(0)
        }
        d.replaceSubrange(sector..<sector + t.count, with: t)
        return d
    }

    /// `audio`: each stream's 8 attribute bytes as (coding, quantization, frequency, channels).
    public static func vts(audio: [(coding: Int, quantization: Int, frequency: Int, channels: Int)], pgcs: [PGC],
                           chapters: [[(pgc: Int, program: Int)]], cellTable: [CellLayout], vobuStarts: [Int] = []) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 0x800)
        d.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        d[0x203] = UInt8(audio.count)
        for (i, a) in audio.enumerated() {
            d[0x204 + 8 * i] = UInt8(a.coding << 5)
            d[0x205 + 8 * i] = UInt8(a.quantization << 6 | a.frequency << 4 | (a.channels - 1))
        }
        func put(_ table: [UInt8], pointer: Int) {
            let s = d.count / sector
            d.replaceSubrange(pointer..<pointer + 4, with: be32(s))
            d += table + [UInt8](repeating: 0, count: (sector - table.count % sector) % sector)
        }
        // Chapters.
        var ptt = be16(chapters.count) + [0, 0] + be32(0)
        var offsets: [Int] = [], entries: [UInt8] = []
        let headerSize = 8 + 4 * chapters.count
        for list in chapters { offsets.append(headerSize + entries.count); for c in list { entries += be16(c.pgc) + be16(c.program) } }
        for o in offsets { ptt += be32(o) }
        ptt += entries
        ptt.replaceSubrange(4..<8, with: be32(ptt.count - 1))
        put(ptt, pointer: 0xC8)
        // Program chains.
        var bodies: [[UInt8]] = []
        for pgc in pgcs {
            var p = [UInt8](repeating: 0, count: 0xEC)
            p[2] = UInt8(pgc.programs.count); p[3] = UInt8(pgc.cells.count)
            p.replaceSubrange(4..<8, with: [0x01, 0x02, 0x03, 0xC4])     // a playback time (display only)
            p.replaceSubrange(0xE6..<0xE8, with: be16(p.count))
            p += pgc.programs.map(UInt8.init)
            while p.count % 2 != 0 { p.append(0) }
            p.replaceSubrange(0xE8..<0xEA, with: be16(p.count))
            for c in pgc.cells {
                var cell = [UInt8](repeating: 0, count: 24)
                cell.replaceSubrange(4..<8, with: [0x00, 0x03, 0x10, 0xC0])
                cell.replaceSubrange(8..<12, with: be32(c.firstSector))
                cell.replaceSubrange(16..<20, with: be32(c.lastSector))
                cell.replaceSubrange(20..<24, with: be32(c.lastSector))
                p += cell
            }
            p.replaceSubrange(0xEA..<0xEC, with: be16(p.count))
            for c in pgc.cells { p += be16(c.vobID) + [0, UInt8(c.cellID)] }
            bodies.append(p)
        }
        var pgcit = be16(pgcs.count) + [0, 0] + be32(0)
        var offset = 8 + 8 * pgcs.count
        for (i, pgc) in pgcs.enumerated() {
            pgcit += [pgc.titleEntry.map { UInt8(0x80 | $0) } ?? 0, 0, 0, 0] + be32(offset)
            offset += bodies[i].count
        }
        for b in bodies { pgcit += b }
        pgcit.replaceSubrange(4..<8, with: be32(pgcit.count - 1))
        put(pgcit, pointer: 0xCC)
        // Cell address table.
        var cadt = be16(Set(cellTable.map(\.vobID)).count) + [0, 0] + be32(8 + 12 * cellTable.count - 1)
        for c in cellTable { cadt += be16(c.vobID) + [UInt8(c.cellID), 0] + be32(c.firstSector) + be32(c.lastSector) }
        put(cadt, pointer: 0xE0)
        if !vobuStarts.isEmpty {
            var map = be32(4 + 4 * vobuStarts.count - 1)
            for s in vobuStarts { map += be32(s) }
            put(map, pointer: 0xE4)
        }
        return d
    }

    /// A VIDEO_TS folder with these files (names → bytes); VOBs over `split` bytes are split into VTS_nn_1, _2 …
    public static func writeFolder(_ files: [String: [UInt8]], at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, bytes) in files { try Data(bytes).write(to: folder.appendingPathComponent(name)) }
    }

    /// A whole VIDEO_TS: menus (which carry LPCM of their own, to prove they're never played), one title set whose
    /// title VOBs are `vobs` (split into VTS_01_1.VOB, _2 … every `splitSectors`), and one title per entry of
    /// `titles`, each a list of programs, each a list of indexes into the cells the VOBs make.
    public static func disc(vobs: [VOB], titles: [[[Int]]], splitSectors: Int = 0,
                            audio: [(coding: Int, quantization: Int, frequency: Int, channels: Int)]? = nil,
                            cellTable: (([CellLayout]) -> [CellLayout])? = nil,
                            chapters: [[(pgc: Int, program: Int)]]? = nil) -> (files: [String: [UInt8]], cells: [CellLayout]) {
        let (title, cells) = titleVOBs(vobs)
        let menuFormat = Format(bits: 16, rate: 48_000, channels: 2)
        let menu = titleVOBs([VOB(vobID: 1, format: menuFormat, samples: samples(frames: 4800, format: menuFormat, seed: 99))]).bytes
        let pgcs = titles.enumerated().map { i, programs in
            var entries: [Int] = [], list: [CellLayout] = []
            for program in programs { entries.append(list.count + 1); list += program.map { cells[$0] } }
            return PGC(titleEntry: i + 1, programs: entries, cells: list)
        }
        let first = vobs.first?.format ?? menuFormat
        let attributes = audio ?? [(4, [16: 0, 20: 1, 24: 2][first.bits]!, first.rate == 96_000 ? 1 : 0, first.channels)]
        let ptt = chapters ?? titles.enumerated().map { i, programs in programs.indices.map { (pgc: i + 1, program: $0 + 1) } }
        let vts = vts(audio: attributes, pgcs: pgcs, chapters: ptt, cellTable: cellTable?(cells) ?? cells)
        let vmg = vmg(titles: titles.enumerated().map { (1, $0.offset + 1, $0.element.count) }, titleSets: 1)
        var files: [String: [UInt8]] = ["VIDEO_TS.IFO": vmg, "VIDEO_TS.BUP": vmg, "VIDEO_TS.VOB": menu,
                                        "VTS_01_0.IFO": vts, "VTS_01_0.BUP": vts, "VTS_01_0.VOB": menu]
        let per = splitSectors > 0 ? splitSectors * sector : max(title.count, 1)
        var part = 1, o = 0
        repeat {
            files["VTS_01_\(part).VOB"] = Array(title[o..<min(o + per, title.count)])
            o += per; part += 1
        } while o < title.count
        return (files, cells)
    }

    // MARK: Disc images

    public enum FileSystems: Sendable { case iso9660, udf, both }

    /// A disc image holding VIDEO_TS (and optionally AUDIO_TS) with the files given, in name order.
    public static func image(_ files: [String: [UInt8]], audioTS: [String: [UInt8]] = [:], fileSystems: FileSystems = .both,
                             udfExtendedEntries: Bool = false) -> [UInt8] {
        // Layout: 0–15 system area, 16… volume descriptors, 32… UDF VDS, 256 anchor, 260 ISO directories,
        // 270… UDF partition (file set, entries, directories), then file data from 400 on.
        var img = [UInt8](repeating: 0, count: 400 * sector)
        func put(_ bytes: [UInt8], at s: Int) {
            if img.count < (s * sector + bytes.count) { img += [UInt8](repeating: 0, count: s * sector + bytes.count - img.count) }
            img.replaceSubrange(s * sector..<s * sector + bytes.count, with: bytes)
        }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func both32(_ v: Int) -> [UInt8] { le32(v) + be32(v) }
        // File data.
        var extents: [String: (sector: Int, length: Int)] = [:]
        var next = 400
        let allFiles = files.map { ("VIDEO_TS", $0.key, $0.value) } + audioTS.map { ("AUDIO_TS", $0.key, $0.value) }
        for (dir, name, bytes) in allFiles.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            put(bytes, at: next)
            extents["\(dir)/\(name)"] = (next, bytes.count)
            next += max(1, (bytes.count + sector - 1) / sector)
        }
        if img.count < next * sector { img += [UInt8](repeating: 0, count: next * sector - img.count) }

        if fileSystems != .udf {
            func record(_ name: String, sector s: Int, length: Int, directory: Bool) -> [UInt8] {
                let id: [UInt8] = name == "." ? [0] : name == ".." ? [1] : Array((directory ? name : name + ";1").utf8)
                var r: [UInt8] = [0, 0] + both32(s) + both32(length) + [UInt8](repeating: 0, count: 7) + [directory ? 2 : 0, 0, 0] + [1, 0, 0, 1] + [UInt8(id.count)] + id
                if r.count % 2 != 0 { r.append(0) }
                r[0] = UInt8(r.count)
                return r
            }
            var root = record(".", sector: 260, length: sector, directory: true) + record("..", sector: 260, length: sector, directory: true)
            root += record("VIDEO_TS", sector: 261, length: sector, directory: true)
            if !audioTS.isEmpty { root += record("AUDIO_TS", sector: 262, length: sector, directory: true) }
            put(root, at: 260)
            for (dir, s, list) in [("VIDEO_TS", 261, files), ("AUDIO_TS", 262, audioTS)] where !list.isEmpty || dir == "VIDEO_TS" {
                var d = record(".", sector: s, length: sector, directory: true) + record("..", sector: 260, length: sector, directory: true)
                for name in list.keys.sorted() { let e = extents["\(dir)/\(name)"]!; d += record(name, sector: e.sector, length: e.length, directory: false) }
                put(d, at: s)
            }
            var pvd = [UInt8](repeating: 0, count: sector)
            pvd.replaceSubrange(0..<7, with: [1] + Array("CD001".utf8) + [1])
            pvd.replaceSubrange(156..<190, with: record(".", sector: 260, length: sector, directory: true).prefix(34))
            put(pvd, at: 16)
            put([255] + Array("CD001".utf8) + [1], at: 17)
        }
        if fileSystems != .iso9660 {
            let partition = 270
            func tag(_ id: Int, _ body: [UInt8]) -> [UInt8] { var t = [UInt8](repeating: 0, count: 16); t.replaceSubrange(0..<2, with: le16(id)); return t + body }
            func longAD(_ lbn: Int, length: Int = sector) -> [UInt8] { le32(length) + le32(lbn) + [0, 0] + [UInt8](repeating: 0, count: 6) }
            // Anchor → VDS at 32: partition descriptor, logical volume descriptor, terminator.
            put(tag(2, le32(4 * sector) + le32(32)), at: 256)
            var pd = tag(5, [UInt8](repeating: 0, count: 300))
            pd.replaceSubrange(188..<192, with: le32(partition))
            put(pd, at: 32)
            var lvd = tag(6, [UInt8](repeating: 0, count: 400))
            lvd.replaceSubrange(212..<216, with: le32(sector))
            lvd.replaceSubrange(248..<264, with: longAD(0))
            put(lvd, at: 33)
            put(tag(8, []), at: 34)
            // Partition: 0 file set, 1 root entry, 2 root directory, 3 VIDEO_TS entry, 4 its directory,
            // 5 AUDIO_TS entry, 6 its directory, 7… file entries.
            var fsd = tag(256, [UInt8](repeating: 0, count: 500))
            fsd.replaceSubrange(400..<416, with: longAD(1))
            put(fsd, at: partition)
            var nextEntry = 7
            func entry(dataSector: Int, length: Int, extended: Bool) -> [UInt8] {
                // Short allocation descriptors, one per ≤ 1 GB piece (as UDF requires extents < 2^30).
                var ads: [UInt8] = []
                var left = length, at = dataSector - partition
                repeat {
                    let piece = min(left, 0x3FFF_F800)
                    ads += le32(piece) + le32(at)
                    left -= piece; at += piece / sector
                } while left > 0
                if extended {
                    var e = tag(266, [UInt8](repeating: 0, count: 200))
                    e.replaceSubrange(56..<64, with: le32(length) + le32(0))
                    e.replaceSubrange(208..<212, with: le32(0)); e.replaceSubrange(212..<216, with: le32(ads.count))
                    return e + ads
                }
                var e = tag(261, [UInt8](repeating: 0, count: 160))
                e.replaceSubrange(56..<64, with: le32(length) + le32(0))
                e.replaceSubrange(168..<172, with: le32(0)); e.replaceSubrange(172..<176, with: le32(ads.count))
                return e + ads
            }
            func fid(_ name: String?, icb: Int, directory: Bool) -> [UInt8] {
                let id: [UInt8] = name.map { [8] + Array($0.utf8) } ?? []
                var f = tag(257, [0, 0, (directory ? 2 : 0) | (name == nil ? 8 : 0), UInt8(id.count)] + longAD(icb) + le16(0)) + id
                while f.count % 4 != 0 { f.append(0) }
                return f
            }
            var rootDir = fid(nil, icb: 1, directory: true) + fid("VIDEO_TS", icb: 3, directory: true)
            if !audioTS.isEmpty { rootDir += fid("AUDIO_TS", icb: 5, directory: true) }
            put(rootDir, at: partition + 2)
            put(entry(dataSector: partition + 2, length: rootDir.count, extended: false), at: partition + 1)
            for (dir, entrySector, list) in [("VIDEO_TS", 3, files), ("AUDIO_TS", 5, audioTS)] where !list.isEmpty || dir == "VIDEO_TS" {
                var d = fid(nil, icb: 1, directory: true)
                for name in list.keys.sorted() {
                    let e = extents["\(dir)/\(name)"]!
                    put(entry(dataSector: e.sector, length: e.length, extended: udfExtendedEntries), at: partition + nextEntry)
                    d += fid(name, icb: nextEntry, directory: false)
                    nextEntry += 1
                }
                put(d, at: partition + entrySector + 1)
                put(entry(dataSector: partition + entrySector + 1, length: d.count, extended: false), at: partition + entrySector)
            }
            precondition(partition + nextEntry < 400)
        }
        return img
    }
}
