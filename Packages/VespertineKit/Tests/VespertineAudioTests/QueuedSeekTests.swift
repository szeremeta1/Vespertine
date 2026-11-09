//
// Vespertine: an output change and a seek that reach the engine together, while the song's share has stopped answering. The
// output change reopens the song and waits on the share; the seek right behind it must end that wait and land.
// The scenario runs on a thread of its own (RigThreadSupport.swift) and waits on conditions; it is judged afterwards.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("A seek behind an output change, on a quiet share", .serialized)
struct QueuedSeekTests {
    private struct Run: Sendable {
        var playing = false, waiting = false
        var landed = false, landedAt = "", quietAtLanding = false
        var stopped = false, end = ""
    }

    @Test("An output change and a seek taken together while the share is quiet: the seek lands, and stop still works")
    func seekBehindOutputChange() async throws {
        let rig = try PlayPauseRig()
        rig.share.goQuiet(from: 6 << 20)        // about 10 s in: the read-ahead reaches it soon
        defer { rig.share.goQuiet(from: nil) }
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            settings.transitions.enabled = true            // a pause waits out its fade: the commands after it arrive together
            rig.engine.update(settings: settings)
            rig.engine.play(rig.item())
            run.playing = rig.scriptWait(timeout: 120) { $0.state == .playing && $0.position > 3 }   // well away from where it seeks to
            guard run.playing else { return run }
            // The read-ahead has decoded up to where the share went quiet and waits there for bytes.
            let entry = try rig.cache.entry(key: "song", url: rig.item().url, foreground: false)
            run.waiting = rig.scriptWait(timeout: 120) { _ in entry.isWaiting && rig.share.readsWaiting > 0 }
            guard run.waiting else { return run }
            // While the engine waits out the pause's fade, another output and a seek back to 1 s: one batch.
            rig.engine.pause()
            rig.scriptSleep(ms: 50)
            settings.exclusive = false
            rig.engine.update(settings: settings)
            rig.engine.seek(to: 1)
            run.landed = rig.scriptWait(timeout: 120) { $0.state == .paused && abs($0.position - 1) < 0.5 && $0.item != nil }
            run.landedAt = "\(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s"
            run.quietAtLanding = rig.share.readsWaiting > 0
            rig.engine.stop()
            run.stopped = rig.scriptWait(timeout: 120) { $0.state == .stopped }
            run.end = "\(rig.engine.snapshot.state)"
            return run
        }
        try #require(run.playing, "the song never played from its prefix")
        try #require(run.waiting, "the read-ahead never reached the quiet part of the song")
        #expect(run.landed, "the seek never landed: \(run.landedAt)")
        #expect(run.quietAtLanding, "the share was not quiet any more when the seek landed")
        #expect(run.stopped, "stop got through while the share was quiet: \(run.end)")
    }
}
