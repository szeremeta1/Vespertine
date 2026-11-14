//
// Vespertine: the song after the one that plays is on a share too slow to have its start ready when the one that plays ends
// (a link slower than the music: the song that plays keeps the whole link until its own copy is whole, so the next one's copy
// only starts then). The output has nothing to play while the next song's first bytes arrive. That wait is a wait for the
// network: it says so ("Buffering from the network…") and it is not a buffer underrun. It used to say nothing and count every
// empty output buffer as an underrun: thousands in one wait.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine, a simulated output, a share the test controls.
// Nothing here is timed. The output's clock is held and the test moves it a quarter second at a time, each step only once the
// engine has what the step will play; the next song's share is not slow but stopped, until the test lets it go. So the first
// song is over exactly when the test has played it out, the wait lasts exactly the three seconds the test steps through, and
// a machine that stands still for a minute changes none of it. The only clock is a patience of two minutes on each thing the
// engine must get round to, which ends a hung run and decides nothing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("The next song's share is slower than the music", .serialized)
struct SlowNextSongTests {
    /// What a run saw, judged afterwards.
    private struct Run: Sendable {
        var problem: String?
        var buffering = false
        /// Underruns counted when the output had run three seconds with nothing to play.
        var duringWait = 0
        var advanced = false
        var afterWait = 0
        var bufferingAfter = true
        var end = ""
    }

    private static let patience = 120.0
    private static let step = Int(PlayPauseRig.rate / 4)

    /// Plays `first` out and into the wait for `second`, whose share stands still, then lets the share go and plays into `second`.
    private func run(_ rig: PlayPauseRig, seconds: Int) async throws -> Run {
        let first = rig.item(), second = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? second : nil }
        rig.nextShare.stall(true)
        rig.holdOutput(true)
        let song = Int(PlayPauseRig.rate) * seconds
        return try await rig.runScript { rig -> Run in
            defer { rig.nextShare.stall(false) }
            var run = Run()
            func readable() -> Int { rig.engine.currentSessionForTesting?.readableFrames ?? 0 }
            // The engine has been round its loop twice: what the output did before this is in the snapshot.
            func settled() -> Bool {
                rig.engine.waitForCommandsForTesting(timeout: Self.patience) && rig.engine.waitForCommandsForTesting(timeout: Self.patience)
            }
            rig.engine.play(first)
            guard rig.scriptWait(timeout: Self.patience, { $0.state == .playing && readable() >= Self.step }),
                  let output = rig.outputs.withLock({ $0.last }) else {
                run.problem = "the first song never played: \(rig.engine.snapshot.state)"
                return run
            }
            // The first song, a quarter second at a time, each one only when it is there to be played (or is all that is left).
            var steps = 0
            while song - rig.audibleFrames > Self.step / 5 {
                guard steps < seconds * 4 + 40,
                      rig.scriptWait(timeout: Self.patience, { _ in readable() >= Self.step || song - rig.audibleFrames - readable() <= Self.step / 5 }) else {
                    run.problem = "the first song stopped \(song - rig.audibleFrames) frames short, with \(readable()) to play, after \(steps) steps"
                    return run
                }
                output.advance(seconds: 0.25)
                steps += 1
            }
            // Three seconds of the output asking and getting nothing.
            for _ in 0..<12 { output.advance(seconds: 0.25) }
            run.buffering = rig.scriptWait(timeout: Self.patience) { $0.isBuffering }
            guard settled() else { run.problem = "the engine stopped answering during the wait"; return run }
            run.duringWait = rig.engine.snapshot.underruns

            // The share answers: the next song starts by itself, and the wait has still counted nothing.
            rig.nextShare.stall(false)
            // The engine says a song is the one playing once the output has reached it, so the steps wait only for sound to play.
            func arrived() -> Bool {
                let now = rig.engine.snapshot
                return now.item?.id == second.id && now.state == .playing && now.position > 0.5
            }
            for _ in 0..<12 where !arrived() {
                guard rig.scriptWait(timeout: Self.patience, { _ in readable() >= Self.step }) else { break }
                output.advance(seconds: 0.25)
                guard settled() else { run.problem = "the engine stopped answering after the wait"; return run }
            }
            run.advanced = arrived()
            let snapshot = rig.engine.snapshot
            run.afterWait = snapshot.underruns
            run.bufferingAfter = snapshot.isBuffering
            run.end = "\(snapshot.state) in \(snapshot.item?.url.lastPathComponent ?? "no song") at \(snapshot.position) s"
            return run
        }
    }

    private func judge(_ run: Run) {
        #expect(run.problem == nil, "\(run.problem ?? "")")
        guard run.problem == nil else { return }
        #expect(run.buffering, "the wait for the next song's bytes shows as buffering from the network")
        #expect(run.duringWait == 0, "\(run.duringWait) underruns counted during the wait")
        #expect(run.advanced, "the next song started: \(run.end)")
        #expect(run.afterWait == 0, "\(run.afterWait) underruns after the wait")
        #expect(!run.bufferingAfter, "no longer buffering once it plays")
    }

    @Test("Waiting for the next song's first bytes shows as buffering and counts no underruns")
    func waitForNextSongIsBufferingNotUnderruns() async throws {
        // 24 s of 96 kHz WAV starts on a prefix (4 MB), and none of the next song's is there when the first one ends.
        let rig = try PlayPauseRig(seconds: 24)
        try #require(NetworkStart.startsEarly(fileExtension: "wav", size: rig.share.size, isRegion: false), "the songs start on a prefix")
        judge(try await run(rig, seconds: 24))
    }

    @Test("A next song that is copied whole first (a small file) arrives late: the wait counts no underruns either")
    func waitForWholeCopyCountsNoUnderruns() async throws {
        // 20 s of 96 kHz WAV is under the size that starts on a prefix: the next song plays from its whole copy (not streamed),
        // and that copy has not begun when the first song ends.
        let rig = try PlayPauseRig(seconds: 20)
        try #require(!NetworkStart.startsEarly(fileExtension: "wav", size: rig.share.size, isRegion: false), "the songs are copied whole")
        judge(try await run(rig, seconds: 20))
    }
}
