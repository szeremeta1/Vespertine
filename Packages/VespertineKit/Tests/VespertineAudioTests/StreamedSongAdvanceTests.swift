//
// Vespertine: a FLAC that plays from a share while it is still being copied (it started on a prefix) is read through the cache's
// input source up to its last frame. When that source did not say where the file ends, the decoder asked it for more for ever: the
// song never ended, the queue never moved on, and once the ring was played out every empty buffer counted as an underrun.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine, a simulated output, a share the test controls.
// Nothing here is timed. The output's clock is held and the test moves it a quarter second at a time, each step only once the
// engine has that much to play, so the song is over when the test has played it out and no step can find the buffer empty
// because the machine was slow. The only clock is a patience on each thing the engine must get round to: it ends a hung run
// (the fault this guards against is a song that never ends) and decides nothing else.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("A streamed song ends and the queue moves on", .serialized)
struct StreamedSongAdvanceTests {
    /// What the run saw, judged afterwards.
    private struct Run: Sendable {
        var problem: String?
        var advanced = false
        var underruns = 0
        var end = ""
    }

    private static let patience = 120.0
    private static let step = Int(PlayPauseRig.rate / 4)

    @Test("A FLAC started on a prefix plays to its end and the next song follows by itself, without a single underrun")
    func flacStreamedToItsEnd() async throws {
        // 40 s of 96 kHz FLAC: above the size that starts on a prefix; the share is quick, so the copy is whole well before the song
        // ends, but the decoder opened on the prefix keeps reading through the cache.
        let seconds = 40
        let rig = try PlayPauseRig(seconds: seconds, bytesPerSecond: 6 * 1_048_576, fileExtension: "flac")
        try #require(NetworkStart.startsEarly(fileExtension: "flac", size: rig.share.size, isRegion: false), "the song starts on a prefix")
        let first = rig.item(), second = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? second : nil }
        rig.holdOutput(true)
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            func readable() -> Int { rig.engine.currentSessionForTesting?.readableFrames ?? 0 }
            // The engine has been round its loop twice: what the output did before this is in the snapshot.
            func settled() -> Bool {
                rig.engine.waitForCommandsForTesting(timeout: Self.patience) && rig.engine.waitForCommandsForTesting(timeout: Self.patience)
            }
            func arrived() -> Bool {
                let now = rig.engine.snapshot
                return now.item?.id == second.id && now.state == .playing
            }
            func note() -> String {
                let now = rig.engine.snapshot
                return "\(now.state) in \(now.item?.url.lastPathComponent ?? "no song") at \(now.position) s, \(readable()) frames to play"
            }
            rig.engine.play(first)
            guard rig.scriptWait(timeout: Self.patience, { $0.state == .playing && readable() >= Self.step }) else {
                run.problem = "the first song never played: \(note())"
                return run
            }
            // The song, a quarter second at a time, each one only when it is there to be played, and on into the next song
            // (the engine says a song is the one playing once the output has reached it). A song that never ends leaves less
            // than a step to play and nothing after it: the wait for the step is where that shows.
            var steps = 0
            while !arrived() {
                guard steps < seconds * 4 + 40 else {
                    run.problem = "the next song had not started after \(steps) steps: \(note())"
                    return run
                }
                guard rig.scriptWait(timeout: Self.patience, { _ in readable() >= Self.step }) else {
                    run.problem = "the output ran out of song after \(steps) steps: \(note())"
                    return run
                }
                // The output the engine plays into now, running: a step of a stopped one moves nothing and is not counted.
                var stepped = false
                _ = rig.scriptWait(timeout: Self.patience) { _ in
                    stepped = rig.outputs.withLock { $0.last }?.advance(seconds: 0.25) == true
                    return stepped
                }
                guard stepped else { run.problem = "the output was not running after \(steps) steps: \(note())"; return run }
                steps += 1
                guard settled() else { run.problem = "the engine stopped answering after \(steps) steps: \(note())"; return run }
            }
            run.advanced = true
            run.underruns = rig.engine.snapshot.underruns
            run.end = note()
            return run
        }
        #expect(run.problem == nil, "\(run.problem ?? "")")
        guard run.problem == nil else { return }
        #expect(run.advanced, "the next song never started: \(run.end)")
        #expect(run.underruns == 0, "\(run.underruns) underruns")
    }
}
