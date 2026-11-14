//
// Vespertine: the queue played on the fake renderer: what it is sent, what it fetches, and the events and snapshot the app sees.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

/// A 24-bit stereo WAV of `seconds` at `rate`, with a different ramp per file so two files never match.
func makeWAV(seconds: Double = 1, rate: Int = 48_000, seed: Int = 1) throws -> URL {
    let frames = Int(Double(rate) * seconds)
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let dataSize = UInt32(frames * 2 * 3)
    data.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataSize); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(2); le32(UInt32(rate)); le32(UInt32(rate * 6)); le16(6); le16(24)
    data.append(contentsOf: Array("data".utf8)); le32(dataSize)
    for i in 0..<frames {
        for c in 0..<2 {
            let v = Int32(truncatingIfNeeded: ((i * (37 + seed) + c * 1000) % 200_000) - 100_000) * Int32(seed)
            let u = UInt32(bitPattern: v)
            data.append(UInt8(u & 0xFF)); data.append(UInt8((u >> 8) & 0xFF)); data.append(UInt8((u >> 16) & 0xFF))
        }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

/// Events the app would get, in order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ e: EngineEvent) {
        let text: String = switch e {
        case .trackStarted(let item): "started \(item.url.lastPathComponent)"
        case .queueEnded: "ended"
        case .failed(_, let message): "failed \(message)"
        case .deviceLost(let name): "lost \(name)"
        case .notice(let message): "notice \(message)"
        default: "other"
        }
        lock.withLock { events.append(text) }
    }
    var all: [String] { lock.withLock { events } }
    func wait(for text: String, timeout: Double = 5) async -> Bool {
        for _ in 0..<Int(timeout * 50) {
            if all.contains(where: { $0.hasPrefix(text) }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

struct Harness {
    let fake: FakeRenderer
    let media: MediaServer
    let playback: RendererPlayback
    let events: EventLog
    let queue: [PlayableItem]

    static func make(kind: FakeRenderer.Kind, files: Int = 3, startTimeout: TimeInterval = 15, lostAfter: TimeInterval = 0.3) async throws -> Harness {
        let fake = try await FakeRenderer(kind: kind)
        let media = MediaServer()
        try await media.start()
        let device = try await RendererDevice.load(location: fake.location)
        let queue = try (0..<files).map { PlayableItem(url: try makeWAV(seed: $0 + 1)) }
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media, pollInterval: 0.05,
                                        startTimeout: startTimeout, lostAfter: lostAfter)
        let items = Locked(queue)
        playback.nextItemProvider = { finished in
            let q = items.withLock { $0 }
            guard let i = q.firstIndex(where: { $0.id == finished.id }), i + 1 < q.count else { return nil }
            return q[i + 1]
        }
        playback.metadataProvider = { item in RendererTrackInfo(title: item.url.lastPathComponent, artist: "Artist", duration: 1) }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        return Harness(fake: fake, media: media, playback: playback, events: events, queue: queue)
    }

    /// The song playing reaches its end on the renderer (the fake's songs are 200 s long): the position is seen there by a
    /// poll first, as it is on a real one.
    func playToEnd() async throws {
        fake.setPosition(198)
        for _ in 0..<100 where playback.snapshot.position < 190 { try await Task.sleep(for: .milliseconds(20)) }
        fake.advance()
    }

    func close() {
        playback.shutdown()
        media.stop()
        fake.stop()
    }
}

@Suite("Renderer playback", .serialized)
struct RendererPlaybackTests {
    @Test("OpenHome: the song plays from Vespertine's server, the renderer gets the file's exact bytes, then the next")
    func openHomePassThrough() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started \(h.queue[0].url.lastPathComponent)"))
        let first = try #require(h.fake.currentURI)
        #expect(first.contains("/media/"))
        #expect(await h.fake.fetched(first) == (try Data(contentsOf: h.queue[0].url)))
        #expect(h.fake.playlistURIs.count == 2)   // current + next only
        let snap = h.playback.snapshot
        #expect(snap.state == .playing)
        #expect(snap.item?.id == h.queue[0].id)
        let path = try #require(snap.signalPath)
        #expect(path.statusLine == "BIT-PERFECT · 24/48 SENT")
        #expect(!path.isBitPerfect)
        #expect(path.isUntouched)
        // The renderer moves on by itself: the next song is reported and the one after it queued on the renderer.
        h.fake.advance()
        #expect(await h.events.wait(for: "started \(h.queue[1].url.lastPathComponent)"))
        let second = try #require(h.fake.currentURI)
        #expect(await h.fake.fetched(second) == (try Data(contentsOf: h.queue[1].url)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.fake.playlistURIs.count == 2)
        #expect(h.fake.playlistURIs.first == second)
        // The last song ends: the queue has ended.
        h.fake.advance()
        #expect(await h.events.wait(for: "started \(h.queue[2].url.lastPathComponent)"))
        try await h.playToEnd()
        #expect(await h.events.wait(for: "ended"))
        #expect(h.playback.snapshot.state == .stopped)
    }

    @Test("Stopped on the player in the middle of a song: paused there, not skipped to the next and not the end of the queue")
    func stoppedOnThePlayer() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.fake.setPosition(60)
        for _ in 0..<100 where h.playback.snapshot.position < 50 { try await Task.sleep(for: .milliseconds(20)) }
        let uri = h.fake.currentURI
        h.fake.stopOnDevice()
        for _ in 0..<100 where h.playback.snapshot.state == .playing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(h.playback.snapshot.state == .paused)
        #expect(!h.playback.wantsPlaying)
        #expect(h.playback.snapshot.item?.id == h.queue[0].id)
        #expect(h.fake.currentURI == uri)
        #expect(!h.events.all.contains { $0.hasPrefix("ended") || $0.hasPrefix("failed") })
    }

    @Test("A renderer that takes a song and never starts it fails the song after a while, by name")
    func neverStarts() async throws {
        let h = try await Harness.make(kind: .av(setNext: true), startTimeout: 0.4)
        defer { h.close() }
        h.fake.ignoresPlay = true
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "failed"))
        #expect(h.events.all.first { $0.hasPrefix("failed") }?.contains("didn't start playing") == true)
        #expect(!h.events.all.contains { $0.hasPrefix("started") })
        #expect(h.playback.snapshot.state == .stopped)
    }

    @Test("A renderer that refuses its next song plays on, and the next song is started when this one ends")
    func nextRefused() async throws {
        let h = try await Harness.make(kind: .av(setNext: true))
        defer { h.close() }
        h.fake.fail("SetNextAVTransportURI", code: 716, times: 100)
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started \(h.queue[0].url.lastPathComponent)"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.playback.snapshot.state == .playing)
        #expect(!h.events.all.contains { $0.hasPrefix("failed") })
        try await h.playToEnd()
        #expect(await h.events.wait(for: "started \(h.queue[1].url.lastPathComponent)"))
        let uri = try #require(h.fake.currentURI)
        #expect(await h.fake.fetched(uri) == (try Data(contentsOf: h.queue[1].url)))
    }

    @Test("A moment without an answer isn't a lost renderer: the song is kept and plays on")
    func briefSilence() async throws {
        let h = try await Harness.make(kind: .openHome, lostAfter: 30)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.fake.fail("TransportState", code: 501, times: 6)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!h.events.all.contains { $0.hasPrefix("lost") })
        #expect(h.playback.snapshot.state == .playing)
        #expect(h.playback.snapshot.item?.id == h.queue[0].id)
        #expect(h.playback.isEngaged)
    }

    @Test("A paused song stays paused when its stream is made again (a change of settings)")
    func pausedStaysPaused() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.playback.pause()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.fake.transportState == "Paused")
        // WAV is passed through here; digital volume would need a processed stream, which this harness has no maker for,
        // so the restart is asked for directly, as a seek in a processed stream does.
        h.playback.restartForTests(at: 10)
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.fake.transportState == "Paused")
        #expect(h.playback.snapshot.state == .paused)
        #expect(!h.playback.wantsPlaying)
    }

    @Test("Pause, resume and seek reach the renderer; the snapshot follows its position")
    func transportCommands() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.playback.pause()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.fake.transportState == "Paused")
        #expect(h.playback.snapshot.state == .paused)
        h.playback.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.fake.transportState == "Playing")
        h.playback.seek(to: 30)
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.fake.calls.contains { $0.action == "SeekSecondAbsolute" && $0.arguments["Value"] == "30" })
        #expect(abs(h.playback.snapshot.position - 30) < 2)
    }

    @Test("A queue edit replaces only the next song on the renderer")
    func queueEdit() async throws {
        let h = try await Harness.make(kind: .openHome, files: 3)
        defer { h.close() }
        let order = Locked([h.queue[0], h.queue[2], h.queue[1]])
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        let current = h.fake.currentURI
        let before = h.fake.playlistURIs
        h.playback.nextItemProvider = { finished in
            let q = order.withLock { $0 }
            guard let i = q.firstIndex(where: { $0.id == finished.id }), i + 1 < q.count else { return nil }
            return q[i + 1]
        }
        h.playback.queueChanged()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.fake.currentURI == current)
        #expect(h.fake.playlistURIs.count == 2)
        #expect(h.fake.playlistURIs.last != before.last)
        h.fake.advance()
        let next = try #require(await { () async -> String? in
            for _ in 0..<100 { if let u = h.fake.currentURI, u != current { return u }; try? await Task.sleep(for: .milliseconds(20)) }
            return nil
        }())
        #expect(await h.fake.fetched(next) == (try Data(contentsOf: h.queue[2].url)))
    }

    @Test("A skip loads the new song; the songs before it on the renderer are gone")
    func skip() async throws {
        let h = try await Harness.make(kind: .av(setNext: true))
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started \(h.queue[0].url.lastPathComponent)"))
        h.playback.play(h.queue[2])
        #expect(await h.events.wait(for: "started \(h.queue[2].url.lastPathComponent)"))
        let uri = try #require(h.fake.currentURI)
        #expect(await h.fake.fetched(uri) == (try Data(contentsOf: h.queue[2].url)))
        #expect(h.fake.nextURI == nil)   // nothing after the last
    }

    @Test("AV without SetNext: the next song still follows, and the path says gapless isn't guaranteed")
    func avWithoutSetNext() async throws {
        let h = try await Harness.make(kind: .av(setNext: false), files: 2)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started \(h.queue[0].url.lastPathComponent)"))
        #expect(h.playback.snapshot.signalPath?.renderer?.gapless == false)
        try await h.playToEnd()
        #expect(await h.events.wait(for: "started \(h.queue[1].url.lastPathComponent)"))
        let uri = try #require(h.fake.currentURI)
        #expect(await h.fake.fetched(uri) == (try Data(contentsOf: h.queue[1].url)))
        // And when the last one ends, the queue has ended.
        try await h.playToEnd()
        #expect(await h.events.wait(for: "ended"))
    }

    @Test("A renderer that stops answering is lost; one that refuses a song fails it")
    func failures() async throws {
        let h = try await Harness.make(kind: .av(setNext: true))
        h.fake.fail("SetAVTransportURI", code: 714)
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "failed"))
        #expect(h.events.all.first { $0.hasPrefix("failed") }?.contains("714") == true)
        h.playback.play(h.queue[1])
        #expect(await h.events.wait(for: "started"))
        h.fake.stop()
        #expect(await h.events.wait(for: "lost Fake Renderer"))
        h.playback.shutdown()
        h.media.stop()
    }

    @Test("Effects without a processed stream maker can't play; settings decide the mode")
    func modeDecision() throws {
        let item = PlayableItem(url: URL(fileURLWithPath: "/music/a.flac"))
        let caps = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*")
        #expect(RendererMode.decide(item: item, url: item.url, source: nil, settings: .init(), capabilities: caps) == .passThrough(mime: "audio/flac"))
        let eq = EQPreset(name: "Warm", preampDB: -3, bands: [])
        #expect(RendererMode.decide(item: item, url: item.url, source: nil, settings: .init(equalizer: eq), capabilities: caps) == .processed([.equalizer]))
        #expect(RendererMode.decide(item: item, url: item.url, source: nil, settings: .init(digitalVolumeDB: -6), capabilities: caps) == .processed([.volume]))
        #expect(RendererMode.decide(item: item, url: item.url, source: nil, settings: .init(digitalVolumeDB: 0), capabilities: caps) == .passThrough(mime: "audio/flac"))
        let gain = PlayableItem(url: item.url, replayGainDB: -4)
        #expect(RendererMode.decide(item: gain, url: item.url, source: nil, settings: .init(), capabilities: caps) == .processed([.replayGain]))
        let cue = PlayableItem(url: item.url, regionStartFrame: 100, regionFrameLength: 1000)
        #expect(RendererMode.decide(item: cue, url: item.url, source: nil, settings: .init(), capabilities: caps) == .processed([.format]))
        let wav = PlayableItem(url: URL(fileURLWithPath: "/music/a.wav"))
        #expect(RendererMode.decide(item: wav, url: wav.url, source: nil, settings: .init(), capabilities: caps) == .processed([.format]))
        let none = RendererCapabilities.parse(sink: "http-get:*:audio/mpeg:*")
        if case .unplayable = RendererMode.decide(item: wav, url: wav.url, source: nil, settings: .init(), capabilities: none) {} else { Issue.record("expected unplayable") }
        // A renderer that says nothing accepts everything.
        #expect(RendererMode.decide(item: wav, url: wav.url, source: nil, settings: .init(), capabilities: .init()) == .passThrough(mime: "audio/wav"))
    }
}

