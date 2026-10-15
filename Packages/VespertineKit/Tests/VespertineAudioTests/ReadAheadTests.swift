//
// Vespertine — decoding a track read live from a share on a thread of its own: the engine never waits on a stalled
// read, and what it gets is exactly what the file holds.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

/// A decoder whose reads can be held, like a share that stops answering (and later carries on).
private final class StallingDecoder: NSObject, PCMDecoding, @unchecked Sendable {
    let inner: PCMDecoding
    private let condition = NSCondition()
    private var held: Bool
    private var stuck = 0

    init(_ inner: PCMDecoding, held: Bool) {
        self.inner = inner
        self.held = held
    }

    func release() { condition.withLock { held = false; condition.broadcast() } }
    /// Reads waiting on the "share" right now.
    var waiting: Int { condition.withLock { stuck } }

    var inputSource: InputSource { inner.inputSource }
    var sourceFormat: AVAudioFormat { inner.sourceFormat }
    var processingFormat: AVAudioFormat { inner.processingFormat }
    var decodingIsLossless: Bool { inner.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { inner.properties }
    var isOpen: Bool { inner.isOpen }
    var supportsSeeking: Bool { inner.supportsSeeking }
    var position: AVAudioFramePosition { inner.position }
    var length: AVAudioFramePosition { inner.length }
    func open() throws {}
    func close() throws { try inner.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        condition.withLock {
            stuck += 1
            while held { condition.wait() }
            stuck -= 1
        }
        try inner.decode(into: buffer, length: length)
    }
    func seek(to frame: AVAudioFramePosition) throws { try inner.seek(to: frame) }
}

@Suite("Reading ahead from a network share")
struct ReadAheadTests {
    private func noise(_ c: Int, _ i: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: i &* 2_654_435_761 &+ c &* 40_503)
        x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
        return Float(Int32(bitPattern: x) >> 8) / Float(1 << 23) * 0.5
    }

