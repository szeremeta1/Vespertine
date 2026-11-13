//
// Vespertine: Dolby Atmos played by macOS's renderer (AVSampleBufferAudioRenderer) across a route change. When the output's
// configuration changes under it (AirPods Max moving between A2DP, call mode and the USB-C cable; a headset connecting), macOS
// throws away what the renderer had queued and posts `AVSampleBufferAudioRendererWasFlushedAutomatically` with the time it
// flushed from. The player has to feed it again from that time. Vespertine didn't listen, so it went on from where its reader
// had got to: everything queued (seconds of the song) was skipped, heard as a gap or as the song "dropping out". The laptop logs
// of 2026-11-13 show macOS posting it to Vespertine twice: 16:51:44.098 ("for time 9.079", the cable going in) and
// 16:56:17.993 ("for time 94.568", call mode ending).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import VespertineAudio

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func add(_ t: Double) { lock.lock(); times.append(t); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
}

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

@Suite("Atmos through macOS's renderer: route changes", .serialized)
struct AtmosRouteChangeTests {
    @Test("After macOS flushes the renderer on a route change, it is fed again from the time it flushed from")
    func refedFromTheFlushTime() throws {
        let url = fixture("dolby-digital-plus-tones.m4a")
        let session = try SystemRendererSession(item: PlayableItem(url: url), url: url,
                                                deviceUID: DeviceQuery.outputUIDs().sorted().first, spatial: false, volume: 0)
        let recorder = Recorder()
        session.enqueueObserver = { buffer in
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts.isValid { recorder.add(CMTimeGetSeconds(pts)) }
        }
        try session.prepare(at: 0)
        defer { session.stop() }
        // Played (silently, at volume 0) until the reader is well past the point macOS will flush from. The renderer keeps only
        // about a second queued, so it has to play to take more.
        session.play()
        let deadline = Date().addingTimeInterval(120)
        while (recorder.all.last ?? 0) - (recorder.all.first ?? 0) < 0.7, !session.inputExhausted, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let before = recorder.all
        let first = try #require(before.first)
        try #require((before.last ?? 0) - first >= 0.7, "the renderer took only \(before.count) buffers")

        // macOS flushes it at 0.2 s into the song, as it does when the route changes.
        let flushTime = first + 0.2
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: session.renderer,
                                        userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(seconds: flushTime, preferredTimescale: 48_000))])

        let wait = Date().addingTimeInterval(20)
        while recorder.all.count == before.count, Date() < wait { Thread.sleep(forTimeInterval: 0.02) }
        let after = Array(recorder.all.dropFirst(before.count))
        let resumed = try #require(after.first, "nothing was queued again after the flush")
        // From the frame that holds the flush time (an E-AC-3 frame is 32 ms), not from where the reader had got to.
        #expect(resumed <= flushTime + 0.001, "fed again from \(resumed) s, after the flush time \(flushTime) s")
        #expect(resumed > flushTime - 0.25, "fed again from \(resumed) s, long before the flush time \(flushTime) s")
    }

    @Test("A flush notice from another renderer is not this session's business")
    func otherRenderersIgnored() throws {
        let url = fixture("dolby-digital-plus-tones.m4a")
        let session = try SystemRendererSession(item: PlayableItem(url: url), url: url,
                                                deviceUID: DeviceQuery.outputUIDs().sorted().first, spatial: false, volume: 0)
        let recorder = Recorder()
        session.enqueueObserver = { buffer in recorder.add(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))) }
        try session.prepare(at: 0)
        defer { session.stop() }
        session.play()
        let deadline = Date().addingTimeInterval(120)
        while (recorder.all.last ?? 0) - (recorder.all.first ?? 0) < 0.7, !session.inputExhausted, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let first = try #require(recorder.all.first)
        let count = recorder.all.count
        let other = AVSampleBufferAudioRenderer()
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: other,
                                        userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(seconds: first + 0.1, preferredTimescale: 48_000))])
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!recorder.all.dropFirst(count).contains { $0 < first + 0.4 }, "re-fed for another renderer's flush")
    }
}
