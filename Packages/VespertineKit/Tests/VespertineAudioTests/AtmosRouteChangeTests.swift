//
// Vespertine: Dolby Atmos played by macOS's renderer (AVSampleBufferAudioRenderer) across a route change. When the output's
// configuration changes under it (AirPods Max moving between A2DP, call mode and the USB-C cable; a headset connecting), macOS
// throws away what the renderer had queued and posts `AVSampleBufferAudioRendererWasFlushedAutomatically` with the time it
// flushed from. The player has to feed it again from that time. Vespertine didn't listen, so it went on from where its reader
// had got to: everything queued (seconds of the song) was skipped, heard as a gap or as the song "dropping out". The laptop logs
// of 2026-11-13 show macOS posting it to Vespertine twice: 16:51:44.098 ("for time 9.079", the cable going in) and
// 16:56:17.993 ("for time 94.568", call mode ending).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import VespertineAudio

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func add(_ t: Double) { lock.lock(); times.append(t); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
}

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

/// What a session was handed, from before and after macOS flushed it.
private struct Fed: Sendable {
    var before: [Double] = []
    var after: [Double] = []
    var flushTime = 0.0
    var problem: String?
}

private let patience: TimeInterval = 90

/// A renderer whose clock stands still, in place of macOS's. It takes buffers until one starts two seconds or more past its
/// clock, and asks for data once each time it is told to, on the queue it is given. It goes by where a buffer starts, since a
/// compressed buffer does not always say how long it is. macOS's own asked when the machine's audio
/// system got to it, and on a busy CI Mac that was sometimes never within the minute these tests gave it ("the renderer took
/// only 0 buffers"). What is tested here is the session: what it reads and queues, and from where after a flush.
private final class HeldRenderer: SystemRendererSink, @unchecked Sendable {
    private let lock = NSLock()
    private var now = CMTime.zero
    private var queuedTo: CMTime?
    private var asking: DispatchQueue?
    private let object = NSObject()

    var noticeObject: AnyObject { object }
    var volume: Float = 0
    var rate: Float = 0
    var failed: Bool { false }
    var error: Error? { nil }
    var isReadyForMoreMediaData: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let queuedTo else { return true }
        return CMTimeGetSeconds(CMTimeSubtract(queuedTo, now)) < 2
    }
    func setRate(_ rate: Float, time: CMTime) { lock.lock(); self.rate = rate; now = time; lock.unlock() }
    func currentTime() -> CMTime { lock.lock(); defer { lock.unlock() }; return now }
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        lock.lock(); asking = queue; lock.unlock()
        queue.async(execute: block)
    }
    func stopRequestingMediaData() {}
    func enqueue(_ buffer: CMSampleBuffer) {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard start.isValid, start.isNumeric else { return }
        lock.lock(); queuedTo = queuedTo.map { CMTimeMaximum($0, start) } ?? start; lock.unlock()
    }
    func flush() { lock.lock(); queuedTo = nil; lock.unlock() }

    /// The session has been given all it was asked for: the request made last has run to its end. An order, not a wait.
    func settle() {
        lock.lock(); let queue = asking; lock.unlock()
        queue?.sync {}
    }

    /// What macOS does when the route changes: throws away what is queued and says from what time, naming `renderer`.
    func flushAutomatically(at seconds: Double, naming renderer: AnyObject? = nil) {
        if renderer == nil { flush() }
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer ?? object,
                                        userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(seconds: seconds, preferredTimescale: 48_000))])
    }
}

/// The fixture has been read and queued past 0.7 s: all the held renderer takes before it plays.
private func queuedPast(_ renderer: HeldRenderer, _ recorder: Recorder) -> Bool {
    renderer.settle()
    return (recorder.all.last ?? 0) - (recorder.all.first ?? 0) >= 0.7
}

private func makeSession(_ recorder: Recorder, _ renderer: HeldRenderer) throws -> SystemRendererSession {
    let url = fixture("dolby-digital-plus-tones.m4a")
    let session = try SystemRendererSession(item: PlayableItem(url: url), url: url, deviceUID: nil, spatial: false, volume: 0, sink: renderer)
    session.enqueueObserver = { buffer in
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if pts.isValid { recorder.add(CMTimeGetSeconds(pts)) }
    }
    return session
}

