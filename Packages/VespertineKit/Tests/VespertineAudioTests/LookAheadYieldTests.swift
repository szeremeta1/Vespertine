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
}
