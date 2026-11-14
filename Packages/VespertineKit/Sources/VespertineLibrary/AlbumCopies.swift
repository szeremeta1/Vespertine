//
// Vespertine: the copies of one album in the library: the same album in several folders, formats and speaker layouts
// (a 24/192 download, a 24/96 vinyl transfer and a Dolby Atmos mix; an SACD's stereo and 5.1 areas; a WAV import beside
// the FLAC on a share), each kept whole, and its songs matched across them so any copy of any song can be found and played.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// The speaker layout a copy is mixed for. Mono and stereo files are one layout: a mono bonus track doesn't make
/// another copy of a stereo album.
public enum CopyLayout: Hashable, Sendable, Comparable {
    case stereo
    case surround(channels: Int)
    case atmos

    public init(_ track: Track) {
        if track.codec == DolbyAtmos.codecName { self = .atmos }
        else if track.channels > 2 { self = .surround(channels: track.channels) }
        else { self = .stereo }
    }

    public var isMultichannel: Bool { self != .stereo }

    /// "Stereo", "5.1", "7.1", "Dolby Atmos".
    public var name: String {
        switch self {
        case .stereo: String(localized: "Stereo")
        case .surround(let channels): ChannelLayouts.name(channels: channels)
        case .atmos: "Dolby Atmos"
        }
    }

    var key: String {
        switch self {
        case .stereo: "st"
        case .surround(let channels): "ch\(channels)"
        case .atmos: "atmos"
        }
    }

    public static func < (a: CopyLayout, b: CopyLayout) -> Bool { a.order < b.order }
    private var order: Int {
        switch self {
        case .stereo: 0
        case .surround(let channels): channels
        case .atmos: 100
        }
    }
}

/// One copy of an album: its tracks in one folder (disc and layer folders count as the album's), in one layout,
/// and in one format where the folder holds the same songs in two (a WAV and a FLAC of each).
public struct AlbumCopy: Sendable, Hashable, Identifiable {
    /// Stable across launches and rescans: the album folder, the layout, and the format when the folder holds two.
    public let id: String
    /// In disc and track order.
    public let tracks: [Track]
    /// The album's folder (above "CD 1", "Stereo", "Multichannel 5.1"), or the disc image.
    public let folder: String
    public let layout: CopyLayout
    /// "FLAC · 24/192", "DSD64", "FLAC · 24/96 + 24/48" (a copy whose songs differ in rate).
    public let format: String
    /// What the folder name says about this copy, when it says something: "Vinyl Transfer 24-96 - Dr. Robert",
    /// "SACD DSD64 Stereo + 5.1 - 2003", "Dolby Atmos". nil for a plain "Album (Year)" folder.
    public let edition: String?
    /// Where in the album folder its files are, when the folder holds this copy and another of the same format: "Digital
    /// Media 01–02" (disc folders) beside the files at its top (nil), or "#2" for the second copy of the same files.
    public let place: String?
    /// How many of the album's songs this copy has, and how many songs the album has across its copies.
    public internal(set) var songCount: Int
    public internal(set) var albumSongCount: Int

    public var isComplete: Bool { songCount >= albumSongCount }
    public var isLossless: Bool { tracks.allSatisfy(\.isLossless) }
    public var isDSD: Bool { tracks.contains(where: \.isDSD) }
    public var isHiRes: Bool { tracks.contains(where: \.isHiRes) }
    public var maxSampleRate: Double { tracks.map(\.sampleRate).max() ?? 0 }
    public var maxBitDepth: Int { tracks.compactMap(\.bitDepth).max() ?? 0 }
    public var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    public var size: Int64 {
        // A disc image's tracks are parts of one file: count it once.
        var seen = Set<String>()
        return tracks.reduce(0) { seen.insert($1.filePath).inserted ? $0 + $1.fileSize : $0 }
    }

    /// "Stereo · FLAC · 24/192", "5.1 · DSD64", "Dolby Atmos · Dolby Atmos" reads as "Dolby Atmos".
    public var summary: String {
        layout == .atmos && format == DolbyAtmos.codecName ? format : "\(layout.name) · \(format)"
    }
}

