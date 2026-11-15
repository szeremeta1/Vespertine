//
// Vespertine: a seek or an output change while the song's share has stopped answering must not take the engine with it:
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

    /// What the seek's run saw, judged afterwards.
    private struct SeekRun: Sendable {
        var played = false
        var playedNote = ""
        var quiet = false
        var stopped = false
        var end = ""
    }

    @Test("A seek into a part of a FLAC the share has not sent yet gives way to stop while the share stays quiet")
    func seekIntoQuietPartThenStop() async throws {
        // The cache's clock runs a thousand times slow (`slowCacheClock`): it plans the start of a song from the copy's speed
        // so far, and on a share that goes quiet that speed falls with every second the machine takes, until the start waits
        // for bytes the share will never send. How many seconds that takes depended on how busy the machine was.
        let rig = try PlayPauseRig(seconds: 40, fileExtension: "flac", cacheClock: PlayPauseRig.slowCacheClock())
        let size = rig.share.size
        #expect(NetworkStart.startsEarly(fileExtension: "flac", size: size, isRegion: false), "the song starts on a prefix (\(size) bytes)")
        let quietFrom = Int64(9 << 20)
        rig.share.goQuiet(from: quietFrom)
        // The song is played from its prefix with the output's clock held, the test moving it: a quarter second at a time,
        // each once the engine has it to play. From a thread of its own, so nothing waits for one of Swift's few shared threads.
        rig.holdOutput(true)
        let step = Int(PlayPauseRig.rate / 4)
        let run = try await rig.runScript { rig -> SeekRun in
            defer { rig.share.goQuiet(from: nil) }
            var run = SeekRun()
            func readable() -> Int { rig.engine.currentSessionForTesting?.readableFrames ?? 0 }
            rig.engine.play(rig.item())
            // The engine has been round its loop twice: what the output did before this is in the snapshot.
            func settled() -> Bool {
                rig.engine.waitForCommandsForTesting(timeout: 120) && rig.engine.waitForCommandsForTesting(timeout: 120)
            }
            for _ in 0..<12 where !run.played {
                guard rig.scriptWait(timeout: 120, { $0.state == .playing && readable() >= step }) else { break }
                rig.outputs.withLock { $0.last }?.advance(seconds: 0.25)
                guard settled() else { break }
                run.played = rig.engine.snapshot.position > 0.5
            }
            run.playedNote = "\(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s, \(readable()) frames to play"
            guard run.played else { return run }

            // Near the end: bytes the share will not send while it is quiet. The engine opens the song again there.
            rig.engine.seek(to: 36)
            rig.scriptSleep(ms: 500)
            rig.engine.stop()
            run.stopped = rig.scriptWait(timeout: 30) { $0.state == .stopped }
            run.quiet = rig.share.readsWaiting > 0
            run.end = "\(rig.engine.snapshot.state)"
            return run
        }
        #expect(run.played, "the song played from its prefix: \(run.playedNote)")
        guard run.played else { return }
        #expect(run.quiet, "the share was still quiet")
        #expect(run.stopped, "stop got through while the share was quiet: \(run.end)")
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
