//
// Nocturne — finds music on this Mac and tells music apart from recordings, prompts and clips.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreServices
import Foundation
import NocturneAudio

/// One audio file, classified from its true (decoded) format.
public struct FoundAudioFile: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case music          // stereo (or mono ≥ 44.1 kHz), long enough to be a track
        case recording      // voice-grade: low sample rate or telephony
        case clip           // too short to be a track (prompts, stings, samples)
    }

    public var id: URL { url }
    public var url: URL
    public var format: SourceFormat
    public var duration: Double
    public var kind: Kind
    public var fileSize: Int64

    /// Identical content in another folder has the same size and length.
    public var duplicateKey: String { "\(fileSize)#\(Int((duration * 10).rounded()))" }

    public var isLossless: Bool { format.encoding != .lossy }
    /// Hi-res: DSD, or lossless with more than 16 bits or more than 48 kHz.
    public var isHiRes: Bool {
        format.encoding == .dsd || (format.encoding == .pcm && ((format.bitDepth ?? 16) > 16 || format.sampleRate > 48_000))
    }
}

/// A folder that directly contains audio files.
public struct FoundFolder: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var files: [FoundAudioFile]

    public var music: [FoundAudioFile] { files.filter { $0.kind == .music } }
    public var hiRes: [FoundAudioFile] { music.filter(\.isHiRes) }
    public var lossless: [FoundAudioFile] { music.filter(\.isLossless) }
    public var excludedCount: Int { files.count - music.count }
    public var totalDuration: Double { music.reduce(0) { $0 + $1.duration } }

    /// "FLAC 24/96 · WAV 24/44.1"
    public var formatSummary: String { Self.formatSummary(of: music) }

    public static func formatSummary(of files: [FoundAudioFile]) -> String {
        var seen: [String: Int] = [:]
        for f in files { seen[f.format.codec + " " + f.format.shortDescription, default: 0] += 1 }
        return seen.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3).map(\.key).joined(separator: " · ")
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

public enum MusicFinder {
    public struct Progress: Sendable {
        public var inspected: Int
        public var total: Int
        public init(inspected: Int, total: Int) { self.inspected = inspected; self.total = total }
    }

    /// Paths never worth offering: app bundles, libraries of other apps, caches, project bundles, trash.
    static let excludedPathFragments = [
        "/Library/", "/.Trash/", ".app/", ".fcpbundle/", ".photoslibrary/", ".musiclibrary/", ".tvlibrary/",
        ".logicx/", ".band/", "/node_modules/", "/.build/", "/DerivedData/", "/.git/", "/Caches/",
        "/Application Support/Nocturne/", ".xcarchive/", "/Pods/",
    ]

    /// Finds audio with Spotlight (all indexed volumes), or by walking `roots` when given.
    /// Files already inside `excludingRoots` (e.g. existing library sources) are skipped.
    public static func find(roots: [URL]? = nil, excludingRoots: [URL] = [],
                            progress: (@Sendable (Progress) -> Void)? = nil) async -> [FoundFolder] {
        let extensions = LibraryScanner.audioExtensions
        var candidates: [URL]
        if let roots {
            candidates = roots.flatMap { LibraryScanner.enumerate($0).audio }
        } else {
            candidates = spotlightAudioFiles()
        }
        let excluded = excludingRoots.map { $0.standardizedFileURL.path + "/" }
        candidates = candidates.filter { url in
            let path = url.path
            return extensions.contains(url.pathExtension.lowercased())
                && !excludedPathFragments.contains { path.contains($0) }
                && !excluded.contains { path.hasPrefix($0) }
        }

        let total = candidates.count
        let inspected = await withTaskGroup(of: FoundAudioFile?.self) { group -> [FoundAudioFile] in
            var results: [FoundAudioFile] = []
            var iterator = candidates.makeIterator()
            for _ in 0..<8 {
                guard let url = iterator.next() else { break }
                group.addTask { classify(url) }
            }
            var done = 0
            while let result = await group.next() {
                done += 1
                if let result { results.append(result) }
                if done % 20 == 0 || done == total { progress?(Progress(inspected: done, total: total)) }
                if let url = iterator.next() { group.addTask { classify(url) } }
            }
            return results
        }

        return Dictionary(grouping: inspected, by: { $0.url.deletingLastPathComponent().standardizedFileURL })
            .map { FoundFolder(url: $0.key, files: $0.value.sorted { $0.url.path < $1.url.path }) }
            .filter { !$0.music.isEmpty }
            .sorted { ($0.hiRes.count, $0.music.count) > ($1.hiRes.count, $1.music.count) }
    }

    static func classify(_ url: URL) -> FoundAudioFile? {
        guard let (format, duration) = try? SourceInspector.inspectWithDuration(url) else { return nil }
        let kind = kind(sampleRate: format.sampleRate, channels: format.channels, duration: duration, isDSD: format.encoding == .dsd)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return FoundAudioFile(url: url, format: format, duration: duration, kind: kind, fileSize: size)
    }

    /// Music vs voice recording vs short clip. Shared by the finder and the library scanner.
    public static func kind(sampleRate: Double, channels: Int, duration: Double, isDSD: Bool) -> FoundAudioFile.Kind {
        if !isDSD && sampleRate < 32_000 { return .recording }
        if channels == 1 && sampleRate < 44_100 { return .recording }
        if duration > 0 && duration < 45 { return .clip }
        return .music
    }

    static func spotlightAudioFiles() -> [URL] {
        let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemContentTypeTree == 'public.audio'" as CFString, nil, nil)
        guard let query else { return [] }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputerIndexed] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var urls: [URL] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { urls.append(URL(fileURLWithPath: path)) }
        }
        return urls
    }
}