/// One song of an album, with every copy of it: at most one track from each copy of the album.
public struct SongCopies: Sendable, Hashable, Identifiable {
    public var id: String { tracks[0].location }
    /// One per copy that has the song, in the album's copy order (the most complete, best copy first).
    public internal(set) var tracks: [Track]
    /// The copy each of `tracks` is from.
    public internal(set) var copyIDs: [String]
    /// The track that numbers and titles the song (from the album's first copy that has it).
    public var lead: Track { tracks[0] }
}

/// An album's copies and its songs across them.
public struct AlbumCopies: Sendable {
    /// Most complete first, then the best (lossless, layout, rate), then by folder: a stable order for display.
    public let copies: [AlbumCopy]
    /// In album order: the songs of the first copy in its order, then songs that only other copies have.
    public let songs: [SongCopies]
    private let copyByLocation: [String: Int]
    private let songByLocation: [String: Int]

    public init(copies: [AlbumCopy], songs: [SongCopies]) {
        self.copies = copies
        self.songs = songs
        var copyBy: [String: Int] = [:], songBy: [String: Int] = [:]
        for (i, c) in copies.enumerated() { for t in c.tracks { copyBy[t.location] = i } }
        for (i, s) in songs.enumerated() { for t in s.tracks { songBy[t.location] = i } }
        copyByLocation = copyBy
        songByLocation = songBy
    }

    public static let empty = AlbumCopies(copies: [], songs: [])

    public func copy(of track: Track) -> AlbumCopy? { copyByLocation[track.location].map { copies[$0] } }
    public func copy(id: String) -> AlbumCopy? { copies.first { $0.id == id } }
    public func song(of track: Track) -> SongCopies? { songByLocation[track.location].map { songs[$0] } }

    /// The other copies of `track`'s song (not `track` itself).
    public func otherCopies(of track: Track) -> [Track] {
        song(of: track)?.tracks.filter { $0.location != track.location } ?? []
    }

    /// How each copy reads beside the others: the layout and format, then whatever else tells it apart (its edition
    /// in the folder name, then the folder's own name). Two copies never read the same unless their folders do.
    public func labels(location: (String) -> String = { ($0 as NSString).lastPathComponent }) -> [String: String] {
        var labels: [String: String] = [:]
        let bySummary = Dictionary(grouping: copies, by: \.summary)
        for (summary, group) in bySummary {
            if group.count == 1 { labels[group[0].id] = summary; continue }
            let byEdition = Dictionary(grouping: group) { $0.edition ?? "" }
            let byFolder = Dictionary(grouping: group, by: \.folder)
            for c in group {
                if byEdition[c.edition ?? ""]?.count == 1, let edition = c.edition {
                    labels[c.id] = "\(summary) · \(edition)"
                } else if byFolder[c.folder]?.count == 1 {
                    labels[c.id] = "\(summary) · \(location(c.folder))"
                } else {
                    labels[c.id] = "\(summary) · \(location(c.folder))" + (c.place.map { " › " + $0 } ?? "")
                }
            }
        }
        return labels
    }
}

public enum LibraryCopies {
    /// The copies of one album (`tracks`: all of one album key) and its songs across them.
    public static func analyze(_ tracks: [Track]) -> AlbumCopies {
        guard !tracks.isEmpty else { return .empty }
        let raw = partition(tracks)
        // Songs: the first copy's tracks start them; each further copy's tracks join the song they match best, at most
        // one track of a copy per song, or start their own (a bonus track only that copy has).
        var songs: [SongCopies] = []
        // Titles and ids worked out once per track, and each song found by them, so a large album (thousands of
        // untagged files under "Unknown Album") doesn't compare every track with every song.
        var keys: [String: MatchKey] = [:]
        for t in tracks { keys[t.location] = MatchKey(t) }
        var index: [String: [Int]] = [:]
        func register(_ k: MatchKey, song: Int) {
            for term in k.terms where index[term]?.last != song { index[term, default: []].append(song) }
        }
        for (copyIndex, copy) in raw.enumerated() {
            var candidates: [(score: Int, track: Int, song: Int)] = []
            if copyIndex > 0 {
                for (ti, t) in copy.tracks.enumerated() {
                    guard let k = keys[t.location] else { continue }
                    let near = Set(k.terms.flatMap { index[$0] ?? [] })
                    for si in near {
                        let best = songs[si].tracks.compactMap { keys[$0.location].map { k.score($0) } }.max() ?? 0
                        if best > 0 { candidates.append((best, ti, si)) }
                    }
                }
            }
            // Strongest first; ties go to the track and song that come first, so an album's own order wins.
            candidates.sort { ($0.score, -$0.track, -$0.song) > ($1.score, -$1.track, -$1.song) }
            var usedTracks = Set<Int>(), usedSongs = Set<Int>()
            for c in candidates where !usedTracks.contains(c.track) && !usedSongs.contains(c.song) {
                usedTracks.insert(c.track); usedSongs.insert(c.song)
                let t = copy.tracks[c.track]
                songs[c.song].tracks.append(t)
                songs[c.song].copyIDs.append(copy.id)
                if let k = keys[t.location] { register(k, song: c.song) }
            }
            for (ti, t) in copy.tracks.enumerated() where !usedTracks.contains(ti) {
                songs.append(SongCopies(tracks: [t], copyIDs: [copy.id]))
                if let k = keys[t.location] { register(k, song: songs.count - 1) }
            }
        }
        var counts: [String: Int] = [:]
        for s in songs { for id in s.copyIDs { counts[id, default: 0] += 1 } }
        let copies = raw.map { c in
            AlbumCopy(id: c.id, tracks: c.tracks, folder: c.folder, layout: c.layout, format: c.format, edition: c.edition,
                      place: c.place, songCount: counts[c.id] ?? 0, albumSongCount: songs.count)
        }
        return AlbumCopies(copies: copies, songs: ordered(songs))
    }

