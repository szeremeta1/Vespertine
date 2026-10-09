//
// Vespertine — finds what makes albums look wrong: one album split in pieces, several editions merged into
// one, the same file listed twice, missing track or disc numbers, titles that are file names.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB

public enum LibraryAudit {
    public struct Finding: Sendable, Hashable {
        public enum Kind: String, Sendable, CaseIterable {
            case splitAlbum = "One album split into several"
            case mergedEditions = "Several editions merged into one album"
            case duplicateFiles = "The same file listed twice"
            case missingNumbers = "Missing track or disc numbers"
            case fileNameTitles = "Titles that are file names"
        }
        public var kind: Kind
        /// "Artist — Album" for each album involved.
        public var albums: [String]
        public var detail: String
        public var paths: [String]
    }

    /// Everything worth a look among `tracks` (present tracks of the whole library), most serious first.
    public static func run(_ tracks: [Track]) -> [Finding] {
        let present = tracks.filter { !$0.isMissing }
        let albums = Dictionary(grouping: present, by: \.albumKey)
        func name(_ t: Track) -> String { "\(t.displayAlbumArtist) — \(t.album ?? "Unknown Album")" }
        var findings: [Finding] = []

        // Split: one album folder holding several albums (minus "Singles"-style folders and different albums that
        // merely share a folder, which have different titles), or one title under several credits or disc markers.
        var byFolder: [String: Set<String>] = [:]
        for t in present { byFolder[albumFolder(t.filePath), default: []].insert(t.albumKey) }
        for (folder, keys) in byFolder where keys.count > 1 {
            let titles = Set(keys.compactMap { albums[$0]?.first.map { comparableTitle($0.album, keepEditions: true) } })
            guard titles.count < keys.count else { continue }   // e.g. Weezer's Black and Teal albums in one folder
            findings.append(Finding(kind: .splitAlbum, albums: keys.sorted().compactMap { albums[$0]?.first.map(name) },
                                    detail: "one folder, \(keys.count) albums", paths: [folder]))
        }
        var byTitle: [String: Set<String>] = [:]
        for (key, ts) in albums {
            guard let t = ts.first, let album = t.album else { continue }
            byTitle[comparableArtist(t.displayAlbumArtist) + "\u{1F}" + comparableTitle(album, keepEditions: true), default: []].insert(key)
        }
        for (_, keys) in byTitle where keys.count > 1 {
            let named = keys.sorted().compactMap { albums[$0]?.first.map(name) }
            guard !findings.contains(where: { $0.kind == .splitAlbum && Set($0.albums) == Set(named) }) else { continue }
            findings.append(Finding(kind: .splitAlbum, albums: named, detail: "same album under different credits or disc titles",
                                    paths: keys.sorted().compactMap { albums[$0]?.first.map { albumFolder($0.filePath) } }))
        }

        for (_, ts) in albums.sorted(by: { $0.key < $1.key }) {
            guard let first = ts.first else { continue }
            // Merged: different songs on one disc and number, from different folders (two editions with one title).
            let songs = TrackVersions.group(ts)
            var byNumber: [String: [[Track]]] = [:]
            for song in songs { if let n = song[0].trackNumber { byNumber["\(song[0].discNumber ?? 1)-\(n)", default: []].append(song) } }
            let clashes = byNumber.values.filter { $0.count > 1 }
            let folders = Set(ts.map { albumFolder($0.filePath) })
            if !clashes.isEmpty && folders.count > 1 {
                findings.append(Finding(kind: .mergedEditions, albums: [name(first)],
                                        detail: "\(folders.count) folders; \(clashes.count) track numbers used by different songs",
                                        paths: folders.sorted()))
            }
            // Copies: the same file (size, length, title) twice. The app shows one; worth tidying anyway. An SACD image's
            // stereo and multichannel tracks share the file and their lengths, not their channels.
            let copies = Dictionary(grouping: ts) { "\($0.fileSize)|\(Int(($0.duration * 100).rounded()))|\($0.title.lowercased())|\($0.cueStartFrame ?? -1)|\($0.channels)" }
                .values.filter { $0.count > 1 }
            if !copies.isEmpty {
                let where_ = Set(copies.flatMap { $0.map { albumFolder($0.filePath) } }).sorted()
                findings.append(Finding(kind: .duplicateFiles, albums: [name(first)],
                                        detail: copies.count == 1 ? copies[0][0].title : "\(copies.count) songs", paths: where_))
            }
            // Numbers: an album (more than one track) with tracks lacking a number, or lacking a disc on a multi-disc album.
            if ts.count > 1 {
                let noNumber = ts.filter { ($0.trackNumber ?? 0) == 0 }.count
                let usesDiscs = Set(ts.compactMap(\.discNumber)).count > 1
                let noDisc = usesDiscs ? ts.filter { $0.discNumber == nil }.count : 0
                if noNumber > 0 || noDisc > 0 {
                    findings.append(Finding(kind: .missingNumbers, albums: [name(first)],
                                            detail: [noNumber > 0 ? "\(noNumber) without a track number" : nil,
                                                     noDisc > 0 ? "\(noDisc) without a disc number" : nil].compactMap { $0 }.joined(separator: ", ") + " (of \(ts.count))",
                                            paths: folders.sorted()))
                }
            }
            let named = ts.filter { $0.title.range(of: #"^.+ - .+ - \d{1,3} - "#, options: .regularExpression) != nil }
            if !named.isEmpty {
                findings.append(Finding(kind: .fileNameTitles, albums: [name(first)], detail: "\(named.count) of \(ts.count)",
                                        paths: [albumFolder(named[0].filePath)]))
            }
        }
        let order = Finding.Kind.allCases
        return findings.sorted { (order.firstIndex(of: $0.kind)!, $0.albums.joined()) < (order.firstIndex(of: $1.kind)!, $1.albums.joined()) }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The folder an album lives in: a file's folder, or the one above a disc folder ("CD 02", "Stereo").
    static func albumFolder(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return ArtworkStore.isDiscFolder((dir as NSString).lastPathComponent) ? (dir as NSString).deletingLastPathComponent : dir
    }

    static func comparableArtist(_ s: String) -> String {
        String(s.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// A title for comparing: case, punctuation and disc markers ("[CD-01]", "(Disc 2)") don't count; edition
    /// brackets ("(Deluxe)", "[2011 SACD]") count unless `keepEditions` is false.
    static func comparableTitle(_ title: String?, keepEditions: Bool) -> String {
        var t = (title ?? "").lowercased().replacingOccurrences(of: "’", with: "'")
        t = t.replacingOccurrences(of: #"\s*[\(\[]\s*(cd|disc|disk)[\s-]*\d{1,2}\s*[\)\]]"#, with: "", options: .regularExpression)
        if !keepEditions { t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression) }
        return String(t.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}

extension LibraryDatabase {
    /// Opens a library for reading only, without migrating it: safe on a library an app is using.
    public static func readOnly(url: URL) throws -> LibraryDatabase {
        var config = Configuration()
        config.readonly = true
        return try LibraryDatabase(writer: DatabaseQueue(path: url.path, configuration: config), migrate: false)
    }

    /// Every present track, for an audit.
    public func auditTracks() throws -> [Track] {
        try writer.read { db in try Track.filter(Column("isMissing") == false).fetchAll(db) }
    }
}
