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
        let decoder = SystemBedDecoder(asset: asset, track: info.track, origin: info.timeRange.start)
        let playhead = Locked(0.5)
        decoder.start(at: 0) { playhead.value }
        defer { decoder.stop() }
        // Wait for the first second of the bed (the fixture is 1.5 s long and decoding stays a second ahead).
        let deadline = Date().addingTimeInterval(10)
        while decoder.tap.endFrame < 36_000, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
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
        let decoder = SystemBedDecoder(asset: asset, track: info.track, origin: info.timeRange.start)
        let playhead = Locked(1.0)
        decoder.start(at: 1.0) { playhead.value }
        defer { decoder.stop() }
        let deadline = Date().addingTimeInterval(10)
        while decoder.tap.endFrame < 60_000, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        var l = [Float](repeating: 0, count: 2048), r = l
        let read = decoder.tap.copy(left: &l, right: &r, playhead: 60_000)
        #expect(read != nil)
        #expect(l.contains { abs($0) > 0.01 })
        var early = [Float](repeating: 0, count: 2048), earlyR = early
        #expect(decoder.tap.copy(left: &early, right: &earlyR, playhead: 20_000) == nil)   // before the seek target
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
