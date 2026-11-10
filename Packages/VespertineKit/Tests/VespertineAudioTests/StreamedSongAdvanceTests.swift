//
// Vespertine: a FLAC that plays from a share while it is still being copied (it started on a prefix) is read through the cache's
// input source up to its last frame. When that source did not say where the file ends, the decoder asked it for more for ever: the
// song never ended, the queue never moved on, and once the ring was played out every empty buffer counted as an underrun.
// The rig is the play/pause one (PlayPauseRigSupport.swift): the real engine, a simulated output, a share the test controls.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("A streamed song ends and the queue moves on", .serialized)
struct StreamedSongAdvanceTests {
    @Test("A FLAC started on a prefix plays to its end and the next song follows by itself, without a single underrun")
    func flacStreamedToItsEnd() async throws {
        // 40 s of 96 kHz FLAC: above the size that starts on a prefix; the share is quick, so the copy is whole well before the song
        // ends, but the decoder opened on the prefix keeps reading through the cache.
        let rig = try PlayPauseRig(seconds: 40, bytesPerSecond: 6 * 1_048_576, fileExtension: "flac")
        try #require(NetworkStart.startsEarly(fileExtension: "flac", size: rig.share.size, isRegion: false), "the song starts on a prefix")
        let first = rig.item(), second = rig.nextItem()
        rig.engine.nextItemProvider = { $0.id == first.id ? second : nil }
        rig.engine.play(first)
        let advanced = await rig.wait(timeout: 100) { $0.item?.id == second.id && $0.state == .playing }
        let snapshot = rig.engine.snapshot
        #expect(advanced, "the next song never started: \(snapshot.state) in \(snapshot.item?.url.lastPathComponent ?? "no song") at \(snapshot.position) s")
        #expect(snapshot.underruns == 0, "\(snapshot.underruns) underruns")
    }
}
