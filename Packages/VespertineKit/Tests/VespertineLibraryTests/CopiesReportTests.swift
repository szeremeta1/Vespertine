//
// Vespertine: a report of what the album copies make of a real library, before (one row per song, the other copies
// a tag beside it) and after (every copy listed and playable). Runs only when asked, on a read-only database:
//   VESPERTINE_COPIES_REPORT_DB=/path/Library.sqlite VESPERTINE_COPIES_REPORT_OUT=/path/report.md \
//     swift test --filter CopiesReportTests
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Copies report")
struct CopiesReportTests {
    @Test("Report on a real library", .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_COPIES_REPORT_DB"] != nil))
    func report() throws {
        let env = ProcessInfo.processInfo.environment
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: try #require(env["VESPERTINE_COPIES_REPORT_DB"]), configuration: config)
        let tracks = try queue.read { db in try Track.fetchAll(db, sql: "SELECT * FROM track WHERE isMissing = 0") }
        let albums = Dictionary(grouping: tracks, by: \.albumKey)
        var r = Report()
        r.tracks = tracks.count
        r.albums = albums.count
        for (_, ts) in albums.sorted(by: { $0.key < $1.key }) {
            let copies = LibraryCopies.analyze(ts)
            // Before: songs by disc, number and title; the row is the best version, the others a tag beside it.
            let legacy = Legacy.group(ts)
            r.songsBefore += legacy.count
            r.songsAfter += copies.songs.count
            if copies.copies.count > 1 { r.multiCopyAlbums += 1; r.copiesInMultiCopyAlbums += copies.copies.count }
            let name = "\(ts[0].displayAlbumArtist) — \(ts[0].displayAlbum)"
            var albumAmbiguous = false
            var shownCopies = Set<String>()
            for song in legacy {
                let chosen = TrackVersions.choose(song, multichannel: false) ?? song[0]
                if let c = copies.copy(of: chosen) { shownCopies.insert(c.id) }
                guard song.count > 1 else { continue }
                r.hiddenBefore += song.count - 1
                // The tag can't tell the copies apart: two others read the same, or one reads as the row already does.
                let names = song.filter { $0.location != chosen.location }.map { Legacy.versionName($0, beside: chosen) }
                let shown = chosen.formatSummary
                if Set(names).count < names.count || names.contains(where: { shown.hasSuffix($0) || $0 == "COPY" }) {
                    r.ambiguousSongsBefore += 1; albumAmbiguous = true
                }
                // Two tracks of one copy as one song (two songs merged by number), or a song spread over copies the
                // album page mixes into one list.
                let ids = song.compactMap { copies.copy(of: $0)?.id }
                if Set(ids).count < ids.count { r.mergedSongsBefore += 1; albumAmbiguous = true }
            }
            if shownCopies.count > 1 && copies.copies.count > 1 {
                r.mixedAlbumsBefore += 1; albumAmbiguous = true
            }
            if albumAmbiguous { r.ambiguousAlbumsBefore.append(name) }

            // After.
            let labels = copies.labels()
            if Set(labels.values).count < labels.count { r.ambiguousCopyLabelsAfter += 1; r.ambiguousAlbumsAfter.append(name + " (labels)") }
            for song in copies.songs where Set(song.copyIDs).count < song.copyIDs.count {
                r.mergedSongsAfter += 1; r.ambiguousAlbumsAfter.append(name + " (song twice in a copy)")
            }
            let covered = Set(copies.copies.flatMap { $0.tracks.map(\.location) })
            r.unreachableAfter += ts.filter { !covered.contains($0.location) }.count
            // Matches worth a look: a track that started its own song though another copy has a song at its number
            // with nearly its length (a retitled track the matcher missed).
            for song in copies.songs where song.tracks.count == 1 {
                let t = song.lead
                guard copies.copies.count > 1, let n = t.trackNumber,
                      copies.copy(of: t)?.id != copies.copies[0].id else { continue }
                if copies.songs.contains(where: { s in s.id != song.id && s.tracks.contains { o in
                    o.trackNumber == n && (o.discNumber ?? 1) == (t.discNumber ?? 1) && abs(o.duration - t.duration) < 2
                        && copies.copy(of: o)?.id != copies.copy(of: t)?.id } }) {
                    r.reviewAfter.append("\(name): \(t.discNumber ?? 1)-\(n) \"\(t.title)\" (\(copies.copy(of: t)?.summary ?? ""))")
                }
            }
            for c in copies.copies { r.layouts[c.layout.name, default: 0] += 1 }
        }
        let text = r.markdown
        if let out = env["VESPERTINE_COPIES_REPORT_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        print(text)
        #expect(r.unreachableAfter == 0)
        #expect(r.mergedSongsAfter == 0)
    }

    struct Report {
        var tracks = 0, albums = 0, songsBefore = 0, songsAfter = 0, multiCopyAlbums = 0, copiesInMultiCopyAlbums = 0
        var hiddenBefore = 0, ambiguousSongsBefore = 0, mergedSongsBefore = 0, mixedAlbumsBefore = 0
        var ambiguousAlbumsBefore: [String] = []
        var ambiguousCopyLabelsAfter = 0, mergedSongsAfter = 0, unreachableAfter = 0
        var ambiguousAlbumsAfter: [String] = []
        var reviewAfter: [String] = []
        var layouts: [String: Int] = [:]

        var markdown: String {
            var s = """
            # Copies report

            | | Before (0.14.2) | After |
            |---|---:|---:|
            | Present tracks | \(tracks) | \(tracks) |
            | Album keys | \(albums) | \(albums) |
            | Songs (rows of all album pages, bundled) | \(songsBefore) | \(songsAfter) |
            | Albums with more than one copy | – | \(multiCopyAlbums) (\(copiesInMultiCopyAlbums) copies) |
            | Tracks with no row of their own (hidden behind a "+ …" tag, unplayable) | \(hiddenBefore) | \(unreachableAfter) |
            | Songs whose tag can't tell the copies apart ("+ 24/48" beside "WAV · 24/48", "+ COPY", two alike) | \(ambiguousSongsBefore) | 0 |
            | Songs holding two tracks of one copy (two songs merged by number) | \(mergedSongsBefore) | \(mergedSongsAfter) |
            | Album pages mixing rows from different copies (DSD64 rows then FLAC rows) | \(mixedAlbumsBefore) | 0 |
            | Albums whose copies read the same | – | \(ambiguousCopyLabelsAfter) |
            | **Ambiguous albums** | **\(ambiguousAlbumsBefore.count)** | **\(ambiguousAlbumsAfter.count)** |

            Copies by layout: \(layouts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

            ## Worth a look after (unmatched track at a number another copy has, length within 2 s): \(reviewAfter.count)

            """
            s += reviewAfter.map { "- " + $0 }.joined(separator: "\n")
            s += "\n\n## Ambiguous after: \(ambiguousAlbumsAfter.count)\n\n" + ambiguousAlbumsAfter.map { "- " + $0 }.joined(separator: "\n")
            s += "\n\n## Ambiguous before: \(ambiguousAlbumsBefore.count)\n\n" + ambiguousAlbumsBefore.map { "- " + $0 }.joined(separator: "\n")
            return s + "\n"
        }
    }

    /// 0.14.2's grouping and tags, kept here to measure against.
    enum Legacy {
        static func group(_ tracks: [Track]) -> [[Track]] {
            var order: [String] = []
            var groups: [String: [Track]] = [:]
            for t in tracks {
                let key = songKey(t) ?? "#\(t.id ?? 0)-\(t.location)"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(t)
            }
            return order.compactMap { groups[$0] }
        }

        static func songKey(_ t: Track) -> String? {
            guard let number = t.trackNumber else { return nil }
            var title = t.title.lowercased()
            title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(stereo|surround|5\.1|7\.1|multichannel|quad|remaster|anniversary|edition)[^\)\]]*[\)\]]"#,
                                               with: "", options: .regularExpression)
            title = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            guard !title.isEmpty else { return nil }
            return "\(t.albumKey)\u{1F}\(t.discNumber ?? 1)\u{1F}\(number)\u{1F}\(title)"
        }

        static func versionName(_ other: Track, beside chosen: Track) -> String {
            if other.isMultichannel != chosen.isMultichannel { return other.isMultichannel ? "\(other.channels)ch" : "STEREO" }
            if other.fileSize == chosen.fileSize && abs(other.duration - chosen.duration) < 0.01 { return "COPY" }
            if other.isDSD { return "DSD\(Int((other.sampleRate / 44_100).rounded()))" }
            if !other.isLossless { return other.codec.uppercased() }
            let rate = other.sampleRate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(other.sampleRate / 1000)) : String(format: "%.1f", other.sampleRate / 1000)
            return "\(other.bitDepth ?? 16)/\(rate)"
        }
    }
}
