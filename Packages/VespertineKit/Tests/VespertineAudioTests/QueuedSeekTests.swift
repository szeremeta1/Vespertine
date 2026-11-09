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
        var playing = false, waiting = false, reopening = false
        var atEdge = false, leadWait = false
        var landed = false, landedAt = "", quietAtLanding = false
        var stopped = false, end = ""
        /// What the engine said at the first step that did not come out, so a failure says where the song went.
        var trouble = ""
    }

    /// The engine's state, position and last error, for a failure message.
    private static func describe(_ rig: PlayPauseRig) -> String {
        let s = rig.engine.snapshot
        return "state \(s.state), position \(s.position) s, buffering \(s.isBuffering), last error \(s.lastError ?? "none")"
    }

    @Test("An output change and a seek taken together while the share is quiet: the seek lands, and stop still works")
    func seekBehindOutputChange() async throws {
        let rig = try PlayPauseRig(cacheClock: PlayPauseRig.slowCacheClock())
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
            guard run.playing else { run.trouble = Self.describe(rig); return run }
            // The read-ahead has decoded up to where the share went quiet and waits there for bytes.
            let entry = try rig.cache.entry(key: "song", url: rig.item().url, foreground: false)
            run.waiting = rig.scriptWait(timeout: 120) { _ in entry.isWaiting && rig.share.readsWaiting > 0 }
            guard run.waiting else { run.trouble = Self.describe(rig); return run }
            // While the engine waits out the pause's fade, another output and a seek back to 1 s: one batch.
            rig.engine.pause()
            rig.scriptSleep(ms: 50)
            settings.exclusive = false
            rig.engine.update(settings: settings)
            rig.engine.seek(to: 1)
            run.landed = rig.scriptWait(timeout: 120) { $0.state == .paused && abs($0.position - 1) < 0.5 && $0.item != nil }
            run.landedAt = "\(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s"
            run.quietAtLanding = rig.share.readsWaiting > 0
            if !run.landed { run.trouble = Self.describe(rig) }
            rig.engine.stop()
            run.stopped = rig.scriptWait(timeout: 120) { $0.state == .stopped }
            run.end = "\(rig.engine.snapshot.state)"
            return run
        }
        try #require(run.playing, "the song never played from its prefix: \(run.trouble)")
        try #require(run.waiting, "the read-ahead never reached the quiet part of the song: \(run.trouble)")
        #expect(run.landed, "the seek never landed: \(run.landedAt); \(run.trouble)")
        #expect(run.quietAtLanding, "the share was not quiet any more when the seek landed")
        #expect(run.stopped, "stop got through while the share was quiet: \(run.end)")
    }

    /// What the engine is asked while it waits for the lead of a song on a quiet share.
    enum Newest: String, CaseIterable, Sendable { case seek, outputChange }

    @Test("A song waiting for its lead on a quiet share gives way to the newest request: a seek lands, an output change reopens the song", arguments: Newest.allCases)
    func newestRequestEndsLeadWait(_ newest: Newest) async throws {
        let rig = try PlayPauseRig(cacheClock: PlayPauseRig.slowCacheClock())
        rig.share.goQuiet(from: 6 << 20)        // about 10 s in: the read-ahead reaches it soon
        defer { rig.share.goQuiet(from: nil) }
        let run = try await rig.runScript { rig -> Run in
            var run = Run()
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            rig.engine.update(settings: settings)
            rig.engine.play(rig.item())
            run.playing = rig.scriptWait(timeout: 120) { $0.state == .playing && $0.position > 3 }
            guard run.playing else { run.trouble = Self.describe(rig); return run }
            let entry = try rig.cache.entry(key: "song", url: rig.item().url, foreground: false)
            run.waiting = rig.scriptWait(timeout: 120) { _ in entry.isWaiting && rig.share.readsWaiting > 0 }
            guard run.waiting else { run.trouble = Self.describe(rig); return run }
            // The playhead has played what was buffered and stands where the share went quiet (a little past 10 s, buffering).
            run.atEdge = rig.scriptWait(timeout: 120) { $0.position > 10 && $0.isBuffering }
            guard run.atEdge else { run.trouble = Self.describe(rig); return run }
            // A seek back to a place that is on disk, but whose lead (the next megabytes, which the song waits for before its
            // output starts) reaches into what the share has not sent: the engine thread waits there, in the song's lead, not in a read.
            rig.engine.seek(to: 8)
            run.leadWait = rig.scriptWait(timeout: 120) { _ in entry.isFillingLead }
            guard run.leadWait else { run.trouble = Self.describe(rig); return run }
            // The newest request, as a command of its own: it has to end that wait, not be handled after the share answers (it never does).
            let opened = rig.opens.withLock { $0 }
            switch newest {
            case .seek:
                rig.engine.seek(to: 1)
                run.landed = rig.scriptWait(timeout: 120) { abs($0.position - 1) < 0.5 && $0.item != nil }
            case .outputChange:
                settings.exclusive = false
                rig.engine.update(settings: settings)
                run.landed = rig.scriptWait(timeout: 120) { _ in rig.opens.withLock { $0 } > opened }
            }
            run.landedAt = "\(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s, \(rig.opens.withLock { $0 } - opened) outputs opened"
            if !run.landed { run.trouble = Self.describe(rig) }
            rig.engine.stop()
            run.stopped = rig.scriptWait(timeout: 120) { $0.state == .stopped }
            run.end = "\(rig.engine.snapshot.state)"
            return run
        }
        try #require(run.playing, "the song never played from its prefix: \(run.trouble)")
        try #require(run.waiting, "the read-ahead never reached the quiet part of the song: \(run.trouble)")
        try #require(run.atEdge, "the playhead never reached the quiet part: \(run.trouble)")
        try #require(run.leadWait, "the song never waited for its lead: \(run.trouble)")
        #expect(run.landed, "the \(newest.rawValue) never took effect: \(run.landedAt); \(run.trouble)")
        #expect(run.stopped, "stop got through while the share was quiet: \(run.end)")
    }
}
