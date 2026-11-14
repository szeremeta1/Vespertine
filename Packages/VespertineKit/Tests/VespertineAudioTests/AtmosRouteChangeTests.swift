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

/// Plays the fixture silently until the reader is past 0.7 s; nil: it never was, or the session couldn't be made.
private func playedPast(_ session: SystemRendererSession, _ recorder: Recorder) -> Bool {
    // The renderer keeps only about a second queued, so it has to play to take more.
    session.play()
    let deadline = Date().addingTimeInterval(60)
    while (recorder.all.last ?? 0) - (recorder.all.first ?? 0) < 0.7, !session.inputExhausted, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return (recorder.all.last ?? 0) - (recorder.all.first ?? 0) >= 0.7
}

private func makeSession(_ recorder: Recorder) throws -> SystemRendererSession {
    let url = fixture("dolby-digital-plus-tones.m4a")
    let session = try SystemRendererSession(item: PlayableItem(url: url), url: url,
                                            deviceUID: DeviceQuery.outputUIDs().sorted().first, spatial: false, volume: 0)
    session.enqueueObserver = { buffer in
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if pts.isValid { recorder.add(CMTimeGetSeconds(pts)) }
    }
    return session
}

// Each test takes its turn at the renderer (`RendererSessionGate`) and runs the session on a thread of its own, waited for
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
                    let session = try makeSession(recorder)
                    try session.prepare(at: 0)
                    defer { session.stop() }
                    guard playedPast(session, recorder) else { fed.problem = "the renderer took only \(recorder.all.count) buffers"; return fed }
                    fed.before = recorder.all
                    // macOS flushes it at 0.2 s into the song, as it does when the route changes.
                    fed.flushTime = fed.before[0] + 0.2
                    NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: session.renderer,
                                                    userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(seconds: fed.flushTime, preferredTimescale: 48_000))])
                    let wait = Date().addingTimeInterval(20)
                    while recorder.all.count == fed.before.count, Date() < wait { Thread.sleep(forTimeInterval: 0.02) }
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
                    let session = try makeSession(recorder)
                    try session.prepare(at: 0)
                    defer { session.stop() }
                    guard playedPast(session, recorder) else { fed.problem = "the renderer took only \(recorder.all.count) buffers"; return fed }
                    fed.before = recorder.all
                    fed.flushTime = fed.before[0] + 0.1
                    NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: AVSampleBufferAudioRenderer(),
                                                    userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(seconds: fed.flushTime, preferredTimescale: 48_000))])
                    Thread.sleep(forTimeInterval: 0.5)
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
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }   // lets the stuck read go, whatever happened
        let answered: Bool? = await RendererSessionGate.shared.exclusive {
            let recorder = Recorder()
            // The read: the feeding callback is inside the observer (under the lock it reads with) and stays there.
            let session = await runBounded(patience: patience) { () -> SystemRendererSession? in
                guard let session = try? makeSession(recorder) else { return nil }
                let once = Recorder()
                session.enqueueObserver = { _ in
                    once.add(0)
                    if once.all.count == 1 { entered.signal(); _ = release.wait(timeout: .now() + 120) }
                }
                guard (try? session.prepare(at: 0)) != nil else { return nil }
                session.play()
                return entered.wait(timeout: .now() + 60) == .success ? session : nil
            } ?? nil
            guard let session else { return nil }
            // The read is held for 120 s: answering in well under that shows the session didn't wait for it. Not 10 s: three
            // calls took longer than that once, on a machine that had just let every test go at the same moment.
            return await runBounded(patience: 45) {
                _ = session.inputExhausted
                _ = session.finished
                session.stop()
                return true
            }
        }
        #expect(answered == true, "the session waited for a read that wasn't returning, so the player's engine would have too")
    }
}
