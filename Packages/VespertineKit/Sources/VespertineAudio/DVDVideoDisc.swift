//
// Vespertine — a DVD-Video's music as tracks: each title's programs (chapters), cut from the disc's physical cells
// by 90 kHz presentation time, never by the IFO's rounded playback times. Menus are never read; navigation
// previews (a short cell of another VOB tacked onto a program) are left out; a disc whose cell table disagrees with
// its NAV packs is mapped from the NAV packs instead.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Which LPCM run of a DVD-Video a library track plays, and its place in the library ("<disc>#dvd-1-0-0-92125-3").
public struct DVDStreamRef: Sendable, Hashable, Codable {
    public var titleSet: Int
    /// The LPCM stream (0–7).
    public var stream: Int
    public var firstSector: Int
    public var lastSector: Int

    public init(titleSet: Int, stream: Int, firstSector: Int, lastSector: Int) {
        self.titleSet = titleSet
        self.stream = stream
        self.firstSector = firstSector
        self.lastSector = lastSector
    }

    /// "<path>#dvd-<title set>-<stream>-<first sector>-<last sector>-<track>": unique per track, and enough to
    /// reopen the run without reading the disc's navigation again.
    public func location(path: String, track: Int) -> String {
        "\(path)#dvd-\(titleSet)-\(stream)-\(firstSector)-\(lastSector)-\(track)"
    }

    /// The run a library location names; nil for every other kind of track.
    public init?(location: String) {
        guard let hash = location.lastIndex(of: "#") else { return nil }
        let tag = location[location.index(after: hash)...]
        guard tag.hasPrefix("dvd-") else { return nil }
        let parts = tag.dropFirst(4).split(separator: "-").map { Int($0) }
        guard parts.count == 5, let v = parts[0], let a = parts[1], let first = parts[2], let last = parts[3], parts[4] != nil,
              (1...99).contains(v), (0...7).contains(a), first >= 0, last >= first else { return nil }
        self.init(titleSet: v, stream: a, firstSector: first, lastSector: last)
    }
}

/// A DVD-Video disc's music.
public struct DVDVideoDisc: Sendable {
    /// A cell as the VOBs hold it: its sectors, VOB and cell IDs, and the time its first VOBU starts.
    public struct PhysicalCell: Sendable, Hashable {
        public var titleSet: Int
        public var vobID: Int
        public var cellID: Int
        public var firstSector: Int
        public var lastSector: Int
        public var startPTM: Int64
        public var endPTM: Int64
    }

    public struct Track: Sendable, Hashable {
        /// Within its album (title).
        public var number: Int
        public var title: Int
        /// The title's chapter (program) this track is.
        public var chapter: Int
        public var run: DVDLPCMRun
        public var startFrame: Int64
        public var frameCount: Int64
        public var cells: [PhysicalCell]
        public var ref: DVDStreamRef {
            DVDStreamRef(titleSet: run.titleSet, stream: run.stream, firstSector: run.firstSector, lastSector: run.lastSector)
        }
        public var duration: Double { Double(frameCount) / Double(run.format.sampleRate) }
    }

    /// One title's tracks: an album (or one side of a disc holding several).
    public struct Album: Sendable, Hashable {
        public var title: Int
        public var tracks: [Track]
    }

    /// Something left out, and why (for diagnostics and verification).
    public struct Exclusion: Sendable, Hashable {
        public var cell: PhysicalCell
        public var seconds: Double
        public var reason: String
    }

    public var volume: DVDVideoVolume
    public var albums: [Album]
    public var excluded: [Exclusion]
    /// The cell table didn't match the NAV packs: cells were mapped from the NAV packs.
    public var usedNAVCells: Bool
    /// Chapters that referred to programs or chains that aren't there (the title's own programs were used).
    public var defectiveChapters: Bool

    public var tracks: [Track] { albums.flatMap(\.tracks) }

    /// A cell from another VOB at the end of a program, shorter than this, is a navigation preview.
    public static let previewLimit: Double = 120

