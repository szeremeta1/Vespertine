//
// Vespertine: the song after the one that plays is on a share too slow to have its start ready when the one that plays ends
// (a link slower than the music: the song that plays keeps the whole link until its own copy is whole, so the next one's copy
// only starts then). The output has nothing to play while the next song's first bytes arrive. That wait is a wait for the
// network: it says so ("Buffering from the network…") and it is not a buffer underrun. It used to say nothing and count every
// empty output buffer as an underrun: thousands in one wait.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine, a simulated output, a share the test controls.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("The next song's share is slower than the music", .serialized)
struct SlowNextSongTests {
    @Test("Waiting for the next song's first bytes shows as buffering and counts no underruns")
    func waitForNextSongIsBufferingNotUnderruns() async throws {
        // The song that plays: 24 s, on a quick share. The next one: 0.1 MB/s, so the prefix it starts on (4 MB) is not there when
        // the first song ends, whatever was copied ahead meanwhile.
        let rig = try PlayPauseRig(seconds: 24, nextBytesPerSecond: 0.1 * 1_048_576)
        let first = rig.item(), second = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? second : nil }
        rig.engine.play(first)
        let playing = await rig.wait(timeout: 60) { $0.state == .playing && $0.position > 0.5 }
        #expect(playing, "the first song played: \(rig.engine.snapshot.state)")

        // The first song has played out and the second has not started: nothing audible, the engine waits on the share.
        let observed: (waited: Bool, buffering: Bool, underruns: Int) = await rig.onOwnThread { rig in
            var quietSince: Date?
            var last = rig.audibleFrames
            let end = Date().addingTimeInterval(90)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.25)
                let now = rig.audibleFrames
                let snapshot = rig.engine.snapshot
                if snapshot.item?.id == second.id, now != last { return (false, false, snapshot.underruns) }   // it started: no wait seen
                if now == last, snapshot.position > 20 || quietSince != nil {
                    quietSince = quietSince ?? Date()
                    // Three seconds into the silence: what does the engine say?
                    if Date().timeIntervalSince(quietSince!) >= 3 { return (true, snapshot.isBuffering, snapshot.underruns) }
                } else { quietSince = nil }
                last = now
            }
            return (false, false, rig.engine.snapshot.underruns)
        }
        #expect(observed.waited, "the output went quiet while the next song's start was on its way")
        #expect(observed.buffering, "the wait for the next song's bytes shows as buffering from the network")
        #expect(observed.underruns == 0, "\(observed.underruns) underruns counted during the wait")

        // Give the share its speed back: the next song starts by itself, and the wait has still counted nothing.
        rig.nextShare.bytesPerSecond = 50 * 1_048_576
        let advanced = await rig.wait(timeout: 120) { $0.item?.id == second.id && $0.state == .playing && $0.position > 0.5 }
        let snapshot = rig.engine.snapshot
        #expect(advanced, "the next song started: \(snapshot.state) in \(snapshot.item?.url.lastPathComponent ?? "no song") at \(snapshot.position) s")
        #expect(snapshot.underruns == 0, "\(snapshot.underruns) underruns after the wait")
        #expect(!snapshot.isBuffering, "no longer buffering once it plays")
    }

    @Test("A next song that is copied whole first (a small file) arrives late: the wait counts no underruns either")
    func waitForWholeCopyCountsNoUnderruns() async throws {
        // 20 s of 96 kHz WAV is under the size that starts on a prefix: the next song plays from its whole copy (not streamed), and
        // at 0.3 MB/s that copy takes longer than the first song lasts.
        let rig = try PlayPauseRig(seconds: 20, nextBytesPerSecond: 0.3 * 1_048_576)
        try #require(!NetworkStart.startsEarly(fileExtension: "wav", size: rig.share.size, isRegion: false), "the songs are copied whole")
        let first = rig.item(), second = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? second : nil }
        rig.engine.play(first)
        let playing = await rig.wait(timeout: 60) { $0.state == .playing && $0.position > 0.5 }
        #expect(playing, "the first song played: \(rig.engine.snapshot.state)")
        // The first song plays out while the second is still copying: the output goes quiet for a few seconds.
        let quiet: Bool = await rig.onOwnThread { rig in
            var last = rig.audibleFrames, quietFor = 0
            let end = Date().addingTimeInterval(90)
            while Date() < end, quietFor < 8 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = rig.audibleFrames
                quietFor = now == last && rig.engine.snapshot.position > 15 ? quietFor + 1 : 0
                last = now
            }
            return quietFor >= 8
        }
        #expect(quiet, "the output went quiet while the next song was copied")
        #expect(rig.engine.snapshot.isBuffering, "the wait shows as buffering from the network")
        rig.nextShare.bytesPerSecond = 50 * 1_048_576
        let advanced = await rig.wait(timeout: 120) { $0.item?.id == second.id && $0.state == .playing && $0.position > 0.5 }
        let snapshot = rig.engine.snapshot
        #expect(advanced, "the next song started: \(snapshot.state) in \(snapshot.item?.url.lastPathComponent ?? "no song") at \(snapshot.position) s")
        #expect(snapshot.underruns == 0, "\(snapshot.underruns) underruns after the wait")
        #expect(!snapshot.isBuffering, "no longer buffering once it plays")
    }
}
