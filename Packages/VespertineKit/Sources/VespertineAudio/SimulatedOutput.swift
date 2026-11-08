//
// Vespertine — a stand-in for the device behind an `OutputSession`, for tests of the engine's state machine.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// It runs the same render context the I/O proc does, on a thread of its own at the pace of the device's clock, while the
// session is started, and counts what comes out: frames rendered, and frames that carry sound (a muted, held or empty
// output renders silence). No Core Audio is involved, so a test can say what is actually audible without hardware.
//

import CVespertineRT
import Foundation

final class SimulatedOutput: @unchecked Sendable {
    private let context: OpaquePointer
    private let channels: Int
    private let rate: Double
    private let frames: Int
    /// Held while a buffer renders, so `stop()` returns only once the I/O thread is out of the context (as `AudioDeviceStop` does).
    private let render = NSLock()
    private let flags = Locked((running: false, cancelled: false))
    private let counts = Locked((rendered: 0, audible: 0))
    private let finished = DispatchSemaphore(value: 0)

    init(context: OpaquePointer, channels: Int, rate: Double, bufferFrames: Int = 480) {
        self.context = context
        self.channels = channels
        self.rate = rate
        self.frames = bufferFrames
        let thread = Thread { [self] in run() }
        thread.name = "Simulated output"
        thread.start()
    }

    func start() { render.withLock { flags.withLock { $0.running = true } } }
    func stop() { render.withLock { flags.withLock { $0.running = false } } }

    /// Ends the thread; the context may be destroyed once this returns.
    func shutdown() {
        flags.withLock { $0.cancelled = true; $0.running = false }
        finished.wait()
    }

    /// Frames rendered while running, and of those the ones that were not silence.
    var rendered: Int { counts.withLock { $0.rendered } }
    var audible: Int { counts.withLock { $0.audible } }

    private func run() {
        var buffer = [Float](repeating: 0, count: frames * channels)
        // Paced by an absolute schedule, as a device's clock is: a sleep that overshoots is made up by the next buffer.
        let period = Double(frames) / rate
        var due = Date()
        while true {
            let (running, cancelled) = flags.withLock { ($0.running, $0.cancelled) }
            if cancelled { break }
            if running {
                render.withLock {
                    guard flags.withLock({ $0.running }) else { return }
                    buffer.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, UInt32(frames), UInt32(channels)) }
                    var sound = 0
                    for frame in 0..<frames where (0..<channels).contains(where: { buffer[frame * channels + $0] != 0 }) { sound += 1 }
                    counts.withLock { $0.rendered += frames; $0.audible += sound }
                }
            }
            due = max(due.addingTimeInterval(period), Date().addingTimeInterval(-0.25))
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        finished.signal()
    }
}
