//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import Foundation
import Testing
@testable import VespertineAudio

/// Stands in for macOS's Atmos renderer: a steady 1 kHz tone in the bed, read at a playhead that moves.
private final class FakeAtmosRender: SystemRenderTap, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var tapping = false
    private var playhead: UInt64 = 0
    let rate = 48_000.0

    func setTapping(_ on: Bool) { lock.lock(); tapping = on; lock.unlock() }
    func advance(by frames: UInt64) { lock.lock(); playhead += frames; lock.unlock() }

    func copy(left: inout [Float], right: inout [Float]) -> PlaybackEngine.VisualizerTapRead? {
        lock.lock(); defer { lock.unlock() }
        guard tapping else { return nil }
        let n = left.count
        for i in 0..<n {
            let t = Double(Int(playhead) - n + i)
            left[i] = Float(0.5 * sin(2 * .pi * 1000 * t / rate))
            right[i] = left[i]
        }
        return .init(frames: n, position: playhead, sampleRate: rate, isDSD: false)
    }
}

/// A bed reader that hands out `buffers` buffers of `frames` frames each (left = the frame number, right = its negative), then
/// either ends or, when `failAfter` is set, throws after that many buffers.
private final class FakeBedReader: BedReading, @unchecked Sendable {
    struct Failure: Error {}
    let frames: Int, buffers: Int, failAfter: Int?, firstFrame: Int64
    private(set) var cancelled = false
    private var handedOut = 0

    init(frames: Int, buffers: Int, failAfter: Int? = nil, firstFrame: Int64 = 0) {
        self.frames = frames; self.buffers = buffers; self.failAfter = failAfter; self.firstFrame = firstFrame
    }

    func start() throws {}
    func cancel() { cancelled = true }

    func next() throws -> BedBuffer? {
        if let failAfter, handedOut == failAfter { throw Failure() }
        guard handedOut < buffers else { return nil }
        let base = firstFrame + Int64(handedOut * frames)
        handedOut += 1
        return BedBuffer(frames: frames) { first, count, destination in
            for i in 0..<count {
                let f = Float(base + Int64(first + i))
                destination[2 * i] = f
                destination[2 * i + 1] = -f
            }
            return true
        }
    }
}

/// Wraps the real asset reader and notes what it did and when, so that a decoder that stalls on a CI machine says where.
private final class TracingBedReader: BedReading, @unchecked Sendable {
    private let inner: BedReading
    private let lock = NSLock()
    private let began = Date()
    private var lines: [String] = []

    init(_ inner: BedReading) { self.inner = inner; note("made") }

    var trace: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: ", ") }
    private func note(_ line: String) {
        lock.lock(); lines.append(String(format: "%.2fs %@", Date().timeIntervalSince(began), line)); lock.unlock()
    }

    func start() throws {
        note("start")
        do { try inner.start(); note("started") } catch { note("start threw \(error)"); throw error }
    }
    func next() throws -> BedBuffer? {
        note("next")
        do {
            let buffer = try inner.next()
            note(buffer.map { "got \($0.frames) frames" } ?? "got the end")
            return buffer
        } catch { note("next threw \(error)"); throw error }
    }
    func cancel() { note("cancel"); inner.cancel() }
}

private final class TraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TracingBedReader?
    var reader: TracingBedReader? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var trace: String { reader?.trace ?? "no reader was made" }
}

@Suite("Visualizer while macOS renders Dolby Atmos")
struct AtmosVisualizerTests {
    @Test("The engine's visualizer tap reads the Atmos render's samples instead of reporting nothing")
    func engineReadsAtmosRender() {
        let engine = PlaybackEngine()
        let render = FakeAtmosRender()
        engine.attachSystemTapForTesting(render)
        engine.setVisualizerTap(true)
        render.advance(by: 48_000)
        var l = [Float](repeating: 0, count: 4096), r = l
        let read = engine.copyVisualizerTap(left: &l, right: &r)
        #expect(read != nil)
        #expect(read?.frames == 4096)
        #expect(read?.sampleRate == 48_000)
        #expect(l.contains { abs($0) > 0.4 })
    }

    /// Energy of `signal` at `hz` (Goertzel).
    private static func energy(_ signal: [Float], at hz: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * hz / rate, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in signal { let s0 = Double(x) + c * s1 - s2; s2 = s1; s1 = s0 }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(signal.count * signal.count)
    }

