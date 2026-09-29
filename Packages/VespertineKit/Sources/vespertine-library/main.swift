//
// vespertine-library — library operations from the command line.
//   vespertine-library find [folder…]        list folders with music (read-only)
//   vespertine-library scan --library <dir> <folder>   index a folder (local or a mounted network share)
//   vespertine-library verify-remote <folder> [n]      check the fast network tag path against direct reads
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary

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
    // vespertine-library import --library <data-dir> --into <managed-root> <file-or-folder…>
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
case "import-server-analysis":
    // vespertine-library import-server-analysis --library <data-dir>
    // Imports results from each network share's `.vespertine/analysis.jsonl` (written by vespertine-analyze).
    guard let li = args.firstIndex(of: "--library"), li + 1 < args.count else { print("needs --library"); exit(2) }
    let dataDir = URL(fileURLWithPath: (args[li + 1] as NSString).expandingTildeInPath)
    let db = try LibraryDatabase(url: dataDir.appendingPathComponent("Library.sqlite"))
    let importer = ServerAnalysisImporter()
    for source in try db.sources() where source.remoteURL != nil {
        let start = Date()
        let root = ServerAnalysisImporter.indexRoot(for: source)
        let n = try importer.importNew(for: source, into: db)
        let status = root.flatMap(ServerAnalysisImporter.status(at:))
        print(String(format: "%@: index %@, imported %d in %.1f s; server %@ %d/%d", source.name ?? "share",
                     root == nil ? "not found" : "found", n, Date().timeIntervalSince(start),
                     status?.state ?? "?", status?.done ?? 0, status?.total ?? 0))
        let again = try importer.importNew(for: source, into: db)
        print("  second pass (incremental): imported \(again)")
    }

