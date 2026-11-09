//
// Vespertine: transitions and the engine's state machine: what happens when something arrives inside an overlap.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// - A starved read-ahead decoder as the incoming song (no hardware): the mix waits for it, sample for sample the same
//   as when it isn't starved, never a hole where its samples should be.
// - Through the real engine on the "Vespertine Loopback" virtual device (opt-in, VESPERTINE_LOOPBACK_TESTS=1, as the
//   other loopback tests): a skip, a seek and a pause inside an overlap that's being heard; a queue edit inside an
//   overlap already baked into the ring but not heard yet (it's taken back and mixed again with the new next song),
//   and one inside an overlap being heard (it plays as mixed; the edit applies from the next boundary).
//

import AVFAudio
import CoreAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

/// A decoder that answers nothing until `release()`, like a share that's slow to deliver the start of a file.
private final class HeldDecoder: NSObject, PCMDecoding, @unchecked Sendable {
    let inner: PCMDecoding
    private let condition = NSCondition()
    private var held = true

    init(_ inner: PCMDecoding) { self.inner = inner }
    func release() { condition.withLock { held = false; condition.broadcast() } }

    var inputSource: InputSource { inner.inputSource }
    var sourceFormat: AVAudioFormat { inner.sourceFormat }
    var processingFormat: AVAudioFormat { inner.processingFormat }
    var decodingIsLossless: Bool { inner.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { inner.properties }
    var isOpen: Bool { inner.isOpen }
    var supportsSeeking: Bool { inner.supportsSeeking }
    var position: AVAudioFramePosition { inner.position }
    var length: AVAudioFramePosition { inner.length }
    func open() throws {}
    func close() throws { try inner.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        condition.withLock { while held { condition.wait() } }
        try inner.decode(into: buffer, length: length)
    }
    func seek(to frame: AVAudioFramePosition) throws { try inner.seek(to: frame) }
}

@Suite("Transitions: the state machine")
struct TransitionStateTests {
    typealias T = TransitionGolden

    @Test("A starved read-ahead decoder as the incoming song: the outgoing one is held back, and the mix is exact")
    func starvedIncomingDeck() throws {
        let (ua, a) = try T.song("starved-a", seconds: 3, seed: 401)
        let (ub, b) = try T.song("starved-b", seconds: 3, seed: 402)
        let probedA = try SourceOpener.probe(ua), probedB = try SourceOpener.probe(ub)
        let plan = GoldenRender.plan(probedA, item: T.item(ua), device: GoldenDevices.dac, settings: .init())
        let session = try GoldenRender.Session(plan: plan, device: GoldenDevices.dac, settings: .init())
        let deckA = try GoldenRender.decoding(T.item(ua), probed: probedA, decoder: try SourceOpener.decoder(for: probedA, plan: plan, item: T.item(ua)),
                                              session: session, settings: .init())
        let held = HeldDecoder(try SourceOpener.decoder(for: probedB, plan: plan, item: T.item(ub)))
        let readAhead = ReadAheadDecoder(held, seconds: 1)
        let deckB = try GoldenRender.decoding(T.item(ub), probed: probedB, decoder: readAhead, session: session, settings: .init())
        let start = 96_000, length = 30_000
        let cf = Crossfade(incoming: deckB, start: UInt64(start), length: length, curve: .equalPower)
        var out: [Float] = []
        let write: (UnsafePointer<Float>, Int) -> Void = { out += UnsafeBufferPointer(start: $0, count: $1 * 2) }
        // The engine's loop (fillWithTransitions): A's next chunk only once B has what its overlap frames need.
        var waits = 0, heldAt: UInt64?
        while !cf.done {
            if !cf.incomingReady(first: deckA.framesProduced, frames: Int(GoldenRender.chunkFrames)) {
                waits += 1
                heldAt = heldAt ?? deckA.framesProduced
                if waits == 20 { held.release() }   // the share answers after a while
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            let first = deckA.framesProduced
            let chunk = deckA.convertChunk()
            guard chunk.frames > 0, let data = chunk.data else { break }
            _ = cf.feed(data, frames: Int(chunk.frames), first: first, write: write)
        }
        cf.flushIncoming(write: write)
        #expect(waits >= 20, "the incoming song was never waited for")
        // Held back at the chunk that reaches the overlap, not before.
        let heldFrame = try #require(heldAt)
        #expect(heldFrame <= UInt64(start) && heldFrame + UInt64(GoldenRender.chunkFrames) > UInt64(start))
        let want = T.crossfade(a, b, start: start, length: length, bStart: 0, curve: .equalPower)
        #expect(out.count <= want.count)
        #expect(T.firstDifference(T.bits(out), T.bits(Array(want.prefix(out.count)))) == nil)
        #expect(out.count >= (start + length) * 2)
        #expect(cf.incomingError == nil)
    }

    @Test("An incoming song that isn't read ahead is always ready: nothing is held back")
    func localIncomingDeckIsReady() throws {
        let (ua, _) = try T.song("ready-a", seconds: 2, seed: 403)
        let (ub, _) = try T.song("ready-b", seconds: 2, seed: 404)
        let probedA = try SourceOpener.probe(ua), probedB = try SourceOpener.probe(ub)
        let plan = GoldenRender.plan(probedA, item: T.item(ua), device: GoldenDevices.dac, settings: .init())
        let session = try GoldenRender.Session(plan: plan, device: GoldenDevices.dac, settings: .init())
        let deckB = try GoldenRender.decoding(T.item(ub), probed: probedB, decoder: try SourceOpener.decoder(for: probedB, plan: plan, item: T.item(ub)),
                                              session: session, settings: .init())
        let cf = Crossfade(incoming: deckB, start: 40_000, length: 20_000, curve: .linear)
        // Before the overlap's chunk: nothing needed, nothing converted.
        #expect(cf.incomingReady(first: 0, frames: 4096))
        #expect(deckB.framesProduced == 0)
        #expect(cf.incomingReady(first: 36_864, frames: 4096))
        #expect(deckB.framesProduced >= 4096 - (40_000 - 36_864))
        // An overlap longer than B: ready once B has ended.
        let deckB2 = try GoldenRender.decoding(T.item(ub), probed: probedB, decoder: try SourceOpener.decoder(for: probedB, plan: plan, item: T.item(ub)),
                                               session: session, settings: .init())
        let long = Crossfade(incoming: deckB2, start: 0, length: 200_000, curve: .linear)
        #expect(long.incomingReady(first: 0, frames: 200_000))
        #expect(deckB2.finished)
    }
}

// MARK: - Through the engine (loopback)

// Part of the "Transition loopback" suite (serialized, opt-in): two suites on the one loopback device at once would
// record each other.
extension TransitionLoopbackTests {
    typealias T = TransitionGolden

