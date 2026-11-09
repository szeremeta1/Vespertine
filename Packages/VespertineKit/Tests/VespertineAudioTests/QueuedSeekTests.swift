//
// Vespertine: an output change and a seek that reach the engine together, while the song's share has stopped answering. The
// output change reopens the song and waits on the share; the seek right behind it must end that wait and land.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("A seek behind an output change, on a quiet share", .serialized)
struct QueuedSeekTests {
    @Test("An output change and a seek taken together while the share is quiet: the seek lands, and stop still works")
    func seekBehindOutputChange() async throws {
        let rig = try PlayPauseRig()
        rig.share.goQuiet(from: 6 << 20)        // about 10 s in: the read-ahead reaches it soon
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = true
        settings.transitions.enabled = true            // a pause waits out its fade: the commands after it arrive together
        rig.engine.update(settings: settings)
        rig.engine.play(rig.item())
        let playing = await rig.wait(timeout: 60) { $0.state == .playing && $0.position > 3 }   // well away from where it seeks to
        #expect(playing, "the song played from its prefix")
        // The read-ahead has decoded up to where the share went quiet and waits there for bytes.
        let staged = try rig.cache.entry(key: "song", url: rig.item().url, foreground: false)
        var waiting = false
        for _ in 0..<600 where !waiting {
            if staged.isWaiting, rig.share.readsWaiting > 0 {
                await rig.sleep(ms: 200)
                waiting = staged.isWaiting
            } else {
                await rig.sleep(ms: 50)
            }
        }
        #expect(waiting, "the read-ahead reached the quiet part of the song")

        // While the engine waits out the pause's fade, another output and a seek back to 1 s: one batch.
        rig.engine.pause()
        await rig.sleep(ms: 50)
        settings.exclusive = false
        rig.engine.update(settings: settings)
        rig.engine.seek(to: 1)
        let landed = await rig.wait(timeout: 15) { $0.state == .paused && abs($0.position - 1) < 0.5 && $0.item != nil }
        #expect(rig.share.readsWaiting > 0, "the share was still quiet")
        #expect(landed, "the seek never landed: \(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s")
        rig.engine.stop()
        let stopped = await rig.wait(timeout: 30) { $0.state == .stopped }
        #expect(stopped, "stop got through while the share was quiet: \(rig.engine.snapshot.state)")
        rig.share.goQuiet(from: nil)
    }
}
