//
// Vespertine: a pause pressed right after a play, resume or skip, while the engine thread is busy, so that the engine takes
// them in one batch: the pause is the last thing asked for, and nothing may be heard after it.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine thread and a simulated output that counts sound.
// The presses run on a thread of their own (RigThreadSupport.swift), so they keep their timing when Swift's cooperative threads
// are all held by other tests; what they saw is judged afterwards.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transport commands that arrive together", .serialized)
struct TransportBatchTests {
    private struct Run: Sendable {
        var started = false, reopening = true
        var paused = false, state = PlaybackState.stopped, heardFrames = 0
    }

    @Test("Pause, play, pause within 150 ms with transitions on: nothing but the last pause's fade out is heard, and it ends paused")
    func pauseResumePauseDuringFade() async throws {
        let rig = try PlayPauseRig()
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            settings.transitions.enabled = true
            rig.engine.update(settings: settings)
            rig.engine.play(rig.item())
            run.started = rig.scriptWait(timeout: 120) { $0.state == .playing && !$0.isBuffering } && rig.scriptHears(0.3, timeout: 60)
            guard run.started else { return run }
            // The engine thread waits out the pause's fade (0.4 s), so the play and pause pressed during it reach it together.
            rig.engine.pause()
            rig.scriptSleep(ms: 100); rig.engine.resume(); rig.scriptSleep(ms: 50)
            // The second pause takes the fade over from where it is: from here, at most its 0.4 s are heard (counted in frames,
            // so a slow machine doesn't change it). Starting the output again for the play in between would add its fade in.
            let from = rig.audibleFrames
            rig.engine.pause()
            run.paused = rig.scriptWait(timeout: 60) { $0.state == .paused }
            rig.scriptSleep(ms: 2000)
            run.state = rig.engine.snapshot.state
            run.heardFrames = rig.audibleFrames - from
            return run
        }
        try #require(run.started, "never started")
        #expect(run.paused && run.state == .paused, "state \(run.state)")
        let heard = Double(run.heardFrames) / PlayPauseRig.rate
        #expect(heard < TransitionSettings.pauseFadeSeconds + 0.1, "heard \(heard) s after the last pause; its fade is \(TransitionSettings.pauseFadeSeconds) s")
    }

    @Test("A song chosen and then paused while the output reopens opens paused and is never heard", arguments: [false, true])
    func playThenPause(transitions: Bool) async throws {
        let rig = try PlayPauseRig()
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            settings.transitions.enabled = transitions
            rig.engine.update(settings: settings)
            rig.engine.play(rig.item())
            run.started = rig.scriptWait(timeout: 120) { $0.state == .playing && !$0.isBuffering } && rig.scriptHears(0.3, timeout: 60)
            guard run.started else { return run }
            // The output reopens, slowly (3 s), so the commands pressed meanwhile pile up and reach the engine together.
            rig.openDelay.withLock { $0 = 3 }
            let opened = rig.opens.withLock { $0 }
            settings.exclusive = false
            rig.engine.update(settings: settings)
            _ = rig.scriptWait(timeout: 60) { _ in rig.opens.withLock { $0 } > opened }
            rig.scriptSleep(ms: 200)
            let silentFrom = rig.audibleFrames
            rig.engine.play(rig.item())
            rig.scriptSleep(ms: 30)
            rig.engine.pause()
            // Still inside the reopen when the pause came: nothing was heard since it began (the old output is gone).
            run.reopening = rig.audibleFrames == silentFrom
            run.paused = rig.scriptWait(timeout: 60) { $0.state == .paused }
            rig.scriptSleep(ms: 2500)
            run.state = rig.engine.snapshot.state
            run.heardFrames = rig.audibleFrames - silentFrom
            return run
        }
        try #require(run.started, "never started")
        try #require(run.reopening, "the presses came after the output had reopened")
        #expect(run.paused && run.state == .paused, "state \(run.state)")
        #expect(run.heardFrames == 0, "heard after the pause: \(run.heardFrames * 1000 / Int(PlayPauseRig.rate)) ms")
    }
}
