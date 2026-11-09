//
// Vespertine: while the engine waits on a share for the song after the one playing (the gapless look-ahead), what the listener
// asks of the song that plays still happens now: a seek lands, a queue edit picks the new next song, a volume change is heard.
// The wait is given up and taken again afterwards. The rig is the play/pause one (PlayPauseRigSupport.swift), with the next
// song's share stalled. Each scenario runs on a thread of its own (RigThreadSupport.swift) and waits on conditions, so a test
// run that holds Swift's cooperative threads can't make it miss its moment; it is judged afterwards.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Commands while the next song is fetched from a share", .serialized)
struct LookAheadYieldTests {
    /// A 20 s song (the buffer holds it whole, so it is decoded at once) playing past `from` seconds, with the next one on a share
    /// that has stalled: the engine is waiting on it. Returns a note when that wasn't reached (nil when it was). For a script.
    private static func waitingOnNext(_ rig: PlayPauseRig, past from: Double) -> String? {
        guard rig.scriptWait(timeout: 120, { $0.state == .playing && $0.position >= from }) else {
            return "never played past \(from) s: \(rig.engine.snapshot.state) at \(rig.engine.snapshot.position) s"
        }
        guard rig.scriptHears(0.25, timeout: 60) else { return "no sound while the next song was fetched" }
        return nil
    }

    private static func rig() throws -> (PlayPauseRig, PlayableItem, Locked<PlayableItem?>) {
        let rig = try PlayPauseRig(seconds: 20)
        rig.nextShare.stall(true)
        let first = rig.item()
        let next = Locked<PlayableItem?>(rig.nextItem())
        rig.engine.nextItemProvider = { $0.id == first.id ? next.withLock { $0 } : nil }
        return (rig, first, next)
    }

    private struct SeekRun: Sendable {
        var setUp: String?
        var landed = false, landedAt = 0.0, landedOn: UUID?
        var playedOn = false, movedTo = 0.0, playedItem: UUID?
    }

    @Test("A seek while the next song is fetched lands and plays from there, before the next song starts")
    func seekLands() async throws {
        let (rig, first, _) = try Self.rig()
        defer { rig.nextShare.stall(false) }
        let run = try await rig.runScript { rig -> SeekRun in
            var run = SeekRun()
            rig.engine.play(first)
            run.setUp = Self.waitingOnNext(rig, past: 4)
            guard run.setUp == nil else { return run }
            rig.engine.seek(to: 1)
            // Lands: the song that plays, near 1 s (well before the 4 s it was at). The next song is stalled, so this comes first.
            run.landed = rig.scriptWait(timeout: 60) { $0.state == .playing && $0.position >= 1 && $0.position < 3.5 }
            run.landedAt = rig.engine.snapshot.position
            run.landedOn = rig.engine.snapshot.item?.id
            // Plays from there: sound comes out and the playhead moves on from where it landed.
            let from = run.landedAt
            run.playedOn = rig.scriptHears(0.25, timeout: 60) && rig.scriptWait(timeout: 60) { $0.position >= from + 0.5 }
            run.movedTo = rig.engine.snapshot.position
            run.playedItem = rig.engine.snapshot.item?.id
            return run
        }
        try #require(run.setUp == nil, "\(run.setUp ?? "")")
        #expect(run.landed, "the seek never landed: at \(run.landedAt) s")
        #expect(run.landedOn == first.id, "landed in another song")
        #expect(run.playedOn, "no sound or no movement after the seek: at \(run.movedTo) s")
        #expect(run.playedItem == first.id, "the next song started before the seek played")
    }

    private struct QueueRun: Sendable {
        var setUp: String?
        var followed = false, sawRemoved = false, heard = false
        var end = ""
    }

    @Test("A queue edit while the next song is fetched: the new next song follows, the removed one never plays")
    func queueEditTakesEffect() async throws {
        let (rig, first, next) = try Self.rig()
        defer { rig.nextShare.stall(false) }
        let removed = try #require(next.withLock { $0 })
        let replacement = PlayableItem(url: first.url, cacheKey: first.cacheKey)   // on the share that answers
        let run = try await rig.runScript { rig -> QueueRun in
            var run = QueueRun()
            rig.engine.play(first)
            run.setUp = Self.waitingOnNext(rig, past: 1)
            guard run.setUp == nil else { return run }
            next.withLock { $0 = replacement }
            rig.engine.queueChanged()
            var sawRemoved = false
            run.followed = rig.scriptWait(timeout: 120) { snapshot in
                if snapshot.item?.id == removed.id { sawRemoved = true }
                return snapshot.item?.id == replacement.id && snapshot.state == .playing
            }
            run.sawRemoved = sawRemoved
            run.heard = rig.scriptHears(0.25, timeout: 60)
            run.end = "\(rig.engine.snapshot.item?.url.lastPathComponent ?? "nothing"), \(rig.engine.snapshot.state)"
            return run
        }
        try #require(run.setUp == nil, "\(run.setUp ?? "")")
        #expect(run.followed, "the new next song never played: \(run.end)")
        #expect(!run.sawRemoved, "the removed song played")
        #expect(run.heard, "the new next song made no sound")
    }