    /// Songs in disc and track order of their lead track when every song has its own number (so a song only a later
    /// copy has falls into place, a bonus disc after the album), else in the order they were found.
    private static func ordered(_ songs: [SongCopies]) -> [SongCopies] {
        let numbers = songs.map { s in s.lead.trackNumber.map { "\(s.lead.discNumber ?? 1)-\($0)" } }
        guard numbers.allSatisfy({ $0 != nil }), Set(numbers).count == numbers.count else { return songs }
        return songs.enumerated().sorted { a, b in
            let x = a.element.lead, y = b.element.lead
            return ((x.discNumber ?? 1), x.trackNumber ?? 0, a.offset) < ((y.discNumber ?? 1), y.trackNumber ?? 0, b.offset)
        }.map(\.element)
    }

    // MARK: Copies

    public struct RawCopy: Sendable {
        var id: String
        var tracks: [Track]
        var folder: String
        var layout: CopyLayout
        var format: String
        var edition: String?
        var place: String?
    }

    /// Splits an album's tracks into copies: by album folder and layout, then by format where one folder holds the
    /// same songs twice (a WAV and a FLAC of each), then whatever is still twice (the same file copied in) into a copy of
    /// its own. Ordered most complete first, then best.
    public static func partition(_ tracks: [Track]) -> [RawCopy] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for t in tracks {
            let key = "\(albumFolder(t))\u{1F}\(CopyLayout(t).key)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        var copies: [RawCopy] = []
        for key in order {
            let group = groups[key] ?? []
            let folder = albumFolder(group[0]), layout = CopyLayout(group[0])
            var parts: [(suffix: String, tracks: [Track])] = [("", group)]
            // The same songs at the folder's top and in its disc folders ("Album/01 …" and "Album/Digital Media 01/01 …"):
            // two copies, the loose files and the disc set.
            if hasRepeats(group) {
                let top = group.filter { ($0.filePath as NSString).deletingLastPathComponent == folder }
                let inDiscs = group.filter { ($0.filePath as NSString).deletingLastPathComponent != folder }
                if !top.isEmpty, !inDiscs.isEmpty, t(top, overlaps: inDiscs) {
                    parts = [("", top), ("\u{1F}discs", inDiscs)]
                }
            }
            parts = parts.flatMap { part -> [(suffix: String, tracks: [Track])] in
                guard hasRepeats(part.tracks) else { return [part] }
                var formatOrder: [String] = []
                var byFormat: [String: [Track]] = [:]
                for t in part.tracks {
                    let f = formatKey(t)
                    if byFormat[f] == nil { formatOrder.append(f) }
                    byFormat[f, default: []].append(t)
                }
                return formatOrder.map { (part.suffix + "\u{1F}" + $0, byFormat[$0] ?? []) }
            }
            // Still twice in one format: the second of each goes to a copy of its own ("…#2"), and so on.
            parts = parts.flatMap { part -> [(suffix: String, tracks: [Track])] in
                guard hasRepeats(part.tracks) else { return [part] }
                var layers: [[Track]] = []
                var seen: [String: Int] = [:]
                for t in part.tracks {
                    let k = numberKey(t) ?? t.location
                    let n = seen[k, default: 0]
                    seen[k] = n + 1
                    if layers.count <= n { layers.append([]) }
                    layers[n].append(t)
                }
                return layers.enumerated().map { (part.suffix + ($0.offset == 0 ? "" : "#\($0.offset + 1)"), $0.element) }
            }
            for part in parts {
                let sorted = part.tracks.enumerated().sorted { a, b in
                    let x = a.element, y = b.element
                    return ((x.discNumber ?? 1), x.trackNumber ?? Int.max, a.offset) < ((y.discNumber ?? 1), y.trackNumber ?? Int.max, b.offset)
                }.map(\.element)
                copies.append(RawCopy(id: key + part.suffix, tracks: sorted, folder: folder, layout: layout,
                                      format: format(of: sorted), edition: edition(folder: folder),
                                      place: parts.count > 1 ? place(of: sorted, in: folder, suffix: part.suffix) : nil))
            }
        }
        return copies.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra > rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Most tracks, then lossless, stereo before surround (the album as most people play it starts the songs), then
    /// the highest rate and depth.
    private static func rank(_ c: RawCopy) -> (Int, Int, Int, Double, Int) {
        (c.tracks.count, c.tracks.allSatisfy(\.isLossless) ? 1 : 0, c.layout.isMultichannel ? 0 : 1,
         c.tracks.map(\.sampleRate).max() ?? 0, c.tracks.compactMap(\.bitDepth).max() ?? 0)
    }

    /// The folder that holds the album: the file's folder, or the one above disc and layer folders ("CD 01",
    /// "Digital Media 02", "Stereo", "Multichannel 5.1", "VIDEO_TS"). A disc image is a copy of its own.
    public static func albumFolder(_ t: Track) -> String {
        if t.sacdArea != nil || (t.dvdStream != nil && !t.isDVDFolderTrack) { return t.filePath }
        var dir = (t.filePath as NSString).deletingLastPathComponent
        for _ in 0..<3 {
            let name = (dir as NSString).lastPathComponent
            guard ArtworkStore.isDiscFolder(name) || ["video_ts", "audio_ts"].contains(name.lowercased()) else { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return dir
    }

    /// Whether a group has some song twice (by disc, number and title, or by title and length when unnumbered).
    private static func hasRepeats(_ tracks: [Track]) -> Bool {
        var seen = Set<String>()
        for t in tracks { if let k = numberKey(t), !seen.insert(k).inserted { return true } }
        return false
    }

    private static func t(_ a: [Track], overlaps b: [Track]) -> Bool {
        let keys = Set(a.compactMap(numberKey))
        return b.contains { numberKey($0).map(keys.contains) ?? false }
    }

    /// "Digital Media 01–02" for a copy in disc folders, the album folder's name for one at its top, and a "#2" copy's number.
    private static func place(of tracks: [Track], in folder: String, suffix: String) -> String? {
        if let r = suffix.range(of: #"#\d+$"#, options: .regularExpression) { return String(suffix[r]) }
        let dirs = Array(Set(tracks.map { ($0.filePath as NSString).deletingLastPathComponent })).sorted()
        let names = dirs.filter { $0 != folder }.map { String($0.dropFirst(folder.count + 1)) }
        guard let first = names.first else { return nil }
        return names.count == 1 ? first : "\(first)–\(names.last!.split(separator: " ").last.map(String.init) ?? names.last!)"
    }

    private static func numberKey(_ t: Track) -> String? {
        let title = strictTitle(t.title)
        guard !title.isEmpty else { return nil }
        if let n = t.trackNumber { return "\(t.discNumber ?? 1)-\(n)-\(title)" }
        return "\(title)-\(Int(t.duration.rounded()))"
    }

    private static func formatKey(_ t: Track) -> String {
        "\(t.codec)|\(Int(t.sampleRate))|\(t.bitDepth ?? 0)|\(t.isLossless ? 1 : 0)"
    }

    /// The format of a copy: its tracks' one format, or the two most common ("FLAC · 24/96 + 24/48").
    static func format(of tracks: [Track]) -> String {
        var counts: [String: Int] = [:], order: [String] = []
        for t in tracks {
            let f = t.baseFormatSummary
            if counts[f] == nil { order.append(f) }
            counts[f, default: 0] += 1
        }
        let top = order.enumerated().sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }.map(\.element)
        guard top.count > 1 else { return top.first ?? "" }
        let first = top[0], second = top[1]
        // "FLAC · 24/96" + "FLAC · 24/48" → "FLAC · 24/96 + 24/48".
        if let a = first.range(of: " · "), let b = second.range(of: " · "), first[..<a.lowerBound] == second[..<b.lowerBound] {
            return first + " + " + second[b.upperBound...] + (top.count > 2 ? " …" : "")
        }
        return first + " + " + second + (top.count > 2 ? " …" : "")
    }

    /// What the album folder's name says about the copy: its last bracketed part ("[Vinyl Transfer 24-96 - Dr. Robert]",
    /// "[Dolby Atmos]"), when there is one that isn't just a year or a disc.
    static func edition(folder: String) -> String? {
        let name = (folder as NSString).lastPathComponent
        // A disc image's extension ("….iso"), not the ".1]" of "[… 16-44.1]".
        let ext = (name as NSString).pathExtension
        let base = ext.count <= 4 && ext.contains(where: \.isLetter) && ext.allSatisfy({ $0.isLetter || $0.isNumber })
            ? (name as NSString).deletingPathExtension : name
        guard let r = base.range(of: #"[\[\(]([^\[\]\(\)]+)[\]\)]\s*$"#, options: .regularExpression) else { return nil }
        let inner = base[r].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, inner.range(of: #"^((18|19|20)\d{2}|(cd|disc|disk)\s*\d+)$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return inner
    }

    // MARK: Matching songs

    /// What matching needs of a track, worked out once.
    struct MatchKey {
        let recording: String?, isrc: String?, strict: String, loose: String
        let duration: Double, disc: Int, number: Int?

        init(_ t: Track) {
            recording = t.musicBrainzRecordingID.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            isrc = t.isrc.flatMap { $0.isEmpty ? nil : $0.uppercased() }
            strict = LibraryCopies.strictTitle(t.title)
            loose = LibraryCopies.looseTitle(t.title)
            duration = t.duration; disc = t.discNumber ?? 1; number = t.trackNumber
        }

        /// The lookups a song is found by.
        var terms: [String] {
            var terms: [String] = []
            if let recording { terms.append("r:" + recording) }
            if let isrc { terms.append("i:" + isrc) }
            if !strict.isEmpty { terms.append("t:" + strict) }
            if !loose.isEmpty, loose != strict { terms.append("t:" + loose) }
            if let number { terms.append("n:\(disc)-\(number)") }
            return terms
        }

        /// How surely two tracks of different copies are the same song (0: they aren't). A MusicBrainz recording or an
        /// ISRC both carry settles it; otherwise the title (exactly, then without a "(2021 mix)", "(5.1 mix)" or "(2009
        /// Remaster)" label) with a length within 6 s or 4 %, helped by the same disc and number. "(Live)", "(Demo)",
        /// "(Acoustic Mix)" or "(1969 Glyn Johns mix)" stay other recordings.
        func score(_ o: MatchKey) -> Int {
            if let recording, recording == o.recording { return 1_000 }
            if let isrc, isrc == o.isrc { return 900 }
            guard !strict.isEmpty, !o.strict.isEmpty else { return 0 }
            var score: Int
            if strict == o.strict { score = 500 }
            else if !loose.isEmpty, loose == o.loose || loose == o.strict || strict == o.loose { score = 400 }
            else if let number, number == o.number, disc == o.disc, duration > 0, o.duration > 0,
                    abs(duration - o.duration) <= max(2, 0.01 * max(duration, o.duration)),
                    case let prefix = strict.commonPrefix(with: o.strict), prefix.count >= min(8, strict.count, o.strict.count),
                    !LibraryCopies.otherRecording(String((strict.count > o.strict.count ? strict : o.strict).dropFirst(prefix.count))) {
                // Same place, same length, titles that start alike: "Dance" and "Dance (Pt. 1)", "Shine On You Crazy
                // Diamond (Parts I - V)" and "…, Parts 1–5", "P.Y.T. (Pretty Young Thing) (Album Version)".
                return 300
            } else { return 0 }
            // Lengths unknown (0) don't count against a match.
            if duration > 0, o.duration > 0 {
                let delta = abs(duration - o.duration), tolerance = max(6, 0.04 * max(duration, o.duration))
                guard delta <= tolerance else { return 0 }
                score += Int(50 * (1 - delta / tolerance))
            }
            if let number, number == o.number { score += disc == o.disc ? 30 : 15 }
            return score
        }
    }

    /// What a longer title adds that makes it another recording, not a longer name for the same one.
    static func otherRecording(_ extra: String) -> Bool {
        ["live", "demo", "acoustic", "instrumental", "remix", "karaoke", "acappella", "rehearsal", "take", "mono", "edit", "reprise", "session"]
            .contains { extra.contains($0) }
    }

    static func match(_ a: Track, _ b: Track) -> Int { MatchKey(a).score(MatchKey(b)) }

    /// Letters and digits only, folded: "It’s All Futile!" and "It's All Futile!" are one title.
    static func strictTitle(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The title without a label that names a mix, master, layout or edition of the same recording.
    static func looseTitle(_ title: String) -> String {
        let label = #"\s*[\(\[][^\)\]]*(stereo|surround|5\.1|7\.1|atmos|multi-?channel|quad|remaster|anniversary|edition|deluxe|hi-?res|24[- ]?bit|\b(19|20)\d{2}\s+(re)?mix(ed)?|\bmix\s+(19|20)\d{2})[^\)\]]*[\)\]]"#
        var t = title.replacingOccurrences(of: label, with: "", options: [.regularExpression, .caseInsensitive])
        // " - 2009 Remaster", " - Remastered 2011", " - 2021 Mix" as Spotify-style suffixes.
        t = t.replacingOccurrences(of: #"\s+-\s+((19|20)\d{2}\s+)?(re-?master(ed)?|mix|stereo)(\s+(19|20)\d{2})?(\s+version)?\s*$"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        return strictTitle(t)
    }
}

/// Which copy of an album plays.
public enum AlbumCopyChoice: Hashable, Sendable {
    /// No choice made: one copy, the best for the output (`AlbumCopies.bestCopy`), shown as chosen for it.
    case automatic
    /// This copy (`AlbumCopy.id`), on every output.
    case copy(String)
    /// All copies as one album: each song plays the copy the output supports best, switching when the output does.
    case bundled
}

extension AlbumCopies {
    /// The copy to play when none is chosen: one that has most of the album (80 % of the songs of the most complete),
    /// in the layout the output wants, then lossless, then the highest rate and depth, then on this Mac (`isLocal`).
    public func bestCopy(multichannel wantsMultichannel: Bool, isLocal: (AlbumCopy) -> Bool = { _ in true }) -> AlbumCopy? {
        guard copies.count > 1 else { return copies.first }
        let most = copies.map(\.songCount).max() ?? 0
        // Copies equal in all of these: the first, which has the most songs.
        func rank(_ c: AlbumCopy) -> (Int, Int, Int, Double, Int, Int) {
            (Double(c.songCount) >= 0.8 * Double(most) ? 1 : 0, c.layout.isMultichannel == wantsMultichannel ? 1 : 0,
             c.isLossless ? 1 : 0, c.maxSampleRate, c.maxBitDepth, isLocal(c) ? 1 : 0)
        }
        return copies.enumerated().max { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset > b.offset
        }?.element
    }

    /// The album's "copies" have no song in common: they are different songs in different layouts or folders (a stereo
    /// album with one surround bonus track), not the same album twice. Choosing one of them would leave songs out.
    public var sharesNoSongs: Bool { copies.count > 1 && songs.allSatisfy { $0.tracks.count == 1 } }

    /// The copy `choice` names, if the album still has it, else the best one for the output; nil when bundled.
    public func selected(_ choice: AlbumCopyChoice, multichannel: Bool, isLocal: (AlbumCopy) -> Bool = { _ in true }) -> AlbumCopy? {
        switch choice {
        case .bundled: return copies.count > 1 ? nil : copies.first
        case .copy(let id): return copy(id: id) ?? bestCopy(multichannel: multichannel, isLocal: isLocal)
        case .automatic: return bestCopy(multichannel: multichannel, isLocal: isLocal)
        }
    }
}