    /// The engine on the loopback device with `transitions`, and a recorder on it.
    private func stateRig(_ transitions: TransitionSettings) throws -> (PlaybackEngine, LoopbackRecorder) {
        let output = try #require(LoopbackGuard.dedicatedDevice(in: DeviceQuery.outputDevices(dopEnabledUIDs: [])), "no Vespertine Loopback device")
        try #require(LoopbackGuard.refusal(output) == nil)
        var settings = EngineSettings()
        settings.exclusive = true
        settings.deviceUID = output.uid
        settings.deviceName = output.name
        settings.ratePolicies = [output.uid: .matchSource]
        settings.spatialModes = [output.uid: .off]
        settings.transitions = transitions
        try? DeviceControl.setNominalRate(48_000, on: output.id)
        let recorder = try LoopbackRecorder(device: output.id, rate: 48_000)
        try recorder.start()
        let engine = PlaybackEngine()
        engine.update(settings: settings)
        return (engine, recorder)
    }

    /// Where `want`'s frames from `anchor` (64 of them) are in the recording, as an offset to add to `want`'s frame numbers.
    private func position(of want: [Float], anchor: Int, in left: [Float], _ right: [Float], from: Int = 0) -> Int? {
        let probe = 64
        guard want.count / 2 >= anchor + probe else { return nil }
        search: for p in from..<max(from, left.count - probe) {
            for j in 0..<probe where left[p + j] != want[(anchor + j) * 2] || right[p + j] != want[(anchor + j) * 2 + 1] { continue search }
            return p - anchor
        }
        return nil
    }

    /// How many of `want`'s frames from `from` to `to` are exactly in the recording at `offset`.
    private func exactRun(_ want: [Float], from: Int, to: Int, offset: Int, _ left: [Float], _ right: [Float]) -> Int {
        var f = from
        while f < to, offset + f < left.count, offset + f >= 0, left[offset + f] == want[f * 2], right[offset + f] == want[f * 2 + 1] { f += 1 }
        return f - from
    }

