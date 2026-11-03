//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AudioToolbox
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Testing
@testable import VespertineAudio

/// Interleaved multichannel frames: every channel holds a constant `level(channel)`, from frame `first` on.
private final class FakeBedChannels: BedReading, @unchecked Sendable {
    let channelLabels: [AudioChannelLabel]
    private let frames: Int, buffers: Int, firstFrame: Int64, level: (Int) -> Float
    private var handedOut = 0

    init(labels: [AudioChannelLabel], frames: Int = 8192, buffers: Int, firstFrame: Int64 = 0, level: @escaping (Int) -> Float) {
        channelLabels = labels; self.frames = frames; self.buffers = buffers; self.firstFrame = firstFrame; self.level = level
    }

    func start() throws {}
    func cancel() {}
    func next() throws -> BedBuffer? {
        guard handedOut < buffers else { return nil }
        handedOut += 1
        let n = channelLabels.count, frames = frames, level = level
        return BedBuffer(frames: frames, copy: { _, count, destination in destination.update(repeating: 0, count: 2 * count); return true },
                         copyChannels: { _, count, destination in
            for i in 0..<count { for c in 0..<n { destination[i * n + c] = level(c) } }
            return true
        }, channels: n)
    }
}

/// Hands over buffers `width` channels wide while naming `channelLabels.count` of them: what a wrapper that forgot to pass
/// the labels on did. Notes whether the decoder asked for the channels, and writes only where a buffer of the named width has room.
private final class FakeMismatchedBed: BedReading, @unchecked Sendable {
    let channelLabels: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
    let width: Int
    let asked = Box(0)
    private var handedOut = 0
    init(width: Int) { self.width = width }
    func start() throws {}
    func cancel() {}
    func next() throws -> BedBuffer? {
        guard handedOut < 4 else { return nil }
        handedOut += 1
        let width = width, asked = asked
        return BedBuffer(frames: 8192, copy: { _, count, destination in destination.update(repeating: 0.25, count: 2 * count); return true },
                         copyChannels: { _, count, destination in
            asked.value += 1
            destination.update(repeating: 0.5, count: width * count)   // an overflow of the decoder's buffer, if it let this run
            return true
        }, channels: width)
    }
}

/// A value shared between the test and the decoder's thread.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&stored) }
}

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

/// Energy of `signal` at `hz` (Goertzel).
private func energy(_ signal: [Float], at hz: Double, rate: Double) -> Double {
    let w = 2 * Double.pi * hz / rate, c = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for x in signal { let s0 = Double(x) + c * s1 - s2; s2 = s1; s1 = s0 }
    return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(signal.count * signal.count)
}

@Suite("Channel meters for Atmos, DTS and other formats macOS or a receiver decodes")
struct BedMeterTests {
    // MARK: Channel layouts

