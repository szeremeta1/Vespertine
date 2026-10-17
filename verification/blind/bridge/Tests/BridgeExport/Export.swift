//
// Vespertine verification, blind-agent round: runs Vespertine's own code on every input in inputs.json and writes
// what it produced to vespertine.json. No checks here: the comparison is ../../tools/compare.py.
//
// Code paths exercised (VespertineKit, read-only):
//   DoP          RawDoPDecoder (FFmpegDecoder.swift), the decoder used for playback, fed from memory (export), and
//                DoP.pack, the packer it shares its sample word with, which refuses half frames (serve)
//   AC-3         IEC61937.ac3Burst, and BitstreamDecoder over an .ac3 file (the playback path)
//   E-AC-3       IEC61937.eac3Burst, BitstreamPacker.eac3Groups (EAC3Grouper), BitstreamDecoder over an .ec3 file
//   DTS          IEC61937.dtsBurst (everything taken from the frame header)
// A framer's refusal is written as {"refused": "<why>"} in place of the output.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

/// Raw DSD from memory, one plane per channel, MSB the oldest bit (the form RawDoPDecoder reads).
final class MemoryDSD: RawDSDSource {
    let planes: [[UInt8]]
    var position = 0
    init(planes: [[UInt8]]) { self.planes = planes }
    var channelCount: Int { planes.count }
    var dsdRate: Double { 2_822_400 }
    var dsdLength: Int64 { Int64(planes.first?.count ?? 0) }
    var isOpen: Bool { true }
    var inputSource: InputSource { InputSource(data: Data()) }
    var concealedFrames: Int { 0 }
    func readDSD(into out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
        let n = max(0, min(bytes, Int(dsdLength) - position))
        guard n > 0 else { return 0 }
        for (c, plane) in planes.enumerated() {
            plane.withUnsafeBufferPointer { out[c].update(from: $0.baseAddress! + position, count: n) }
        }
        position += n
        return n
    }
    func seekDSD(to position: Int64) throws { self.position = Int(position) }
    func close() throws {}
}

func bytes(_ hex: String) -> [UInt8] {
    var out = [UInt8](), it = hex.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

func hex16(_ words: [Int16]) -> String { words.map { String(format: "%04x", UInt16(bitPattern: $0)) }.joined() }

/// A burst's words, or the framer's refusal.
func burstEntry(_ make: () throws(BurstError) -> [Int16]) -> [String: Any] {
    do throws(BurstError) { return ["words": hex16(try make())] } catch { return ["refused": "\(error)"] }
}

/// DoP frames as frames[n][c] 24-bit words: RawDoPDecoder's Float32 output is the 24-bit word over 2^23.
func dopFrames(planes: [[UInt8]], firstMarker: Int) throws -> [[UInt32]] {
    let decoder = try RawDoPDecoder(source: MemoryDSD(planes: planes))
    decoder.nextMarker = firstMarker == 0x05 ? 0 : 1
    let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 1000)!   // not a power of two: crosses calls
    var frames: [[UInt32]] = []
    while true {
        try decoder.decode(into: buffer, length: 1000)
        let n = Int(buffer.frameLength)
        guard n > 0, let data = buffer.floatChannelData else { break }
        for i in 0..<n {
            frames.append((0..<planes.count).map { c in
                UInt32(bitPattern: Int32(clamping: Int64((Double(data[c][i]) * 2_147_483_648).rounded()))) >> 8
            })
        }
    }
    return frames
}

/// The whole carrier BitstreamDecoder produces for an elementary-stream file holding `frames`.
func carrier(frames: [[UInt8]], ext: String) throws -> (words: [Int16], rate: Double) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blind-\(UUID().uuidString).\(ext)")
    try Data(frames.flatMap { $0 }).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let d = try BitstreamDecoder.open(url: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: d.processingFormat, frameCapacity: 1000)!
    var out: [Int16] = []
    while true {
        try d.decode(into: buffer, length: 1000)
        let n = Int(buffer.frameLength)
        guard n > 0, let p = buffer.int16ChannelData?[0] else { break }
        out += UnsafeBufferPointer(start: p, count: n * 2)
    }
    return (out, d.processingFormat.sampleRate)
}

