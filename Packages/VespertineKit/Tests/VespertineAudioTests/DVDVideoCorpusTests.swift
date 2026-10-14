// Vespertine — opt-in real-disc DVD-Video LPCM audit: every track through the app's own source opener and region
// decoder, complete-PCM hashes against independent references, and seeks at the beginning, middle and end.
// No audio or private paths are checked in. Set VESPERTINE_DVD_FIXTURES to a folder holding the discs (a .iso, or a
// folder with VIDEO_TS) and, optionally, VESPERTINE_DVD_REFERENCE to a JSON file of expected results
// (docs/verification/dvd-video-lpcm-2026-10-14.json) and VESPERTINE_DVD_AUDIT_OUTPUT to write the measured results.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import VespertineAudio

private let fixtures = ProcessInfo.processInfo.environment["VESPERTINE_DVD_FIXTURES"]

/// The discs under the fixture folder: .iso files, and folders named VIDEO_TS.
private func dvdSources(_ root: URL) -> [URL] {
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    var out: [URL] = []
    while let url = e?.nextObject() as? URL {
        if url.pathExtension.lowercased() == "iso" { out.append(url) }
        if url.lastPathComponent.uppercased() == "VIDEO_TS" { out.append(url.appendingPathComponent("VIDEO_TS.IFO")); e?.skipDescendants() }
    }
    return out.sorted { $0.path < $1.path }
}

private func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// Samples as signed 24-bit little-endian, the byte order FLAC's MD5 signature uses.
private func s24le(_ floats: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int, into bytes: inout [UInt8]) {
    bytes.removeAll(keepingCapacity: true)
    for i in 0..<frames {
        for c in 0..<channels {
            let v = Int32(Double(floats[c][i]) * 2_147_483_648) >> 8
            bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(truncatingIfNeeded: v >> 8)); bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        }
    }
}

struct DVDTrackAudit: Codable {
    var track: Int
    var title: Int
    var chapter: Int
    var vobCells: [String]
    var startFrame: Int64
    var frames: Int64
    var seconds: Double
    var md5: String
    /// Every sample of channel 1 equals channel 2 (a mono master in a stereo stream).
    var identicalChannels: Bool?
    /// Stereo only: the side signal's level against the mid's (dB). Far below 0 (≈ −27 dB or less) is a mono master
    /// carried in two channels that aren't bit-identical.
    var sideToMidDB: Double?
    var seekWindows: [String: String]
    var seekMatches: Bool
    var referenceMD5: String?
    var referenceFrames: Int64?
    var referenceMatch: String?
}

