//
// Vespertine: room correction the way a listener goes through it, end to end and over and over: measure (through the
// measurement controller, against a simulated room with a resonance per speaker), keep it as a profile, play it
// (through the I/O-thread code), switch outputs, export and import, quit and start again. At every step what plays
// has to be what was measured and saved.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

/// One speaker as the microphone hears it: its delay, level and one resonance.
private struct StressSpeaker: Sendable {
    var gain: Double
    var delay: Double
    var modeHz: Double
    var modeDB: Double
    var modeQ: Double
}

/// A stereo room: `TestRoom` (delay and level per speaker) with each speaker's resonance on top.
private struct StressRoom: Sendable {
    var left = StressSpeaker(gain: 0.05, delay: 0.0081, modeHz: 120, modeDB: 9, modeQ: 4)
    var right = StressSpeaker(gain: 0.04, delay: 0.0094, modeHz: 180, modeDB: 7, modeQ: 3)

    func record(_ request: RoomCaptureRequest) -> [Float] {
        let rate = request.layout.sampleRate
        var heard = [Float](repeating: 0, count: request.layout.recordingFrames)
        for (channel, s) in [(0, left), (1, right)] {
            let alone = TestRoom(gain: [channel: s.gain], delay: [channel: s.delay]).record(request)
            let shaped = Self.peak(alone, hz: s.modeHz, db: s.modeDB, q: s.modeQ, rate: rate)
            for i in heard.indices where i < shaped.count { heard[i] += shaped[i] }
        }
        return heard
    }

    /// The resonance as a peaking biquad (RBJ), run over the recording.
    static func peak(_ x: [Float], hz: Double, db: Double, q: Double, rate: Double) -> [Float] {
        let a = pow(10, db / 40), w = 2 * Double.pi * hz / rate, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha / a
        let b0 = (1 + alpha * a) / a0, b1 = -2 * c / a0, b2 = (1 - alpha * a) / a0, a1 = -2 * c / a0, a2 = (1 - alpha / a) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return x.map { sample in
            let x0 = Double(sample)
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            return Float(y0)
        }
    }
}

/// The desk measured once, at two seats (the second with smaller resonances), and shared by the tests that start from
/// it: a measurement is by far the slowest step.
private actor DeskMeasurement {
    static let shared = DeskMeasurement()
    private var running: Task<RoomMeasurementResult, Error>?

    func result() async throws -> RoomMeasurementResult {
        if let running { return try await running.value }
        let task = Task {
            var moved = StressRoom()
            moved.left.modeDB = 6
            moved.right.modeDB = 5
            return try await Stress.measure(StressRoom(), on: "zd3", positions: 2, moved: moved, name: "Desk", in: try Stress.folder("measure"))
        }
        running = task
        return try await task.value
    }
}

private enum Stress {
    static let rate = 48_000.0
    static let created = Date(timeIntervalSince1970: 1_793_000_000)

    static func output(_ uid: String, channels: Int = 2) -> OutputDevice {
        OutputDevice(id: 0, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: rate,
                     capabilities: DeviceCapabilities(sampleRates: [rate], physicalFormats: [], outputChannels: channels, supportsDoP: true),
                     hasHardwareVolume: false, isDefault: false)
    }

    /// Measures `room` on output `uid` at `positions` seats, the way the app does, and returns the profile it makes.
    static func measure(_ room: StressRoom, on uid: String, positions: Int = 1, moved: StressRoom? = nil, name: String,
                        in folder: URL) async throws -> RoomMeasurementResult {
        var s = RoomMeasurementSettings(inputDevice: 91, outputDevice: 72)
        s.sampleRate = rate
        s.sweepSeconds = 1.5
        s.checkSweepSeconds = 1
        s.positions = positions
        s.minimumPeakToNoiseDB = 20
        s.routeMinimumPeakToNoiseDB = 10
        let session = RoomSession(id: UUID(), createdAt: created, deviceUID: uid, layout: .stereo, channelMap: .standard(.stereo),
                                  mic: RoomMic(serial: "7001234", orientation: .upward, calibrationSHA256: nil), target: .flat)
        let capturer = ScriptedCapturer { r, _ in room.record(r) }
        let controller = RoomMeasurementController(settings: s, session: session, capturer: capturer, folder: folder)
        var end = await controller.run()
        for position in 1..<max(positions, 1) {
            #expect(end == .waitingForMic(position: position))
            if let moved { capturer.room = { r, _ in moved.record(r) } }
            controller.confirmMicMoved()
            end = await controller.run()
        }
        #expect(end == .completed, "\(end) \(controller.log.last?.issues ?? [])")
        return try RoomMeasurementResult.make(recordings: controller.acceptedRecordings, session: controller.session, calibration: nil,
                                              name: name, micSerial: "7001234", options: RoomFilterDesignOptions(target: .flat),
                                              createdAt: created)
    }