/// Request/response mode for ../tools/vespertine_adapter.py, which puts these same calls behind the blind
/// interface so the tester's suite can run against Vespertine. One JSON object per line through two FIFOs in
/// $BLIND_SERVE (req, resp); only runs when that variable is set.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BLIND_SERVE"] != nil)) func serve() throws {
    let dir = ProcessInfo.processInfo.environment["BLIND_SERVE"]!
    guard let req = FileHandle(forReadingAtPath: dir + "/req"), let resp = FileHandle(forWritingAtPath: dir + "/resp") else { return }
    var pending = Data()
    func reply(_ obj: [String: Any]) {
        resp.write(try! JSONSerialization.data(withJSONObject: obj) + Data("\n".utf8))
    }
    while true {
        let chunk = req.availableData
        if chunk.isEmpty { return }
        pending += chunk
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending = Data(pending[(nl + 1)...])
            guard let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = r["op"] as? String else {
                reply(["error": "bad request"]); continue
            }
            do {
                switch op {
                case "dop_pack":
                    do throws(DoPError) {
                        let frames = try DoP.pack((r["planes"] as! [String]).map(bytes), firstMarker: UInt8(r["first_marker"] as! Int))
                        reply(["frames": frames.map { $0.map(Int.init) }])
                    } catch { reply(["refused": "\(error)"]) }
                case "ac3_burst": reply(burstEntry { () throws(BurstError) in try IEC61937.ac3Burst(bytes(r["frame"] as! String)) })
                case "eac3_burst": reply(burstEntry { () throws(BurstError) in try IEC61937.eac3Burst((r["frames"] as! [String]).map(bytes)) })
                case "dts_burst": reply(burstEntry { () throws(BurstError) in try IEC61937.dtsBurst(bytes(r["frame"] as! String)) })
                case "eac3_group":
                    let raw = (r["frames"] as! [String]).map(bytes)
                    // Vespertine's grouper takes parsed frames; a frame its parser rejects can't be grouped.
                    let parsed = raw.map { DolbyFrames.frame(in: $0, at: 0) }
                    if parsed.contains(where: { $0 == nil }) { reply(["unparsed": true]); break }
                    var next = 0
                    reply(["groups": BitstreamPacker.eac3Groups(parsed.map { $0! }).map { g in g.map { _ in defer { next += 1 }; return next } }])
                default: reply(["error": "unknown op \(op)"])
                }
            } catch {
                reply(["error": "\(error)"])
            }
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BLIND_SERVE"] == nil)) func export() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLIND_VECTORS"] ?? "../vectors")
    let input = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("inputs.json"))) as! [String: [[String: Any]]]
    var out: [String: [[String: Any]]] = [:]

    out["dop"] = try input["dop"]!.map { c in
        let planes = (c["planes"] as! [String]).map(bytes)
        let frames = try dopFrames(planes: planes, firstMarker: c["first_marker"] as! Int)
        return ["name": c["name"]!, "frames": frames.map { $0.map(Int.init) }]
    }
    out["ac3"] = input["ac3"]!.map { c in
        burstEntry { () throws(BurstError) in try IEC61937.ac3Burst(bytes(c["frame"] as! String)) }.merging(["name": c["name"]!]) { a, _ in a }
    }
    out["eac3"] = input["eac3"]!.map { c in
        burstEntry { () throws(BurstError) in try IEC61937.eac3Burst((c["frames"] as! [String]).map(bytes)) }.merging(["name": c["name"]!]) { a, _ in a }
    }
    out["eac3_group"] = input["eac3_group"]!.map { c in
        let frames = (c["frames"] as! [String]).map { DolbyFrames.frame(in: bytes($0), at: 0)! }
        var next = 0
        let groups = BitstreamPacker.eac3Groups(frames).map { g in g.map { _ in defer { next += 1 }; return next } }
        return ["name": c["name"]!, "groups": groups]
    }
    out["dts"] = input["dts"]!.map { c in
        burstEntry { () throws(BurstError) in try IEC61937.dtsBurst(bytes(c["frame"] as! String)) }.merging(["name": c["name"]!]) { a, _ in a }
    }
    for key in ["ac3_stream", "eac3_stream"] {
        out[key] = try input[key]!.map { c in
            let r = try carrier(frames: (c["frames"] as! [String]).map(bytes), ext: c["ext"] as! String)
            return ["name": c["name"]!, "words": hex16(r.words), "carrier_rate": r.rate]
        }
    }
    let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("vespertine.json"))
}