    public static func read(_ url: URL) throws -> DVDVideoDisc {
        let volume = try DVDVideoVolume.open(url)
        let manager = try DVDVideoManager.parse(try volume.contents(of: "VIDEO_TS.IFO"))
        var albums: [Album] = []
        var excluded: [Exclusion] = []
        var usedNAV = false, defective = false
        var unsupported: DVDVideoError?
        for set in 1...manager.titleSetCount {
            let name = String(format: "VTS_%02d_0.IFO", set)
            guard volume.files[name] != nil else { continue }
            let info = try DVDTitleSetInfo.parse(try volume.contents(of: name), titleSet: set)
            // The first LPCM stream the title set declares.
            guard let stream = info.audio.firstIndex(where: \.isLPCM) else {
                if let a = info.audio.first { unsupported = .unsupportedAudio(String(localized: "\(a.codingName) audio", comment: "Why DVD audio can't be played: its coding.")) }
                continue
            }
            let reader = DVDSectorReader(extents: volume.titleVOBs(titleSet: set))
            guard reader.sectorCount > 0 else { continue }
            var mapping = try TitleSetMapping(info: info, reader: reader)
            usedNAV = usedNAV || mapping.usedNAV
            try mapping.analyzeRuns(stream: stream)
            let titles = manager.titles.filter { $0.titleSet == set }
            let (setAlbums, setExcluded, setDefective) = try mapping.albums(titles: titles)
            defective = defective || setDefective
            albums += setAlbums
            excluded += setExcluded
        }
        albums.sort { $0.title < $1.title }
        if albums.isEmpty {
            if volume.hasDVDAudio { throw DVDVideoError.dvdAudioOnly }
            throw unsupported ?? DVDVideoError.unsupportedAudio(String(localized: "no LPCM audio", comment: "Why DVD audio can't be played."))
        }
        return DVDVideoDisc(volume: volume, albums: albums, excluded: excluded, usedNAVCells: usedNAV, defectiveChapters: defective)
    }

    /// Whether a .iso holds a DVD-Video (a VIDEO_TS with VIDEO_TS.IFO in its file system).
    public static func isDVDVideo(_ url: URL) -> Bool { (try? DVDVideoVolume.open(url)) != nil }
}

/// One title set's cells, LPCM runs and the tracks its titles make of them.
struct TitleSetMapping {
    let info: DVDTitleSetInfo
    let reader: DVDSectorReader
    var cells: [DVDVideoDisc.PhysicalCell] = []
    var usedNAV = false
    /// Run (by first sector) → its LPCM.
    var runs: [Int: DVDLPCMRun] = [:]
    /// Cell index → (run first sector, start frame, end frame).
    var cellFrames: [Int: (run: Int, start: Int64, end: Int64)] = [:]

    init(info: DVDTitleSetInfo, reader: DVDSectorReader) throws {
        self.info = info
        self.reader = reader
        // Cells the IFO places past the end of the VOBs: a truncated copy. That's damage, not navigation to work around.
        let lastNamed = (info.cellAddresses.map(\.lastSector) + info.programChains.flatMap { $0.cells.map(\.lastSector) }).max() ?? -1
        guard lastNamed < reader.sectorCount else {
            throw DVDVideoError.damaged(String(localized: "the VOBs end before the cells the IFO lists (a truncated copy)",
                                               comment: "Part of “This DVD-Video is damaged (…).”"))
        }
        if let fromTable = try? cellsFromTable() { cells = fromTable } else {
            cells = try cellsFromNAV()
            usedNAV = true
        }
    }

    private func nav(at sector: Int) throws -> DVDNav? {
        try DVDPacks.parse(try reader.sector(sector, ahead: false), sector: sector).nav
    }

    /// The cell address table, checked: in order, inside the VOBs, consistent with every program chain's cells, and
    /// each cell starting with a NAV pack that carries its VOB and cell ID. Any disagreement throws.
    private func cellsFromTable() throws -> [DVDVideoDisc.PhysicalCell] {
        let table = info.cellAddresses.sorted { $0.firstSector < $1.firstSector }
        guard !table.isEmpty else { throw DVDVideoError.damaged("cell table") }
        var out: [DVDVideoDisc.PhysicalCell] = []
        var previous = -1
        for c in table {
            guard c.firstSector > previous, c.lastSector >= c.firstSector, c.lastSector < reader.sectorCount,
                  let n = try nav(at: c.firstSector), n.vobID == c.vobID, n.cellID == c.cellID
            else { throw DVDVideoError.damaged("cell table") }
            // The cell's last VOBU ends at the cell's last sector.
            out.append(.init(titleSet: info.titleSet, vobID: c.vobID, cellID: c.cellID, firstSector: c.firstSector,
                             lastSector: c.lastSector, startPTM: n.startPTM, endPTM: n.endPTM))
            previous = c.lastSector
        }
        for chain in info.programChains {
            for cell in chain.cells {
                guard let match = out.first(where: { $0.vobID == cell.vobID && $0.cellID == cell.cellID }),
                      match.firstSector <= cell.firstSector, cell.lastSector <= match.lastSector
                else { throw DVDVideoError.damaged("program chain cells") }
            }
        }
        return out
    }