@Suite("Renderer playback: transient refusals", .serialized)
struct RendererTransientTests {
    @Test("Starting at a position waits for the renderer to play, and a 701 on that seek is tried again, not a failed song")
    func startAtPosition() async throws {
        let h = try await Harness.make(kind: .av(setNext: true))
        defer { h.close() }
        h.fake.fail("Seek", code: 701)   // "Transition not available" while it is still loading
        h.playback.play(h.queue[0], at: 30)
        #expect(await h.events.wait(for: "started"))
        for _ in 0..<100 where !h.fake.calls.contains(where: { $0.action == "Seek" && $0.arguments["Target"] == "0:00:30" && h.fake.calls.filter { $0.action == "Seek" }.count >= 2 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(h.fake.calls.filter { $0.action == "Seek" }.count >= 2)
        #expect(!h.events.all.contains { $0.hasPrefix("failed") })
        #expect(h.playback.snapshot.state == .playing)
    }

    @Test("A pause refused once is tried again and lands")
    func pauseRetried() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.fake.fail("Pause", code: 701)
        h.playback.pause()
        try await Task.sleep(for: .milliseconds(800))
        #expect(h.fake.transportState == "Paused")
        #expect(!h.events.all.contains { $0.hasPrefix("failed") })
    }

    @Test("A seek refused twice says so, and the song plays on (not stopped, not skipped)")
    func seekRefused() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        let uri = h.fake.currentURI
        h.fake.fail("SeekSecondAbsolute", code: 701, times: 2)
        h.playback.seek(to: 40)
        #expect(await h.events.wait(for: "notice"))
        #expect(!h.events.all.contains { $0.hasPrefix("failed") })
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.fake.transportState == "Playing")
        #expect(h.fake.currentURI == uri)
        #expect(h.playback.snapshot.state == .playing)
    }

    @Test("A pause refused twice leaves the snapshot as the player really is: playing, and still meant to play")
    func pauseRefusedTwice() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.fake.fail("Pause", code: 701, times: 2)
        h.playback.pause()
        #expect(await h.events.wait(for: "notice"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.fake.transportState == "Playing")
        #expect(h.playback.snapshot.state == .playing)
        #expect(h.playback.wantsPlaying)
    }

    @Test("A resume refused twice leaves it paused, and not meant to play")
    func resumeRefusedTwice() async throws {
        let h = try await Harness.make(kind: .openHome)
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started"))
        h.playback.pause()
        try await Task.sleep(for: .milliseconds(300))
        h.fake.fail("Play", code: 701, times: 2)
        h.playback.resume()
        #expect(await h.events.wait(for: "notice"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.fake.transportState == "Paused")
        #expect(h.playback.snapshot.state == .paused)
        #expect(!h.playback.wantsPlaying)
    }
}
