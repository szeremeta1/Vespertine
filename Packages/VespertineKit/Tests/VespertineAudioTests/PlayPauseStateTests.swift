//
// Vespertine — play and pause pressed quickly, while a song on a share is buffering, opening or being looked ahead for:
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

    @Test("Pause while the share has gone quiet and the song is buffering: it pauses, stays silent, and plays on when asked")
    func pauseDuringBuffering() async throws {
        let rig = try PlayPauseRig()
        // Late enough in the file that a slow start still has its lead: the engine plans the lead from the copy's speed so far
        // (bytes over the time since the copy began), and on a starved machine that looks slow, which would ask for more than the share gives.
        rig.share.goQuiet(from: 9 << 20)
        rig.engine.play(rig.item())
        let ranShort = await rig.wait(timeout: 40) { $0.state == .playing && $0.isBuffering }
        let seen = rig.engine.snapshot
        #expect(ranShort, "the song never ran short of data: \(seen.state), buffering \(seen.isBuffering), at \(seen.position) s, \(rig.audibleFrames) frames heard, \(rig.elapsed) s in")
        let before = rig.engine.snapshot.position
        rig.engine.pause()
        await expectPaused(rig, "paused while buffering")
        #expect(abs(rig.engine.snapshot.position - before) < 1.5, "the playhead stayed where the pause caught it")
        rig.engine.resume()
        await rig.sleep(ms: 300)
        let o = await rig.observe(0.6)
        #expect(o.state == .playing && o.audible, "resumed while the share is still quiet: \(o)")
        rig.share.goQuiet(from: nil)
        await expectPlaying(rig, "the share is back")
        rig.engine.pause()
        await expectPaused(rig, "paused again")
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

    @Test("While the next song is fetched from a slow share the playing one still shows its playhead, pauses, resumes and loses nothing")
    func lookAheadWait() async throws {
        let rig = try PlayPauseRig(nextBytesPerSecond: 0.7 * 1_048_576)
        let first = rig.item(), next = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? next : nil }
        rig.engine.play(first)
        await expectPlaying(rig, "started")
        await rig.sleep(ms: 1500)      // the decoder has the whole song, and is now waiting for the next one
        // What plays now is the buffered song: the playhead moves with it, and nothing says "buffering" (it is not).
        let o = await rig.observe(1.0)
        #expect(o.state == .playing && o.audible && o.moving && !o.buffering, "while the next song is fetched: \(o)")
        rig.engine.pause()
        await rig.sleep(ms: 500)
        let pausedAt = rig.engine.snapshot.position
        await expectPaused(rig, "paused during the fetch")
        rig.engine.resume()
        await rig.sleep(ms: 300)
        let after = await rig.observe(1.0)
        #expect(after.state == .playing && after.audible && after.moving, "resumed during the fetch: \(after)")
        #expect(rig.engine.snapshot.position - pausedAt < 2.5, "the paused song lost its place: paused at \(pausedAt), now \(rig.engine.snapshot.position)")
        rig.engine.pause(); await rig.sleep(ms: 60); rig.engine.resume(); await rig.sleep(ms: 60); rig.engine.pause()
        await expectPaused(rig, "quick presses during the fetch ending on pause")
        rig.engine.resume(); await rig.sleep(ms: 80); rig.engine.pause(); await rig.sleep(ms: 80); rig.engine.resume()
        await expectPlaying(rig, "quick presses during the fetch ending on play")
    }

    @Test("Random presses of play and pause against a slow share and a slow output settle on the last one")
    func lastPressWins() async throws {
        for seed in 0..<4 {
            var rng = SeededRandom(state: UInt64(seed) &* 7919 &+ 1)
            let rig = try PlayPauseRig(bytesPerSecond: Double.random(in: 1.5...6, using: &rng) * 1_048_576)
            var settings = EngineSettings(); settings.deviceUID = "sim-out"; settings.exclusive = true
            settings.releaseExclusiveAfterPause = 0.3      // a pause of a moment lets the output go: resuming reopens it
            rig.engine.update(settings: settings)
            rig.openDelay.withLock { $0 = Double.random(in: 0...1, using: &rng) }
            rig.engine.play(rig.item())
            await rig.sleep(ms: Int.random(in: 200...2000, using: &rng))
            var last = true, presses: [String] = []
            for _ in 0..<Int.random(in: 3...8, using: &rng) {
                last = Bool.random(using: &rng)
                if last { rig.engine.resume() } else { rig.engine.pause() }
                let gap = Bool.random(using: &rng) ? Int.random(in: 0...150, using: &rng) : Int.random(in: 300...1200, using: &rng)
                presses.append("\(last ? "play" : "pause") +\(gap)ms")
                await rig.sleep(ms: gap)
            }
            _ = await rig.wait(timeout: 8) { $0.state != .stopped && !$0.isBuffering }
            await rig.sleep(ms: 1200)
            let o = await rig.observe(1.0)
            let note = "seed \(seed): \(presses.joined(separator: ", ")) → \(o)"
            if last { #expect(o.state == .playing && o.audible && o.moving, "\(note)") }
            else { #expect(o.state == .paused && !o.audible && !o.moving, "\(note)") }
        }
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state ^ (state >> 29) }
}
