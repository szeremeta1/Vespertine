//
// nocturne-library — library operations from the command line.
//   nocturne-library find [folder…]        list folders with music (read-only)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneLibrary

let args = Array(CommandLine.arguments.dropFirst())

func minutes(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

switch args.first {
case "find":
    let roots = args.count > 1 ? args.dropFirst().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } : nil
    let folders = await MusicFinder.find(roots: roots) { p in
        FileHandle.standardError.write("\rinspected \(p.inspected)/\(p.total)".data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    for f in folders {
        print("\(f.hiRes.isEmpty ? "  " : "★ ")\(f.displayPath)")
        print("     \(f.music.count) music (\(f.hiRes.count) hi-res, \(f.lossless.count) lossless) · \(minutes(f.totalDuration)) · \(f.formatSummary)\(f.excludedCount > 0 ? " · \(f.excludedCount) recordings/clips skipped" : "")")
    }
case "hires":
    // Every hi-res music file found, with its true format.
    let folders = await MusicFinder.find()
    for f in folders where !f.hiRes.isEmpty {
        print(f.displayPath)
        for file in f.hiRes { print("   \(file.format.codec) \(file.format.shortDescription)  \(minutes(file.duration))  \(file.url.lastPathComponent)") }
    }
case "search":
    // Search the tags of every music file found (artist, album artist, album, title).
    let term = args.dropFirst().joined(separator: " ").lowercased()
    for folder in await MusicFinder.find() {
        for file in folder.music {
            guard let t = try? MetadataReader.read(url: file.url, artwork: nil) else { continue }
            let hay = [t.title, t.artist, t.albumArtist, t.album, t.composer].compactMap { $0 }.joined(separator: " ").lowercased()
            if hay.contains(term) {
                print("\(file.format.codec) \(file.format.shortDescription) | \(t.displayArtist) — \(t.title) (\(t.displayAlbum)) | \(folder.displayPath)/\(file.url.lastPathComponent)")
            }
        }
    }
case "import":
    // nocturne-library import --library <data-dir> --into <managed-root> <file-or-folder…>
    var library: String?, into: String?, inputs: [URL] = []
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--library": library = args[i + 1]; i += 2
        case "--into": into = args[i + 1]; i += 2
        default: inputs.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)); i += 1
        }
    }
    guard let library, let into else { print("import needs --library and --into"); exit(2) }
    let dataDir = URL(fileURLWithPath: (library as NSString).expandingTildeInPath)
    let root = URL(fileURLWithPath: (into as NSString).expandingTildeInPath)
    let db = try LibraryDatabase(url: dataDir.appendingPathComponent("Library.sqlite"))
    let written = try Importer.copyAndOrganize(inputs, into: root)
    print("imported \(written.count) files into \(root.path)")
    let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dataDir.appendingPathComponent("Artwork")))
    let source = try db.addSource(LibrarySource(path: root.standardizedFileURL.path, mode: .managed))
    let summary = try await scanner.scan(source)
    print("scan: \(summary.added) added, \(summary.updated) updated, \(summary.skipped) skipped, \(summary.failed.count) failed")
case "enrich":
    // nocturne-library enrich --library <data-dir> [--apply high|all]
    guard let li = args.firstIndex(of: "--library") else { print("enrich needs --library"); exit(2) }
    let dataDir = URL(fileURLWithPath: (args[li + 1] as NSString).expandingTildeInPath)
    let mode = args.firstIndex(of: "--apply").map { args[$0 + 1] }
    let db = try LibraryDatabase(url: dataDir.appendingPathComponent("Library.sqlite"))
    let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dataDir.appendingPathComponent("Artwork")))
    let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dataDir.appendingPathComponent("Tag Backups"))
    let enricher = MetadataEnricher(database: db)
    for album in try db.albums() {
        let tracks = try db.tracks(albumKey: album.key)
        guard MetadataEnricher.needsEnrichment(tracks) else { print("✓ \(album.artist) — \(album.title): complete"); continue }
        guard let p = await enricher.propose(albumKey: album.key, tracks: tracks) else { print("· \(album.artist) — \(album.title): nothing found"); continue }
        let src: String = p.sources.map { (source: EnrichmentProposal.Source) -> String in
            if case .musicBrainz(let score, _) = source { return "MusicBrainz " + String(score) + "%" }
            return "file names"
        }.joined(separator: " + ")
        print("\(p.isHighConfidence ? "●" : "○") \(album.artist) — \(album.title) → \(p.artist) — \(p.title)\(p.year.map { " (\($0))" } ?? "") [\(src)] \(p.summary)")
        for t in tracks { if let e = p.edits[t.id ?? -1] { print("     \(t.title): " + e.fields.map { "\($0.key.rawValue)=\($0.value ?? "∅")" }.sorted().joined(separator: ", ")) } }
        if mode == "all" || (mode == "high" && p.isHighConfidence) {
            let r = try await writer.apply(p, tracks: tracks)
            print("     applied: \(r.written) files\(r.failures.isEmpty ? "" : ", \(r.failures.count) failed: \(r.failures[0].message)")")
        }
    }
case "tags":
    for path in args.dropFirst() {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let t = try? MetadataReader.read(url: url, artwork: nil) else { print("\(url.lastPathComponent): unreadable"); continue }
        print("\(url.lastPathComponent)")
        print("   title=\(t.title) | artist=\(t.artist ?? "-") | album=\(t.album ?? "-") | albumArtist=\(t.albumArtist ?? "-") | year=\(t.year.map(String.init) ?? "-") | track=\(t.trackNumber.map(String.init) ?? "-")/\(t.trackTotal.map(String.init) ?? "-") | genre=\(t.genre ?? "-") | art=\(ArtworkStore.hasEmbeddedArt(url) ? "yes" : "no")")
    }
default:
    print("usage: nocturne-library find [folder…] | hires | tags <file…> | search <term> | import --library <dir> --into <dir> <files…> | enrich --library <dir> [--apply high|all]")
}
