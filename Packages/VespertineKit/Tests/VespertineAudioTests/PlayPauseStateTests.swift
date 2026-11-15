//
// Vespertine: play and pause pressed quickly, while a song on a share is buffering, opening or being looked ahead for:
// what the engine says (state, buffering, playhead) and what comes out of the output must agree, and the last press wins.
// A rig with the real engine thread, an output that counts the sound it is given, and a share the test slows, stalls or silences.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Play and pause pressed quickly", .serialized)
struct PlayPauseStateTests {
    /// The engine says it is paused and nothing comes out, the playhead stands still.
    private func expectPaused(_ rig: PlayPauseRig, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await rig.sleep(ms: 400)    // the pause fades out, then the output stops
        let o = await rig.observe(0.6)
        #expect(o.state == .paused && !o.audible && !o.moving && !o.buffering, "\(note): \(o)", sourceLocation: sourceLocation)
    }

    /// The engine says it plays, the playhead moves and sound comes out (or it says it is buffering, and says so with the playhead).
    private func expectPlaying(_ rig: PlayPauseRig, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        _ = await rig.wait(timeout: 30) { $0.state == .playing && !$0.isBuffering }
        let o = await rig.observe(0.8)
        #expect(o.state == .playing && o.audible && o.moving, "\(note): \(o)", sourceLocation: sourceLocation)
    }

    /// What one run of the script below saw, to be judged afterwards.
    private struct QuietShareRun: Sendable {
        var ranShort = false
        var short = ""
        var pausedAt = 0.0, positionAfterPause = 0.0
        var whilePaused: Observation?
        var resumedQuiet: Observation?
        var backPlaying: Observation?
        var pausedAgain: Observation?
    }

    @Test("Pause while the share has gone quiet and the song is buffering: it pauses, stays silent, and plays on when asked")
    func pauseDuringBuffering() async throws {
        let rig = try PlayPauseRig()
        // Late enough in the file that a slow start still has its lead: the engine plans the lead from the copy's speed so far
        // (bytes over the time since the copy began), and on a starved machine that looks slow, which would ask for more than the share gives.
        rig.share.goQuiet(from: 9 << 20)
        // The scene is set with the output's clock stopped, so it does not depend on how fast the machine runs: the decoder fills the output
        // buffer from the start of the song up to where the share goes quiet and then waits on the share, while nothing is played away.
        // (Left running, a machine slower than the song's pace drained the buffer first, and "buffering" then meant the output had
        // starved, not that the share was quiet: a pause then had nothing left to play on from.)
        // The presses then come from a thread of its own: once the output runs again the buffer plays out in real time, and a test task
        // resumed late (every cooperative thread held by other tests for a while) would find it empty. The same task also timed out
        // its own wait for the scene while starved, so the waits are on that thread too.
        rig.holdOutput(true)
        let run = await rig.onOwnThread { rig -> QuietShareRun in
            var run = QuietShareRun()
            rig.engine.play(rig.item())
            run.ranShort = rig.waitBlocking(timeout: 120) { $0.state == .playing && $0.isBuffering && rig.share.readsWaiting > 0 && $0.bufferFill > 0.25 }
            let seen = rig.engine.snapshot
            run.short = "\(seen.state), buffering \(seen.isBuffering), \(rig.share.readsWaiting) reads waiting, buffer \(seen.bufferFill), \(rig.elapsed) s in"
            rig.holdOutput(false)
            run.pausedAt = rig.engine.snapshot.position
            rig.engine.pause()
            Thread.sleep(forTimeInterval: 0.4)                // the pause fades out, then the output stops
            run.whilePaused = rig.observeBlocking(0.6)
            run.positionAfterPause = rig.engine.snapshot.position
            rig.engine.resume()
            Thread.sleep(forTimeInterval: 0.3)
            run.resumedQuiet = rig.observeBlocking(0.6)
            rig.share.goQuiet(from: nil)
            _ = rig.waitBlocking(timeout: 60) { $0.state == .playing && !$0.isBuffering }
            run.backPlaying = rig.observeBlocking(0.8)
            rig.engine.pause()
            Thread.sleep(forTimeInterval: 0.4)
            run.pausedAgain = rig.observeBlocking(0.6)
            return run
        }
        #expect(run.ranShort, "the share never went quiet under the song: \(run.short)")
        func paused(_ o: Observation?) -> Bool { o.map { $0.state == .paused && !$0.audible && !$0.moving && !$0.buffering } == true }
        func playing(_ o: Observation?) -> Bool { o.map { $0.state == .playing && $0.audible } == true }
        #expect(paused(run.whilePaused), "paused while buffering: \(String(describing: run.whilePaused))")
        #expect(abs(run.positionAfterPause - run.pausedAt) < 1.5, "the playhead stayed where the pause caught it")
        #expect(playing(run.resumedQuiet), "resumed while the share is still quiet: \(String(describing: run.resumedQuiet))")
        #expect(playing(run.backPlaying) && run.backPlaying?.moving == true, "the share is back: \(String(describing: run.backPlaying))")
        #expect(paused(run.pausedAgain), "paused again: \(String(describing: run.pausedAgain))")
    }

