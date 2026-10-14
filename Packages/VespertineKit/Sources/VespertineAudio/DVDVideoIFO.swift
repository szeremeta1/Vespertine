//
// Vespertine — DVD-Video navigation: the video manager (VIDEO_TS.IFO: which title set each title is in) and each
// title set's information file (VTS_nn_0.IFO: audio attributes, program chains, their programs and cells, the cell
// address table and the VOBU address map). Field offsets follow the DVD-Video layout as documented by the
// open-source libdvdread project (ifo_types.h); this reader is Vespertine's own. Menus (VMGM, VTSM) are never read
// for audio.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

func dvdBE16(_ d: [UInt8], _ o: Int) -> Int { o >= 0 && o + 2 <= d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
func dvdBE32(_ d: [UInt8], _ o: Int) -> Int {
    o >= 0 && o + 4 <= d.count ? Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) : 0
}

/// VIDEO_TS.IFO: the disc's titles, in the order the disc numbers them.
public struct DVDVideoManager: Sendable, Hashable {
    public struct Title: Sendable, Hashable {
        public var number: Int
        public var titleSet: Int
        /// The title's number within its title set (VTS_TTN).
        public var titleSetTitle: Int
        public var chapters: Int
    }
    public var titleSetCount: Int
    public var titles: [Title]

    public static func parse(_ d: [UInt8]) throws -> DVDVideoManager {
        guard d.count >= 0x200, d.starts(with: Array("DVDVIDEO-VMG".utf8)) else { throw DVDVideoError.notDVDVideo }
        let sets = dvdBE16(d, 0x3E)
        let srpt = dvdBE32(d, 0xC4) * DVDVideoVolume.sectorSize
        guard sets > 0, sets <= 99, srpt > 0, srpt + 8 <= d.count else { throw DVDVideoError.damaged("VIDEO_TS.IFO") }
        let count = dvdBE16(d, srpt)
        guard count > 0, count <= 99, srpt + 8 + 12 * count <= d.count else { throw DVDVideoError.damaged("VIDEO_TS.IFO") }
        var titles: [Title] = []
        for i in 0..<count {
            let e = srpt + 8 + 12 * i
            titles.append(Title(number: i + 1, titleSet: Int(d[e + 6]), titleSetTitle: Int(d[e + 7]), chapters: dvdBE16(d, e + 2)))
        }
        return DVDVideoManager(titleSetCount: sets, titles: titles)
    }
}

/// One title set's VTS_nn_0.IFO.
public struct DVDTitleSetInfo: Sendable, Hashable {
    /// An audio stream as the title set declares it (8 bytes of audio attributes).
    public struct AudioStream: Sendable, Hashable {
        /// 0 AC-3, 2 MPEG-1, 3 MPEG-2, 4 LPCM, 6 DTS.
        public var coding: Int
        public var quantization: Int
        public var frequency: Int
        public var channels: Int
        public var language: String?
        public var isLPCM: Bool { coding == 4 }
        public var codingName: String {
            switch coding {
            case 0: "AC-3"
            case 2, 3: "MPEG audio"
            case 4: "LPCM"
            case 6: "DTS"
            default: "audio coding \(coding)"
            }
        }
    }

    public struct Cell: Sendable, Hashable {
        public var firstSector: Int
        public var lastSector: Int
        public var vobID: Int
        public var cellID: Int
        /// The IFO's playback time, rounded to video frames (display only: never used for audio timing).
        public var declaredSeconds: Double
        /// 0 normal, 1 angle block; within a block, 1 first cell, 2 middle, 3 last.
        public var blockType: Int
        public var blockMode: Int
        /// Angles 2… of a multi-angle block (only the first angle is played as audio).
        public var isOtherAngle: Bool { blockType == 1 && blockMode != 1 }
    }

    public struct ProgramChain: Sendable, Hashable {
        public var number: Int
        public var isTitleEntry: Bool
        /// Each program's first cell (1-based), in order.
        public var programEntries: [Int]
        public var cells: [Cell]
        /// The cells (indexes into `cells`) of each program.
        public var programCells: [[Int]] {
            programEntries.enumerated().map { i, entry in
                let next = i + 1 < programEntries.count ? programEntries[i + 1] : cells.count + 1
                return Array((entry - 1)..<max(entry - 1, next - 1))
            }
        }
    }

    public struct CellAddress: Sendable, Hashable {
        public var vobID: Int
        public var cellID: Int
        public var firstSector: Int
        public var lastSector: Int
    }

    public var titleSet: Int
    public var audio: [AudioStream]
    public var programChains: [ProgramChain]
    public struct Chapter: Sendable, Hashable { public var pgc: Int; public var program: Int }
    /// Title (VTS_TTN) → its chapters, each a program of a program chain.
    public var chapters: [[Chapter]]
    public var cellAddresses: [CellAddress]
    /// The first sector of every VOBU of the title VOBs, when the map is present and in order.
    public var vobuStarts: [Int]
    /// Sectors in the title VOBs, by the IFO (VTS last sector minus the IFO, menu VOBs and backup).
    public var titleVOBStart: Int

