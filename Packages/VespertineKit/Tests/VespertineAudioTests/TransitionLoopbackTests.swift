//
// Vespertine — a crossfade through the real engine (PlaybackEngine's own planning, decks, segments and fader) to the
// "Vespertine Loopback" virtual device, recorded back and compared with the offline mixer sample for sample.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_LOOPBACK_TESTS=1 swift test --filter TransitionLoopback (needs the Vespertine Loopback device
// and audio input access for the test process). Nothing is audible: the device is virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transition loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_LOOPBACK_TESTS"] == "1"))
struct TransitionLoopbackTests {
    @Test("A crossfade played by the engine is the offline mix, sample for sample; Now Playing switches at its middle")
    func crossfadeThroughTheEngine() throws {
        let output = try #require(LoopbackGuard.dedicatedDevice(in: DeviceQuery.outputDevices(dopEnabledUIDs: [])), "no Vespertine Loopback device")
        try #require(LoopbackGuard.refusal(output) == nil)
        #expect(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        let rate = 48_000.0
        let (ua, _) = try TransitionGolden.song("loop-a", seconds: 4, seed: 301)
        let (ub, _) = try TransitionGolden.song("loop-b", seconds: 4, seed: 302)
        let items = [PlayableItem(url: ua), PlayableItem(url: ub)]
        var transitions = TransitionGolden.settings(1, curve: .equalPower)
        transitions.skip = .instant

        // What the offline mixer makes of it (no dither: a float device, nothing after the ring dithers either way).
        let offline = try GoldenRender.render(items, device: GoldenDevices.dac, transitions: transitions, dither: false)
        let mix = try #require(offline.mixes.first)
        let expected = try #require(offline.output.sessions.first).words.map { Float(bitPattern: $0) }
        let expectedFrames = expected.count / 2

        var settings = EngineSettings()
        settings.exclusive = true
        settings.deviceUID = output.uid
        settings.deviceName = output.name
        settings.ratePolicies = [output.uid: .matchSource]
        settings.spatialModes = [output.uid: .off]
        settings.transitions = transitions
        try? DeviceControl.setNominalRate(rate, on: output.id)
        let recorder = try LoopbackRecorder(device: output.id, rate: rate)
        try recorder.start()
        defer { recorder.restore() }

        let engine = PlaybackEngine()
        engine.update(settings: settings)
        engine.nextItemProvider = { finished in finished.id == items[0].id ? items[1] : nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        let started = Date()
        var played = false, switchedAt: Double?, lastA: Double?, badge = false, badgeAfterSwitch = false
        while Date().timeIntervalSince(started) < 8 + 10 {
            Thread.sleep(forTimeInterval: 0.01)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true }
            if snap.signalPath?.transition?.audible == true {
                badge = true
                #expect(snap.signalPath?.statusLine == "CROSSFADE")
                if switchedAt != nil { badgeAfterSwitch = true }
            }
            if switchedAt == nil, snap.item?.id == items[0].id, snap.state == .playing { lastA = snap.position }
            if switchedAt == nil, snap.item?.id == items[1].id { switchedAt = snap.position }
            if played, snap.state == .stopped { break }
        }
        let tailEnd = Date().addingTimeInterval(0.4)
        while Date() < tailEnd { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
        #expect(played)
        #expect(badge, "the badge never said CROSSFADE")
        #expect(badgeAfterSwitch, "the badge went before the middle of the crossfade")
        // B became the song playing half a crossfade into itself: never before (B's first position seen is past the
        // middle), never after (A's last position seen is before it). Polling only ever sees the switch late, so these
        // two bounds hold whatever the polling jitter; one I/O buffer of slack.
        let half = Double(mix.length / 2) / rate
        let middleOfA = Double(Int(mix.ringFrame) + mix.length / 2) / rate
        let slack = 0.012
        let switched = try #require(switchedAt, "Now Playing never switched")
        let beforeSwitch = try #require(lastA)
        #expect(switched >= half - slack && switched < half + 0.5, "the next song showed at \(switched) s into itself, the middle is \(half) s")
        #expect(beforeSwitch <= middleOfA + slack && beforeSwitch > middleOfA - 0.5, "the song was still shown at \(beforeSwitch) s, the middle is \(middleOfA) s")

        // Line the recording up with the offline output after the start's fade in (0.25 s), then compare every frame.
        let captured = recorder.samples
        try #require(captured.count >= 2)
        let left = captured[0], right = captured[1]
        let anchor = Int(rate * 0.5)          // half a second in: past the fade in
        let probe = 64
        var offset: Int?
        search: for p in 0..<max(0, left.count - expectedFrames + anchor) {
            for j in 0..<probe where left[p + j] != expected[(anchor + j) * 2] || right[p + j] != expected[(anchor + j) * 2 + 1] { continue search }
            offset = p - anchor
            break
        }
        let start = try #require(offset, "the recording never matched the offline output")
        var wrong = 0, first: Int?
        for f in anchor..<expectedFrames {
            let i = start + f
            guard i < left.count else { wrong += expectedFrames - f; first = first ?? f; break }
            if left[i] != expected[f * 2] || right[i] != expected[f * 2 + 1] { wrong += 1; first = first ?? f }
        }
        #expect(wrong == 0, "\(wrong) frames differ from the offline mix, the first at \(first ?? -1) (overlap \(mix.ringFrame)…\(mix.ringFrame + UInt64(mix.length)))")
        #expect(recorder.discontinuityCount == 0)
    }

    /// The engine on the loopback device with `transitions`, and a recorder on it.
    private func rig(_ transitions: TransitionSettings) throws -> (PlaybackEngine, LoopbackRecorder, OutputDevice) {
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
        return (engine, recorder, output)
    }

    /// Where `want` (interleaved stereo, from its frame `anchor` on, 64 frames) starts in the recording, as an offset
    /// to add to `want`'s frame numbers.
    private func offset(of want: [Float], anchor: Int, in left: [Float], _ right: [Float]) -> Int? {
        let probe = 64
        guard want.count / 2 >= anchor + probe else { return nil }
        search: for p in 0..<max(0, left.count - probe) {
            for j in 0..<probe where left[p + j] != want[(anchor + j) * 2] || right[p + j] != want[(anchor + j) * 2 + 1] { continue search }
            return p - anchor
        }
        return nil
    }

    @Test("Smart Mix through the engine (a quick cut, measured just in time) is the offline mix, sample for sample")
    func smartMixThroughTheEngine() throws {
        let a = try SmartGolden.song("loop-cold-a", seconds: 5, seed: 321, silentTail: 0.3)
        let b = try SmartGolden.song("loop-cold-b", seconds: 5, seed: 322, silentHead: 0.2)
        let items = [PlayableItem(url: a.0), PlayableItem(url: b.0)]
        var transitions = SmartGolden.smart
        transitions.skip = .instant
        let offline = try GoldenRender.render(items, device: GoldenDevices.dac, transitions: transitions, dither: false)
        guard case .mix(let shape) = try #require(offline.decisions.first) else { Issue.record("\(offline.decisions)"); return }
        #expect(shape.kind == .coldCut)
        let expected = try #require(offline.output.sessions.first).words.map { Float(bitPattern: $0) }
        let (engine, recorder, _) = try rig(transitions)
        defer { recorder.restore() }
        engine.nextItemProvider = { finished in finished.id == items[0].id ? items[1] : nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        let started = Date()
        var played = false, mixing = false
        while Date().timeIntervalSince(started) < 10 + 10 {
            Thread.sleep(forTimeInterval: 0.01)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true }
            if snap.signalPath?.transition?.audible == true { mixing = true; #expect(snap.signalPath?.statusLine == "MIXING") }
            if played, snap.state == .stopped { break }
        }
        let tailEnd = Date().addingTimeInterval(0.4)
        while Date() < tailEnd { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
        #expect(played && mixing)
        let captured = recorder.samples
        try #require(captured.count >= 2)
        let anchor = 24_000
        let start = try #require(offset(of: expected, anchor: anchor, in: captured[0], captured[1]), "the recording never matched the offline output")
        var wrong = 0, first: Int?
        for f in anchor..<(expected.count / 2) {
            let i = start + f
            guard i < captured[0].count else { wrong += expected.count / 2 - f; first = first ?? f; break }
            if captured[0][i] != expected[f * 2] || captured[1][i] != expected[f * 2 + 1] { wrong += 1; first = first ?? f }
        }
        #expect(wrong == 0, "\(wrong) frames differ from the offline Smart Mix, the first at \(first ?? -1); mixes \(offline.mixes)")
        #expect(recorder.discontinuityCount == 0)
    }

    @Test("A skip that crossfades: the old song exact up to the cut, the blend exact for the curve, then the new song exact")
    func skipCrossfade() throws {
        let (ua, sa) = try TransitionGolden.song("loop-skip-a", seconds: 8, seed: 331)
        let (ub, sb) = try TransitionGolden.song("loop-skip-b", seconds: 6, seed: 332)
        let items = [PlayableItem(url: ua), PlayableItem(url: ub)]
        var transitions = TransitionGolden.settings(1, curve: .equalPower)
        transitions.skip = .crossfade
        let (engine, recorder, _) = try rig(transitions)
        defer { recorder.restore() }
        engine.nextItemProvider = { _ in nil }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        var started = Date(), skipped = false, badge = false, switched = false
        while Date().timeIntervalSince(started) < 20 {
            Thread.sleep(forTimeInterval: 0.01)
            recorder.drain()
            let snap = engine.snapshot
            if !skipped, snap.state == .playing, snap.position >= 2 {
                engine.play(items[1])
                skipped = true
                started = Date()
            }
            if skipped, snap.signalPath?.transition?.audible == true { badge = true }
            if skipped, snap.item?.id == items[1].id { switched = true }
            if skipped, switched, Date().timeIntervalSince(started) > 4 { break }
        }
        engine.stopAndWait()
        recorder.stop()
        #expect(skipped && badge && switched)
        let left = recorder.samples[0], right = recorder.samples[1]
        let fa = TransitionGolden.floats(sa), fb = TransitionGolden.floats(sb)
        // A, half a second in (past the start's fade in), lines up with the recording.
        let aStart = try #require(offset(of: fa, anchor: 24_000, in: left, right), "A not found")
        // A plays exactly until the overlap: its first frame is A's own (gains 1 and 0), so the cut is the frame
        // before the first one that differs.
        var cut = 24_000
        while cut < fa.count / 2, aStart + cut < left.count, left[aStart + cut] == fa[cut * 2], right[aStart + cut] == fa[cut * 2 + 1] { cut += 1 }
        cut -= 1
        #expect(cut > 96_000 && cut < 96_000 + 72_000, "the blend began at A's frame \(cut)")
        let length = 48_000
        var wrong = 0, firstWrong: Int?
        for k in 0..<length {
            let g = TransitionCurve.equalPower.gains(at: Double(k) / Double(length))
            let ga = Float(g.out), gb = Float(g.in)
            let i = aStart + cut + k
            guard i < left.count else { wrong += length - k; break }
            let wantL: Float = fa[(cut + k) * 2] * ga + fb[k * 2] * gb
            let wantR: Float = fa[(cut + k) * 2 + 1] * ga + fb[k * 2 + 1] * gb
            if left[i] != wantL || right[i] != wantR {
                wrong += 1; firstWrong = firstWrong ?? k
            }
        }
        #expect(wrong == 0, "\(wrong) blend frames differ, the first at \(firstWrong ?? -1)")
        // Then B, exactly, from the end of the blend on.
        for k in length..<min(fb.count / 2, length + 48_000) {
            let i = aStart + cut + k
            guard i < left.count else { break }
            if left[i] != fb[k * 2] || right[i] != fb[k * 2 + 1] { Issue.record("B differs at its frame \(k)"); break }
        }
        #expect(recorder.discontinuityCount == 0)
    }
}
