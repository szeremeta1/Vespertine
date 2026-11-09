//
// Vespertine: a pause pressed right after a play, resume or skip, while the engine thread is busy, so that the engine takes
// them in one batch: the pause is the last thing asked for, and nothing may be heard after it.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine thread and a simulated output that counts sound.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transport commands that arrive together", .serialized)
struct TransportBatchTests {
    /// Plays the rig's song with transitions on or off, then makes the output reopen slowly (1.2 s), so the commands pressed
    /// meanwhile pile up and reach the engine together. Returns once the reopen has begun.
    private func reopening(transitions: Bool) async throws -> (PlayPauseRig, EngineSettings) {
        let rig = try PlayPauseRig()
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = true
        settings.transitions.enabled = transitions
        rig.engine.update(settings: settings)
        rig.engine.play(rig.item())
        _ = await rig.wait(timeout: 30) { $0.state == .playing && !$0.isBuffering }
        let o = await rig.observe(0.6)
        #expect(o.state == .playing && o.audible, "never started: \(o)")
        rig.openDelay.withLock { $0 = 1.2 }
        let opened = rig.opens.withLock { $0 }
        settings.exclusive = false                     // reopens the output, slowly
        rig.engine.update(settings: settings)
        let replacing = await rig.wait(timeout: 30) { _ in rig.opens.withLock { $0 } > opened }
        #expect(replacing, "the output was never reopened")
        await rig.sleep(ms: 200)
        return (rig, settings)
    }

    @Test("Pause, play, pause within 150 ms with transitions on: nothing but the last pause's fade out is heard, and it ends paused")
    func pauseResumePauseDuringFade() async throws {
        let rig = try PlayPauseRig()
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = true
        settings.transitions.enabled = true
        rig.engine.update(settings: settings)
        rig.engine.play(rig.item())
        _ = await rig.wait(timeout: 30) { $0.state == .playing && !$0.isBuffering }
        let o = await rig.observe(0.6)
        #expect(o.state == .playing && o.audible, "never started: \(o)")
        // The engine thread waits out the pause's fade (0.4 s), so the play and pause pressed during it reach it together.
        rig.engine.pause()
        await rig.sleep(ms: 100); rig.engine.resume(); await rig.sleep(ms: 50)
        // The second pause takes the fade over from where it is: from here, at most its 0.4 s are heard (counted in frames,
        // so a slow machine doesn't change it). Starting the output again for the play in between would add its fade in.
        let from = rig.audibleFrames
        rig.engine.pause()
        await rig.sleep(ms: 2000)
        #expect(rig.engine.snapshot.state == .paused, "state \(rig.engine.snapshot.state)")
        let heard = Double(rig.audibleFrames - from) / PlayPauseRig.rate
        #expect(heard < TransitionSettings.pauseFadeSeconds + 0.1, "heard \(heard) s after the last pause; its fade is \(TransitionSettings.pauseFadeSeconds) s")
    }

    @Test("A song chosen and then paused while the output reopens opens paused and is never heard", arguments: [false, true])
    func playThenPause(transitions: Bool) async throws {
        let (rig, _) = try await reopening(transitions: transitions)
        rig.engine.play(rig.item())
        await rig.sleep(ms: 30)
        rig.engine.pause()
        let silentFrom = rig.audibleFrames
        await rig.sleep(ms: 2500)
        #expect(rig.engine.snapshot.state == .paused, "state \(rig.engine.snapshot.state)")
        #expect(rig.audibleFrames == silentFrom, "heard after the pause: \((rig.audibleFrames - silentFrom) * 1000 / Int(PlayPauseRig.rate)) ms")
    }
}
