//
// Nocturne — adding music: reference in place, or copy & organize into a managed folder.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreServices
import Darwin
import Foundation
import SFBAudioEngine

public enum ImportMode: String, Sendable, CaseIterable {
    case reference, copyAndOrganize
}

public enum Importer {
    /// Copies audio files into `root/Album Artist/Album/NN Title.ext` (plus cover images found beside them).
    /// Folders are expanded; `include` filters individual files (e.g. music only, hi-res only).
    /// On APFS the copies are clones: instant and taking no extra space until modified.
    /// Existing files are never overwritten. Returns the destination files.
    @discardableResult
    public static func copyAndOrganize(_ urls: [URL], into root: URL, include: (URL) -> Bool = { _ in true }) throws -> [URL] {
        let audioExts = LibraryScanner.audioExtensions
        let files = urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            return isDir.boolValue ? LibraryScanner.enumerate(url).audio : [url]
        }.filter { audioExts.contains($0.pathExtension.lowercased()) && include($0) }

        // A source folder's cover image is only meaningful when that folder holds a single album.
        var albumsPerSourceFolder: [URL: Set<URL>] = [:]
        var written: [URL] = []
        var destinations: [String: URL] = [:]
        let managed = root.resolvingSymlinksInPath().path
        for file in files where destinations[file.standardizedFileURL.path] == nil {
            // Never re-import files that already live in the managed folder.
            if file.resolvingSymlinksInPath().path.hasPrefix(managed + "/") { continue }
            let md = (try? AudioFile(readingPropertiesAndMetadataFrom: file))?.metadata
            let inferred = FilenameParser.parse(file)
            let artist = sanitize(md?.albumArtist.flatMap(nonEmpty) ?? md?.artist.flatMap(nonEmpty) ?? inferred.artist ?? "Unknown Artist")
            let album = sanitize(md?.albumTitle.flatMap(nonEmpty) ?? inferred.album ?? "Singles")
            let title = md?.title.flatMap(nonEmpty) ?? inferred.title
            let number = md?.trackNumber ?? inferred.trackNumber
            let disc = (md?.discTotal ?? 1) > 1 ? md?.discNumber.map { "\($0)-" } ?? "" : ""
            let name = disc + (number.map { String(format: "%02d ", $0) } ?? "") + title

            let folder = root.appendingPathComponent(artist, isDirectory: true).appendingPathComponent(album, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = uniqueURL(folder.appendingPathComponent(sanitize(name)).appendingPathExtension(file.pathExtension.lowercased()))
            try cloneOrCopy(file, to: dest)
            written.append(dest)
            destinations[file.standardizedFileURL.path] = dest
            // The copy is ours: record what the file name told us, where the tags are empty.
            fillMissingTags(at: dest, from: inferred, existing: md)

            albumsPerSourceFolder[file.deletingLastPathComponent(), default: []].insert(folder)
        }

        // Bring cover images from single-album source folders (never from mixed folders).
        for (sourceFolder, albums) in albumsPerSourceFolder where albums.count == 1 {
            let allAudio = LibraryScanner.enumerate(sourceFolder).audio.filter { $0.deletingLastPathComponent() == sourceFolder }
            let imported = files.filter { $0.deletingLastPathComponent() == sourceFolder }
            // Skip when the folder also holds audio we didn't import (it may belong to other albums).
            guard Set(allAudio.map(\.standardizedFileURL)).isSubset(of: Set(imported.map(\.standardizedFileURL))) else { continue }
            let siblings = (try? FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)) ?? []
            for sibling in siblings where ["cover", "folder", "front"].contains(sibling.deletingPathExtension().lastPathComponent.lowercased())
                && ["jpg", "jpeg", "png"].contains(sibling.pathExtension.lowercased()) {
                let target = albums.first!.appendingPathComponent(sibling.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try? cloneOrCopy(sibling, to: target) }
            }
        }
        // Rewrite CUE FILE references after every destination is known, including collision suffixes.
        let parents = Set(files.map { $0.deletingLastPathComponent() })
        for parent in parents {
            let siblings = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            for sheetURL in siblings where sheetURL.pathExtension.lowercased() == "cue" {
                guard let sheet = CueSheet.load(sheetURL), !sheet.files.isEmpty else { continue }
                let mapped = sheet.files.compactMap { destinations[parent.appendingPathComponent($0.name).standardizedFileURL.path] }
                guard mapped.count == sheet.files.count, let folder = mapped.first?.deletingLastPathComponent() else { continue }
                let data = try Data(contentsOf: sheetURL)
                guard var text = [String.Encoding.utf8, .windowsCP1252, .isoLatin1, .shiftJIS]
                    .compactMap({ String(data: data, encoding: $0) }).first else { continue }
                for (source, dest) in zip(sheet.files, mapped) {
                    let from = folder.standardizedFileURL.pathComponents
                    let to = dest.standardizedFileURL.pathComponents
                    let common = zip(from, to).prefix(while: { $0 == $1 }).count
                    let relative = (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(separator: "/")
                    let pattern = "(?im)^(\\s*FILE\\s+)(?:\"" + NSRegularExpression.escapedPattern(for: source.name)
                        + "\"|" + NSRegularExpression.escapedPattern(for: source.name) + ")(?=\\s)"
                    let regex = try NSRegularExpression(pattern: pattern)
                    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for match in matches.reversed() {
                        guard let range = Range(match.range, in: text), let prefix = Range(match.range(at: 1), in: text) else { continue }
                        text.replaceSubrange(range, with: String(text[prefix]) + "\"" + relative + "\"")
                    }
                }
                try text.write(to: uniqueURL(folder.appendingPathComponent(sheetURL.lastPathComponent)), atomically: true, encoding: .utf8)
            }
        }
        return written
    }