/// Decodes one track through `SourceOpener` exactly as playback does (region over the run), hashing every sample.
private func auditTrack(_ url: URL, _ t: DVDVideoDisc.Track, prefixFrames: Int64?) throws -> (DVDTrackAudit, Insecure.MD5?) {
    let ref = t.ref
    let item = PlayableItem(url: url, regionStartFrame: t.startFrame, regionFrameLength: t.frameCount, dvd: ref)
    let probed = try SourceOpener.probe(url, dvd: ref)
    let rate = Double(t.run.format.sampleRate)
    let plan = OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: 32,
                          channels: t.run.format.channels, dsdConvertedToPCM: false, reason: "")
    let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
    defer { try? decoder.close() }
    #expect(decoder.length == t.frameCount)
    let channels = t.run.format.channels
    let chunk: AVAudioFrameCount = 8192, window = 4096
    let windows: [(String, Int64)] = [("begin", 0), ("middle", t.frameCount / 2), ("end", max(0, t.frameCount - Int64(window)))]
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: chunk))
    var md5 = Insecure.MD5(), prefix: Insecure.MD5? = prefixFrames.map { _ in Insecure.MD5() }, prefixDone: Insecure.MD5?
    var windowHashes: [String: Insecure.MD5] = [:], windowBytes: [String: [UInt8]] = [:]
    var bytes: [UInt8] = []
    var position: Int64 = 0
    var identical = channels == 2
    var midEnergy = 0.0, sideEnergy = 0.0
    while true {
        try decoder.decode(into: pcm, length: chunk)
        let n = Int(pcm.frameLength)
        if n == 0 { break }
        s24le(UnsafePointer(pcm.floatChannelData!), channels: channels, frames: n, into: &bytes)
        md5.update(data: bytes)
        if channels == 2, let f = pcm.floatChannelData {
            for i in 0..<n {
                let l = Double(f[0][i]), r = Double(f[1][i])
                if l != r { identical = false }
                midEnergy += (l + r) * (l + r); sideEnergy += (l - r) * (l - r)
            }
        }
        if let p = prefixFrames, prefix != nil {
            let take = Int(max(0, min(Int64(n), p - position)))
            prefix!.update(data: bytes[0..<take * 3 * channels])
            if position + Int64(n) >= p { prefixDone = prefix; prefix = nil }
        }
        for (name, start) in windows {
            let lo = max(start, position), hi = min(start + Int64(window), position + Int64(n))
            if hi > lo { windowBytes[name, default: []] += bytes[Int(lo - position) * 3 * channels..<Int(hi - position) * 3 * channels] }
        }
        position += Int64(n)
    }
    #expect(position == t.frameCount, "complete tail: decoded \(position) of \(t.frameCount)")
    for (name, data) in windowBytes { var h = Insecure.MD5(); h.update(data: data); windowHashes[name] = h }
    // Seeks: each window decoded again after a seek must be the same samples.
    var seekMatches = true
    let small = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: AVAudioFrameCount(window)))
    for (name, start) in windows.reversed() {
        try decoder.seek(to: start)
        #expect(decoder.position == start)
        var got: [UInt8] = []
        while got.count < Int(min(Int64(window), t.frameCount - start)) * 3 * channels {
            try decoder.decode(into: small, length: AVAudioFrameCount(window) - AVAudioFrameCount(got.count / 3 / channels))
            if small.frameLength == 0 { break }
            s24le(UnsafePointer(small.floatChannelData!), channels: channels, frames: Int(small.frameLength), into: &bytes)
            got += bytes
        }
        var h = Insecure.MD5(); h.update(data: got)
        if hex(h.finalize()) != windowHashes[name].map({ hex($0.finalize()) }) { seekMatches = false }
    }
    #expect(seekMatches)
    let audit = DVDTrackAudit(track: t.number, title: t.title, chapter: t.chapter,
                              vobCells: t.cells.map { "\($0.vobID)/\($0.cellID)" }, startFrame: t.startFrame, frames: t.frameCount,
                              seconds: t.duration, md5: hex(md5.finalize()), identicalChannels: channels == 2 ? identical : nil,
                              sideToMidDB: channels == 2 && midEnergy > 0 ? (10 * log10(max(sideEnergy, 1e-30) / midEnergy) * 10).rounded() / 10 : nil,
                              seekWindows: windowHashes.mapValues { hex($0.finalize()) }, seekMatches: seekMatches)
    return (audit, prefixDone)
}

struct DVDReference: Codable {
    struct Track: Codable { var md5: String; var frames: Int64 }
    struct Disc: Codable {
        var source: String
        var expectedTracks: Int
        var referenceTracks: [Int: Track]
    }
    var discs: [Disc]
}