    /// The cells as the NAV packs mark them: each VOBU's NAV pack names its VOB and cell; consecutive VOBUs with the
    /// same IDs are one cell. Follows each VOBU's end address, or scans when that's missing or wrong.
    func cellsFromNAV() throws -> [DVDVideoDisc.PhysicalCell] {
        var out: [DVDVideoDisc.PhysicalCell] = []
        var s = 0
        while s < reader.sectorCount {
            guard let n = try nav(at: s) else { s += 1; continue }
            let end = n.vobuEnd > 0 && s + n.vobuEnd < reader.sectorCount ? s + n.vobuEnd : nil
            if var last = out.last, last.vobID == n.vobID, last.cellID == n.cellID {
                last.lastSector = (end ?? s)
                if n.endPTM >= 0 { last.endPTM = n.endPTM }
                out[out.count - 1] = last
            } else {
                if !out.isEmpty { out[out.count - 1].lastSector = max(out[out.count - 1].lastSector, s - 1) }
                out.append(.init(titleSet: info.titleSet, vobID: n.vobID, cellID: n.cellID, firstSector: s, lastSector: end ?? s,
                                 startPTM: n.startPTM, endPTM: n.endPTM))
            }
            s = (end ?? s) + 1
        }
        if !out.isEmpty { out[out.count - 1].lastSector = reader.sectorCount - 1 }
        guard !out.isEmpty else { throw DVDVideoError.damaged(String(localized: "no NAV packs", comment: "Part of “This DVD-Video is damaged (…).”")) }
        return out
    }

    /// Groups consecutive cells of one VOB into runs and reads each run's LPCM ends; then places every cell in its
    /// run by presentation time: a cell starts at the run's sample nearest its first VOBU's start time (the run's
    /// first cell at its first sample, its last cell running to its last sample, so a VOB's whole audio is kept).
    mutating func analyzeRuns(stream: Int) throws {
        var i = 0
        while i < cells.count {
            var j = i
            while j + 1 < cells.count, cells[j + 1].vobID == cells[i].vobID, cells[j + 1].firstSector == cells[j].lastSector + 1 { j += 1 }
            if let run = try DVDLPCMRun.analyze(reader, titleSet: info.titleSet, stream: stream,
                                                sectors: cells[i].firstSector...cells[j].lastSector) {
                runs[run.firstSector] = run
                var starts: [Int64] = (i...j).map { k in k == i ? 0 : run.frame(atPTS: cells[k].startPTM) }
                // Times that go backwards (a damaged NAV pack) keep the cell empty rather than reorder audio.
                for k in 1..<starts.count { starts[k] = max(starts[k], starts[k - 1]) }
                for k in i...j {
                    let end = k == j ? run.frameCount : starts[k - i + 1]
                    cellFrames[k] = (run.firstSector, starts[k - i], end)
                }
            }
            i = j + 1
        }
    }

    private func cellIndex(vob: Int, cell: Int, sectors: ClosedRange<Int>?) -> Int? {
        cells.firstIndex { c in
            c.vobID == vob && c.cellID == cell
        } ?? sectors.flatMap { r in cells.firstIndex { $0.firstSector <= r.lowerBound && r.upperBound <= $0.lastSector } }
    }

    private func seconds(_ frames: Int64, _ run: DVDLPCMRun) -> Double { Double(frames) / Double(run.format.sampleRate) }