    static func fillMissingTags(at url: URL, from inferred: InferredTags, existing md: AudioMetadata?) {
        let needsTitle = md?.title.flatMap(nonEmpty) == nil
        let needsArtist = md?.artist.flatMap(nonEmpty) == nil && inferred.artist != nil
        let needsAlbum = md?.albumTitle.flatMap(nonEmpty) == nil && inferred.album != nil
        let needsNumber = md?.trackNumber == nil && inferred.trackNumber != nil
        guard needsTitle || needsArtist || needsAlbum || needsNumber,
              let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return }
        let m = file.metadata
        if needsTitle { m.title = inferred.title }
        if needsArtist { m.artist = inferred.artist; if m.albumArtist == nil { m.albumArtist = inferred.artist } }
        if needsAlbum { m.albumTitle = inferred.album }
        if needsNumber { m.trackNumber = inferred.trackNumber }
        TagWriter.protectDate(in: file)
        try? file.writeMetadata()
    }

    /// APFS clone when possible (same volume), full copy otherwise. Metadata and timestamps are preserved.
    static func cloneOrCopy(_ source: URL, to dest: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { src in
            dest.withUnsafeFileSystemRepresentation { dst in
                copyfile(src!, dst!, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
            }
        }
        if status != 0 { try FileManager.default.copyItem(at: source, to: dest) }
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        let trimmed = cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
        return String(trimmed.prefix(120)).isEmpty ? "_" : String(trimmed.prefix(120))
    }

    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for i in 2... {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// Watches library folders with FSEvents and reports changed roots (debounced).
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "org.nocturne.fsevents")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onChange: @Sendable ([String]) -> Void
    private var pending = Set<String>()
    private var roots: [String] = []
    private var debounce: DispatchWorkItem?

    public init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public func watch(_ paths: [String]) {
        queue.async { [self] in
            stopLocked()
            roots = paths
            guard !paths.isEmpty else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                watcher.received(Array(array.prefix(count)))
            }
            let watchedPaths = paths.map { path in
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return URL(fileURLWithPath: path).deletingLastPathComponent().path
                }
                return path
            }
            stream = FSEventStreamCreate(nil, callback, &context, watchedPaths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                         FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf))
            if let stream {
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
            }
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopLocked() }
        else { queue.sync { stopLocked() } }
    }

    private func stopLocked() {
        debounce?.cancel()
        debounce = nil
        pending.removeAll()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        for path in paths {
            for root in roots where path == root || path.hasPrefix(root == "/" ? "/" : root + "/") {
                pending.insert(root)
            }
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changed = Array(pending)
            pending.removeAll()
            if !changed.isEmpty { onChange(changed) }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
