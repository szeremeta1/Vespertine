//
// Vespertine — a seek or an output change while the song's share has stopped answering must not take the engine with it:
// a stop (or a skip) pressed after it still gets through while the share stays quiet.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Commands while the share is quiet", .serialized)
struct StalledShareCommandTests {
    /// The staged copy of the rig's song (the one the engine holds).
    private func entry(_ rig: PlayPauseRig) throws -> NetworkPlaybackCache.Entry {
        try rig.cache.entry(key: "song", url: rig.item().url, foreground: false)
    }

    @Test("A seek into a part of a FLAC the share has not sent yet gives way to stop while the share stays quiet")
    func seekIntoQuietPartThenStop() async throws {
        let rig = try PlayPauseRig(seconds: 40, fileExtension: "flac")
        let size = rig.share.size
        #expect(NetworkStart.startsEarly(fileExtension: "flac", size: size, isRegion: false), "the song starts on a prefix (\(size) bytes)")
        let quietFrom = Int64(9 << 20)
        rig.share.goQuiet(from: quietFrom)
        rig.engine.play(rig.item())
        let playing = await rig.wait(timeout: 60) { $0.state == .playing && $0.position > 0.5 }
        #expect(playing, "the song played from its prefix: \(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s")

        // Near the end: bytes the share will not send while it is quiet. The engine opens the song again there.
        rig.engine.seek(to: 36)
        await rig.sleep(ms: 500)
        rig.engine.stop()
        let stopped = await rig.wait(timeout: 30) { $0.state == .stopped }
        #expect(rig.share.readsWaiting > 0, "the share was still quiet")
        #expect(stopped, "stop got through while the share was quiet: \(rig.engine.snapshot.state)")
        rig.share.goQuiet(from: nil)
    }

    @Test("An output change while the read-ahead waits on a quiet share gives way to stop while the share stays quiet")
    func outputChangeWhileQuietThenStop() async throws {
        let rig = try PlayPauseRig()
        rig.share.goQuiet(from: 10 << 20)
        rig.engine.play(rig.item())
        let playing = await rig.wait(timeout: 60) { $0.state == .playing && $0.position > 0.5 }
        #expect(playing, "the song played from its prefix")
        // The read-ahead has decoded up to where the share went quiet and waits there for bytes.
        let staged = try entry(rig)
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

        // Another output: the engine reopens the song there, at the playhead.
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = false
        rig.engine.update(settings: settings)
        await rig.sleep(ms: 500)
        rig.engine.stop()
        let stopped = await rig.wait(timeout: 30) { $0.state == .stopped }
        #expect(rig.share.readsWaiting > 0, "the share was still quiet")
        #expect(stopped, "stop got through while the share was quiet: \(rig.engine.snapshot.state)")
        rig.share.goQuiet(from: nil)
    }
}
