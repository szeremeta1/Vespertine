//
// Nocturne — adding music: reference in place, or copy & organize into a managed folder.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreServices
import Foundation
import SFBAudioEngine

public enum ImportMode: String, Sendable, CaseIterable {
    case reference, copyAndOrganize
}

public enum Importer {
    /// Copies audio files (and their CUE sheets and cover images) into `root/Album Artist/Album/NN Title.ext`.
    /// Returns the destination folders touched. Existing files are never overwritten.
    public static func copyAndOrganize(_ urls: [URL], into root: URL) throws -> [URL] {
        var touched = Set<URL>()
        let audioExts = LibraryScanner.audioExtensions
        let files = urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            return isDir.boolValue ? LibraryScanner.enumerate(url).audio : [url]
        }.filter { audioExts.contains($0.pathExtension.lowercased()) }

        for file in files {
            let md = (try? AudioFile(readingPropertiesAndMetadataFrom: file))?.metadata
            let artist = sanitize(md?.albumArtist ?? md?.artist ?? "Unknown Artist")
            let album = sanitize(md?.albumTitle ?? "Unknown Album")
            var name = file.deletingPathExtension().lastPathComponent
            if let title = md?.title, !title.isEmpty {
                let number = md?.trackNumber.map { String(format: "%02d ", $0) } ?? ""
                let disc = (md?.discTotal ?? 1) > 1 ? md?.discNumber.map { "\($0)-" } ?? "" : ""
                name = disc + number + title
            }
            let folder = root.appendingPathComponent(artist, isDirectory: true).appendingPathComponent(album, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = uniqueURL(folder.appendingPathComponent(sanitize(name)).appendingPathExtension(file.pathExtension.lowercased()))
            try FileManager.default.copyItem(at: file, to: dest)
            touched.insert(folder)

            // Bring along companions that live next to the source.
            let siblings = (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            for sibling in siblings where ["jpg", "jpeg", "png", "cue", "log"].contains(sibling.pathExtension.lowercased()) {
                let target = folder.appendingPathComponent(sibling.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: sibling, to: target) }
            }
        }
        return Array(touched)
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
    private let onChange: @Sendable ([String]) -> Void
    private var pending = Set<String>()
    private var roots: [String] = []
    private var debounce: DispatchWorkItem?

    public init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
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
            stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                         FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf))
            if let stream {
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
            }
        }
    }

    public func stop() { queue.sync { stopLocked() } }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        for path in paths {
            if let root = roots.first(where: { path.hasPrefix($0) }) { pending.insert(root) }
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [self] in
            let changed = Array(pending)
            pending.removeAll()
            if !changed.isEmpty { onChange(changed) }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
