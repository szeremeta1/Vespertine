//
// Vespertine: with transitions on and skips set to crossfade, every skip blends, at a high rate and with a long crossfade too.
// The blend copies what the ring holds a quarter second ahead of what is heard and takes the ring back there; the output reads
// on meanwhile, and the skip must not fall back to a quick fade because of it.
// The rig is the play/pause one (PlayPauseRigSupport.swift), here with two local songs.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Skips that crossfade", .serialized)
struct SkipBlendTests {
    @Test("At 96 kHz with a 12 s crossfade, each of four skips blends into the new song")
    func everySkipBlends() async throws {
        let rig = try PlayPauseRig()
        let a = rig.directory.appendingPathComponent("blend-a.wav"), b = rig.directory.appendingPathComponent("blend-b.wav")
        try PlayPauseRig.writeWAV(a, seconds: 24)
        try PlayPauseRig.writeWAV(b, seconds: 24)
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = true
        settings.transitions.enabled = true
        settings.transitions.skip = .crossfade
        settings.transitions.crossfadeSeconds = 12
        rig.engine.update(settings: settings)
        rig.engine.nextItemProvider = { _ in nil }
        var blended = 0, tries: [String] = []
        rig.engine.play(PlayableItem(url: a))
        for i in 0..<4 {
            // Several seconds in and past any blend, so the ring holds more than the crossfade ahead of what is heard.
            let ready = await rig.wait(timeout: 30) { $0.state == .playing && $0.position >= 4 && $0.signalPath?.transition?.audible != true }
            #expect(ready, "skip \(i): never ready, at \(rig.engine.snapshot.position) s")
            rig.engine.play(PlayableItem(url: i.isMultiple(of: 2) ? b : a))
            let blend = await rig.wait(timeout: 3) { $0.signalPath?.transition?.audible == true }
            if blend { blended += 1 }
            tries.append(blend ? "blend" : "fade")
        }
        #expect(blended == 4, "\(tries)")
    }
}