    /// What the app hands the engine for `book` (`AppSettings.engineSettings`): a correction for each output that's on.
    static func engine(_ book: RoomProfileBook, impulses: URL) -> EngineSettings {
        var s = EngineSettings()
        s.roomCorrections = Dictionary(uniqueKeysWithValues: book.assignments.keys.compactMap { uid in
            book.active(for: uid).map { (uid, RoomCorrectionPlayback(profile: $0, impulseDirectory: impulses)) }
        })
        return s
    }

    /// A tone through the real I/O-thread code with `correction` installed: the settled peak per channel, in dB re the input.
    static func playedDB(_ correction: RoomCorrectionPlayback?, left: Double, right: Double) -> (left: Double, right: Double) {
        let frames = 48_000
        let input = (0..<frames).flatMap { i -> [Float] in
            let t = Double(i) / rate
            return [Float(0.25 * sin(2 * Double.pi * left * t)), Float(0.25 * sin(2 * Double.pi * right * t))]
        }
        let ring = nrt_ring_create(UInt32(2 * frames), 2)!
        let context = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
        nrt_context_set_gain(context, 1, 32)
        RoomCorrectionPlayback.install(correction, on: context, sampleRate: rate, channelCount: 2)
        #expect(nrt_ring_write(ring, input, UInt32(frames)) == UInt32(frames))
        var out = [Float](repeating: 0, count: input.count)
        nrt_context_render_interleaved(context, &out, UInt32(frames), 2)
        func peak(_ channel: Int) -> Double {
            // After 0.5 s: the filters (and any alignment delay) have settled.
            let p = stride(from: 24_000 * 2 + channel, to: out.count, by: 2).map { abs(Double(out[$0])) }.max() ?? 0
            return 20 * log10(p / 0.25)
        }
        return (peak(0), peak(1))
    }

    /// The level of `curve` at `hz` re its level at 1 kHz.
    static func relative(_ curve: RoomCurve, at hz: Double) -> Double {
        func at(_ f: Double) -> Double { curve.db[curve.frequencies.indices.min { abs(curve.frequencies[$0] - f) < abs(curve.frequencies[$1] - f) }!] }
        return at(hz) - at(1_000)
    }

    static func folder(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-stress-\(tag)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A measured filter (impulse response) written into `directory`, as an import of a measurement app's filter does.
    static func impulse(_ file: String, in directory: URL, seed: Int) throws -> RoomImpulse {
        var taps = [Float](repeating: 0, count: 256)
        taps[0] = 0.5
        for i in 1..<taps.count { taps[i] = Float((i * 37 + seed) % 23 - 11) * 0.0004 }
        try taps.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(file)) }
        return RoomImpulse(file: file, name: file, sampleRate: rate, frames: taps.count)
    }

    /// The `.f32` files in `directory`.
    static func impulseFiles(_ directory: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".f32") })
    }
}