    @Test("Play, pause, play within 100 ms of each other, on a playing song, ends playing; pause, play, pause ends paused")
    func quickPressesWhilePlaying() async throws {
        let rig = try PlayPauseRig()
        rig.engine.play(rig.item())
        await expectPlaying(rig, "started")
        rig.engine.pause(); await rig.sleep(ms: 40); rig.engine.resume(); await rig.sleep(ms: 40); rig.engine.pause()
        await rig.sleep(ms: 20); rig.engine.resume()
        await expectPlaying(rig, "pause, play, pause, play")
        rig.engine.pause(); await rig.sleep(ms: 60); rig.engine.resume(); await rig.sleep(ms: 60); rig.engine.pause()
        await expectPaused(rig, "pause, play, pause")
    }

    @Test("Play and pause pressed while the song is still opening on a slow share: the last press wins, and nothing plays after a pause")
    func quickPressesWhileOpening() async throws {
        let rig = try PlayPauseRig(bytesPerSecond: 3 * 1_048_576)
        rig.engine.play(rig.item())
        await rig.sleep(ms: 500)
        rig.engine.pause(); await rig.sleep(ms: 50); rig.engine.resume(); await rig.sleep(ms: 50); rig.engine.pause()
        let silentFrom = rig.audibleFrames
        await expectPaused(rig, "opened, last press was pause")
        #expect(rig.audibleFrames == silentFrom, "the song started and was heard before its pause was acted on")
        rig.engine.resume(); await rig.sleep(ms: 50); rig.engine.pause(); await rig.sleep(ms: 50); rig.engine.resume()
        await expectPlaying(rig, "last press was play")
    }

    @Test("Pause pressed while the output is being replaced (a speaker group's aggregate takes a while): it never sounds, and plays when asked")
    func pauseWhileSessionReplaced() async throws {
        let rig = try PlayPauseRig()
        rig.engine.play(rig.item())
        await expectPlaying(rig, "started")
        rig.openDelay.withLock { $0 = 1.2 }
        let opened = rig.opens.withLock { $0 }
        var settings = EngineSettings(); settings.deviceUID = "sim-out"; settings.exclusive = false
        rig.engine.update(settings: settings)           // a change of output setting reopens it: replaceSession, slowly
        let replacing = await rig.wait(timeout: 30) { _ in rig.opens.withLock { $0 } > opened }
        #expect(replacing, "the output was never reopened")
        await rig.sleep(ms: 200)                              // inside the slow open: the old output is gone, the new one not there yet
        rig.engine.pause()
        let silentFrom = rig.audibleFrames
        await rig.sleep(ms: 2000)
        #expect(rig.engine.snapshot.state == .paused, "state \(rig.engine.snapshot.state)")
        #expect(rig.audibleFrames == silentFrom, "the new output sounded before the pause was acted on: \((rig.audibleFrames - silentFrom) * 1000 / Int(PlayPauseRig.rate)) ms")
        await expectPaused(rig, "paused during the replace")
        rig.engine.resume()
        await expectPlaying(rig, "resumed")
    }