    @Test("A bed's channels are named, in the file's order, like any other surround track", arguments: [
        (kAudioChannelLayoutTag_MPEG_5_1_A, "5.1", ["L", "R", "C", "LFE", "Ls", "Rs"]),
        (kAudioChannelLayoutTag_MPEG_7_1_C, "7.1", ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]),
        (kAudioChannelLayoutTag_Atmos_5_1_2, "5.1.2", ["L", "R", "C", "LFE", "Ls", "Rs", "Lts", "Rts"]),
        (kAudioChannelLayoutTag_Atmos_7_1_4, "7.1.4", ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs", "Ltf", "Rtf", "Ltr", "Rtr"]),
        (kAudioChannelLayoutTag_Stereo, "Stereo", ["L", "R"]),
    ] as [(AudioChannelLayoutTag, String, [String])])
    func layoutNames(tag: AudioChannelLayoutTag, name: String, speakers: [String]) throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        let bed = BedMeterLayout(labels: layout.channelLabels)
        #expect(bed.layout == name)
        #expect(bed.names == speakers)
        #expect(bed.labels.count == bed.names.count)
    }

    @Test("A bed whose channels are unnamed is taken in the standard order for its count")
    func unlabeledBed() {
        #expect(ChannelLayouts.standardLabels(channels: 6).map { BedMeterLayout(labels: $0).names } == ["L", "R", "C", "LFE", "Ls", "Rs"])
        #expect(ChannelLayouts.standardLabels(channels: 8).map { BedMeterLayout(labels: $0).layout } == "7.1")
        // Discrete channels are numbered.
        #expect(BedMeterLayout(labels: (0..<3).map { kAudioChannelLabel_Discrete_0 + AudioChannelLabel($0) }).names == ["1", "2", "3"])
    }

    @Test("The meters show a bed's channels in the usual order, whatever order the decoder gave them in")
    func meterOrder() {
        // Core Audio's Dolby order: L C R Ls Rs LFE.
        let decoded = [kAudioChannelLabel_Left, kAudioChannelLabel_Center, kAudioChannelLabel_Right,
                       kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen]
        #expect(ChannelLayouts.meterOrder(decoded) == [0, 2, 1, 5, 3, 4])
        // Already in order, and heights after the bed.
        let atmos = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)!.channelLabels
        #expect(ChannelLayouts.meterOrder(atmos) == Array(0..<12))
        // A scrambled 7.1.4 comes out in the usual order.
        let scrambled = [atmos[8], atmos[3], atmos[0], atmos[11], atmos[6], atmos[1], atmos[9], atmos[2], atmos[7], atmos[4], atmos[10], atmos[5]]
        let shown = ChannelLayouts.meterOrder(scrambled).map { scrambled[$0] }
        #expect(shown == atmos)
        // Unplaced channels keep their order, last.
        let odd = [kAudioChannelLabel_Discrete_0 + 1, kAudioChannelLabel_Right, kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Left]
        #expect(ChannelLayouts.meterOrder(odd) == [3, 1, 0, 2])
    }

    @Test("The tap reports a bed's peaks in the meters' order")
    func tapPeaksInMeterOrder() {
        let tap = SystemBedTap(sampleRate: 48_000, capacity: 1 << 14)
        // Decoder order L C R Ls Rs LFE with levels 1…6 tenths.
        tap.setLayout([kAudioChannelLabel_Left, kAudioChannelLabel_Center, kAudioChannelLabel_Right,
                       kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen])
        #expect(tap.channelLabels?.map(ChannelLayouts.shortName) == ["L", "R", "C", "LFE", "Ls", "Rs"])
        tap.reset(at: 0)
        let stereo = [Float](repeating: 0, count: 2 * 4800)
        var bed = [Float](repeating: 0, count: 6 * 4800)
        for i in 0..<4800 { for c in 0..<6 { bed[i * 6 + c] = Float(c + 1) / 10 } }
        stereo.withUnsafeBufferPointer { s in bed.withUnsafeBufferPointer { tap.append(interleaved: s.baseAddress!, frames: 4800, at: 0, bed: $0.baseAddress!) } }
        let peaks = tap.takePeaks(playhead: 4800)!
        for (shown, expected) in [1, 3, 2, 6, 4, 5].enumerated() { #expect(abs(peaks[shown] - Float(expected) / 10) < 1e-6, "slot \(shown)") }
    }

    // MARK: The tap's peaks

    private static let bed51: [AudioChannelLabel] = [
        kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
        kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    ]

    @Test("The tap keeps each channel's peak per block, and a read covers what played since the last one")
    func peaksFollowThePlayhead() {
        let tap = SystemBedTap(sampleRate: 48_000, capacity: 1 << 14)
        #expect(tap.takePeaks(playhead: 1000) == nil)   // nothing decoded, no layout
        tap.setLayout(Self.bed51)
        tap.reset(at: 0)
        let stereo = [Float](repeating: 0, count: 2 * 9600)
        // 0.2 s: channel c is c * 0.1 (the LFE, channel 3, 0.3) except one loud frame on channel 4 at frame 4800.
        var bed = [Float](repeating: 0, count: 6 * 9600)
        for i in 0..<9600 { for c in 0..<6 { bed[i * 6 + c] = Float(c) * 0.1 } }
        bed[4800 * 6 + 4] = 0.9
        stereo.withUnsafeBufferPointer { s in bed.withUnsafeBufferPointer { tap.append(interleaved: s.baseAddress!, frames: 9600, at: 0, bed: $0.baseAddress!) } }

        let early = tap.takePeaks(playhead: 4000)!            // frames 0…3999 (the first read looks back 50 ms)
        #expect(early.count == 6)
        for c in 0..<6 { #expect(abs(early[c] - Float(c) * 0.1) < 1e-6, "channel \(c)") }
        let next = tap.takePeaks(playhead: 6000)!             // 4000…5999: holds the loud frame
        #expect(abs(next[4] - 0.9) < 1e-6)
        #expect(abs(next[5] - 0.5) < 1e-6)
        let after = tap.takePeaks(playhead: 8000)!            // 6000…7999: past it
        #expect(abs(after[4] - 0.4) < 1e-6)
        // Playing on past what was decoded: silence, not stale levels.
        let beyond = tap.takePeaks(playhead: 9600 + 4800)!
        #expect(beyond.allSatisfy { $0 == 0 } || beyond[0] == 0)
        #expect(tap.channelLabels == Self.bed51)
    }

    @Test("A seek forgets the peaks, and a read after it covers only the last 50 ms")
    func seekResetsPeaks() {
        let tap = SystemBedTap(sampleRate: 48_000, capacity: 1 << 14)
        tap.setLayout([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center])
        tap.reset(at: 0)
        let stereo = [Float](repeating: 0, count: 2 * 4800)
        let loud = [Float](repeating: 0.8, count: 3 * 4800)
        stereo.withUnsafeBufferPointer { s in loud.withUnsafeBufferPointer { tap.append(interleaved: s.baseAddress!, frames: 4800, at: 0, bed: $0.baseAddress!) } }
        #expect(tap.takePeaks(playhead: 4800)?.max() ?? 0 > 0.79)
        tap.reset(at: 48_000)
        #expect(tap.takePeaks(playhead: 48_000) == nil)
        let quiet = [Float](repeating: 0.1, count: 3 * 4800)
        stereo.withUnsafeBufferPointer { s in quiet.withUnsafeBufferPointer { tap.append(interleaved: s.baseAddress!, frames: 4800, at: 48_000, bed: $0.baseAddress!) } }
        let read = tap.takePeaks(playhead: 52_800)!
        #expect(read.allSatisfy { abs($0 - 0.1) < 1e-6 })
    }

    @Test("A decoder running a fake multichannel bed fills the peaks the meters take, in step with the playhead")
    func decoderFeedsMeters() throws {
        let labels = Self.bed51
        let reader = FakeBedChannels(labels: labels, buffers: 12) { Float($0 + 1) / 10 }
        let decoder = SystemBedDecoder(makeReader: { _ in reader })
        let playhead = Box(0.0)
        let source = BedMeterSource(decoder: decoder, metering: true, position: { playhead.value })
        source.start(at: 0)
        defer { source.stop() }
        let deadline = Date().addingTimeInterval(30)
        while decoder.tap.endFrame < 48_000, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(source.channelLabels == labels)
        playhead.value = 0.5
        let peaks = try #require(source.takeChannelPeaks())
        #expect(peaks.count == 6)
        for c in 0..<6 { #expect(abs(peaks[c] - Float(c + 1) / 10) < 1e-6) }
    }

    @Test("A reader whose buffers are wider than the channels it names is stored as stereo, and its channels are never copied")
    func wideBufferNamedNarrow() throws {
        let reader = FakeMismatchedBed(width: 6)
        let decoder = SystemBedDecoder(makeReader: { _ in reader })
        decoder.start(at: 0, playhead: { 0 })
        defer { decoder.stop() }
        let deadline = Date().addingTimeInterval(30)
        while decoder.tap.endFrame < 4 * 8192, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(decoder.tap.endFrame == 4 * 8192)
        #expect(reader.asked.value == 0)
        #expect(decoder.tap.takePeaks(playhead: 8192)?.allSatisfy { $0 == 0 } ?? true)
        #expect(decoder.error == nil)
    }

    @Test("Nobody asking for the bed: nothing is decoded")
    func idleWhenNobodyWants() {
        final class Counting: BedReading, @unchecked Sendable {
            let made = Box(0)
            func start() throws { made.value += 1 }
            func next() throws -> BedBuffer? { nil }
            func cancel() {}
        }
        let reader = Counting()
        let decoder = SystemBedDecoder(makeReader: { _ in reader })
        let source = BedMeterSource(decoder: decoder, position: { 0 })
        source.start(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(reader.made.value == 0)
        source.setMetering(true)
        let deadline = Date().addingTimeInterval(10)
        while reader.made.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(reader.made.value == 1)
        source.setMetering(false)
        source.stop()
    }

    // MARK: Real files

    /// The first `frames` frames of the bed's own channels from `reader`, one array per channel.
    private static func channels(of reader: BedReading, frames: Int) throws -> [[Float]] {
        try reader.start()
        let n = reader.channelLabels.count
        var out = [[Float]](repeating: [], count: n)
        while out[0].count < frames, let buffer = try reader.next() {
            var scratch = [Float](repeating: 0, count: buffer.frames * n)
            #expect(buffer.copyChannels?(0, buffer.frames, &scratch) == true)
            for i in 0..<buffer.frames { for c in 0..<n { out[c].append(scratch[i * n + c]) } }
        }
        return out
    }

    /// The fixtures' tones: L 440, R 550, C 660, LFE 60, Ls 770, Rs 880 Hz.
    private static let tones: [String: Double] = ["L": 440, "R": 550, "C": 660, "LFE": 60, "Ls": 770, "Rs": 880]

    /// Each channel of `channels` carries the tone of the speaker `labels` names for it, and no other.
    private static func expectTones(_ channels: [[Float]], labels: [AudioChannelLabel], rate: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(channels.count == 6 && labels.count == 6, sourceLocation: sourceLocation)
        let names = labels.map(ChannelLayouts.shortName)
        for (c, signal) in channels.enumerated() {
            let window = Array(signal[8192..<(8192 + 4096)])
            let own = energy(window, at: tones[names[c]] ?? 0, rate: rate)
            for other in tones.keys where other != names[c] {
                #expect(own > 100 * energy(window, at: tones[other]!, rate: rate), "channel \(c) (\(names[c])) carries \(other)'s tone", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("Dolby Digital Plus: the bed decodes with the speakers named and each tone on its own channel")
    func dolbyDigitalPlusBed() throws {
        let reader = try AudioFileBedReader(url: fixture("dolby-digital-plus-tones.m4a"), seconds: 0)
        // Core Audio hands a Dolby bed over as L C R Ls Rs LFE: the labels follow the channels, not the other way round.
        #expect(reader.channelLabels.map(ChannelLayouts.shortName) == ["L", "C", "R", "Ls", "Rs", "LFE"])
        #expect(BedMeterLayout(labels: reader.channelLabels).layout == "5.1")
        Self.expectTones(try Self.channels(of: reader, frames: 16_384), labels: reader.channelLabels, rate: 48_000)
    }

    @Test("A DTS CD (a bitstream a receiver decodes): the same decode the engine uses gives the 5.1 bed")
    func dtsBed() throws {
        let reader = try PCMBedReader(decoder: try SourceOpener.pcmDecoder(for: fixture("dts-cd-tones.wav")), seconds: 0)
        #expect(BedMeterLayout(labels: reader.channelLabels).layout == "5.1")
        Self.expectTones(try Self.channels(of: reader, frames: 16_384), labels: reader.channelLabels, rate: 48_000)   // converted to 48 kHz
    }

    @Test("DTS and TrueHD in Matroska, and raw Dolby Digital, give a 5.1 bed too", arguments: [
        "dts-tones.mka", "truehd-tones.mka", "dolby-digital-tones.ac3", "dts-tones.dts", "truehd-tones.thd",
    ])
    func otherFormats(name: String) throws {
        let reader = try PCMBedReader(decoder: try SourceOpener.pcmDecoder(for: fixture(name)), seconds: 0)
        #expect(BedMeterLayout(labels: reader.channelLabels).layout == "5.1", "\(name)")
        Self.expectTones(try Self.channels(of: reader, frames: 16_384), labels: reader.channelLabels, rate: 48_000)
    }

    @Test("The whole chain on a real file: decoder, tap and peaks give six live channels")
    func realFileChain() throws {
        let url = fixture("dolby-digital-plus-tones.m4a")
        let decoder = SystemBedDecoder(url: url)
        let playhead = Box(0.1)
        let source = BedMeterSource(decoder: decoder, metering: true, position: { playhead.value })
        source.start(at: 0)
        defer { source.stop() }
        let deadline = Date().addingTimeInterval(120)
        while decoder.tap.endFrame < 36_000, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        playhead.value = 0.7
        let peaks = try #require(source.takeChannelPeaks())
        #expect(peaks.count == 6)
        #expect(peaks.allSatisfy { $0 > 0.01 }, "\(peaks)")
        #expect(source.channelLabels.map(BedMeterLayout.init(labels:))?.layout == "5.1")
    }

    // MARK: The output isn't touched

    /// What macOS's renderer was handed for the fixture: a digest of every compressed buffer, and whether it took them all.
    private struct Rendered {
        var digest = "", exhausted = false, buffers = 0, bytes = 0
    }

    /// Renders the fixture through macOS's renderer with the meters `on` or off.
    private static func renderedDigest(metering on: Bool, visualizer: Bool) throws -> Rendered {
        let session = try SystemRendererSession(item: PlayableItem(url: fixture("dolby-digital-plus-tones.m4a")), url: fixture("dolby-digital-plus-tones.m4a"),
                                                deviceUID: DeviceQuery.outputUIDs().sorted().first, spatial: false, volume: 0)
        let hasher = Box(SHA256())
        let count = Box(0), total = Box(0)
        session.enqueueObserver = { buffer in
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            hasher.withLock {
                total.value += bytes.count
                $0.update(data: bytes)
                $0.update(data: withUnsafeBytes(of: pts.value) { Data($0) })
            }
            count.value += 1
        }
        session.setMetering(on)
        session.setTapping(visualizer)
        try session.prepare(at: 0)
        defer { session.stop() }
        // At volume 0 the renderer plays the 1.5 s fixture through (silently), taking every frame.
        session.play()
        // Generous: the suite's hardware tests share the output device, and under a sanitizer a session takes minutes.
        let deadline = Date().addingTimeInterval(180)
        while !session.inputExhausted, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let digest = hasher.withLock { $0 }.finalize().map { String(format: "%02x", $0) }.joined()
        return Rendered(digest: digest, exhausted: session.inputExhausted, buffers: count.value, bytes: total.value)
    }

    /// `renderedDigest` on a thread of its own, given up on after `patience` seconds. The session's lock is held by the
    /// decoder while it reads, so a read that never returns (on a CI runner it didn't, for 8 minutes) also stalls
    /// `inputExhausted`, and with it the 180 s deadline above; a test thread blocked there would take a thread of the
    /// cooperative pool with it, and starve the tests that need one. Here the test fails after `patience` instead, and
    /// the stuck thread (and its session, which `stop()` would wait on) is left behind.
    private static func boundedDigest(metering on: Bool, visualizer: Bool, patience: TimeInterval = 300) -> Rendered? {
        let done = DispatchSemaphore(value: 0)
        let result = Box<Result<Rendered, Error>?>(nil)
        Thread.detachNewThread {
            result.value = Result { try renderedDigest(metering: on, visualizer: visualizer) }
            done.signal()
        }
        guard done.wait(timeout: .now() + patience) == .success else { return nil }
        return try? result.value?.get()
    }

    @Test("The compressed frames macOS is handed are byte-identical with the meters and the visualizer on or off",
          .enabled(if: !DeviceQuery.outputUIDs().isEmpty, "needs an output device for the renderer"))
    func rendererInputUntouched() throws {
        var runs: [Rendered] = []
        for (metering, visualizer) in [(false, false), (true, false), (true, true)] {
            let run = try #require(Self.boundedDigest(metering: metering, visualizer: visualizer),
                                   "the renderer was not handed the stream, or the read of it never returned (metering \(metering), visualizer \(visualizer))")
            #expect(run.exhausted, "the renderer was handed the whole stream (metering \(metering), visualizer \(visualizer))")
            #expect(run.buffers >= 1 && run.bytes > 2000, "\(run.buffers) buffers, \(run.bytes) bytes")
            runs.append(run)
        }
        let summary = runs.map { "\($0.digest) \($0.buffers) buffers, \($0.bytes) bytes" }
        #expect(summary[0] == summary[1])
        #expect(summary[0] == summary[2])
    }
}