    /// Waits until the decoder has stored the bed up to `frame`. The first buffer comes out of AVFoundation's decoder on
    /// its own threads, and when the rest of the suite keeps every core busy (a release run, or a small CI machine) that
    /// takes more than ten seconds, so the bound is generous: the poll ends the moment the frames are there, and only a
    /// decoder that has really stopped makes it fail, with the frame it stopped at.
    private static func waitForBed(_ decoder: SystemBedDecoder, through frame: Int64, timeout: TimeInterval = 120,
                                   trace: @autoclosure () -> String = "") throws {
        let deadline = Date().addingTimeInterval(timeout)
        while decoder.tap.endFrame < frame {
            guard Date() < deadline else {
                throw BedTimeout(description: "the bed decoder had stored up to frame \(decoder.tap.endFrame) of \(frame) after \(Int(timeout)) s; decoder error: \(decoder.error.map { String(describing: $0) } ?? "none"); reader: \(trace())")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    @Test("The bed tap returns the frames before the playhead, zeros where nothing was decoded, and nil when it has nothing")
    func bedTapWindow() {
        let tap = SystemBedTap(sampleRate: 48_000, capacity: 1024)
        var l = [Float](repeating: -1, count: 8), r = l
        #expect(tap.copy(left: &l, right: &r, playhead: 100) == nil)
        tap.reset(at: 100)
        let samples: [Float] = (0..<16).flatMap { [Float(100 + $0), -Float(100 + $0)] }
        samples.withUnsafeBufferPointer { tap.append(interleaved: $0.baseAddress!, frames: 16, at: 100) }
        let read = tap.copy(left: &l, right: &r, playhead: 104)       // frames 96…103: 96…99 aren't decoded
        #expect(read?.frames == 8 && read?.position == 104 && read?.sampleRate == 48_000)
        #expect(l == [0, 0, 0, 0, 100, 101, 102, 103])
        #expect(r == l.map { -$0 })
        _ = tap.copy(left: &l, right: &r, playhead: 116)
        #expect(l == (108...115).map(Float.init))
        #expect(tap.copy(left: &l, right: &r, playhead: 100) == nil)   // nothing before the first decoded frame
        #expect(tap.copy(left: &l, right: &r, playhead: 500) == nil)   // the playhead is far past what was decoded
        // The ring keeps only its capacity, and a start that doesn't continue drops what was stored.
        let more = [Float](repeating: 0.25, count: 2 * 2048)
        more.withUnsafeBufferPointer { tap.append(interleaved: $0.baseAddress!, frames: 2048, at: 116) }
        #expect(tap.copy(left: &l, right: &r, playhead: 116 + 2048)?.frames == 8)
        #expect(l.allSatisfy { $0 == 0.25 })
        more.withUnsafeBufferPointer { tap.append(interleaved: $0.baseAddress!, frames: 4, at: 9000) }
        #expect(tap.copy(left: &l, right: &r, playhead: 2000) == nil)
    }

    @Test("A real Dolby Digital Plus file decodes to a stereo bed downmix that follows the playhead")
    func decodesBed() throws {
        let url = Bundle.module.url(forResource: "dolby-digital-plus-tones.m4a", withExtension: nil, subdirectory: "Fixtures")!
        let asset = AVURLAsset(url: url)
        let info = try #require(LoadedAudioTrack(asset))
        let tracing = TraceBox()
        let decoder = SystemBedDecoder(makeReader: { seconds in
            let reader = TracingBedReader(try AssetBedReader(asset: asset, track: info.track, origin: info.timeRange.start, seconds: seconds))
            tracing.reader = reader
            return reader
        })
        let playhead = Locked(0.5)
        decoder.start(at: 0) { playhead.value }
        defer { decoder.stop() }
        // Wait for the first second of the bed (the fixture is 1.5 s long and decoding stays a second ahead).
        try Self.waitForBed(decoder, through: 36_000, trace: tracing.trace)
        playhead.value = 0.75
        var l = [Float](repeating: 0, count: 4096), r = l
        let read = try #require(decoder.tap.copy(left: &l, right: &r, playhead: 36_000))
        #expect(read.frames == 4096 && read.sampleRate == 48_000)
        // FL 440, FR 550, FC 660 (both sides), SL 770 (left), SR 880 (right) fold into the pair; LFE (60) stays out.
        let rate = 48_000.0
        let floor = Self.energy(l, at: 1500, rate: rate) + 1e-9
        for hz in [440.0, 660, 770] { #expect(Self.energy(l, at: hz, rate: rate) > 100 * floor, "left \(hz)") }
        for hz in [550.0, 660, 880] { #expect(Self.energy(r, at: hz, rate: rate) > 100 * floor, "right \(hz)") }
        #expect(Self.energy(l, at: 550, rate: rate) < Self.energy(l, at: 440, rate: rate) / 100)
        #expect(Self.energy(r, at: 440, rate: rate) < Self.energy(r, at: 550, rate: rate) / 100)
    }

    @Test("Seeking restarts the bed at the new position")
    func seekRestarts() throws {
        let url = Bundle.module.url(forResource: "dolby-digital-plus-tones.m4a", withExtension: nil, subdirectory: "Fixtures")!
        let asset = AVURLAsset(url: url)
        let info = try #require(LoadedAudioTrack(asset))
        let tracing = TraceBox()
        let decoder = SystemBedDecoder(makeReader: { seconds in
            let reader = TracingBedReader(try AssetBedReader(asset: asset, track: info.track, origin: info.timeRange.start, seconds: seconds))
            tracing.reader = reader
            return reader
        })
        let playhead = Locked(1.0)
        decoder.start(at: 1.0) { playhead.value }
        defer { decoder.stop() }
        try Self.waitForBed(decoder, through: 60_000, trace: tracing.trace)
        var l = [Float](repeating: 0, count: 2048), r = l
        let read = decoder.tap.copy(left: &l, right: &r, playhead: 60_000)
        #expect(read != nil)
        #expect(l.contains { abs($0) > 0.01 })
        var early = [Float](repeating: 0, count: 2048), earlyR = early
        #expect(decoder.tap.copy(left: &early, right: &earlyR, playhead: 20_000) == nil)   // before the seek target
    }

    @Test("Buffers bigger than a chunk are stored whole, in order, never skipped")
    func largeBuffersAreStored() throws {
        let reader = FakeBedReader(frames: 32_768, buffers: 3)
        let decoder = SystemBedDecoder(makeReader: { _ in reader })
        decoder.start(at: 0) { 100 }
        defer { decoder.stop() }
        try Self.waitForBed(decoder, through: 3 * 32_768, timeout: 20)
        #expect(decoder.error == nil)
        var l = [Float](repeating: 0, count: 64), r = l
        let playheads: [Int64] = [32_768, 32_775, 65_536, 98_304]          // across and inside the buffer boundaries
        for playhead in playheads {
            let read = try #require(decoder.tap.copy(left: &l, right: &r, playhead: playhead))
            #expect(read.frames == 64)
            let expected: [Float] = (0..<64).map { (i: Int) -> Float in Float(playhead - 64 + Int64(i)) }
            #expect(l == expected, "playhead \(playhead)")
            #expect(r == l.map { -$0 })
        }
    }

    @Test("A big buffer doesn't hold the lookahead open: the decoder still waits for the playhead")
    func largeBuffersKeepTheLookahead() throws {
        let decoder = SystemBedDecoder(makeReader: { _ in FakeBedReader(frames: 32_768, buffers: 10) })
        let playhead = Locked(0.0)
        decoder.start(at: 0) { playhead.value }
        defer { decoder.stop() }
        try Self.waitForBed(decoder, through: 2 * 32_768, timeout: 20)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(decoder.tap.endFrame == 2 * 32_768)           // 1.37 s in, so it holds until the playhead catches up
        playhead.value = 10
        try Self.waitForBed(decoder, through: 10 * 32_768, timeout: 20)
    }

    @Test("A reader that fails mid-stream ends the decoder with the error recorded, keeping what it had stored")
    func readerFailureIsRecorded() throws {
        let reader = FakeBedReader(frames: 8192, buffers: 10, failAfter: 3)
        let decoder = SystemBedDecoder(makeReader: { _ in reader })
        decoder.start(at: 0) { 100 }
        defer { decoder.stop() }
        try Self.waitForBed(decoder, through: 3 * 8192, timeout: 20)
        let deadline = Date().addingTimeInterval(20)
        while decoder.error == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(decoder.error is FakeBedReader.Failure)
        #expect(decoder.tap.endFrame == 3 * 8192)
        #expect(reader.cancelled)
        // A new start clears the error and decodes again.
        decoder.start(at: 0) { 100 }
        #expect(decoder.error == nil)
    }

    @Test("A buffer without data ends the decoder with an error instead of silently")
    func missingDataIsRecorded() throws {
        final class EmptyReader: BedReading {
            var handed = 0
            func start() throws {}
            func cancel() {}
            func next() throws -> BedBuffer? {
                handed += 1
                if handed == 1 { return BedBuffer(frames: 4096) { _, count, d in d.update(repeating: 0.5, count: 2 * count); return true } }
                return BedBuffer(frames: 4096) { _, _, _ in false }
            }
        }
        let decoder = SystemBedDecoder(makeReader: { _ in EmptyReader() })
        decoder.start(at: 0) { 100 }
        defer { decoder.stop() }
        let deadline = Date().addingTimeInterval(20)
        while decoder.error == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(decoder.error != nil)
        #expect(decoder.tap.endFrame == 4096)
    }

    @Test("A reader that can't be made or started is recorded too")
    func startFailureIsRecorded() throws {
        let decoder = SystemBedDecoder(makeReader: { _ in throw FakeBedReader.Failure() })
        decoder.start(at: 0) { 0 }
        defer { decoder.stop() }
        let deadline = Date().addingTimeInterval(20)
        while decoder.error == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(decoder.error is FakeBedReader.Failure)
    }
}

private struct BedTimeout: Error, CustomStringConvertible { var description: String }

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