    /// What the look-ahead run saw, judged afterwards.
    private struct LookAheadRun: Sendable {
        var scene = ""
        var whileFetched: Observation?
        var paused: Observation?
        var pausedAt = 0.0, positionAfter = 0.0
        /// Seconds of sound that came out between the two readings of the playhead.
        var heardSince = 0.0
        var resumed: Observation?
        var endedPaused: Observation?
        var endedPlaying: Observation?
    }

    @Test("While the next song is fetched from a slow share the playing one still shows its playhead, pauses, resumes and loses nothing")
    func lookAheadWait() async throws {
        let rig = try PlayPauseRig(nextBytesPerSecond: 0.7 * 1_048_576)
        let first = rig.item(), next = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? next : nil }
        // The scene is set with the output's clock held and moved by the test, so it does not depend on how fast the machine
        // runs: the song is longer than the output's buffer, so the decoder has all of it (and turns to the next one) only
        // once some of it has played, and that much is played a quarter second at a time, each once it is there. The scene
        // is the next song's fetch under way, and from then on the share sends nothing more until the test is over: the
        // fetch lasts as long as the presses do, however long the machine takes over them. (Left to real time, a test task
        // resumed late found the first song played out, or the next one already fetched.) The presses then come from a
        // thread of its own, as in `pauseDuringBuffering`.
        rig.holdOutput(true)
        let step = Int(PlayPauseRig.rate / 4)
        let run = await rig.onOwnThread { rig -> LookAheadRun in
            defer { rig.nextShare.stall(false) }
            var run = LookAheadRun()
            func readable() -> Int { rig.engine.currentSessionForTesting?.readableFrames ?? 0 }
            func fetching() -> Bool { rig.nextShare.bytesAsked > 0 }
            func note() -> String {
                let seen = rig.engine.snapshot
                return "\(seen.state), buffering \(seen.isBuffering), at \(seen.position) s, \(readable()) frames to play, \(rig.nextShare.bytesAsked) bytes of the next song asked for, \(rig.elapsed) s in"
            }
            rig.engine.play(first)
            guard rig.waitBlocking(timeout: 120, { $0.state == .playing && readable() >= step }) else {
                run.scene = "the song never played: \(note())"
                return run
            }
            // Up to eight seconds of the song (it is 24 s long, the buffer holds under 22): the decoder reaches its end.
            for _ in 0..<32 where !fetching() {
                guard rig.waitBlocking(timeout: 120, { _ in fetching() || readable() >= step }) else { break }
                if !fetching() { rig.outputs.withLock { $0.last }?.advance(seconds: 0.25) }
            }
            guard rig.waitBlocking(timeout: 120, { _ in fetching() }) else {
                run.scene = "the next song was never asked for: \(note())"
                return run
            }
            rig.nextShare.stall(true)
            rig.holdOutput(false)
            guard rig.waitBlocking(timeout: 120, { $0.state == .playing && !$0.isBuffering }) else {
                run.scene = "the song was not playing when its clock was let go: \(note())"
                return run
            }

            // What plays now is the buffered song: the playhead moves with it, and nothing says "buffering" (it is not).
            run.whileFetched = rig.observeBlocking(1.0)
            rig.engine.pause()
            Thread.sleep(forTimeInterval: 0.4)                // the pause fades out, then the output stops
            run.paused = rig.observeBlocking(0.6)
            // The place the pause left the song at, and the sound that has come out so far: what the playhead may move by
            // after this is what is heard after this, whatever the machine does between the two readings.
            run.pausedAt = rig.engine.snapshot.position
            let heard = rig.audibleFrames
            rig.engine.resume()
            Thread.sleep(forTimeInterval: 0.3)
            run.resumed = rig.observeBlocking(1.0)
            run.positionAfter = rig.engine.snapshot.position
            run.heardSince = Double(rig.audibleFrames - heard) / PlayPauseRig.rate

            rig.engine.pause(); Thread.sleep(forTimeInterval: 0.06); rig.engine.resume(); Thread.sleep(forTimeInterval: 0.06); rig.engine.pause()
            Thread.sleep(forTimeInterval: 0.4)
            run.endedPaused = rig.observeBlocking(0.6)
            rig.engine.resume(); Thread.sleep(forTimeInterval: 0.08); rig.engine.pause(); Thread.sleep(forTimeInterval: 0.08); rig.engine.resume()
            _ = rig.waitBlocking(timeout: 30) { $0.state == .playing && !$0.isBuffering }
            run.endedPlaying = rig.observeBlocking(0.8)
            return run
        }
        #expect(run.scene == "", "\(run.scene)")
        guard run.scene == "" else { return }
        func paused(_ o: Observation?) -> Bool { o.map { $0.state == .paused && !$0.audible && !$0.moving && !$0.buffering } == true }
        func playing(_ o: Observation?) -> Bool { o.map { $0.state == .playing && $0.audible && $0.moving } == true }
        #expect(playing(run.whileFetched) && run.whileFetched?.buffering == false, "while the next song is fetched: \(String(describing: run.whileFetched))")
        #expect(paused(run.paused), "paused during the fetch: \(String(describing: run.paused))")
        #expect(playing(run.resumed), "resumed during the fetch: \(String(describing: run.resumed))")
        #expect(run.positionAfter - run.pausedAt < run.heardSince + 0.75,
                "the paused song lost its place: paused at \(run.pausedAt), at \(run.positionAfter) after \(run.heardSince) s of sound")
        #expect(paused(run.endedPaused), "quick presses during the fetch ending on pause: \(String(describing: run.endedPaused))")
        #expect(playing(run.endedPlaying), "quick presses during the fetch ending on play: \(String(describing: run.endedPlaying))")
    }

    @Test("Random presses of play and pause against a slow share and a slow output settle on the last one")
    func lastPressWins() async throws {
        for seed in 0..<4 {
            // Everything random is drawn here, in the order it always was; the script below only carries it out.
            var rng = SeededRandom(state: UInt64(seed) &* 7919 &+ 1)
            let rate = Double.random(in: 1.5...6, using: &rng) * 1_048_576
            let openDelay = Double.random(in: 0...1, using: &rng)
            let startAfter = Int.random(in: 200...2000, using: &rng)
            var presses: [(play: Bool, gap: Int)] = []
            for _ in 0..<Int.random(in: 3...8, using: &rng) {
                let play = Bool.random(using: &rng)
                presses.append((play, Bool.random(using: &rng) ? Int.random(in: 0...150, using: &rng) : Int.random(in: 300...1200, using: &rng)))
            }
            let rig = try PlayPauseRig(bytesPerSecond: rate)
            var settings = EngineSettings(); settings.deviceUID = "sim-out"; settings.exclusive = true
            settings.releaseExclusiveAfterPause = 0.3      // a pause of a moment lets the output go: resuming reopens it
            rig.engine.update(settings: settings)
            rig.openDelay.withLock { $0 = openDelay }
            let sequence = presses
            // The song is 24 s long and the presses take up to 10 s: from a test task resumed late (every cooperative thread held
            // by other tests) the presses would come after the song had ended. They come from a thread of its own instead.
            let (last, settledOn, o) = await rig.onOwnThread { rig -> (Bool, Bool, Observation) in
                rig.engine.play(rig.item())
                Thread.sleep(forTimeInterval: Double(startAfter) / 1000)
                var last = true
                for press in sequence {
                    last = press.play
                    if last { rig.engine.resume() } else { rig.engine.pause() }
                    Thread.sleep(forTimeInterval: Double(press.gap) / 1000)
                }
                // The end state has to settle (a share to catch up, an output to reopen, a fade to finish) and then hold.
                let settled = last
                    ? rig.settledBlocking(timeout: 60, hold: 0.5) { $0.state == .playing && !$0.isBuffering }
                    : rig.settledBlocking(timeout: 60, hold: 1.2) { $0.state == .paused }
                return (last, settled, rig.observeBlocking(1.0))
            }
            let note = "seed \(seed): \(sequence.map { "\($0.play ? "play" : "pause") +\($0.gap)ms" }.joined(separator: ", ")) → \(o)"
            #expect(settledOn, "the end state never settled: \(note)")
            if last { #expect(o.state == .playing && o.audible && o.moving, "\(note)") }
            else { #expect(o.state == .paused && !o.audible && !o.moving, "\(note)") }
        }
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state ^ (state >> 29) }
}
