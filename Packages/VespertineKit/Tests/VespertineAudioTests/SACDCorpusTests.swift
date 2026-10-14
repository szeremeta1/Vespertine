// Vespertine — opt-in real-disc decode audit. No audio or private paths are checked in.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import CryptoKit
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Test("Real SACD: every DSD frame, track seeks, PCM and DoP",
      .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_SACD_AUDIT_IMAGE"] != nil))
func realSACDCorpusImage() throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: try #require(env["VESPERTINE_SACD_AUDIT_IMAGE"]))
    let image = try SACDImage.read(url)
    #expect(SACDImage.isSACD(url))
    #expect(!image.areas.isEmpty)
    var results: [[String: Any]] = []
    for area in image.areas {
        let source = try SACDSource(url: url, area: area, frames: area.frameRange)
        var buffer = [UInt8](repeating: 0, count: area.frameBytes * area.channels)
        var hash = SHA256(), count: Int64 = 0
        while true {
            let n = try buffer.withUnsafeMutableBufferPointer {
                try source.readInterleaved(into: $0.baseAddress!, bytes: area.frameBytes)
            }
            if n == 0 { break }
            hash.update(data: buffer.prefix(n * area.channels))
            count += Int64(n)
        }
        #expect(count == source.dsdLength)
        #expect(source.concealedFrames == 0)
        let probed = try SourceOpener.probe(url, area: area.kind)
        #expect(probed.format.channels == area.channels)
        for track in area.tracks {
            let perFrame = area.samplesPerFrame
            let item = PlayableItem(url: url, regionStartFrame: Int64(track.startFrame) * perFrame,
                                    regionFrameLength: Int64(track.frameCount) * perFrame, sacdArea: area.kind)
            for mode in [OutputPlan.Mode.pcm, .dop] {
                let rate = mode == .dop ? area.sampleRate / 16 : area.sampleRate / 8
                let plan = OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate,
                                      physicalBitDepth: mode == .dop ? 24 : 32, channels: area.channels,
                                      dsdConvertedToPCM: mode == .pcm, reason: "")
                let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
                defer { try? decoder.close() }
                let pcm = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
                for position in [Int64(0), decoder.length / 2, max(0, decoder.length - 4096)] {
                    try decoder.seek(to: position)
                    try decoder.decode(into: pcm, length: 4096)
                    #expect(pcm.frameLength > 0)
                    if let channels = pcm.floatChannelData {
                        for c in 0..<area.channels {
                            let finite = UnsafeBufferPointer(start: channels[c], count: Int(pcm.frameLength)).allSatisfy { $0.isFinite }
                            #expect(finite)
                        }
                    }
                }
                #expect((decoder as? ConcealingDecoder)?.concealedFrames ?? 0 == 0)
            }
        }
        results.append(["area": area.kind.rawValue, "channels": area.channels, "dst": area.isDST,
                        "stride": area.layout.stride, "tracks": area.tracks.count,
                        "bytesPerChannel": count, "concealedFrames": source.concealedFrames,
                        "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()])
    }
    if let output = env["VESPERTINE_SACD_AUDIT_OUTPUT"] {
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}

@Test("Real DSDIFF: PCM and DoP track seeks",
      .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_DSD_AUDIT_IMAGE"] != nil))
func realDSDIFFCorpusFile() throws {
    let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VESPERTINE_DSD_AUDIT_IMAGE"]))
    let probed = try SourceOpener.probe(url)
    #expect(probed.format.encoding == .dsd)
    let info = try #require(try DSTDSDIFFInfo.read(url))
    let source = try DSTDSDIFFSource(url: url, info: info)
    var hash = SHA256(), bytes: Int64 = 0
    var data = [UInt8](repeating: 0, count: 65536 * info.channels)
    while true {
        let n = try data.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: 65536) }
        if n == 0 { break }
        hash.update(data: data.prefix(n * info.channels)); bytes += Int64(n)
    }
    #expect(bytes == source.dsdLength)
    if let output = ProcessInfo.processInfo.environment["VESPERTINE_DSD_AUDIT_OUTPUT"] {
        let result: [String: Any] = ["channels": info.channels, "frameCount": info.frameCount,
            "bytesPerChannel": bytes, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
    for mode in [OutputPlan.Mode.pcm, .dop] {
        let rate = probed.format.sampleRate / (mode == .dop ? 16 : 8)
        let plan = OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate,
                              physicalBitDepth: mode == .dop ? 24 : 32, channels: probed.format.channels,
                              dsdConvertedToPCM: mode == .pcm, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        defer { try? decoder.close() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
        for position in [Int64(0), decoder.length / 2, max(0, decoder.length - 4096)] {
            try decoder.seek(to: position)
            try decoder.decode(into: buffer, length: 4096)
            #expect(buffer.frameLength > 0)
        }
    }
}