@Test("Real DVD-Video: tracks, complete PCM against references, seeks", .enabled(if: fixtures != nil))
func realDVDVideoCorpus() throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(fixtures))
    let reference: DVDReference? = try env["VESPERTINE_DVD_REFERENCE"].map {
        try JSONDecoder().decode(DVDReference.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
    }
    var report: [[String: Any]] = []
    let sources = dvdSources(root)
    #expect(!sources.isEmpty)
    for url in sources {
        let disc = try DVDVideoDisc.read(url)
        // References are keyed by the source's name relative to the fixture folder.
        let name = String(url.path.dropFirst(root.path.count + 1))
        let expected = reference?.discs.first { $0.source == name }
        if let expected { #expect(disc.tracks.count == expected.expectedTracks, "\(name)") }
        var concatenated = Insecure.MD5()
        var audits: [DVDTrackAudit] = []
        for (index, t) in disc.tracks.enumerated() {
            let ref = expected?.referenceTracks[index + 1]
            var (audit, prefix) = try auditTrack(url, t, prefixFrames: ref.flatMap { $0.frames < t.frameCount ? $0.frames : nil })
            if let ref {
                audit.referenceMD5 = ref.md5
                audit.referenceFrames = ref.frames
                if ref.frames == t.frameCount {
                    audit.referenceMatch = audit.md5 == ref.md5 ? "identical" : "DIFFERENT"
                    #expect(audit.md5 == ref.md5, "\(name) track \(index + 1)")
                } else if let prefix {
                    let p = hex(prefix.finalize())
                    audit.referenceMatch = p == ref.md5 ? "reference is the first \(ref.frames) of \(t.frameCount) frames" : "DIFFERENT"
                    #expect(p == ref.md5, "\(name) track \(index + 1) prefix")
                } else {
                    audit.referenceMatch = "DIFFERENT (reference longer)"
                    Issue.record("\(name) track \(index + 1): reference has \(ref.frames) frames, decoder \(t.frameCount)")
                }
            }
            audits.append(audit)
            print("[dvd] \(name) #\(audit.track) \(audit.frames) \(audit.md5) \(audit.referenceMatch ?? "-") seek \(audit.seekMatches) identical-channels \(audit.identicalChannels.map(String.init) ?? "-") side/mid \(audit.sideToMidDB.map { String($0) } ?? "-") dB")
        }
        // The tracks of each run, end to end, are its whole audio: hash them in order straight from the run.
        var runs: [DVDStreamRef: (frames: Int64, md5: String)] = [:]
        // Every run with music or an excluded preview, in disc order: together, all the title VOBs' LPCM.
        let stream = disc.tracks.first?.run.stream ?? 0
        let excludedRuns = disc.excluded.map { DVDStreamRef(titleSet: $0.cell.titleSet, stream: stream, firstSector: $0.cell.firstSector, lastSector: $0.cell.lastSector) }
        for ref in Set(disc.tracks.map(\.ref) + excludedRuns).sorted(by: { ($0.titleSet, $0.firstSector) < ($1.titleSet, $1.firstSector) }) {
            let d = try DVDLPCMDecoder(url: url, ref: ref)
            var h = Insecure.MD5(), n: Int64 = 0
            var ints = [Int32](repeating: 0, count: 8192 * d.run.format.channels), bytes: [UInt8] = []
            while true {
                let got = try ints.withUnsafeMutableBufferPointer { try d.readIntegers(into: $0.baseAddress!, frames: 8192) }
                if got == 0 { break }
                bytes.removeAll(keepingCapacity: true)
                for v in ints[0..<got * d.run.format.channels] { let s = v >> 8; bytes += [UInt8(truncatingIfNeeded: s), UInt8(truncatingIfNeeded: s >> 8), UInt8(truncatingIfNeeded: s >> 16)] }
                h.update(data: bytes); concatenated.update(data: bytes)
                n += Int64(got)
            }
            runs[ref] = (n, hex(h.finalize()))
            let inRun = disc.tracks.filter { $0.ref == ref }
            if !inRun.isEmpty { #expect(inRun.first?.startFrame == 0 && inRun.last.map { $0.startFrame + $0.frameCount } == n)
            #expect(zip(inRun, inRun.dropFirst()).allSatisfy { $0.startFrame + $0.frameCount == $1.startFrame }) }
        }
        report.append([
            "source": name,
            "tracks": audits.map { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) ?? [:] },
            "runs": runs.sorted { $0.key.firstSector < $1.key.firstSector }.map { entry in
                ["titleSet": entry.key.titleSet, "firstSector": entry.key.firstSector, "lastSector": entry.key.lastSector,
                 "music": disc.tracks.contains { $0.ref == entry.key }, "frames": entry.value.frames, "md5": entry.value.md5] as [String: Any] },
            "allRunsConcatenatedMD5": hex(concatenated.finalize()),
            "excluded": disc.excluded.map { ["vob": $0.cell.vobID, "cell": $0.cell.cellID, "seconds": $0.seconds, "reason": $0.reason] },
            "navCells": disc.usedNAVCells, "defectiveChapters": disc.defectiveChapters,
        ])
    }
    if let output = env["VESPERTINE_DVD_AUDIT_OUTPUT"] {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
