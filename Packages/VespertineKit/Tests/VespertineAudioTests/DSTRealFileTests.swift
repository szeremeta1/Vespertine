//
// Vespertine — DST in DSDIFF, from a real encoder's file: native decoding agrees with FFmpeg's own DST decoder, and the
// DSD it yields goes out as DoP bit for bit.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import VespertineAudio

@Suite("DST DSDIFF from a real encoder")
struct DSTRealFileTests {
    /// FFmpeg's FATE sample `dst/dst-64fs44-2ch.dff`: 10 frames (0.133 s) of stereo DSD64 compressed with DST.
    let url = ContainerFormatTests.fixture("dst-fate-stereo.dff")

    private func decode(_ mode: OutputPlan.Mode) throws -> [[Float]] {
        try WavPackDSDTests.decode(url, mode: mode).audio
    }

    @Test("Opened natively as DST, not through FFmpeg's DSDIFF reader")
    func probes() throws {
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.encoding == .dsd && probed.format.codec == "DSDIFF" && probed.format.sampleRate == 2_822_400 && probed.format.channels == 2)
        #expect(probed.decoderName.contains("DST"))
        #expect(abs(try SourceInspector.inspectWithDuration(url).duration - 10.0 / 75) < 1e-9)
    }

    @Test("The PCM equals what FFmpeg's DST decoder makes of the same file, bit for bit")
    func pcmMatchesFFmpeg() throws {
        let audio = try decode(.pcm)
        #expect(audio.count == 2 && audio[0].count == 47_040)
        var bytes = Data(capacity: audio[0].count * 8)
        for i in 0..<audio[0].count { for c in 0..<2 { withUnsafeBytes(of: audio[c][i].bitPattern.littleEndian) { bytes.append(contentsOf: $0) } } }
        // `ffmpeg -i dst-64fs44-2ch.dff -f f32le -c:a pcm_f32le -`, FFmpeg 9.0.2's dst decoder.
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "293a54dd0ec92cbb773703ebbaaffb4c8c4888d6c27cda7903bc7bf4aa4fd787")
    }

    @Test("DoP carries the decoded DSD untouched: its words unpack to exactly the DSD the converter was given")
    func dopIsTheDSD() throws {
        let probed = try SourceOpener.probe(url)
        let info = try #require(probed.dstDSDIFF)
        let source = try DSTDSDIFFSource(url: url, info: info)
        let bytesPerChannel = Int(source.dsdLength)
        var inter = [UInt8](repeating: 0, count: bytesPerChannel * 2)
        #expect(try inter.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: bytesPerChannel) } == bytesPerChannel)
        let planes = (0..<2).map { c in (0..<bytesPerChannel).map { inter[$0 * 2 + c] } }
        let expected = try DoP.pack(planes)
        let played = try decode(.dop)
        #expect(played[0].count == expected.count)
        for c in 0..<2 {
            let words = played[c].map { UInt32(bitPattern: Int32($0 * 8_388_608)) & 0xFFFFFF }
            #expect(words == expected.map { $0[c] }, "channel \(c)")
        }
        // Not silence, and not the stored frames' header: real music.
        #expect(Set(planes[0]).count > 16)
    }
}