    public static func parse(_ d: [UInt8], titleSet: Int) throws -> DVDTitleSetInfo {
        let name = String(format: "VTS_%02d_0.IFO", titleSet)
        func bad(_ what: String = "") -> DVDVideoError { .damaged(what.isEmpty ? name : "\(name) \(what)") }
        guard d.count >= 0x300, d.starts(with: Array("DVDVIDEO-VTS".utf8)) else { throw bad() }
        let sector = DVDVideoVolume.sectorSize
        var info = DVDTitleSetInfo(titleSet: titleSet, audio: [], programChains: [], chapters: [], cellAddresses: [], vobuStarts: [],
                                   titleVOBStart: dvdBE32(d, 0xC4))
        let audioCount = Int(d[0x203])
        guard audioCount <= 8 else { throw bad("audio") }
        for i in 0..<audioCount {
            let a = Array(d[0x204 + 8 * i..<0x20C + 8 * i])
            let lang = a[2] != 0 && a[3] != 0 && (a[0] >> 2 & 3) == 1 ? String(bytes: a[2...3], encoding: .ascii) : nil
            info.audio.append(AudioStream(coding: Int(a[0] >> 5), quantization: Int(a[1] >> 6), frequency: Int(a[1] >> 4 & 3),
                                          channels: Int(a[1] & 7) + 1, language: lang))
        }

        // Program chains.
        let pgcit = dvdBE32(d, 0xCC) * sector
        guard pgcit > 0, pgcit + 8 <= d.count else { throw bad("program chains") }
        let pgcCount = dvdBE16(d, pgcit)
        guard pgcCount <= 999, pgcit + 8 + 8 * pgcCount <= d.count else { throw bad("program chains") }
        for i in 0..<pgcCount {
            let e = pgcit + 8 + 8 * i
            let pg = pgcit + dvdBE32(d, e + 4)
            guard pg + 0xEC <= d.count else { throw bad("program chain \(i + 1)") }
            let programs = Int(d[pg + 2]), cells = Int(d[pg + 3])
            let mapAt = pg + dvdBE16(d, pg + 0xE6), playbackAt = pg + dvdBE16(d, pg + 0xE8), positionAt = pg + dvdBE16(d, pg + 0xEA)
            var chain = ProgramChain(number: i + 1, isTitleEntry: d[e] & 0x80 != 0, programEntries: [], cells: [])
            if programs > 0 {
                guard cells > 0, mapAt + programs <= d.count, playbackAt + 24 * cells <= d.count, positionAt + 4 * cells <= d.count
                else { throw bad("program chain \(i + 1)") }
                chain.programEntries = (0..<programs).map { Int(d[mapAt + $0]) }
                for c in 0..<cells {
                    let x = playbackAt + 24 * c, y = positionAt + 4 * c
                    chain.cells.append(Cell(firstSector: dvdBE32(d, x + 8), lastSector: dvdBE32(d, x + 20),
                                            vobID: dvdBE16(d, y), cellID: Int(d[y + 3]),
                                            declaredSeconds: Self.playbackSeconds(Array(d[x + 4..<x + 8])),
                                            blockType: Int(d[x] >> 4 & 3), blockMode: Int(d[x] >> 6)))
                }
            }
            info.programChains.append(chain)
        }

        // Chapters (part-of-title search pointers).
        let ptt = dvdBE32(d, 0xC8) * sector
        if ptt > 0, ptt + 8 <= d.count {
            let titles = dvdBE16(d, ptt), last = dvdBE32(d, ptt + 4)
            for t in 0..<min(titles, 99) {
                let start = ptt + dvdBE32(d, ptt + 8 + 4 * t)
                let end = t + 1 < titles ? ptt + dvdBE32(d, ptt + 8 + 4 * (t + 1)) : ptt + last + 1
                var list: [Chapter] = []
                var o = start
                while o + 4 <= min(end, d.count) { list.append(Chapter(pgc: dvdBE16(d, o), program: dvdBE16(d, o + 2))); o += 4 }
                info.chapters.append(list)
            }
        }

        // Cell address table: every cell of the title VOBs, by VOB and cell ID.
        let cadt = dvdBE32(d, 0xE0) * sector
        if cadt > 0, cadt + 8 <= d.count {
            let last = dvdBE32(d, cadt + 4)
            var o = cadt + 8
            while o + 12 <= min(cadt + last + 1, d.count) {
                info.cellAddresses.append(CellAddress(vobID: dvdBE16(d, o), cellID: Int(d[o + 2]),
                                                      firstSector: dvdBE32(d, o + 4), lastSector: dvdBE32(d, o + 8)))
                o += 12
            }
        }
        // VOBU address map.
        let admap = dvdBE32(d, 0xE4) * sector
        if admap > 0, admap + 4 <= d.count {
            let last = dvdBE32(d, admap)
            var o = admap + 4
            var previous = -1
            while o + 4 <= min(admap + last + 1, d.count) {
                let s = dvdBE32(d, o)
                guard s > previous else { info.vobuStarts = []; break }    // out of order: not usable
                info.vobuStarts.append(s)
                previous = s
                o += 4
            }
        }
        return info
    }

    /// BCD hh:mm:ss:ff with the frame rate in the top bits of ff (25 or 29.97 fps).
    static func playbackSeconds(_ t: [UInt8]) -> Double {
        func bcd(_ b: UInt8) -> Double { Double(b >> 4) * 10 + Double(b & 0x0F) }
        let fps: Double = (t[3] >> 6) == 3 ? 30_000.0 / 1001 : 25
        return bcd(t[0]) * 3600 + bcd(t[1]) * 60 + bcd(t[2]) + bcd(t[3] & 0x3F) / fps
    }
}
