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

    /// Move through sample time, holding the output between observations. A busy runner cannot play past the badge
    /// while the script waits to be scheduled. Wall-clock patience only bounds work that must eventually complete.
    private func advance(_ rig: PlayPauseRig, seconds: Double, settling item: UUID? = nil,
                         until condition: (EngineSnapshot) -> Bool) -> Bool {
        for _ in 0..<Int(seconds * 4) {
            if condition(rig.engine.snapshot) { return true }
            // The badge has a minimum wall-clock hold too. Once the incoming song is past its 12 s overlap,
            // let that hold expire with the output frozen instead of consuming the rest of the song.
            if let item, rig.engine.snapshot.item?.id == item,
               rig.engine.snapshot.position >= 12, rig.engine.snapshot.signalPath?.transition?.audible == true,
               rig.scriptWait(timeout: 10, condition) { return true }
            guard rig.scriptWait(timeout: 120, { _ in
                (rig.engine.currentSessionForTesting?.readableFrames ?? 0) >= Int(PlayPauseRig.rate / 4)
            }), let output = rig.outputs.withLock({ $0.last }) else { return false }
            let before = rig.engine.snapshot
            output.advance(seconds: 0.25)
            guard rig.scriptWait(timeout: 120, {
                $0.position != before.position || $0.item?.id != before.item?.id
            }) else { return false }
        }
        return condition(rig.engine.snapshot)
    }

    @Test("At 96 kHz with a 12 s crossfade, each of four skips blends into the new song")
    func everySkipBlends() async throws {
        let rig = try PlayPauseRig()
        let aURL = rig.directory.appendingPathComponent("blend-a.wav"), bURL = rig.directory.appendingPathComponent("blend-b.wav")
        try PlayPauseRig.writeWAV(aURL, seconds: 24)
        try PlayPauseRig.writeWAV(bURL, seconds: 24)
        // Explicitly resolved local sources avoid an unrelated volume query on GCD's pool, which other suites stall.
        let a = PlayableItem(url: URL(fileURLWithPath: "/test/blend-a.wav"), cacheKey: "blend-a")
        let b = PlayableItem(url: URL(fileURLWithPath: "/test/blend-b.wav"), cacheKey: "blend-b")
        rig.engine.urlResolver = { $0.id == a.id ? aURL : bURL }
        rig.holdOutput(true)
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
            rig.engine.play(a)
            guard rig.scriptWait(timeout: 120, { $0.state == .playing
                && (rig.engine.currentSessionForTesting?.readableFrames ?? 0) >= Int(20 * PlayPauseRig.rate) }) else {
                run.tries.append("initial song never buffered")
                return run
            }
            for i in 0..<4 {
                // Several seconds in and past any blend, so the ring holds more than the crossfade ahead of what is heard.
                guard advance(rig, seconds: 20, settling: i.isMultiple(of: 2) ? a.id : b.id,
                              until: { $0.state == .playing && $0.position >= 4 && $0.signalPath?.transition?.audible != true }) else {
                    run.tries.append("never ready at \(rig.engine.snapshot.position) s")
                    break
                }
                rig.engine.play(i.isMultiple(of: 2) ? b : a)
                // Wait for the skip to be handled before advancing its clock.
                guard rig.engine.waitForCommandsForTesting(timeout: 120) else {
                    run.tries.append("skip never handled")
                    break
                }
                // A blend shows CROSSFADE for its 12 s; a quick fade never does.
                let blend = advance(rig, seconds: 2, until: { $0.signalPath?.transition?.audible == true })
                run.tries.append(blend ? "blend" : "fade")
            }
            return run
        }
        #expect(run.tries == ["blend", "blend", "blend", "blend"], "\(run.tries)")
    }
}