    /// Each title's chapters as tracks. A chapter is its program's cells; cells of the program's own VOB make the
    /// track, and a short cell of another VOB at its end (a preview of what follows) is excluded. Duplicated
    /// chapters (a "play all" title over the same cells) are listed once, under the first title that has them.
    func albums(titles: [DVDVideoManager.Title]) throws -> ([DVDVideoDisc.Album], [DVDVideoDisc.Exclusion], Bool) {
        var defective = false
        struct Candidate { var title: Int; var chapter: Int; var cells: [Int] }
        var candidates: [Candidate] = []
        let titleList: [(number: Int, chapters: [DVDTitleSetInfo.Chapter])] = titles.isEmpty
            ? info.chapters.enumerated().map { ($0.offset + 1, $0.element) }
            : titles.map { t in (t.number, t.titleSetTitle >= 1 && t.titleSetTitle <= info.chapters.count ? info.chapters[t.titleSetTitle - 1] : []) }
        var usedChains = Set<Int>()
        for (number, chapters) in titleList {
            // Chapters must name existing programs of existing chains; otherwise use the title's entry chain's own programs.
            var list = chapters.filter { ch in
                ch.pgc >= 1 && ch.pgc <= info.programChains.count && ch.program >= 1 && ch.program <= info.programChains[ch.pgc - 1].programEntries.count
            }
            if list.count != chapters.count || list.isEmpty {
                defective = true
                if let chain = chapters.first.map(\.pgc).flatMap({ $0 >= 1 && $0 <= info.programChains.count ? $0 : nil })
                    ?? info.programChains.first(where: { $0.isTitleEntry && !usedChains.contains($0.number) })?.number {
                    list = (1...max(1, info.programChains[chain - 1].programEntries.count)).map { .init(pgc: chain, program: $0) }
                }
            }
            for (k, ch) in list.enumerated() {
                let chain = info.programChains[ch.pgc - 1]
                usedChains.insert(chain.number)
                guard ch.program - 1 < chain.programCells.count else { continue }
                let indexes = chain.programCells[ch.program - 1].compactMap { c -> Int? in
                    guard c < chain.cells.count, !chain.cells[c].isOtherAngle else { return nil }
                    let cell = chain.cells[c]
                    return cellIndex(vob: cell.vobID, cell: cell.cellID, sectors: cell.firstSector...max(cell.firstSector, cell.lastSector))
                }
                if !indexes.isEmpty { candidates.append(Candidate(title: number, chapter: k + 1, cells: indexes)) }
            }
        }

        // Duplicates and "play all" aggregates: a candidate whose cells all belong to other, smaller candidates goes.
        var kept: [Candidate] = []
        for (i, c) in candidates.enumerated() {
            if kept.contains(where: { $0.cells == c.cells }) { continue }
            let others = candidates.enumerated().filter { $0.offset != i && $0.element.cells.count < c.cells.count }.map(\.element)
            if c.cells.count > 1, c.cells.allSatisfy({ cell in others.contains { $0.cells.contains(cell) } }) { continue }
            kept.append(c)
        }

        var albums: [Int: [DVDVideoDisc.Track]] = [:]
        var excluded: [DVDVideoDisc.Exclusion] = []
        var placed = Set<Int>()
        for c in kept {
            // Split the program's cells into stretches of one run.
            var groups: [[Int]] = []
            for cell in c.cells where cellFrames[cell] != nil {
                if let last = groups.last?.last, cellFrames[last]!.run == cellFrames[cell]!.run, cell == last + 1 { groups[groups.count - 1].append(cell) }
                else { groups.append([cell]) }
            }
            guard let main = groups.first else { continue }
            let mainRun = cellFrames[main[0]]!.run
            for (g, group) in groups.enumerated() {
                let f = cellFrames[group[0]]!, last = cellFrames[group[group.count - 1]]!
                let run = runs[f.run]!
                let frames = last.end - f.start
                if g > 0, f.run != mainRun, seconds(frames, run) < DVDVideoDisc.previewLimit {
                    for cell in group where !placed.contains(cell) {
                        let cf = cellFrames[cell]!
                        excluded.append(.init(cell: cells[cell], seconds: seconds(cf.end - cf.start, run),
                                              reason: "navigation preview: a short cell of another VOB at the end of title \(c.title) chapter \(c.chapter)"))
                    }
                    group.forEach { placed.insert($0) }
                    continue
                }
                guard frames > 0, !group.allSatisfy({ placed.contains($0) }) else { continue }
                group.forEach { placed.insert($0) }
                albums[c.title, default: []].append(.init(number: 0, title: c.title, chapter: c.chapter, run: run,
                                                          startFrame: f.start, frameCount: frames, cells: group.map { cells[$0] }))
            }
        }
        // Cells no title plays: music that only the VOBs have. Kept unless short (previews), in their own album.
        for (i, cell) in cells.enumerated() where !placed.contains(i) {
            guard let f = cellFrames[i], let run = runs[f.run], f.end > f.start else { continue }
            if seconds(f.end - f.start, run) < DVDVideoDisc.previewLimit {
                excluded.append(.init(cell: cell, seconds: seconds(f.end - f.start, run), reason: "short cell that no title plays"))
                continue
            }
            albums[0, default: []].append(.init(number: 0, title: 0, chapter: 0, run: run, startFrame: f.start,
                                                frameCount: f.end - f.start, cells: [cell]))
        }
        let result = albums.keys.sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }.map { title in
            DVDVideoDisc.Album(title: title, tracks: albums[title]!.enumerated().map { i, t in var t = t; t.number = i + 1; return t })
        }
        return (result, excluded, defective)
    }
}