@Suite("Room correction stress: measure, profile, play, switch outputs, export and import, restart", .serialized)
struct RoomProfileStressTests {
    @Test("Measured at two seats, the profile cuts each speaker's own resonance, and what plays is that profile at its strength")
    func measureToPlayback() async throws {
        let impulses = try Stress.folder("impulses")
        defer { try? FileManager.default.removeItem(at: impulses) }
        let result = try await DeskMeasurement.shared.result()

        // Measured: each speaker's resonance where it is, averaged over both seats, kept per seat for Advanced.
        let left = try #require(result.curves[.left]), right = try #require(result.curves[.right])
        #expect(Stress.relative(left, at: 120) > 5 && Stress.relative(left, at: 180) < Stress.relative(left, at: 120) - 3)
        #expect(Stress.relative(right, at: 180) > 4 && Stress.relative(right, at: 120) < Stress.relative(right, at: 180) - 2)
        let measured = result.profile
        #expect(measured.positionCount == 2 && measured.deviceUID == "zd3" && measured.source == .measured)
        // Lined up at the seat: the nearer left speaker waits for the right one (8.1 ms vs 9.4 ms).
        let delay = try #require(measured.alignment?[.left]?.delayMs)
        #expect(abs(delay - 1.3) < 0.15, "left delay \(delay) ms")

        // Kept as a profile, named and labelled, and switched on for the output.
        var book = RoomProfileBook()
        let desk = book.add(measured)
        try book.update(desk.id) { $0.tags = RoomProfileTags(speakers: "Fosi ZD3 + LS3", room: "Downstairs", position: "Desk") }
        book.setEnabled(true, for: "zd3")
        #expect(book.active(for: "zd3")?.id == desk.id)

        // Played through the I/O thread: the left resonance comes down, the right channel's own tone much less so,
        // and what is heard matches the profile's own response.
        let engine = Stress.engine(book, impulses: impulses)
        let playing = try #require(engine.roomCorrection(for: Stress.output("zd3")))
        #expect(playing.profileID == desk.id)
        let full = Stress.playedDB(playing, left: 120, right: 180)
        let open = Stress.playedDB(nil, left: 120, right: 180)
        #expect(abs(open.left) < 0.05 && abs(open.right) < 0.05)
        let predictedLeft = playing.responseDB(channel: 0, at: [120], sampleRate: Stress.rate)[0]   // bands, preamp and level
        #expect(abs(full.left - predictedLeft) < 0.5, "played \(full.left) dB, profile says \(predictedLeft) dB")
        #expect(full.left < -4, "the 120 Hz resonance is cut")
        #expect(full.right < -3, "the right speaker's 180 Hz resonance is cut")

        // Strength 50 %: about half the cut in dB; 0 %: nothing but level. Compare on Original: the correction is off.
        try book.update(desk.id) { $0.strength = 0.5 }
        let half = Stress.playedDB(Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("zd3")), left: 120, right: 180)
        #expect(half.left > full.left + 1.5 && half.left < -1)
        try book.update(desk.id) { $0.strength = 0 }
        let zero = Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("zd3"))
        let none = Stress.playedDB(zero, left: 120, right: 180)
        #expect((zero?.preampDB ?? 0) == 0 && zero?.channels.allSatisfy { $0.bands.allSatisfy { $0.gainDB == 0 } } != false)
        #expect(abs(none.left - (zero?.channels[0].levelDB ?? 0)) < 0.3 && abs(none.right - (zero?.channels[1].levelDB ?? 0)) < 0.3,
                "at 0 % only the speakers' level trims are left")
        try book.update(desk.id) { $0.strength = 1 }
        book.setEnabled(false, for: "zd3")
        #expect(Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("zd3")) == nil)
        book.setEnabled(true, for: "zd3")
        #expect(Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("zd3")) == playing)

        // Advanced: leaving the second seat out refits from the first one alone (a deeper cut: that seat had the bigger peak).
        var seatOnly = try #require(book.profile(desk.id))
        try seatOnly.setExcludedPositions([1])
        let refit = try seatOnly.redesigned()
        let refitLeft = Stress.playedDB(RoomCorrectionPlayback(profile: refit, impulseDirectory: impulses), left: 120, right: 180).left
        #expect(refitLeft < full.left - 0.5, "seat only \(refitLeft) dB vs both \(full.left) dB")
        #expect(throws: RoomProfileError.noPositionsLeft) { try seatOnly.setExcludedPositions([0, 1]) }
    }

    @Test("Switching outputs plays each output's own profile, never another's; off on one leaves the others; a new UID keeps it")
    func switchOutputs() async throws {
        let impulses = try Stress.folder("impulses")
        defer { try? FileManager.default.removeItem(at: impulses) }
        // The sofa's room (a 70 Hz resonance on both speakers), designed straight from its curves.
        let sofa = try ProfileFixtures.curve(ProfileFixtures.mode(70, 9, 3))
        let sofaDesign = try RoomFilterDesigner.design(channels: [.left: sofa, .right: sofa], options: RoomFilterDesignOptions(target: .flat))
        var book = RoomProfileBook()
        let desk = book.add(try await DeskMeasurement.shared.result().profile)
        let couch = book.add(sofaDesign.profile(name: "Sofa", sessionID: UUID(), deviceUID: "k11", channelMap: .standard(.stereo),
                                                micSerial: "7001234", calibrationSHA256: nil, createdAt: Stress.created))
        let deskNear = try book.duplicate(desk.id)
        book.setEnabled(true, for: "zd3")
        book.setEnabled(true, for: "k11")

        var engine = Stress.engine(book, impulses: impulses)
        #expect(engine.roomCorrection(for: Stress.output("zd3"))?.profileID == desk.id)
        #expect(engine.roomCorrection(for: Stress.output("k11"))?.profileID == couch.id)
        #expect(engine.roomCorrection(for: Stress.output("airpods")) == nil, "an output with no profile plays as it is")
        // Each output's own correction plays: the desk's cut is at 120 Hz, the sofa's at 70 Hz.
        let atDesk = Stress.playedDB(engine.roomCorrection(for: Stress.output("zd3")), left: 120, right: 70)
        let atSofa = Stress.playedDB(engine.roomCorrection(for: Stress.output("k11")), left: 120, right: 70)
        #expect(atDesk.left < atSofa.left - 3 && atSofa.right < atDesk.right - 3)

        // A profile made for another output is never chosen for this one.
        book.choose(couch.id, for: "zd3")
        #expect(book.active(for: "zd3")?.id == desk.id)
        // The other desk profile, then back: the engine follows each choice.
        book.choose(deskNear.id, for: "zd3")
        engine = Stress.engine(book, impulses: impulses)
        #expect(engine.roomCorrection(for: Stress.output("zd3"))?.profileID == deskNear.id)
        book.choose(desk.id, for: "zd3")
        // Off on one output leaves the other on, and keeps its choice for switching back on.
        book.setEnabled(false, for: "zd3")
        engine = Stress.engine(book, impulses: impulses)
        #expect(engine.roomCorrection(for: Stress.output("zd3")) == nil && engine.roomCorrection(for: Stress.output("k11"))?.profileID == couch.id)
        book.setEnabled(true, for: "zd3")
        #expect(book.active(for: "zd3")?.id == desk.id)
        // The same DAC on another USB port (new UID) keeps its profiles and its choice.
        book.moveDevice(from: "zd3", to: "zd3-port2")
        engine = Stress.engine(book, impulses: impulses)
        #expect(engine.roomCorrection(for: Stress.output("zd3-port2"))?.profileID == desk.id && engine.roomCorrection(for: Stress.output("zd3")) == nil)
        // Deleting the playing profile switches that output off, and only that one.
        book.delete(desk.id)
        #expect(!book.isEnabled("zd3-port2") && book.active(for: "k11")?.id == couch.id)
        #expect(book.profiles(for: "zd3-port2").map(\.id) == [deskNear.id])
    }

    @Test("Export and import, then quit and start again: every output plays exactly what it played before")
    func exportImportRestart() async throws {
        let here = try Stress.folder("here"), there = try Stress.folder("there"), data = try Stress.folder("data")
        defer { for url in [here, there, data] { try? FileManager.default.removeItem(at: url) } }
        var book = RoomProfileBook()
        var desk = book.add(try await DeskMeasurement.shared.result().profile)
        try book.update(desk.id) {
            $0.tags = RoomProfileTags(speakers: "LS3", room: "Downstairs", position: "Desk")
            $0.strength = 0.8
            $0.setAlignment(RoomSpeakerAlignment(delayMs: 0.7, levelDB: -1.2), for: .right)
            try $0.setBands([EQBand(kind: .peak, frequency: 118, gainDB: -7.5, q: 4.2), EQBand(kind: .lowShelf, frequency: 60, gainDB: 1.5, q: 0.7)], for: .left)
        }
        desk = try #require(book.profile(desk.id))
        // An imported measured filter (impulse responses), on another output.
        var ir = try ProfileFixtures.profile(name: "Studio", device: "k11")
        ir.impulses = [.left: try Stress.impulse("studio-left.f32", in: here, seed: 1), .right: try Stress.impulse("studio-right.f32", in: here, seed: 2)]
        ir = book.add(ir)
        // A copy made today (not on a whole second) has to come back from the file as it was, too.
        try book.duplicate(desk.id)
        book.setEnabled(true, for: "zd3")
        book.setEnabled(true, for: "k11")
        let before = Stress.engine(book, impulses: here)

        // Export both and import them on "another Mac" (an empty library, its own filter folder) for its own outputs.
        var other = RoomProfileBook()
        for (profile, uid) in [(desk, "mac2-dac"), (ir, "mac2-dac")] {
            let file = try RoomProfileArchive.encode(profile, impulseDirectory: here)
            let imported = other.add(try RoomProfileArchive.decode(file, into: there).retargeted(toDevice: uid, outputChannels: 2))
            #expect(imported.filters == profile.filters && imported.tags == profile.tags && imported.strength == profile.strength)
            #expect(imported.alignment == profile.alignment && imported.measured == profile.measured && imported.positionCurves == profile.positionCurves)
        }
        #expect(other.profiles(for: "mac2-dac").map(\.name).sorted() == ["Desk", "Studio"])
        // The measured filters arrived as files of their own, sample for sample.
        let arrived = try #require(other.profiles.first { $0.name == "Studio" }?.impulses?[.left])
        #expect(arrived.samples(in: there) == ir.impulses?[.left]?.samples(in: here))
        // An import on this Mac (same ids) is a second profile beside the original, never a replacement.
        let again = book.add(try RoomProfileArchive.decode(RoomProfileArchive.encode(desk, impulseDirectory: here), into: here), makeChosen: false)
        #expect(again.id != desk.id && again.name == "Desk 2" && book.active(for: "zd3")?.id == desk.id)

        // Quit and start again: the library file is read back into the same library, and every output plays the same.
        let store = RoomProfileStore(directory: data)
        try store.save(book, unreadable: [])
        let restarted = try #require(RoomProfileStore(directory: data).load()).book
        #expect(restarted == book)
        let after = Stress.engine(restarted, impulses: here)
        #expect(after.roomCorrections == before.roomCorrections)
        #expect(Stress.playedDB(after.roomCorrection(for: Stress.output("zd3")), left: 118, right: 1_000)
                == Stress.playedDB(before.roomCorrection(for: Stress.output("zd3")), left: 118, right: 1_000))

        // A crash halfway through the next save: the last good library is used, nothing is lost.
        var changed = restarted
        try changed.rename(desk.id, to: "Desk, after the move")
        try store.save(changed, unreadable: [])
        try Data("{\"version\": 1, \"profiles\": [".utf8).write(to: store.fileURL)
        let recovered = try #require(RoomProfileStore(directory: data).load()).book
        #expect(recovered == book, "the previous version (before the rename) is what's left")
    }

    @Test("Thirty rounds of switch, edit, export, import, delete and restart: nothing drifts, piles up or leaks")
    func manyRounds() async throws {
        let impulses = try Stress.folder("impulses"), data = try Stress.folder("data")
        defer { for url in [impulses, data] { try? FileManager.default.removeItem(at: url) } }
        var book = RoomProfileBook()
        let desk = book.add(try await DeskMeasurement.shared.result().profile)
        var studio = try ProfileFixtures.profile(name: "Studio", device: "k11")
        studio.impulses = [.left: try Stress.impulse("studio-left.f32", in: impulses, seed: 3)]
        studio = book.add(studio)
        let studioTaps = try #require(studio.impulses?[.left]?.samples(in: impulses))
        book.setEnabled(true, for: "zd3")
        book.setEnabled(true, for: "k11")
        let deskPlays = try #require(Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("zd3")))
        let store = RoomProfileStore(directory: data)
        var current = (desk: desk.id, studio: studio.id)

        for round in 0..<30 {
            // Switch: the other output, then back.
            book.setEnabled(round.isMultiple(of: 2), for: "k11")
            // Edit and undo an edit: strength down and back up.
            try book.update(current.desk) { $0.strength = 0.3 }
            try book.update(current.desk) { $0.strength = nil }
            // Export, import (a copy), make the copy the one playing, delete the original, rename the copy back.
            for uid in ["zd3", "k11"] {
                let id = uid == "zd3" ? current.desk : current.studio
                let original = try #require(book.profile(id))
                let wasOn = book.isEnabled(uid)
                let copy = book.add(try RoomProfileArchive.decode(RoomProfileArchive.encode(original, impulseDirectory: impulses), into: impulses))
                book.setEnabled(true, for: uid)
                for impulse in book.delete(original.id) { impulse.delete(in: impulses) }
                book.choose(copy.id, for: uid)
                book.setEnabled(wasOn, for: uid)
                try book.rename(copy.id, to: original.name)
                if uid == "zd3" { current.desk = copy.id } else { current.studio = copy.id }
            }
            // Quit and start again.
            try store.save(book, unreadable: [])
            book = try #require(RoomProfileStore(directory: data).load()).book

            #expect(book.profiles.count == 2, "round \(round)")
            #expect(book.profile(current.desk)?.name == "Desk" && book.profile(current.studio)?.name == "Studio", "round \(round)")
            let plays = try #require(Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("zd3")))
            #expect(plays.channels == deskPlays.channels && plays.preampDB == deskPlays.preampDB, "round \(round)")
            #expect((Stress.engine(book, impulses: impulses).roomCorrection(for: Stress.output("k11")) != nil) == round.isMultiple(of: 2))
            // Each import wrote its filter under a new name and each delete removed the old one: one file, not thirty.
            #expect(Stress.impulseFiles(impulses).count == 1, "round \(round): \(Stress.impulseFiles(impulses).sorted())")
        }
        let studioNow = try #require(book.profile(current.studio))
        #expect(studioNow.impulses?[.left]?.samples(in: impulses) == studioTaps, "the measured filter is still sample for sample the first one")
    }
}