case "scan":
    // vespertine-library scan --library <data-dir> <folder>   (adds the folder by reference, then indexes it)
    guard let li = args.firstIndex(of: "--library"), li + 1 < args.count else { print("scan needs --library"); exit(2) }
    let dataDir = URL(fileURLWithPath: (args[li + 1] as NSString).expandingTildeInPath)
    let folders = args.dropFirst().enumerated().filter { $0.offset + 1 != li && $0.offset + 1 != li + 1 }.map(\.element)
    guard let folder = folders.first else { print("scan needs a folder"); exit(2) }
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let db = try LibraryDatabase(url: dataDir.appendingPathComponent("Library.sqlite"))
    let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dataDir.appendingPathComponent("Artwork")))
    let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
    let source = try db.addSource(LibrarySource(path: root.path, mode: .reference))
    let start = Date()
    let summary = try await scanner.scan(source) { p in
        let rate = Double(p.processed) / max(0.001, Date().timeIntervalSince(start))
        FileHandle.standardError.write(String(format: "\r%@ %d/%d files · %.0f/s   ", p.phase.rawValue, p.processed, p.total, rate).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    print(String(format: "scan: %d added, %d updated, %d skipped, %d missing, %d failed in %.1fs", summary.added, summary.updated, summary.skipped, summary.missing, summary.failed.count, Date().timeIntervalSince(start)))
    for f in summary.failed.prefix(10) { print("   failed: \(f)") }
case "export-spatial":
    // vespertine-library export-spatial <file> <output.m4a> [binaural|multichannel]
    guard args.count >= 3 else { print("export-spatial needs a file and an output path"); exit(2) }
    let kind: MultichannelExport.Kind = args.count > 3 && args[3] == "multichannel" ? .multichannelALAC : .spatialStereo
    let started = Date()
    let written = try MultichannelExport.export(PlayableItem(url: URL(fileURLWithPath: args[1], isDirectory: false)), kind: kind,
                                                to: URL(fileURLWithPath: args[2], isDirectory: false)) { f in
        FileHandle.standardError.write(String(format: "\r%3.0f%%", f * 100).data(using: .utf8)!)
    }
    print(String(format: "\nwrote %d channels in %.1f s → %@", written, Date().timeIntervalSince(started), args[2]))
case "verify-remote":
    // vespertine-library verify-remote <folder> [count]
    // Checks the fast network tag path against a direct read, field by field.
    guard args.count > 1 else { print("verify-remote needs a folder"); exit(2) }
    let root = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let limit = args.count > 2 ? Int(args[2]) ?? 50 : 50
    let files = LibraryScanner.enumerate(root).audio
    // Spread the sample across formats and folders.
    let byExt = Dictionary(grouping: files) { $0.pathExtension.lowercased() }
    var sample: [URL] = []
    while sample.count < min(limit, files.count) {
        var added = false
        for (_, group) in byExt.sorted(by: { $0.key < $1.key }) where sample.count < limit {
            let pick = group[(sample.count * 7919) % group.count]
            if !sample.contains(pick) { sample.append(pick); added = true }
        }
        if !added { break }
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-verify-\(getpid())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let art = ArtworkStore(directory: tmp.appendingPathComponent("Artwork"))
    var mismatches = 0, totalRequests = 0, fastTime = 0.0, directTime = 0.0
    for url in sample {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let shadow = tmp.appendingPathComponent(url.lastPathComponent)
        var t = Date()
        let requests = (try? RemoteMetadata.makeShadow(of: url, size: size, at: shadow)) ?? -1
        let fast = try? MetadataReader.read(url: shadow, artwork: art, original: url)
        fastTime += Date().timeIntervalSince(t)
        t = Date()
        let direct = try? MetadataReader.read(url: url, artwork: art)
        directTime += Date().timeIntervalSince(t)
        try? FileManager.default.removeItem(at: shadow)
        totalRequests += max(0, requests)
        guard let fast, let direct else {
            mismatches += 1
            print("✗ \(url.lastPathComponent): fast=\(fast != nil) direct=\(direct != nil)")
            continue
        }
        let pairs: [(String, String, String)] = [
            ("title", fast.title, direct.title), ("artist", fast.artist ?? "", direct.artist ?? ""),
            ("album", fast.album ?? "", direct.album ?? ""), ("albumArtist", fast.albumArtist ?? "", direct.albumArtist ?? ""),
            ("track", "\(fast.trackNumber ?? 0)/\(fast.trackTotal ?? 0)", "\(direct.trackNumber ?? 0)/\(direct.trackTotal ?? 0)"),
            ("disc", "\(fast.discNumber ?? 0)", "\(direct.discNumber ?? 0)"), ("date", fast.releaseDate ?? "", direct.releaseDate ?? ""),
            ("genre", fast.genre ?? "", direct.genre ?? ""), ("codec", fast.codec, direct.codec),
            ("rate", "\(fast.sampleRate)", "\(direct.sampleRate)"), ("bits", "\(fast.bitDepth ?? 0)", "\(direct.bitDepth ?? 0)"),
            ("channels", "\(fast.channels)", "\(direct.channels)"),
            ("duration", String(format: "%.1f", fast.duration), String(format: "%.1f", direct.duration)),
            ("mbid", fast.musicBrainzReleaseID ?? "", direct.musicBrainzReleaseID ?? ""),
            ("rg", "\(fast.rgTrackGain ?? 0)", "\(direct.rgTrackGain ?? 0)"),
            ("art", fast.artworkKey ?? "-", direct.artworkKey ?? "-"),
        ]
        let diff = pairs.filter { $0.1 != $0.2 }
        if diff.isEmpty { print("✓ \(url.pathExtension.lowercased()) \(requests) reads  \(url.lastPathComponent)") }
        else {
            mismatches += 1
            print("✗ \(url.lastPathComponent): " + diff.map { "\($0.0) fast=\($0.1) direct=\($0.2)" }.joined(separator: "; "))
        }
    }
    print(String(format: "%d files, %d mismatches · fast %.2fs/file (%.1f reads/file) · direct %.2fs/file",
                 sample.count, mismatches, fastTime / Double(max(1, sample.count)), Double(totalRequests) / Double(max(1, sample.count)),
                 directTime / Double(max(1, sample.count))))
case "enrich":
    // vespertine-library enrich --library <data-dir> [--apply high|all]
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
    print("usage: vespertine-library find [folder…] | hires | tags <file…> | search <term> | scan --library <dir> <folder> | verify-remote <folder> [count] | import --library <dir> --into <dir> <files…> | enrich --library <dir> [--apply high|all]")
}

