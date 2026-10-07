//
// Vespertine — `vespertine-analyze index` reads and compacts a large `.vespertine/analysis.jsonl` a chunk at a time,
// keeping the latest line for each file, copied as it is. Runs the built tool on files whose records are current,
// so nothing is decoded (no ffmpeg needed).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAnalysisCore

private final class Marker {}

@Suite("Server index")
struct IndexTests {
    /// The built `vespertine-analyze`, beside the tests.
    static var tool: URL? {
        // The test bundle's folder on macOS; the test executable's on Linux.
        let dirs = [Bundle(for: Marker.self).bundleURL.deletingLastPathComponent(),
                    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()]
            + Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        return dirs.map { $0.appendingPathComponent("vespertine-analyze") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()

    struct Record: Encodable {
        var path: String
        var size: Int64
        var mtime: Double
        var analysis: FileAnalysis
    }

    static func line(_ path: String, size: Int64, mtime: Double, summary: String) throws -> String {
        let spectrum = (0..<256).map { -Float($0) / 3 - 0.1 }
        let a = FileAnalysis(claimedBitDepth: 24, effectiveBitDepth: 24, sampleRate: 96_000, bandwidthHz: 40_000, peakDBFS: -1,
                             clippedSamples: 0, verdict: .genuine, summary: summary, spectrum: spectrum, secondsAnalyzed: 300,
                             version: FileAnalysis.currentVersion, confidence: 0.9)
        return String(decoding: try encoder.encode(Record(path: path, size: size, mtime: mtime, analysis: a)), as: UTF8.self) + "\n"
    }

    /// A folder of `count` stand-in audio files (never decoded: their records are current), with their size and date.
    static func folder(_ count: Int) throws -> (dir: URL, files: [(path: String, size: Int64, mtime: Double)]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-index-\(UUID().uuidString)")
        var files: [(String, Int64, Double)] = []
        for i in 0..<count {
            let path = String(format: "Artist %02d/Album/%04d Track.flac", i % 7, i)
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(i % 251), count: 100 + i).write(to: url)
            let mtime = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            files.append((path, Int64(100 + i), mtime.timeIntervalSince1970))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".vespertine"), withIntermediateDirectories: true)
        return (dir, files)
    }

    /// Runs `vespertine-analyze index` on `dir`; returns what it printed to stderr.
    static func index(_ dir: URL) throws -> String {
        let tool = try #require(tool, "vespertine-analyze isn't built beside the tests")
        let p = Process()
        p.executableURL = tool
        p.arguments = ["index", dir.path, "--jobs", "1"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(text)")
        return text
    }

    @Test("A large index is read and compacted a chunk at a time: the latest line per present file, verbatim, sorted")
    func largeIndex() throws {
        let (dir, files) = try Self.folder(1_500)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Three passes over every file (the last wins), records for files since removed, then a line cut off mid-write.
        var text = ""
        for pass in 1...3 {
            for f in files.shuffled() { text += try Self.line(f.path, size: f.size, mtime: f.mtime, summary: "pass \(pass)") }
            for i in 0..<200 { text += try Self.line("Gone/\(pass)-\(i).flac", size: 1, mtime: 1, summary: "gone") }
        }
        let last = try Self.line(files[0].path, size: files[0].size, mtime: files[0].mtime, summary: "pass 4")
        text += String(last.prefix(last.count / 2))
        let file = dir.appendingPathComponent(".vespertine/analysis.jsonl")
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(text.utf8.count > 2 * (4 << 20))

        let log = try Self.index(dir)
        #expect(log.contains("1500 audio files, 0 to analyze"), "\(log)")
        let expected = try files.sorted { $0.path < $1.path }.map { try Self.line($0.path, size: $0.size, mtime: $0.mtime, summary: "pass 3") }
        #expect(try String(contentsOf: file, encoding: .utf8) == expected.joined())

        // Compacted again: the same file.
        _ = try Self.index(dir)
        #expect(try String(contentsOf: file, encoding: .utf8) == expected.joined())
    }

    @Test("A last record that's whole but lacks its newline still counts, and is kept")
    func lastLineWithoutNewline() throws {
        let (dir, files) = try Self.folder(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Self.line(files[0].path, size: files[0].size, mtime: files[0].mtime, summary: "a")
        let b = try Self.line(files[1].path, size: files[1].size, mtime: files[1].mtime, summary: "b")
        let file = dir.appendingPathComponent(".vespertine/analysis.jsonl")
        try (b + a.dropLast()).write(to: file, atomically: true, encoding: .utf8)
        let log = try Self.index(dir)
        #expect(log.contains("2 audio files, 0 to analyze"), "\(log)")
        #expect(try String(contentsOf: file, encoding: .utf8) == a + b)
    }
}
