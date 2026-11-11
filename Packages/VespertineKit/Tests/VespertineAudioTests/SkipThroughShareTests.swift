//
// Vespertine: skipping quickly through songs on a share far away. Each song skipped past had begun to copy: megabyte reads, several
// in flight, and a read that has been sent can't be taken back, so every one of them still crossed the link after the skip. On a
// link of about 1 MB/s the song landed on waited behind all of that ("Buffering from the network…" for 26 s after six skips, where
// a start by itself takes a few seconds). A copy now begins with small reads, so a song skipped past leaves little behind.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine, a simulated output, a share the test controls, here
// with the cache's blocks as large as the app's.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Skipping through songs on a slow share", .serialized)
struct SkipThroughShareTests {
    @Test("The song landed on after five quick skips does not wait behind the reads of the songs skipped past")
    func landingSongDoesNotWaitBehindSkippedSongs() async throws {
        // One link of 1 MiB/s for every song of the share; 24 s of 96 kHz WAV starts on a 4 MiB prefix. Blocks of 1 MiB, as in the app.
        let rig = try PlayPauseRig(seconds: 24, bytesPerSecond: 1_048_576, cacheChunk: 1 << 20)
        try #require(NetworkStart.startsEarly(fileExtension: "wav", size: rig.share.size, isRegion: false), "the songs start on a prefix")
        let songs = (1...6).map { rig.item(numbered: $0) }
        // Five songs skipped past, 0.7 s each, then the sixth is left to play. On a thread of its own: the presses keep their pace.
        let result: (playing: Bool, seconds: Double, askedAtLastPress: Int64, askedWhenPlaying: Int64) = await rig.onOwnThread { rig in
            for song in songs.dropLast() {
                rig.engine.play(song)
                Thread.sleep(forTimeInterval: 0.7)
            }
            let pressed = Date(), before = rig.share.bytesAsked
            rig.engine.play(songs[5])
            let playing = rig.waitBlocking(timeout: 90) { $0.state == .playing && $0.item?.id == songs[5].id && $0.position > 0.2 }
            return (playing, Date().timeIntervalSince(pressed), before, rig.share.bytesAsked)
        }
        #expect(result.playing, "the sixth song played: \(rig.engine.snapshot.state)")
        // What the link carried between the last press and the first sound. The song itself needs its prefix and a lead (about
        // 6 MiB, and it keeps copying while the lead fills). Everything above that is reads of the songs skipped past.
        let carried = Double(result.askedWhenPlaying - result.askedAtLastPress) / 1_048_576
        let total = Double(result.askedWhenPlaying) / 1_048_576
        #expect(result.seconds < 14, "the song started \(String(format: "%.1f", result.seconds)) s after the last skip (the link carried \(String(format: "%.1f", carried)) MiB meanwhile, \(String(format: "%.1f", total)) MiB in all)")
        rig.engine.stop()
    }
}
