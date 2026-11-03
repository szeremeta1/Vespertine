//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing

@Suite("Visualizer tap")
struct VisualizerTapTests {
    /// Stereo frames whose left sample is the frame number and right its negative, exact in Float32 up to 2^24.
    private static func ramp(from start: Int, count: Int) -> [Float] {
        (0..<count).flatMap { [Float(start + $0), -Float(start + $0)] }
    }

    private static func render(_ ctx: OpaquePointer, frames: Int, channels: Int = 2) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(ctx, $0.baseAddress!, UInt32(frames), UInt32(channels)) }
        return out
    }

    @Test("Off by default: nothing is tapped")
    func offByDefault() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        #expect(!nrt_context_viz(ctx))
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 512), 512)
        _ = Self.render(ctx, frames: 512)
        var l = [Float](repeating: 0, count: 64), r = l
        var position: UInt64 = 99
        _ = nrt_context_copy_viz(ctx, &l, &r, 64, &position)
        #expect(position == 0)
        #expect(l.allSatisfy { $0 == 0 })
    }

    @Test("The output is bit-identical with the tap on or off, at unity gain and with gain", arguments: [1.0, 0.5])
    func outputUntouched(gain: Double) {
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 { input[i] = Float(Int32(truncatingIfNeeded: i &* 2_654_435_761) >> 8) / 8_388_608 }
        var outputs: [[UInt32]] = []
        for on in [false, true] {
            let ring = nrt_ring_create(4096, 2)!
            let ctx = nrt_context_create(ring, 4096)!
            defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
            nrt_context_set_gain(ctx, gain, 24)
            nrt_context_set_viz(ctx, on)
            _ = nrt_ring_write(ring, input, 2048)
            outputs.append(Self.render(ctx, frames: 2048).map(\.bitPattern))
        }
        #expect(outputs[0] == outputs[1])
        if gain == 1 { #expect(outputs[1] == input.map(\.bitPattern)) }
    }

    @Test("Copies the newest frames oldest first, left and right apart, at the music's size whatever the gain")
    func newestFramesUnscaled() {
        let ring = nrt_ring_create(8192, 2)!
        let ctx = nrt_context_create(ring, 1024)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        nrt_context_set_gain(ctx, 0.25, 0)    // no dither, so the output is exactly a quarter
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 3000), 3000)
        let out = Self.render(ctx, frames: 3000)
        #expect(out[2 * 2999] == 750)
        var l = [Float](repeating: 0, count: 100), r = l
        var position: UInt64 = 0
        #expect(nrt_context_copy_viz(ctx, &l, &r, 100, &position) == 100)
        #expect(position == 3000)
        #expect(l == (2901...3000).map(Float.init))
        #expect(r == (2901...3000).map { -Float($0) })
    }

    @Test("A mono source reaches both sides")
    func mono() {
        let ring = nrt_ring_create(4096, 1)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        let input = (0..<256).map { Float($0) / 256 }
        _ = nrt_ring_write(ring, input, 256)
        _ = Self.render(ctx, frames: 256)
        var l = [Float](repeating: 0, count: 256), r = l
        #expect(nrt_context_copy_viz(ctx, &l, &r, 256, nil) == 256)
        #expect(l == input && r == input)
    }

    @Test("The position stands still while muted, and nothing is tapped from silence held for a pause")
    func standsStillWhenMuted() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 1024), 1024)
        _ = Self.render(ctx, frames: 256)
        var l = [Float](repeating: 0, count: 16), r = l
        var position: UInt64 = 0
        _ = nrt_context_copy_viz(ctx, &l, &r, 16, &position)
        #expect(position == 256)
        nrt_context_set_muted(ctx, true)
        _ = Self.render(ctx, frames: 256)
        _ = nrt_context_copy_viz(ctx, &l, &r, 16, &position)
        #expect(position == 256)
        #expect(l.last == 256)
    }

    @Test("DoP: the tap reads the levels of the DSD bits, and the frames still go out untouched")
    func dop() {
        let ring = nrt_ring_create(4096, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_passthrough(ctx, true)
        nrt_context_set_dop(ctx, true)
        nrt_context_set_viz(ctx, true)
        var frames: [Float] = []
        for i in 0..<256 {
            let marker: UInt32 = i % 2 == 0 ? 0x05 : 0xFA
            for bits: UInt32 in [0xFFFF, 0x5555] {
                frames.append(Float(Int32(bitPattern: (marker << 16 | bits) << 8) >> 8) / 8_388_608)
            }
        }
        _ = nrt_ring_write(ring, frames, 256)
        #expect(Self.render(ctx, frames: 256).map(\.bitPattern) == frames.map(\.bitPattern))
        var l = [Float](repeating: 0, count: 128), r = l
        #expect(nrt_context_copy_viz(ctx, &l, &r, 128, nil) == 128)
        #expect(l.allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(r.allSatisfy { abs($0) < 1e-6 })
    }

    /// The newest `count` frames of the tap, and the position it reports.
    private static func read(_ ctx: OpaquePointer, count: Int = 64) -> (left: [Float], position: UInt64, got: UInt32) {
        var l = [Float](repeating: 0, count: count), r = l
        var position: UInt64 = 0
        let got = nrt_context_copy_viz(ctx, &l, &r, UInt32(count), &position)
        return (l, position, got)
    }

    @Test("Closed, a song skipped to on the same output, shown again: the tap carries the new song and moves on")
    func reopenAfterSkipOnTheSameOutput() {
        let ring = nrt_ring_create(16384, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 1000), 1000)
        _ = Self.render(ctx, frames: 1000)
        let open = Self.read(ctx)
        #expect(open.position == 1000 && open.left.last == 1000)
        // The window closes: the tap stops, and the song goes on being rendered, then a skip (the ring is flushed).
        nrt_context_set_viz(ctx, false)
        _ = nrt_ring_write(ring, Self.ramp(from: 1001, count: 500), 500)
        _ = Self.render(ctx, frames: 500)
        #expect(Self.read(ctx).position == 1000, "the closed tap moved")
        nrt_ring_reset(ring)
        nrt_context_reset_history(ctx)
        _ = nrt_ring_write(ring, Self.ramp(from: 90_001, count: 700), 700)
        _ = Self.render(ctx, frames: 300)
        #expect(Self.read(ctx).position == 1000, "the closed tap moved")
        // The window shows again.
        nrt_context_set_viz(ctx, true)
        _ = Self.render(ctx, frames: 200)
        let reopened = Self.read(ctx)
        #expect(reopened.got == 64)
        #expect(reopened.position == 1200, "the tap didn't go on from where it stopped")
        #expect(abs((reopened.left.last ?? 0) - 90_500) < 0.5, "the tap shows another song than the one playing")
        _ = Self.render(ctx, frames: 200)
        let later = Self.read(ctx)
        #expect(later.position == 1400 && abs((later.left.last ?? 0) - 90_700) < 0.5)
    }

    @Test("Closed, a skip to a song on a new output session (another rate), shown again: the new session's tap starts moving")
    func reopenAfterSkipToANewSession() {
        let ringA = nrt_ring_create(8192, 2)!
        let a = nrt_context_create(ringA, 512)!
        nrt_context_set_viz(a, true)
        _ = nrt_ring_write(ringA, Self.ramp(from: 1, count: 600), 600)
        _ = Self.render(a, frames: 600)
        #expect(Self.read(a).position == 600)
        // Closed: the engine remembers the choice (off) and gives the next session that.
        nrt_context_set_viz(a, false)
        nrt_context_destroy(a); nrt_ring_destroy(ringA)
        let ringB = nrt_ring_create(8192, 2)!
        let b = nrt_context_create(ringB, 512)!
        defer { nrt_context_destroy(b); nrt_ring_destroy(ringB) }
        nrt_context_set_viz(b, false)
        _ = nrt_ring_write(ringB, Self.ramp(from: 5001, count: 1200), 1200)
        _ = Self.render(b, frames: 400)
        #expect(Self.read(b).position == 0)
        // Shown again.
        nrt_context_set_viz(b, true)
        _ = Self.render(b, frames: 256)
        let first = Self.read(b)
        #expect(first.got == 64 && first.position == 256 && abs((first.left.last ?? 0) - 5_656) < 0.5)
        _ = Self.render(b, frames: 256)
        #expect(Self.read(b).position == 512)
    }

    @Test("Skipping with the tap on: the position never goes back and the picture changes song")
    func skipWhileOpen() {
        let ring = nrt_ring_create(16384, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 800), 800)
        _ = Self.render(ctx, frames: 800)
        let before = Self.read(ctx)
        nrt_ring_reset(ring)
        nrt_context_reset_history(ctx)
        _ = nrt_ring_write(ring, Self.ramp(from: 70_001, count: 800), 800)
        _ = Self.render(ctx, frames: 400)
        let after = Self.read(ctx)
        #expect(after.position == before.position + 400)
        #expect(abs((after.left.last ?? 0) - 70_400) < 0.5)
    }

    @Test("Gapless: the tap runs on across the end of one song into the next, in order, with the position unbroken")
    func gaplessIntoTheNextSong() {
        let ring = nrt_ring_create(16384, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_viz(ctx, true)
        // Song A ends at frame 300 and B follows at once (both queued before the I/O thread gets to them).
        _ = nrt_ring_write(ring, Self.ramp(from: 1, count: 300), 300)
        _ = nrt_ring_write(ring, Self.ramp(from: 10_001, count: 500), 500)
        _ = Self.render(ctx, frames: 400)
        let r = Self.read(ctx, count: 400)
        #expect(r.position == 400)
        #expect(Array(r.left[0..<300]) == (1...300).map(Float.init))
        #expect(Array(r.left[300..<400]) == (10_001...10_100).map(Float.init))
    }

    @Test("DoP: closed, skipped, shown again, the tap reads the new song's DSD levels and moves")
    func dopReopenAfterSkip() {
        let ring = nrt_ring_create(8192, 2)!
        let ctx = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(ctx); nrt_ring_destroy(ring) }
        nrt_context_set_passthrough(ctx, true)
        nrt_context_set_dop(ctx, true)
        func dop(_ bits: [UInt32], frames: Int) -> [Float] {
            var out: [Float] = []
            for i in 0..<frames {
                let marker: UInt32 = i % 2 == 0 ? 0x05 : 0xFA
                for b in bits { out.append(Float(Int32(bitPattern: (marker << 16 | b) << 8) >> 8) / 8_388_608) }
            }
            return out
        }
        nrt_context_set_viz(ctx, true)
        _ = nrt_ring_write(ring, dop([0xFFFF, 0x5555], frames: 256), 256)
        _ = Self.render(ctx, frames: 256)
        let open = Self.read(ctx, count: 128)
        #expect(open.position == 256 && open.got == 128)
        nrt_context_set_viz(ctx, false)                      // closed
        _ = nrt_ring_write(ring, dop([0x0000, 0x5555], frames: 256), 256)   // the next song, DSD of the other sign
        _ = Self.render(ctx, frames: 256)
        #expect(Self.read(ctx).position == 256)
        nrt_context_set_viz(ctx, true)                       // shown again
        _ = nrt_ring_write(ring, dop([0x0000, 0x5555], frames: 256), 256)
        _ = Self.render(ctx, frames: 256)
        var l = [Float](repeating: 0, count: 128), r = l
        var position: UInt64 = 0
        #expect(nrt_context_copy_viz(ctx, &l, &r, 128, &position) == 128)
        #expect(position == 512)
        #expect(l.allSatisfy { abs($0 + 1) < 1e-6 }, "the tap still shows the song before the skip")
    }

    /// The render context and ring, shared with the threads below. The threads hold it, and it destroys the context and
    /// ring only once the last of them lets go: a race that gives up on a slow worker must not free what that worker
    /// is still using. `onDestroy` is told how many threads were still working with it (none, if this holds).
    private final class Rig: @unchecked Sendable {
        let ring: OpaquePointer
        let ctx: OpaquePointer
        let working = Locked(0)
        private let onDestroy: @Sendable (Int) -> Void

        init(onDestroy: @escaping @Sendable (Int) -> Void = { _ in }) {
            ring = nrt_ring_create(65536, 2)!
            ctx = nrt_context_create(ring, 512)!
            self.onDestroy = onDestroy
        }

        deinit {
            onDestroy(working.value)
            nrt_context_destroy(ctx)
            nrt_ring_destroy(ring)
        }
    }

    /// What the reader and the writer saw in one race.
    private struct Race {
        var kept = 0, dropped = 0, torn = 0
        var elapsed = Double.infinity
        var finished = false
    }

    /// The I/O side renders `slices` slices while a reader copies the tap as fast as it can, checking every copy it
    /// keeps. Both run on threads of their own, never the cooperative pool: a reader that spins until the writer
    /// is done must not depend on the pool giving the writer a thread (a busy pool starved it for the whole job).
    /// Blocks the caller; gives up (`finished == false`) after `patience` seconds, leaving the rig to the threads still
    /// running (they stop at their next slice). `slowdown` makes the writer take that long per slice.
    private static func race(_ shared: Rig, slices: Int, slice: Int, patience: TimeInterval = 120, slowdown: TimeInterval = 0) -> Race {
        let stop = Locked(false)
        let readerDone = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0)
        let outcome = Locked(Race())

        // The reader copies as fast as it can, the largest windows the tap allows.
        shared.working.withLock { $0 += 2 }
        Thread.detachNewThread {
            defer { shared.working.withLock { $0 -= 1 } }
            var l = [Float](repeating: 0, count: Int(NRT_VIZ_TAP_SIZE / 2)), r = l
            var seen = Race()
            while !stop.value {
                let got = nrt_context_copy_viz(shared.ctx, &l, &r, UInt32(l.count), nil)
                if got == 0 { seen.dropped += 1; continue }
                guard let first = l.first, first > 0 else { continue }   // before the first full window
                seen.kept += 1
                for i in 1..<l.count where l[i] != l[i - 1] + 1 || r[i] != -l[i] { seen.torn += 1; break }
            }
            outcome.withLock { $0.kept = seen.kept; $0.dropped = seen.dropped; $0.torn = seen.torn }
            readerDone.signal()
        }

        // The I/O side: decode-and-render loops, as fast as they go. Its time per slice shouldn't depend on the reader.
        Thread.detachNewThread {
            defer { shared.working.withLock { $0 -= 1 } }
            var out = [Float](repeating: 0, count: slice * 2)
            var next = 1
            let start = Date()
            for _ in 0..<slices where !stop.value {
                if slowdown > 0 { Thread.sleep(forTimeInterval: slowdown) }
                let input = (0..<slice).flatMap { [Float(next + $0), -Float(next + $0)] }
                next += slice
                if next > 1 << 23 { next = 1 }   // stay exact in Float32
                _ = nrt_ring_write(shared.ring, input, UInt32(slice))
                out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(shared.ctx, $0.baseAddress!, UInt32(slice), 2) }
            }
            outcome.withLock { $0.elapsed = Date().timeIntervalSince(start) }
            writerDone.signal()
        }

        let wrote = writerDone.wait(timeout: .now() + patience) == .success
        stop.value = true
        let read = readerDone.wait(timeout: .now() + 30) == .success
        return outcome.withLock { var seen = $0; seen.finished = wrote && read; return seen }
    }

    private static func expectRace(_ result: Race, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.finished, "the writer or the reader never finished", sourceLocation: sourceLocation)
        #expect(result.torn == 0, sourceLocation: sourceLocation)
        #expect(result.kept > 0, sourceLocation: sourceLocation)
        // 8000 slices of 512 frames is 93 s of 44.1 kHz audio; rendering it with the reader racing must stay far
        // faster than real time (a reader that could hold the I/O thread up would show here).
        #expect(result.elapsed < 20, sourceLocation: sourceLocation)
    }

    @Test("The I/O side never waits for the reader, and every copy the reader keeps is one moment, never torn")
    func neverBlocksNeverTears() {
        let rig = Rig()
        nrt_context_set_viz(rig.ctx, true)
        Self.expectRace(Self.race(rig, slices: 8000, slice: 512))
    }

    @Test("A race that gives up on a slow writer leaves the context and ring to the threads still using them")
    func timeoutKeepsTheRigAlive() {
        let destroyedWith = Locked<Int?>(nil)
        var rig: Rig? = Rig { destroyedWith.value = $0 }
        nrt_context_set_viz(rig!.ctx, true)
        let result = Self.race(rig!, slices: 50, slice: 512, patience: 0.05, slowdown: 0.3)
        #expect(!result.finished)
        rig = nil   // the test lets go; the threads that are still running keep it
        let deadline = Date().addingTimeInterval(30)
        while destroyedWith.value == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(destroyedWith.value == 0, "the context and ring were freed while a thread was still using them")
    }

    /// Holds the calling thread until `gate` is signalled (a blocking call, which `Task` bodies can't make directly).
    private static func hold(_ gate: DispatchSemaphore, counting held: Locked<Int>) {
        held.withLock { $0 += 1 }
        gate.wait()
    }

    @Test("The same race finishes while every thread of the cooperative pool is held by blocked tasks")
    func notStarvedByABusyPool() {
        let rig = Rig()
        nrt_context_set_viz(rig.ctx, true)
        // More blockers than the pool has threads, held until the race is over: what blocking tests of a loaded suite do.
        let gate = DispatchSemaphore(value: 0)
        let blockers = ProcessInfo.processInfo.activeProcessorCount + 2
        let held = Locked(0)
        for _ in 0..<blockers { Task.detached { Self.hold(gate, counting: held) } }
        let deadline = Date().addingTimeInterval(10)
        while held.value < min(blockers, ProcessInfo.processInfo.activeProcessorCount - 1), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let result = Self.race(rig, slices: 2000, slice: 512)
        for _ in 0..<blockers { gate.signal() }
        Self.expectRace(result)
    }
}

/// A value shared between test threads.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&stored) }
}
