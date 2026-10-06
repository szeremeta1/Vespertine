//
// Vespertine — adding music: reference in place, or copy & organize into a managed folder.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreServices
import CryptoKit
import Darwin
import Foundation
import SFBAudioEngine

public enum ImportMode: String, Sendable, CaseIterable {
    case reference, copyAndOrganize
}

public enum ImportError: LocalizedError, Equatable {
    case notEnoughSpace(ImportSpace)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let space):
            let needed = ByteCountFormatter.string(fromByteCount: space.bytesToCopy, countStyle: .file)
            let free = space.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "less"
            let spare = ByteCountFormatter.string(fromByteCount: ImportSpace.reserve, countStyle: .file)
            return "Nothing was imported: the copies need \(needed) and the Mac has \(free) free (Vespertine keeps \(spare) spare). Free up some space, or use Add Folder to play the music where it is."
        }
    }
}

public enum Importer {
    /// Copies audio files into `root/Album Artist/Album/NN Title.ext` (plus cover images found beside them).
    /// Folders are expanded; `include` filters individual files (e.g. music only, hi-res only).
    /// On APFS the copies are clones: instant and taking no extra space until modified.
    /// Existing files are never overwritten, and a file imported before is not copied again (importing the same folder
    /// twice used to leave a "… 2" of everything). Nothing is copied unless it all fits with `ImportSpace.reserve`
    /// to spare. Returns the files written.
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
        var planned: [(file: URL, wanted: URL, inferred: InferredTags, md: AudioMetadata?)] = []
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
            let wanted = folder.appendingPathComponent(sanitize(name)).appendingPathExtension(file.pathExtension.lowercased())
            albumsPerSourceFolder[file.deletingLastPathComponent(), default: []].insert(folder)
            if let earlier = earlierCopy(of: file, at: wanted) {
                destinations[file.standardizedFileURL.path] = earlier
            } else {
                planned.append((file, wanted, inferred, md))
                destinations[file.standardizedFileURL.path] = wanted   // the final name is chosen when it's copied
            }
        }

        let space = ImportSpace.measure(files: planned.map { ($0.file, fileSize($0.file)) }, destination: root)
        guard space.fits else { throw ImportError.notEnoughSpace(space) }
        for item in planned {
            try FileManager.default.createDirectory(at: item.wanted.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dest = uniqueURL(item.wanted)
            try cloneOrCopy(item.file, to: dest)
            written.append(dest)
            destinations[item.file.standardizedFileURL.path] = dest
            // The copy is ours: record what the file name told us, where the tags are empty.
            fillMissingTags(at: dest, from: item.inferred, existing: item.md)
            stamp(dest, from: item.file)
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
                let mapped = sheet.files.compactMap { file in
                    CueSheet.audioFile(named: file.name, besideSheet: sheetURL).flatMap { destinations[$0.standardizedFileURL.path] }
                }
                guard mapped.count == sheet.files.count, let folder = mapped.first?.deletingLastPathComponent() else { continue }
                let data = try Data(contentsOf: sheetURL)
                guard var text = CueSheet.text(of: data) else { continue }
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
                // Imported before: the same sheet is already there.
                let existing = folder.appendingPathComponent(sheetURL.lastPathComponent)
                if (try? Data(contentsOf: existing)).flatMap(CueSheet.text(of:)) == text { continue }
                try text.write(to: uniqueURL(existing), atomically: true, encoding: .utf8)
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

    /// APFS clone when possible (same volume), full copy otherwise. Metadata and timestamps are preserved. The copy is
    /// made under a hidden temporary name beside `dest` and renamed into place, so one that fails partway (a full disk,
    /// a card pulled out) is removed rather than left at `dest`, where it would be scanned as music.
    static func cloneOrCopy(_ source: URL, to dest: URL) throws {
        let temporary = dest.deletingLastPathComponent().appendingPathComponent(".vespertine-import-\(UUID().uuidString)")
        do {
            let status = source.withUnsafeFileSystemRepresentation { src in
                temporary.withUnsafeFileSystemRepresentation { dst in
                    copyfile(src!, dst!, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
                }
            }
            if status != 0 {
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.copyItem(at: source, to: temporary)
            }
            // Never over a file that's there already (checked first where the volume can't make the rename exclusive).
            let renamed = temporary.withUnsafeFileSystemRepresentation { src in
                dest.withUnsafeFileSystemRepresentation { dst in
                    if renamex_np(src!, dst!, UInt32(RENAME_EXCL)) == 0 { return Int32(0) }
                    guard errno == ENOTSUP || errno == EINVAL else { return errno }
                    if access(dst!, F_OK) == 0 { return EEXIST }
                    return rename(src!, dst!) == 0 ? 0 : errno
                }
            }
            guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: renamed) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Every copy carries the size, modification date and a content fingerprint of the file it came from, so importing
    /// that file again finds the copy (whatever was written into its tags since) instead of making a "… 2", while a
    /// different file that only shares its size and date (a WAV of the same length, a card that keeps whole seconds)
    /// is still imported.
    private static let stampName = "org.szeremeta.vespertine.imported-from"

    static func identity(of url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return "\(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }

    /// The first and last MiB of the file (all of a small one), hashed: two reads, not the whole file, and any two
    /// different recordings differ there.
    static func fingerprint(of url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let span: UInt64 = 1 << 20
        var hash = SHA256()
        do {
            let end = try file.seekToEnd()
            let whole = end <= 2 * span
            for offset in whole ? [0] : [0, end - span] {
                try file.seek(toOffset: offset)
                hash.update(data: try file.read(upToCount: Int(whole ? end : span)) ?? Data())
            }
        } catch { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func stamp(_ copy: URL, from source: URL) {
        guard let identity = identity(of: source), let print = fingerprint(of: source) else { return }
        _ = "\(identity) \(print)".withCString { setxattr(copy.path, stampName, $0, strlen($0), 0, 0) }
    }

    /// An earlier copy of `source` at `wanted` or at one of its "… 2", "… 3" names: stamped with the source's size,
    /// date and fingerprint, or (copies made before stamping) an untouched copy, which keeps all three.
    static func earlierCopy(of source: URL, at wanted: URL) -> URL? {
        guard let identity = identity(of: source) else { return nil }
        var sourcePrint: String??
        func printOfSource() -> String? {
            if sourcePrint == nil { sourcePrint = .some(fingerprint(of: source)) }
            return sourcePrint!
        }
        let base = wanted.deletingPathExtension().lastPathComponent, ext = wanted.pathExtension
        for i in 1...1000 {
            let candidate = i == 1 ? wanted : wanted.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            var buffer = [UInt8](repeating: 0, count: 256)
            let length = getxattr(candidate.path, stampName, &buffer, buffer.count, 0, 0)
            let stamped = length > 0 ? String(decoding: buffer.prefix(length), as: UTF8.self).split(separator: " ").map(String.init) : []
            // Size and date first (cheap), then the content, which only a match makes it worth reading.
            if stamped.count == 3 {
                if stamped[0...1].joined(separator: " ") == identity, let print = printOfSource(), stamped[2] == print { return candidate }
            } else if self.identity(of: candidate) == identity, let print = printOfSource(), fingerprint(of: candidate) == print {
                return candidate
            }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        var st = stat()
        return stat(url.path, &st) == 0 ? Int64(st.st_size) : 0
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
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.fsevents")
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
                    return (path as NSString).deletingLastPathComponent
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