    private func flac(from wav: URL, bits: Int) throws -> URL {
        let source = try AVAudioFile(forReading: wav)
        let url = wav.deletingPathExtension().appendingPathExtension("flac")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: source.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: bits]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: buffer)
        try out.write(from: buffer)
        return url
    }

    private func plan(for format: SourceFormat, mode: OutputPlan.Mode = .pcm, rate: Double? = nil) -> OutputPlan {
        OutputPlan(mode: mode, deviceSampleRate: rate ?? format.sampleRate, decodedSampleRate: rate ?? format.sampleRate,
                   physicalBitDepth: 32, channels: format.channels, dsdConvertedToPCM: false, reason: "")
    }

    private func open(_ url: URL, plan: ((SourceFormat) -> OutputPlan)? = nil) throws -> (ProbedSource, OutputPlan, PCMDecoding) {
        let probed = try SourceOpener.probe(url)
        let p = plan?(probed.format) ?? self.plan(for: probed.format)
        return (probed, p, try SourceOpener.decoder(for: probed, plan: p, item: PlayableItem(url: url)))
    }

    /// The raw bytes a decoder hands over (per buffer), waiting out `Starved` the way the engine does.
    private func drain(_ decoder: PCMDecoding, chunk: AVAudioFrameCount, into out: inout [[UInt8]], limit: Int = .max) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: chunk)!
        let bytesPerFrame = Int(decoder.processingFormat.streamDescription.pointee.mBytesPerFrame)
        var taken = 0
        let giveUp = Date().addingTimeInterval(30)
        while taken < limit, Date() < giveUp {
            do {
                try decoder.decode(into: buffer, length: AVAudioFrameCount(min(Int(chunk), limit - taken)))
            } catch is ReadAheadDecoder.Starved {
                (decoder as? ReadAheadDecoder)?.waitForAudio(timeout: 0.05)
                continue
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            taken += n
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            if out.count < list.count { out += Array(repeating: [], count: list.count - out.count) }
            for (i, b) in list.enumerated() { out[i] += UnsafeRawBufferPointer(start: b.mData, count: n * bytesPerFrame) }
        }
    }

    private func audioFile(_ name: String, ext: String, rate: Double, bits: Int, seconds: Double = 3) throws -> URL {
        let wav = try writeWAV("readahead-\(name)", rate: rate, bits: bits, seconds: seconds, noise)
        guard ext == "flac" else { return wav }
        defer { try? FileManager.default.removeItem(at: wav) }
        return try flac(from: wav, bits: bits)
    }

    @Test("Reading ahead hands over exactly what the file holds", arguments: [
        ("flac", 96_000.0, 24), ("flac", 44_100.0, 16), ("wav", 48_000.0, 24),
    ])
    func exact(ext: String, rate: Double, bits: Int) throws {
        let url = try audioFile("exact-\(ext)", ext: ext, rate: rate, bits: bits)
        defer { try? FileManager.default.removeItem(at: url) }
        var reference: [[UInt8]] = [], ahead: [[UInt8]] = []
        try drain(try open(url).2, chunk: 4096, into: &reference)
        let decoder = ReadAheadDecoder(try open(url).2, seconds: 0.5)
        try drain(decoder, chunk: 3001, into: &ahead)
        #expect(ahead.map(\.count) == reference.map(\.count))
        #expect(ahead == reference)
        #expect(decoder.position == decoder.length)
    }

    @Test("A read stuck on the share never holds up the engine; playback carries on once it returns")
    func stalledRead() throws {
        let url = try audioFile("stall", ext: "flac", rate: 44_100, bits: 16, seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        var reference: [[UInt8]] = []
        try drain(try open(url).2, chunk: 4096, into: &reference)

        let share = StallingDecoder(try open(url).2, held: true)
        let decoder = ReadAheadDecoder(share, seconds: 0.25)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        let started = Date()
        while share.waiting == 0, Date().timeIntervalSince(started) < 5 { usleep(1000) }
        #expect(share.waiting == 1)   // the read-ahead thread is the one waiting on the share
        let asked = Date()
        #expect(throws: ReadAheadDecoder.Starved.self) { try decoder.decode(into: buffer, length: 4096) }
        #expect(Date().timeIntervalSince(asked) < 0.25)
        #expect(!decoder.waitForAudio(timeout: 0.05))
        #expect(decoder.position == 0)

        share.release()
        var ahead: [[UInt8]] = []
        try drain(decoder, chunk: 4096, into: &ahead)
        #expect(ahead == reference)
    }

    @Test("A seek drops what was read ahead and continues from the frame asked for")
    func seek() throws {
        let url = try audioFile("seek", ext: "flac", rate: 48_000, bits: 24, seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, _, plain) = try open(url)
        try plain.seek(to: 61_234)
        var reference: [[UInt8]] = []
        try drain(plain, chunk: 4096, into: &reference)

        let decoder = ReadAheadDecoder(try open(url).2, seconds: 0.5)
        var discarded: [[UInt8]] = []
        try drain(decoder, chunk: 4096, into: &discarded, limit: 10_000)
        decoder.waitForAudio(timeout: 1)   // and more read ahead past it
        try decoder.seek(to: 61_234)
        #expect(decoder.position == 61_234)
        var ahead: [[UInt8]] = []
        try drain(decoder, chunk: 2048, into: &ahead)
        #expect(ahead == reference)
    }

    @Test("A track read ahead moves to its local copy at the frame the engine reached, not the one read up to")
    func moveToLocalCopy() throws {
        let url = try audioFile("move", ext: "flac", rate: 96_000, bits: 24)
        defer { try? FileManager.default.removeItem(at: url) }
        let copy = url.deletingLastPathComponent().appendingPathComponent("copy-\(UUID()).flac")
        try FileManager.default.copyItem(at: url, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        var reference: [[UInt8]] = []
        try drain(try open(url).2, chunk: 4096, into: &reference)

        let (probed, plan, inner) = try open(url)
        let streaming = ReadAheadDecoder(inner, seconds: 1)
        var joined: [[UInt8]] = []
        try drain(streaming, chunk: 3001, into: &joined, limit: 131_507)
        streaming.waitForAudio(timeout: 1)
        let (_, local) = try #require(try PlaybackEngine.reopen(probed, decoder: streaming, at: copy, plan: plan, item: PlayableItem(url: url)))
        #expect(local.position == 131_507)
        try drain(local, chunk: 3001, into: &joined)
        #expect(joined == reference)
    }

    @Test("DoP read ahead keeps the marker sequence, across a join and a move to the local copy")
    func dopMarkers() throws {
        let planes = DSDFiles.modulate(rate: 2_822_400, seconds: 0.5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("readahead-\(UUID()).dsf")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("readahead-copy-\(UUID()).dsf")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: copy) }
        try DSDFiles.writeDSF(planes, rate: 2_822_400, to: url)
        try FileManager.default.copyItem(at: url, to: copy)

        let (probed, plan, inner) = try open(url) { self.plan(for: $0, mode: .dop, rate: 176_400) }
        #expect(inner is RawDoPDecoder)
        let decoder = ReadAheadDecoder(inner, seconds: 0.25)
        decoder.waitForAudio(timeout: 1)       // decoded ahead with the sequence starting on 0x05
        decoder.nextDoPMarker = 1              // the track before ended on 0x05
        var bytes: [[UInt8]] = []
        try drain(decoder, chunk: 1001, into: &bytes, limit: 1001)
        let first = bytes[0].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in 0..<4 {
            let word = UInt32(bitPattern: Int32(first[i] * 2_147_483_648)) >> 8
            #expect(word >> 16 == (i % 2 == 0 ? 0xFA : 0x05))
            #expect(UInt8(word >> 8 & 0xFF) == planes[0][2 * i] && UInt8(word & 0xFF) == planes[0][2 * i + 1])
        }
        #expect(decoder.nextDoPMarker == 0)    // 1001 frames on from 0xFA
        decoder.waitForAudio(timeout: 1)
        let (_, local) = try #require(try PlaybackEngine.reopen(probed, decoder: decoder, at: copy, plan: plan, item: PlayableItem(url: url)))
        #expect(local.position == 1001)
        #expect((local as? RawDoPDecoder)?.nextMarker == 0)
    }

    @Test("A share that keeps stalling buffers longer before playing on: 5, 10, then 20 s; a lone stall doesn't")
    func rebufferGrows() {
        var seconds = PlaybackEngine.rebufferRange.lowerBound
        seconds = PlaybackEngine.nextRebufferSeconds(seconds, sinceLastStall: .infinity)
        #expect(seconds == 5)
        seconds = PlaybackEngine.nextRebufferSeconds(seconds, sinceLastStall: 30)
        #expect(seconds == 10)
        seconds = PlaybackEngine.nextRebufferSeconds(seconds, sinceLastStall: 45)
        #expect(seconds == 20)
        seconds = PlaybackEngine.nextRebufferSeconds(seconds, sinceLastStall: 10)
        #expect(seconds == 20)
        #expect(PlaybackEngine.nextRebufferSeconds(10, sinceLastStall: 90) == 10)
    }
}
