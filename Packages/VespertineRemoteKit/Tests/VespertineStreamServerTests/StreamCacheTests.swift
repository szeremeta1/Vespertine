//
// Vespertine: the transcode cache: files named by what they were made from, least recently used first out, never one in use.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineStreamServer

private func makeCache(limit: Int64 = 1000) throws -> (StreamCache, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-cache-\(UUID().uuidString)", isDirectory: true)
    return (try StreamCache(directory: dir, limitBytes: limit), dir)
}

private func put(_ cache: StreamCache, _ key: String, bytes: Int, at age: TimeInterval) throws {
    let url = cache.url(for: key)
    try Data(repeating: 7, count: bytes).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
}

@Suite struct Cache {
    @Test func theKeyChangesWithEverythingTheBytesDependOn() {
        let base = TranscodeRequest(source: URL(fileURLWithPath: "/a.dsf"), sourceSize: 100, sourceModified: Date(timeIntervalSince1970: 1), regionKey: nil,
                                    sampleRate: 176_400, bitDepth: 24, channels: 6)
        var keys: Set<String> = [StreamCache.key(for: base)]
        var other = base; other.sampleRate = 88_200; keys.insert(StreamCache.key(for: other))
        other = base; other.bitDepth = 16; keys.insert(StreamCache.key(for: other))
        other = base; other.channels = 2; keys.insert(StreamCache.key(for: other))
        other = base; other.sourceSize = 101; keys.insert(StreamCache.key(for: other))
        other = base; other.sourceModified = Date(timeIntervalSince1970: 2); keys.insert(StreamCache.key(for: other))
        other = base; other.regionKey = "cue:4"; keys.insert(StreamCache.key(for: other))
        other = base; other.source = URL(fileURLWithPath: "/b.dsf"); keys.insert(StreamCache.key(for: other))
        #expect(keys.count == 8)
        #expect(StreamCache.key(for: base) == StreamCache.key(for: base), "and is stable")
    }

    @Test func leastRecentlyUsedGoesFirstUntilItFits() throws {
        let (cache, dir) = try makeCache(limit: 250)
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(cache, "old", bytes: 100, at: 300)
        try put(cache, "mid", bytes: 100, at: 200)
        try put(cache, "new", bytes: 100, at: 100)
        cache.evict()
        #expect(!FileManager.default.fileExists(atPath: cache.url(for: "old").path))
        #expect(FileManager.default.fileExists(atPath: cache.url(for: "mid").path))
        #expect(FileManager.default.fileExists(atPath: cache.url(for: "new").path))
    }

    @Test func aFileInUseIsNeverEvictedEvenIfTheCacheIsOverTheLimit() throws {
        let (cache, dir) = try makeCache(limit: 50)
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(cache, "playing", bytes: 100, at: 999)
        cache.evict(keeping: ["playing"])
        #expect(FileManager.default.fileExists(atPath: cache.url(for: "playing").path))
    }

    @Test func usingAFileMakesItTheNewest() throws {
        let (cache, dir) = try makeCache(limit: 150)
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(cache, "a", bytes: 100, at: 300)
        try put(cache, "b", bytes: 100, at: 200)
        cache.touch("a")
        cache.evict()
        #expect(FileManager.default.fileExists(atPath: cache.url(for: "a").path))
        #expect(!FileManager.default.fileExists(atPath: cache.url(for: "b").path))
    }

    @Test func halfWrittenFilesFromACrashAreRemovedAtStart() throws {
        let (first, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = first.partialURL(for: "x")
        try Data([1, 2, 3]).write(to: partial)
        _ = try StreamCache(directory: dir, limitBytes: 1000)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func theSizeIsWhatIsOnDisk() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(cache, "a", bytes: 120, at: 1)
        try put(cache, "b", bytes: 30, at: 1)
        #expect(cache.totalBytes == 150)
    }
}
