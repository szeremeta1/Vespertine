//
// Vespertine: the next song is at another rate, so the output is set up again for it; while that song's start waits on a
// slow share, a stop or a skip is a stop or a skip, not an error about the song.
// The rig is the play/pause one (PlayPauseRigSupport.swift), with the next song at 48 kHz on a share that goes quiet. The scenario
// runs on a thread of its own (RigThreadSupport.swift) and waits on conditions; what it saw is judged afterwards.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Stopping while a song at another rate opens")
struct RateJoinStopTests {
    @Test("Stop while the next song at another rate waits on its share: no error, and it stops", arguments: [false, true])
    func stopDuringRateJoin(skip: Bool) async throws {
        // The first song is as short as can be while its 21 s still make the next one's copy look slow (below), and the two
        // cases run side by side, each on a rig of its own.
        let rig = try PlayPauseRig(seconds: 21)
        // The next song: 48 kHz (the first is 96 kHz), just large enough to start on a prefix, on a share that goes quiet right
        // after the prefix. By the time the first song has played out, the copy looks far too slow for the rest to arrive in
        // time (only the prefix in 21 s, for a 44 s song), so the next song's start waits for more of it.
        let url = rig.directory.appendingPathComponent("next48.wav")
        try PlayPauseRig.writeWAV(url, rate: 48_000, seconds: 44)
        let slow = ControlledShare(data: try Data(contentsOf: url), bytesPerSecond: 50 * 1_048_576)
        slow.goQuiet(from: NetworkStart.prefix + (256 << 10))
        defer { slow.goQuiet(from: nil) }
        let fast = rig.share
        rig.cache.readerFactory = { $0.lastPathComponent == "next48.wav" ? slow : fast }
        let first = rig.item()
        let next = PlayableItem(url: URL(fileURLWithPath: "/share/next48.wav"), cacheKey: "next48")
        rig.engine.nextItemProvider = { $0.id == first.id ? next : nil }
        let failures = Locked<[String]>([])
        rig.engine.eventHandler = { event in
            if case .failed(let item, let message) = event { failures.withLock { $0.append("\(item?.url.lastPathComponent ?? "?"): \(message)") } }
        }
        struct Run: Sendable { var reopened = false, settled = false, end = "" }
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            rig.engine.play(first)
            // The first song plays out (21 s), the output is set up at 48 kHz, and the next song's start waits for the share
            // (until the test ends: the share stays quiet).
            run.reopened = rig.scriptWait(timeout: 180) { _ in rig.outputs.withLock { $0.count } >= 2 }
            guard run.reopened else { return run }
            rig.scriptSleep(ms: 500)
            if skip { rig.engine.play(first) } else { rig.engine.stop() }
            run.settled = rig.scriptWait(timeout: 60) { skip ? $0.item?.id == first.id && $0.state == .playing : $0.state == .stopped }
            rig.scriptSleep(ms: 300)
            run.end = "state \(rig.engine.snapshot.state), item \(rig.engine.snapshot.item?.url.lastPathComponent ?? "none")"
            return run
        }
        try #require(run.reopened, "the output was never set up for the next song")
        #expect(run.settled, "\(run.end)")
        #expect(failures.withLock { $0 }.isEmpty, "\(failures.withLock { $0 })")
        #expect(rig.engine.snapshot.lastError == nil, "\(rig.engine.snapshot.lastError ?? "")")
    }
}
