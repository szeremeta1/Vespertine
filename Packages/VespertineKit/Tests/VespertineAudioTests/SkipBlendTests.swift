//
// Vespertine: with transitions on and skips set to crossfade, every skip blends, at a high rate and with a long crossfade too.
// The blend copies what the ring holds a quarter second ahead of what is heard and takes the ring back there; the output reads
// on meanwhile, and the skip must not fall back to a quick fade because of it.
// The rig is the play/pause one (PlayPauseRigSupport.swift), here with two local songs. The skips run on a thread of their own
// (RigThreadSupport.swift) and wait on conditions; what they saw is judged afterwards.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Skips that crossfade", .serialized)
struct SkipBlendTests {
    private struct Run: Sendable {
        var tries: [String] = []
    }

    @Test("At 96 kHz with a 12 s crossfade, each of four skips blends into the new song")
    func everySkipBlends() async throws {
        let rig = try PlayPauseRig()
        let a = rig.directory.appendingPathComponent("blend-a.wav"), b = rig.directory.appendingPathComponent("blend-b.wav")
        try PlayPauseRig.writeWAV(a, seconds: 24)
        try PlayPauseRig.writeWAV(b, seconds: 24)
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            settings.transitions.enabled = true
            settings.transitions.skip = .crossfade
            settings.transitions.crossfadeSeconds = 12
            rig.engine.update(settings: settings)
            rig.engine.nextItemProvider = { _ in nil }
            rig.engine.play(PlayableItem(url: a))
            for i in 0..<4 {
                // Several seconds in and past any blend, so the ring holds more than the crossfade ahead of what is heard.
                guard rig.scriptWait(timeout: 120, { $0.state == .playing && $0.position >= 4 && $0.signalPath?.transition?.audible != true }) else {
                    run.tries.append("never ready at \(rig.engine.snapshot.position) s")
                    break
                }
                rig.engine.play(PlayableItem(url: i.isMultiple(of: 2) ? b : a))
                // A blend shows CROSSFADE for its 12 s; a quick fade never does.
                let blend = rig.scriptWait(timeout: 30) { $0.signalPath?.transition?.audible == true }
                run.tries.append(blend ? "blend" : "fade")
            }
            return run
        }
        #expect(run.tries == ["blend", "blend", "blend", "blend"], "\(run.tries)")
    }
}