// The session is given a renderer whose clock the test holds (`HeldRenderer`); the file is still read by the system's media
// framework. Each test takes its turn (`RendererSessionGate`) and runs the session on a thread of its own, waited for
// with `await` and given up on after `patience`: a read stuck in the system's media framework fails the test, with the
// reason, instead of holding a pool thread and the session's lock until the CI watchdog prints stacks.
@Suite("Atmos through macOS's renderer: route changes")
struct AtmosRouteChangeTests {
    @Test("After macOS flushes the renderer on a route change, it is fed again from the time it flushed from")
    func refedFromTheFlushTime() async throws {
        let fed = await RendererSessionGate.shared.exclusive {
            await runBounded(patience: patience) { () -> Fed in
                var fed = Fed()
                let recorder = Recorder()
                do {
                    let renderer = HeldRenderer()
                    let session = try makeSession(recorder, renderer)
                    try session.prepare(at: 0)
                    defer { session.stop() }
                    guard queuedPast(renderer, recorder) else { fed.problem = "the renderer took only \(recorder.all.count) buffers"; return fed }
                    fed.before = recorder.all
                    // macOS flushes it at 0.2 s into the song, as it does when the route changes.
                    fed.flushTime = fed.before[0] + 0.2
                    renderer.flushAutomatically(at: fed.flushTime)
                    renderer.settle()
                    fed.after = Array(recorder.all.dropFirst(fed.before.count))
                } catch { fed.problem = "\(error)" }
                return fed
            }
        }
        let run = try #require(fed, "the session didn't answer in \(Int(patience)) s (a read of the file never returned)")
        try #require(run.problem == nil, "\(run.problem ?? "")")
        let resumed = try #require(run.after.first, "nothing was queued again after the flush")
        // From the frame that holds the flush time (an E-AC-3 frame is 32 ms), not from where the reader had got to.
        #expect(resumed <= run.flushTime + 0.001, "fed again from \(resumed) s, after the flush time \(run.flushTime) s")
        #expect(resumed > run.flushTime - 0.25, "fed again from \(resumed) s, long before the flush time \(run.flushTime) s")
    }

    @Test("A flush notice from another renderer is not this session's business")
    func otherRenderersIgnored() async throws {
        let fed = await RendererSessionGate.shared.exclusive {
            await runBounded(patience: patience) { () -> Fed in
                var fed = Fed()
                let recorder = Recorder()
                do {
                    let renderer = HeldRenderer()
                    let session = try makeSession(recorder, renderer)
                    try session.prepare(at: 0)
                    defer { session.stop() }
                    guard queuedPast(renderer, recorder) else { fed.problem = "the renderer took only \(recorder.all.count) buffers"; return fed }
                    fed.before = recorder.all
                    fed.flushTime = fed.before[0] + 0.1
                    renderer.flushAutomatically(at: fed.flushTime, naming: NSObject())
                    renderer.settle()
                    fed.after = Array(recorder.all.dropFirst(fed.before.count))
                } catch { fed.problem = "\(error)" }
                return fed
            }
        }
        let run = try #require(fed, "the session didn't answer in \(Int(patience)) s (a read of the file never returned)")
        try #require(run.problem == nil, "\(run.problem ?? "")")
        #expect(!run.after.contains { $0 < run.before[0] + 0.4 }, "re-fed for another renderer's flush")
    }

    @Test("A read that doesn't return never stops the session from saying how far it has got, or from being stopped")
    func stuckReadDoesNotWedgeTheSession() async throws {
        // The read is stuck until this test lets it go, however long that is. So the verdict is an order, not a time: the
        // session answered while the read was still stuck, or it did not answer until the read was let go. `patience` only
        // ends a run where it never answers; it is not what "soon enough" means, and a slow machine cannot fail this.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }   // lets the stuck read go, whatever happened
        let problem: String? = await RendererSessionGate.shared.exclusive {
            await runBounded(patience: patience * 3) { () -> String in
                let recorder = Recorder()
                guard let session = try? makeSession(recorder, HeldRenderer()) else { return "the session couldn't be made" }
                // The read: the feeding callback is inside the observer (under the lock it reads with) and stays there.
                let once = Recorder()
                session.enqueueObserver = { _ in
                    once.add(0)
                    if once.all.count == 1 { entered.signal(); release.wait() }
                }
                guard (try? session.prepare(at: 0)) != nil else { return "the session couldn't be prepared" }
                session.play()
                guard entered.wait(timeout: .now() + patience) == .success else { return "the renderer never asked for a buffer" }
                // What the player's engine asks of a session, on a thread of its own, with the read still stuck.
                let answered = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    _ = session.inputExhausted
                    _ = session.finished
                    session.stop()
                    answered.signal()
                }
                if answered.wait(timeout: .now() + patience) == .success { return "" }
                release.signal()
                return "the session waited for a read that wasn't returning, so the player's engine would have too"
            }
        }
        #expect(problem == "", "\(problem ?? "the test's own thread never came back")")
    }
}
