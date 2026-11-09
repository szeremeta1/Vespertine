//
// Vespertine: a pause while the song waits on a quiet share (the output holding in silence for data) says paused, not buffering.
// The rig is the play/pause one (PlayPauseRigSupport.swift); the scenario runs on a thread of its own (RigThreadSupport.swift)
// and waits on conditions; what it saw is judged afterwards.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Paused is not buffering", .serialized)
struct PausedNotBufferingTests {
    private struct Run: Sendable {
        var ranDry = false, silent = false, paused = false
        var buffering = true, end = ""
    }

    @Test("Paused after the output ran dry on a quiet share: the snapshot says paused and not buffering")
    func pausedAfterRunningDry() async throws {
        let rig = try PlayPauseRig()
        rig.share.goQuiet(from: 9 << 20)          // about 16 s into the 24 s song
        defer { rig.share.goQuiet(from: nil) }
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            rig.engine.play(rig.item())
            // Played everything that arrived, and now holds in silence for the share: playing, buffering.
            run.ranDry = rig.scriptWait(timeout: 180) { $0.state == .playing && $0.isBuffering && $0.bufferFill < 0.01 && rig.share.readsWaiting > 0 }
            guard run.ranDry else { return run }
            // And holds in silence: no sound for 300 ms on end (what was left in the device's own buffer has played out).
            let end = Date().addingTimeInterval(60)
            while !run.silent, Date() < end {
                let before = rig.audibleFrames
                rig.scriptSleep(ms: 300)
                run.silent = rig.audibleFrames == before && rig.engine.snapshot.state == .playing
            }
            rig.engine.pause()
            run.paused = rig.scriptWait(timeout: 60) { $0.state == .paused }
            rig.scriptSleep(ms: 300)                // a few snapshots after the pause
            let snapshot = rig.engine.snapshot
            run.buffering = snapshot.isBuffering
            run.end = "\(snapshot.state), buffering \(snapshot.isBuffering), fill \(snapshot.bufferFill)"
            return run
        }
        try #require(run.ranDry, "the song never ran dry on the quiet share")
        #expect(run.silent, "the output was not holding in silence")
        #expect(run.paused, "never paused: \(run.end)")
        #expect(!run.buffering, "paused, yet the snapshot says buffering: \(run.end)")
    }
}