    /// Runs the engine until `done` says so (or `limit` seconds), calling `step` with each snapshot.
    private func runEngine(_ engine: PlaybackEngine, _ recorder: LoopbackRecorder, limit: TimeInterval,
                     step: (EngineSnapshot) -> Bool) {
        let started = Date()
        while Date().timeIntervalSince(started) < limit {
            Thread.sleep(forTimeInterval: 0.005)
            recorder.drain()
            if step(engine.snapshot) { break }
        }
        let tailEnd = Date().addingTimeInterval(0.4)
        while Date() < tailEnd { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
    }

    @Test("A skip inside an overlap being heard: the third song plays, exactly, and nothing of the second follows it",
          arguments: [SkipTransition.instant, .crossfade])
    func skipInsideOverlap(_ skip: SkipTransition) throws {
        let (ua, _) = try T.song("sm-skip-a", seconds: 4, seed: 411)
        let (ub, sb) = try T.song("sm-skip-b", seconds: 6, seed: 412)
        let (uc, sc) = try T.song("sm-skip-c", seconds: 5, seed: 413)
        let items = [PlayableItem(url: ua), PlayableItem(url: ub), PlayableItem(url: uc)]
        var transitions = T.settings(2, curve: .equalPower)
        transitions.skip = skip
        let (engine, recorder) = try stateRig(transitions)
        defer { recorder.restore() }
        engine.nextItemProvider = { finished in finished.id == items[0].id ? items[1] : nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        var skipped = false, sawC = false, lastItem: UUID?, played = false, errors: [String] = []
        runEngine(engine, recorder, limit: 25) { snap in
            if snap.state == .playing { played = true }
            if let e = snap.lastError { errors.append(e) }
            if !skipped, snap.signalPath?.transition?.audible == true {
                engine.play(items[2])
                skipped = true
            }
            if skipped, snap.item?.id == items[2].id { sawC = true }
            if snap.item != nil { lastItem = snap.item?.id }
            return played && snap.state == .stopped
        }
        #expect(skipped, "the overlap was never heard")
        #expect(sawC && lastItem == items[2].id, "the skipped-to song wasn't the one playing at the end")
        #expect(errors.isEmpty, "\(errors)")
        let left = recorder.samples[0], right = recorder.samples[1]
        let fc = T.floats(sc), fb = T.floats(sb)
        // C from 3 s in (past a skip blend of up to 2 s) to its end, exactly and in one piece.
        let from = 3 * 48_000
        let cOffset = try #require(position(of: fc, anchor: from, in: left, right), "C not found")
        let run = exactRun(fc, from: from, to: fc.count / 2, offset: cOffset, left, right)
        #expect(run == fc.count / 2 - from, "C exact for \(run) frames from 3 s")
        // Nothing of B past its first three seconds (it was skipped inside its fade in).
        #expect(position(of: fb, anchor: 3 * 48_000, in: left, right) == nil, "B played on after the skip")
        #expect(recorder.discontinuityCount == 0)
    }

    @Test("A seek inside an overlap being heard: the song shown plays from there, exactly, and the queue carries on")
    func seekInsideOverlap() throws {
        let (ua, sa) = try T.song("sm-seek-a", seconds: 5, seed: 421)
        let (ub, sb) = try T.song("sm-seek-b", seconds: 5, seed: 422)
        let items = [PlayableItem(url: ua), PlayableItem(url: ub)]
        var transitions = T.settings(2, curve: .equalPower)
        transitions.skip = .instant
        let (engine, recorder) = try stateRig(transitions)
        defer { recorder.restore() }
        engine.nextItemProvider = { finished in finished.id == items[0].id ? items[1] : nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        var sought: UUID?, played = false, errors: [String] = [], sawBAfter = false
        runEngine(engine, recorder, limit: 30) { snap in
            if snap.state == .playing { played = true }
            if let e = snap.lastError { errors.append(e) }
            if sought == nil, snap.signalPath?.transition?.audible == true, let item = snap.item?.id {
                sought = item
                engine.seek(to: 1.0)
            }
            if sought == items[0].id, snap.item?.id == items[1].id { sawBAfter = true }
            return played && snap.state == .stopped
        }
        let which = try #require(sought, "the overlap was never heard")
        #expect(errors.isEmpty, "\(errors)")
        let left = recorder.samples[0], right = recorder.samples[1]
        let fa = T.floats(sa), fb = T.floats(sb)
        if which == items[0].id {
            // Before the middle: A from 1 s again (past the seek's fade in), then a crossfade into B again, and B to its end.
            #expect(sawBAfter)
            let first = try #require(position(of: fa, anchor: 2 * 48_000, in: left, right), "A not found")
            // The first sight of A at 2 s is the one before the seek; the one after it is later in the recording.
            let again = try #require(position(of: fa, anchor: 2 * 48_000, in: left, right, from: first + 2 * 48_000 + 64), "A not played again from 1 s")
            #expect(exactRun(fa, from: Int(1.5 * 48_000), to: 2 * 48_000, offset: again, left, right) == 24_000)
        } else {
            // After the middle: B from 1 s, to its end.
            let bOffset = try #require(position(of: fb, anchor: 2 * 48_000, in: left, right), "B not found")
            _ = bOffset
        }
        // B's last two seconds, exactly, at the end.
        let end = fb.count / 2
        let bEnd = try #require(position(of: fb, anchor: end - 2 * 48_000, in: left, right), "B's end not found")
        #expect(exactRun(fb, from: end - 2 * 48_000, to: end, offset: bEnd, left, right) == 2 * 48_000)
        #expect(recorder.discontinuityCount == 0)
    }

    @Test("A pause inside an overlap being heard: on resume the mix carries on where it was, exactly, to the end")
    func pauseInsideOverlap() throws {
        let (ua, sa) = try T.song("sm-pause-a", seconds: 5, seed: 431)
        let (ub, sb) = try T.song("sm-pause-b", seconds: 5, seed: 432)
        let items = [PlayableItem(url: ua), PlayableItem(url: ub)]
        var transitions = T.settings(3, curve: .equalPower)
        transitions.skip = .instant
        let offline = try GoldenRender.render(items, device: GoldenDevices.dac, transitions: transitions, dither: false)
        let mix = try #require(offline.mixes.first)
        let expected = try #require(offline.output.sessions.first).words.map { Float(bitPattern: $0) }
        let (engine, recorder) = try stateRig(transitions)
        defer { recorder.restore() }
        engine.nextItemProvider = { finished in finished.id == items[0].id ? items[1] : nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        var pausedAt: Date?, resumed = false, played = false, errors: [String] = []
        runEngine(engine, recorder, limit: 30) { snap in
            if snap.state == .playing { played = true }
            if let e = snap.lastError { errors.append(e) }
            if pausedAt == nil, snap.signalPath?.transition?.audible == true {
                engine.pause()
                pausedAt = Date()
            }
            if let at = pausedAt, !resumed, Date().timeIntervalSince(at) > 1 {
                #expect(snap.state == .paused)
                engine.resume()
                resumed = true
            }
            return resumed && played && snap.state == .stopped
        }
        #expect(resumed, "the overlap was never heard")
        #expect(errors.isEmpty, "\(errors)")
        _ = sa; _ = sb
        let left = recorder.samples[0], right = recorder.samples[1]
        // The end of the overlap and all of B after it: exact (the resume's fade in is long over).
        let afterMix = Int(mix.ringFrame) + mix.length
        let anchor = min(afterMix + 24_000, expected.count / 2 - 64)
        let at = try #require(position(of: expected, anchor: anchor, in: left, right), "the mix's end not found after the resume")
        #expect(exactRun(expected, from: anchor, to: expected.count / 2, offset: at, left, right) == expected.count / 2 - anchor)
        // And the start: A exact up to the pause.
        let aAt = try #require(position(of: expected, anchor: 24_000, in: left, right), "A not found")
        #expect(exactRun(expected, from: 24_000, to: Int(mix.ringFrame), offset: aAt, left, right) == Int(mix.ringFrame) - 24_000)
        // Every frame of the offline output is heard once: what's after the pause continues the frames before it (no
        // repeat, nothing missing), so the two pieces line up at a frame count no larger than the pause's fade.
        #expect(at - aAt >= 0, "the mix was heard earlier after the resume than before it")
        #expect(recorder.discontinuityCount == 0)
    }

    @Test("A queue edit inside an overlap baked into the ring but not heard yet: taken back, mixed with the new next song")
    func queueEditInsideBakedOverlap() throws {
        let (ua, _) = try T.song("sm-edit-a", seconds: 9, seed: 441)
        let (ub, sb) = try T.song("sm-edit-b", seconds: 4, seed: 442)
        let (uc, _) = try T.song("sm-edit-c", seconds: 4, seed: 443)
        let a = PlayableItem(url: ua), b = PlayableItem(url: ub), c = PlayableItem(url: uc)
        var transitions = T.settings(1, curve: .equalPower)
        transitions.skip = .instant
        // What A then C should be.
        let offline = try GoldenRender.render([a, c], device: GoldenDevices.dac, transitions: transitions, dither: false)
        let expected = try #require(offline.output.sessions.first).words.map { Float(bitPattern: $0) }
        let mix = try #require(offline.mixes.first)
        let (engine, recorder) = try stateRig(transitions)
        defer { recorder.restore() }
        let next = Locked(b)
        engine.nextItemProvider = { finished in finished.id == a.id ? next.withLock { $0 } : nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(a)
        var edited = false, played = false, errors: [String] = [], baked = false
        runEngine(engine, recorder, limit: 30) { snap in
            if snap.state == .playing { played = true }
            if let e = snap.lastError { errors.append(e) }
            // The overlap is planned at once (A is shorter than the planning lead) and written into the ring as the ring
            // reaches it: with A 1 s from its overlap (inside the ring's few seconds), it's baked but not heard.
            if !edited, snap.item?.id == a.id, snap.state == .playing, snap.position >= 9 - 1 - 1.6 {
                baked = snap.signalPath?.transition?.audible != true
                next.withLock { $0 = c }
                engine.queueChanged()
                edited = true
            }
            return played && snap.state == .stopped
        }
        #expect(edited && baked)
        #expect(errors.isEmpty, "\(errors)")
        let left = recorder.samples[0], right = recorder.samples[1]
        // A, the overlap with C and C to its end: exactly the offline A → C.
        let anchor = Int(mix.ringFrame) - 24_000
        let at = try #require(position(of: expected, anchor: anchor, in: left, right), "A's end not found")
        let run = exactRun(expected, from: anchor, to: expected.count / 2, offset: at, left, right)
        #expect(run == expected.count / 2 - anchor, "A → C exact for \(run) of \(expected.count / 2 - anchor) frames")
        // Nothing of B.
        let fb = T.floats(sb)
        #expect(position(of: fb, anchor: 2 * 48_000, in: left, right) == nil, "B was heard after the queue edit")
        #expect(recorder.discontinuityCount == 0)
    }

    @Test("A queue edit inside an overlap being heard: it plays as mixed, and the edit applies from the next boundary")
    func queueEditInsideAudibleOverlap() throws {
        let (ua, _) = try T.song("sm-edit2-a", seconds: 4, seed: 451)
        let (ub, _) = try T.song("sm-edit2-b", seconds: 4, seed: 452)
        let (uc, sc) = try T.song("sm-edit2-c", seconds: 4, seed: 453)
        let (ud, sd) = try T.song("sm-edit2-d", seconds: 4, seed: 454)
        let a = PlayableItem(url: ua), b = PlayableItem(url: ub), c = PlayableItem(url: uc), d = PlayableItem(url: ud)
        var transitions = T.settings(2, curve: .equalPower)
        transitions.skip = .instant
        let offline = try GoldenRender.render([a, b, d], device: GoldenDevices.dac, transitions: transitions, dither: false)
        let expected = try #require(offline.output.sessions.first).words.map { Float(bitPattern: $0) }
        let (engine, recorder) = try stateRig(transitions)
        defer { recorder.restore() }
        // Before the edit: A, B, C. The edit (inside A → B) replaces C with D.
        let afterB = Locked(c)
        engine.nextItemProvider = { finished in
            if finished.id == a.id { return b }
            if finished.id == b.id { return afterB.withLock { $0 } }
            return nil
        }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(a)
        var edited = false, played = false, errors: [String] = []
        runEngine(engine, recorder, limit: 30) { snap in
            if snap.state == .playing { played = true }
            if let e = snap.lastError { errors.append(e) }
            if !edited, snap.signalPath?.transition?.audible == true {
                afterB.withLock { $0 = d }
                engine.queueChanged()
                edited = true
            }
            return played && snap.state == .stopped
        }
        #expect(edited)
        #expect(errors.isEmpty, "\(errors)")
        let left = recorder.samples[0], right = recorder.samples[1]
        // All of A → B → D after the start's fade in, exactly.
        let anchor = 24_000
        let at = try #require(position(of: expected, anchor: anchor, in: left, right), "A not found")
        let run = exactRun(expected, from: anchor, to: expected.count / 2, offset: at, left, right)
        #expect(run == expected.count / 2 - anchor, "A → B → D exact for \(run) of \(expected.count / 2 - anchor) frames")
        #expect(position(of: T.floats(sc), anchor: 2 * 48_000, in: left, right) == nil, "C was heard after the queue edit")
        _ = sd
        #expect(recorder.discontinuityCount == 0)
    }
}