    private struct VolumeRun: Sendable {
        var setUp: String?
        var applied = false, gain = -1.0, heard = false
    }

    @Test("A volume change while the next song is fetched is applied while it waits")
    func volumeApplies() async throws {
        let (rig, first, _) = try Self.rig()
        defer { rig.nextShare.stall(false) }
        let run = try await rig.runScript { rig -> VolumeRun in
            var run = VolumeRun()
            rig.engine.play(first)
            run.setUp = Self.waitingOnNext(rig, past: 1)
            guard run.setUp == nil else { return run }
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            settings.digitalVolumeDB = -6
            rig.engine.update(settings: settings)
            run.applied = rig.scriptWait(timeout: 60) { _ in
                rig.engine.currentSessionForTesting.map { abs(nrt_context_gain($0.context) - pow(10, -6.0 / 20)) < 1e-6 } ?? false
            }
            run.gain = rig.engine.currentSessionForTesting.map { nrt_context_gain($0.context) } ?? -1
            run.heard = rig.scriptHears(0.25, timeout: 60) && rig.engine.snapshot.item?.id == first.id
            return run
        }
        try #require(run.setUp == nil, "\(run.setUp ?? "")")
        #expect(run.applied, "the output's gain is still \(run.gain)")
        #expect(run.heard, "no sound from the song after the change")
    }

    private struct GapRun: Sendable {
        var started = false, gap = -1.0
    }

    @Test("A gap between songs stays one gap when the next song's wait is given up for a volume change")
    func gapOwedOnce() async throws {
        let rig = try PlayPauseRig()          // 24 s songs: the next one is large enough to start on a prefix
        let first = rig.item(), next = rig.nextItem()
        let provided = Locked<PlayableItem?>(nil)
        rig.engine.nextItemProvider = { $0.id == first.id ? provided.withLock { $0 } : nil }
        rig.nextShare.stall(true)
        let run = try await rig.runScript { rig -> GapRun in
            var run = GapRun()
            var settings = EngineSettings()
            settings.deviceUID = rig.device.uid
            settings.exclusive = true
            settings.transitions.enabled = true
            settings.transitions.gapSeconds = 2
            rig.engine.update(settings: settings)
            rig.engine.play(first)
            _ = rig.scriptWait(timeout: 120) { $0.state == .playing && $0.position >= 3 }     // decoded to its end by now
            // Added to the queue after the first song was decoded: no boundary was planned for it, so the gap is decided when
            // the next song has been looked at.
            provided.withLock { $0 = next }
            rig.engine.queueChanged()
            // Its share answers only after 10 s, and then only the prefix: the copy looks slow, so the song's start waits for
            // more, after the gap has been decided. Volume changes give that wait up.
            rig.scriptSleep(ms: 10_000)
            rig.nextShare.goQuiet(from: NetworkStart.prefix + (256 << 10))
            rig.nextShare.stall(false)
            rig.scriptSleep(ms: 1000)
            for volume in [-6.0, -7, -6] {
                settings.digitalVolumeDB = volume
                rig.engine.update(settings: settings)
                rig.scriptSleep(ms: 500)
            }
            rig.nextShare.goQuiet(from: nil)
            run.started = rig.scriptWait(timeout: 120) { $0.item?.id == next.id && $0.state == .playing && $0.position > 0.2 }
            guard run.started, let session = rig.engine.currentSessionForTesting else { return run }
            // Where the next song starts in the output: the read position less what of it has played (the read position taken
            // on both sides of the snapshot, so a slow moment between the two reads can't skew it).
            let before = Double(session.totalRead)
            let position = rig.engine.snapshot.position
            let after = Double(session.totalRead)
            let start = (before + after) / 2 - position * PlayPauseRig.rate
            run.gap = (start - 24 * PlayPauseRig.rate) / PlayPauseRig.rate
            return run
        }
        try #require(run.started, "the next song never played")
        #expect(abs(run.gap - 2) < 0.25, "the silence between the songs is \(run.gap) s, not 2 s")
    }
}
