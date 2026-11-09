//
// Vespertine: while the engine waits on a share for the song after the one playing (the gapless look-ahead), what the listener
// asks of the song that plays still happens now: a seek lands, a queue edit picks the new next song, a volume change is heard.
// The wait is given up and taken again afterwards. The rig is the play/pause one (PlayPauseRigSupport.swift), with the next
// song's share stalled.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Commands while the next song is fetched from a share", .serialized)
struct LookAheadYieldTests {
    /// A 6 s song (decoded whole at once) playing, with the next one on a share that has stalled: the engine is waiting on it.
    private func waitingOnNext() async throws -> (PlayPauseRig, PlayableItem, Locked<PlayableItem?>) {
        let rig = try PlayPauseRig(seconds: 6)
        rig.nextShare.stall(true)
        let first = rig.item()
        let next = Locked<PlayableItem?>(rig.nextItem())
        rig.engine.nextItemProvider = { $0.id == first.id ? next.withLock { $0 } : nil }
        rig.engine.play(first)
        _ = await rig.wait(timeout: 30) { $0.state == .playing && !$0.isBuffering }
        _ = await rig.wait(timeout: 10) { $0.position >= 2.5 }   // the song is decoded; the engine now waits for the next one
        let o = await rig.observe(0.5)
        #expect(o.state == .playing && o.audible && o.moving, "before: \(o)")
        return (rig, first, next)
    }

    @Test("A seek while the next song is fetched lands at once and plays from there")
    func seekLands() async throws {
        let (rig, _, _) = try await waitingOnNext()
        defer { rig.nextShare.stall(false) }
        rig.engine.seek(to: 0.5)
        let landed = await rig.wait(timeout: 10) { $0.state == .playing && $0.position < 2 }
        #expect(landed, "the seek never landed: at \(rig.engine.snapshot.position) s")
        let o = await rig.observe(0.6)
        #expect(o.state == .playing && o.audible && o.moving, "after the seek: \(o)")
        let position = rig.engine.snapshot.position
        #expect(position > 0.5 && position < 2.5, "position \(position) after a seek to 0.5 s")
    }

    @Test("A queue edit while the next song is fetched: the new next song follows, the removed one never plays")
    func queueEditTakesEffect() async throws {
        let (rig, first, next) = try await waitingOnNext()
        defer { rig.nextShare.stall(false) }
        let removed = try #require(next.withLock { $0 })
        let replacement = PlayableItem(url: first.url, cacheKey: first.cacheKey)   // on the share that answers
        next.withLock { $0 = replacement }
        rig.engine.queueChanged()
        var sawRemoved = false
        let followed = await rig.wait(timeout: 20) { snapshot in
            if snapshot.item?.id == removed.id { sawRemoved = true }
            return snapshot.item?.id == replacement.id && snapshot.state == .playing
        }
        #expect(followed, "the new next song never played: \(rig.engine.snapshot.item?.url.lastPathComponent ?? "nothing"), \(rig.engine.snapshot.state)")
        #expect(!sawRemoved, "the removed song played")
        let o = await rig.observe(0.6)
        #expect(o.audible && o.moving, "the new next song: \(o)")
    }

    @Test("A volume change while the next song is fetched is applied at once")
    func volumeApplies() async throws {
        let (rig, _, _) = try await waitingOnNext()
        defer { rig.nextShare.stall(false) }
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = true
        settings.digitalVolumeDB = -6
        rig.engine.update(settings: settings)
        let applied = await rig.wait(timeout: 2) { _ in
            rig.engine.currentSessionForTesting.map { abs(nrt_context_gain($0.context) - pow(10, -6.0 / 20)) < 1e-6 } ?? false
        }
        #expect(applied, "the output's gain is still \(rig.engine.currentSessionForTesting.map { nrt_context_gain($0.context) } ?? -1)")
        let o = await rig.observe(0.5)
        #expect(o.state == .playing && o.audible && o.moving, "after the change: \(o)")
    }

    @Test("A gap between songs stays one gap when the next song's wait is given up for a volume change")
    func gapOwedOnce() async throws {
        let rig = try PlayPauseRig()          // 24 s songs: the next one is large enough to start on a prefix
        var settings = EngineSettings()
        settings.deviceUID = rig.device.uid
        settings.exclusive = true
        settings.transitions.enabled = true
        settings.transitions.gapSeconds = 2
        rig.engine.update(settings: settings)
        let first = rig.item(), next = rig.nextItem()
        let provided = Locked<PlayableItem?>(nil)
        rig.engine.nextItemProvider = { $0.id == first.id ? provided.withLock { $0 } : nil }
        rig.nextShare.stall(true)
        rig.engine.play(first)
        _ = await rig.wait(timeout: 30) { $0.state == .playing && !$0.isBuffering }
        _ = await rig.wait(timeout: 30) { $0.position >= 3 }     // decoded to its end by now
        // Added to the queue after the first song was decoded: no boundary was planned for it, so the gap is decided when the
        // next song has been looked at.
        provided.withLock { $0 = next }
        rig.engine.queueChanged()
        // Its share answers only after 10 s, and then only the prefix: the copy looks slow, so the song's start waits for
        // more, after the gap has been decided. Volume changes give that wait up.
        await rig.sleep(ms: 10_000)
        rig.nextShare.goQuiet(from: NetworkStart.prefix + (256 << 10))
        rig.nextShare.stall(false)
        await rig.sleep(ms: 1000)
        for volume in [-6.0, -7, -6] {
            settings.digitalVolumeDB = volume
            rig.engine.update(settings: settings)
            await rig.sleep(ms: 500)
        }
        rig.nextShare.goQuiet(from: nil)
        let started = await rig.wait(timeout: 40) { $0.item?.id == next.id && $0.state == .playing && $0.position > 0.2 }
        try #require(started, "the next song never played")
        // Where the next song starts in the output: the read position less what of it has played.
        let snapshot = rig.engine.snapshot
        let read = Double(try #require(rig.engine.currentSessionForTesting).totalRead)
        let start = read - snapshot.position * PlayPauseRig.rate
        let gap = (start - 24 * PlayPauseRig.rate) / PlayPauseRig.rate
        #expect(abs(gap - 2) < 0.25, "the silence between the songs is \(gap) s, not 2 s")
    }
}
