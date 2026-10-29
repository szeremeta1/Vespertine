//
// Vespertine — room correction filter design: a cut-dominant parametric fit to a target curve, with bounded boost,
// no boost below the speaker's roll-off, a correction range and a preamp that keeps the result out of clipping.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A 48-points-per-octave curve from 25 Hz to 16 kHz with `shape(f)` in dB.
private func curve(_ shape: (Double) -> Double) throws -> RoomCurve {
    let n = Int((log2(16_000.0 / 25) * 48).rounded(.down)) + 1
    let f = (0..<n).map { 25 * pow(2, Double($0) / 48) }
    return try RoomCurve(frequencies: f, db: f.map(shape))
}

/// The magnitude (dB) of a single peaking band at `f`, as the playback path builds it at 48 kHz.
private func peak(_ f0: Double, _ gain: Double, _ q: Double) -> (Double) -> Double {
    let preset = EQPreset(name: "", bands: [EQBand(kind: .peak, frequency: f0, gainDB: gain, q: q)])
    return { preset.responseDB(at: [$0], sampleRate: 48_000)[0] }
}

/// Second-order high-pass roll-off at `corner` (dB).
private func rollOff(_ corner: Double) -> (Double) -> Double {
    { f in let r = pow(f / corner, 4); return 10 * log10(r / (1 + r)) }
}

private let rates = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000]

@Suite("Room correction filter design")
struct RoomFilterDesignTests {
    private let flatTarget = RoomFilterDesignOptions(target: .flat)

    @Test("A broad room mode is cut close to the target: the error shrinks by far more than 3 dB")
    func broadPeakIsCut() throws {
        let mode = peak(120, 15, 4)
        let design = try RoomFilterDesigner.design(try curve(mode), options: flatTarget)
        let before = design.maxErrorDB(in: 40...500, corrected: false)
        let after = design.maxErrorDB(in: 40...500, corrected: true)
        #expect(before > 13)
        #expect(after < 2.5, "max error after \(after)")
        let main = try #require(design.bands.min { $0.gainDB < $1.gainDB })
        #expect(abs(log2(main.frequency / 120)) < 0.1 && main.gainDB < -11)
        #expect(design.bands.allSatisfy { $0.kind == .peak && $0.q <= RoomFilterDesignOptions.default.maxCutQ })
    }

    @Test("A deep narrow null stays unboosted, and no boost ever exceeds the limit")
    func deepNullNotBoosted() throws {
        let null = peak(200, -20, 8)
        let design = try RoomFilterDesigner.design(try curve(null), options: flatTarget)
        let correction = design.correctionDB(at: [190, 200, 210])
        #expect(correction.allSatisfy { $0 <= RoomFilterDesignOptions.default.maxBoostDB + 0.05 })
        let grid = (0...400).map { 10 * pow(2, Double($0) / 40) }
        #expect(design.correctionDB(at: grid).max()! <= 3.05)
    }

    @Test("A broad shallow dip gets at most +3 dB, and never below the speaker's roll-off")
    func boundedBoost() throws {
        let shape: (Double) -> Double = { f in rollOff(45)(f) + peak(300, -5, 1.2)(f) }
        let design = try RoomFilterDesigner.design(try curve(shape), options: flatTarget)
        // −6 dB under the midrange: a second-order roll-off with its −3 dB corner at 45 Hz is 6 dB down at about 34 Hz.
        #expect(abs(design.rollOffHz - 34) < 6, "roll-off found at \(design.rollOffHz)")
        let grid = (0...400).map { 10 * pow(2, Double($0) / 40) }
        #expect(design.correctionDB(at: grid).max()! <= 3.05)
        let below = grid.filter { $0 < design.rollOffHz }
        #expect(design.correctionDB(at: below).max()! <= 0.5)
        #expect(design.correctionDB(at: [300])[0] > 1.5, "the dip should get some help")
    }

    @Test("The default range leaves everything above 500 Hz alone; full range corrects a treble peak")
    func correctionRange() throws {
        let shape: (Double) -> Double = { f in peak(120, 10, 4)(f) + peak(3_000, 6, 2)(f) }
        let low = try RoomFilterDesigner.design(try curve(shape), options: flatTarget)
        #expect(low.bands.allSatisfy { $0.frequency <= 500 })
        #expect(abs(low.correctionDB(at: [3_000])[0]) < 0.5)

        var options = flatTarget
        options.range = RoomFilterDesignOptions.fullRange
        let full = try RoomFilterDesigner.design(try curve(shape), options: options)
        #expect(full.correctionDB(at: [3_000])[0] < -4)
    }

    @Test("The target tilts gently down: more level in the bass than the treble, 0 dB at 1 kHz")
    func targetTilt() {
        let t = RoomTargetCurve.gentleTilt
        #expect(abs(t.db(at: 1_000)) < 1e-9)
        #expect(t.db(at: 100) > t.db(at: 1_000) && t.db(at: 1_000) > t.db(at: 10_000))
        #expect(t.tiltDBPerOctave < 0 && t.tiltDBPerOctave >= -1.5)
        #expect(RoomTargetCurve.flat.db(at: 50) == 0)
        // Stored with the profile as anchors.
        #expect(t.roomTarget.anchors.count >= 3 && t.roomTarget.name == t.name)
    }

    @Test("Peaks above the target are cut toward the tilted target, not toward flat")
    func fitsTheTarget() throws {
        let target = RoomTargetCurve.gentleTilt
        let shape: (Double) -> Double = { f in target.db(at: f) + peak(120, 12, 4)(f) }
        let design = try RoomFilterDesigner.design(try curve(shape), options: RoomFilterDesignOptions(target: target))
        #expect(design.maxErrorDB(in: 50...500, corrected: true) < 2.5)
        #expect(abs(design.correctionDB(at: [60])[0]) < 1.5, "the tilt itself is not 'corrected' away")
    }

    @Test("Preamp keeps the corrected response at or below 0 dB at every common rate")
    func headroom() throws {
        let shape: (Double) -> Double = { f in rollOff(40)(f) + peak(120, 12, 4)(f) + peak(250, -6, 1)(f) }
        let design = try RoomFilterDesigner.design(try curve(shape), options: flatTarget)
        for rate in rates {
            let preset = EQPreset(name: "", preampDB: design.preampDB, bands: design.bands)
            #expect(preset.peakDB(sampleRate: rate) <= 0.001, "peak at \(rate) Hz")
        }
        #expect(design.preampDB <= 0)
    }

    @Test("Same measurement, same filters: the design is deterministic")
    func deterministic() throws {
        let shape: (Double) -> Double = { f in rollOff(45)(f) + peak(120, 15, 4)(f) + peak(70, -6, 2)(f) + peak(300, 5, 3)(f) }
        let a = try RoomFilterDesigner.design(try curve(shape), options: .default)
        let b = try RoomFilterDesigner.design(try curve(shape), options: .default)
        #expect(a.bands.map { [$0.frequency, $0.gainDB, $0.q] } == b.bands.map { [$0.frequency, $0.gainDB, $0.q] })
        #expect(a.preampDB == b.preampDB)
        #expect(a.bands.count <= RoomFilterDesignOptions.default.maxBands)
        #expect(a.bands.allSatisfy { $0.q >= RoomFilterDesignOptions.default.minQ && $0.q <= RoomFilterDesignOptions.default.maxCutQ })
    }

    @Test("A measurement already on target needs no filters")
    func flatNeedsNothing() throws {
        let design = try RoomFilterDesigner.design(try curve { _ in 0 }, options: flatTarget)
        #expect(design.bands.isEmpty && design.preampDB == 0)
    }

    @Test("Unusable measurements are refused with a reason")
    func refusals() throws {
        #expect(throws: RoomFilterDesignError.self) { try RoomCurve(frequencies: [100, 200], db: [0, .nan]) }
        #expect(throws: RoomFilterDesignError.self) { try RoomCurve(frequencies: [100, 200, 300], db: [0, 0]) }
        #expect(throws: RoomFilterDesignError.self) { try RoomCurve(frequencies: [200, 100, 300], db: [0, 0, 0]) }
        // Measured only above the correction range.
        let high = try RoomCurve(frequencies: [1_000, 2_000, 4_000, 8_000], db: [0, 0, 0, 0])
        #expect(throws: RoomFilterDesignError.self) { try RoomFilterDesigner.design(high, options: .default) }
    }

    @Test("Reads the measurement CSV the measurement writes (normalised column)")
    func readsCSV() throws {
        let text = """
        frequency_hz,raw_db,mic_compensation_db,calibrated_db,calibrated_normalised_db
        28.704,-39.0733,-0.2688,-39.3421,-21.1413
        29.545,-35.3532,-0.2815,-35.6347,-17.4338
        30.411,-35.8659,-0.2917,-36.1576,-17.9567

        """
        let c = try RoomCurve.parseCSV(text)
        #expect(c.frequencies == [28.704, 29.545, 30.411])
        #expect(c.db == [-21.1413, -17.4338, -17.9567])
        #expect(throws: RoomFilterDesignError.self) { try RoomCurve.parseCSV("hello\n1,2\n") }
    }

    @Test("Stereo: each channel is fitted from its own measurement only, with one shared preamp")
    func stereoIsPerChannel() throws {
        let left = try curve(peak(120, 10, 4)), right = try curve(peak(90, 14, 5))
        let design = try RoomFilterDesigner.design(channels: [.left: left, .right: right], options: flatTarget)
        let l = try #require(design.channels[.left]), r = try #require(design.channels[.right])
        #expect(l.bands.contains { abs(log2($0.frequency / 120)) < 0.1 })
        #expect(!l.bands.contains { abs(log2($0.frequency / 90)) < 0.1 && $0.gainDB < -6 })
        #expect(r.bands.contains { abs(log2($0.frequency / 90)) < 0.1 })
        #expect(design.preampDB == min(l.preampDB, r.preampDB))
        let set = design.filterSet
        #expect(set.version == RoomFilterDesigner.version && set.channels[.left] == l.bands && set.channels[.right] == r.bands)
        #expect(set.preampDB == design.preampDB)
    }

    @Test("The designed profile plays per output channel, in channel-map order, and survives encoding")
    func profilePlayback() throws {
        let left = try curve(peak(120, 10, 4)), right = try curve(peak(90, 14, 5))
        let design = try RoomFilterDesigner.design(channels: [.left: left, .right: right], options: flatTarget)
        let profile = design.profile(name: "Desk", sessionID: UUID(), deviceUID: "zd3", channelMap: .standard(.stereo),
                                     micSerial: "0000000", calibrationSHA256: nil, createdAt: Date(timeIntervalSince1970: 0))
        let decoded = try RoomCorrectionCoding.decodeProfile(try RoomCorrectionCoding.encode(profile))
        #expect(decoded == profile)
        let playback = RoomCorrectionPlayback(profile: decoded)
        #expect(playback.channels.count == 2)
        #expect(playback.channels[0].bands == design.channels[.left]!.bands)
        #expect(playback.channels[1].bands == design.channels[.right]!.bands)
        #expect(playback.preampDB == design.preampDB && playback.profileID == profile.id && playback.name == "Desk")
    }

    @Test("Positions of one speaker average in power; a single position is unchanged")
    func positionAverage() throws {
        let a = try RoomCurve(frequencies: [100, 200, 400], db: [0, 0, 0])
        let b = try RoomCurve(frequencies: [100, 200, 400], db: [-10, 0, 3])
        let mean = try RoomCurve.powerAverage([a, b])
        #expect(abs(mean.db[0] - 10 * log10(1.1 / 2)) < 1e-9 && abs(mean.db[1]) < 1e-12)
        #expect(abs(mean.db[2] - 10 * log10((1 + pow(10, 0.3)) / 2)) < 1e-9)
        #expect(try RoomCurve.powerAverage([b]) == b)
        #expect(throws: RoomFilterDesignError.self) { try RoomCurve.powerAverage([]) }
    }

    @Test("A profile keeps its measurement and options, so it can be redrawn and refitted; the preview predicts the fit")
    func profileKeepsMeasurement() throws {
        let left = try curve(peak(120, 10, 4)), right = try curve(peak(90, 14, 5))
        let design = try RoomFilterDesigner.design(channels: [.left: left, .right: right], options: .default)
        var profile = design.profile(name: "Desk", sessionID: UUID(), deviceUID: "zd3", channelMap: .standard(.stereo),
                                     micSerial: "0000000", calibrationSHA256: nil, createdAt: Date(timeIntervalSince1970: 0))
        profile.measured = [.left: left, .right: right]
        profile.designOptions = .default
        let decoded = try RoomCorrectionCoding.decodeProfile(try RoomCorrectionCoding.encode(profile))
        #expect(decoded == profile)
        #expect(decoded.target == RoomTargetCurve.warm.roomTarget)
        let list = try RoomCorrectionCoding.decodeProfiles(try RoomCorrectionCoding.encodeProfiles([profile, profile]))
        #expect(list == [profile, profile])

        let preview = try #require(RoomCorrectionPreview(profile: decoded))
        let fresh = RoomCorrectionPreview(design: design)
        #expect(preview.channels.map(\.speaker) == [.left, .right])
        for (a, b) in zip(preview.channels, fresh.channels) {
            #expect(a.frequencies == b.frequencies)
            #expect(zip(a.predictedDB, b.predictedDB).allSatisfy { abs($0 - $1) < 1e-9 })
            #expect(zip(a.targetDB, b.targetDB).allSatisfy { abs($0 - $1) < 1e-9 })
            #expect(a.rmsErrorAfterDB < a.rmsErrorBeforeDB)
        }
        let png = try preview.renderPNG(title: "Desk")
        #expect(png.count > 10_000 && png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        // Without a stored measurement there is nothing to draw.
        profile.measured = nil
        #expect(RoomCorrectionPreview(profile: profile) == nil)
    }

    /// Designs from a real measurement folder and writes the result (opt-in: set VESPERTINE_ROOM_DESIGN_RUN to a
    /// measurement folder with response-p1-left.csv and response-p1-right.csv, and VESPERTINE_ROOM_DESIGN_OUT).
    @Test("Design from a real measurement folder", .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_ROOM_DESIGN_RUN"] != nil))
    func designFromRun() throws {
        let env = ProcessInfo.processInfo.environment
        let run = URL(fileURLWithPath: try #require(env["VESPERTINE_ROOM_DESIGN_RUN"]))
        let out = URL(fileURLWithPath: env["VESPERTINE_ROOM_DESIGN_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var curves: [RoomSpeaker: RoomCurve] = [:]
        for speaker in [RoomSpeaker.left, .right] {
            curves[speaker] = try RoomCurve.parseCSV(String(contentsOf: run.appendingPathComponent("response-p1-\(speaker.rawValue).csv"), encoding: .utf8))
        }
        var report = "# Room correction designs for \(run.lastPathComponent)\n"
        let variants: [(String, RoomFilterDesignOptions)] = [
            ("default", .default),
            ("flat", RoomFilterDesignOptions(target: .flat)),
            ("warm", RoomFilterDesignOptions(target: .warm)),
            ("fullrange", RoomFilterDesignOptions(range: RoomFilterDesignOptions.fullRange)),
        ]
        for (name, options) in variants {
            let started = Date()
            let design = try RoomFilterDesigner.design(channels: curves, options: options)
            let seconds = Date().timeIntervalSince(started)
            report += "\n## \(name): target \(options.target.name), range \(Int(options.range.lowerBound))-\(Int(options.range.upperBound)) Hz, preamp \(String(format: "%.1f", design.preampDB)) dB (\(String(format: "%.2f", seconds)) s)\n"
            for speaker in [RoomSpeaker.left, .right] {
                let c = try #require(design.channels[speaker])
                report += "\n\(speaker.rawValue): roll-off \(String(format: "%.1f", c.rollOffHz)) Hz, fit \(String(format: "%.1f", c.fitBand.lowerBound))-\(String(format: "%.0f", c.fitBand.upperBound)) Hz, RMS error \(String(format: "%.1f", c.rmsErrorDB(in: c.fitBand, corrected: false))) -> \(String(format: "%.1f", c.rmsErrorDB(in: c.fitBand, corrected: true))) dB, max error \(String(format: "%.1f", c.maxErrorDB(in: c.fitBand, corrected: false))) -> \(String(format: "%.1f", c.maxErrorDB(in: c.fitBand, corrected: true))) dB\n"
                report += "| Hz | dB | Q |\n|---|---|---|\n"
                for b in c.bands { report += String(format: "| %.1f | %+.1f | %.2f |\n", b.frequency, b.gainDB, b.q) }
                let grid = (0...400).map { 10 * pow(2, Double($0) / 40) }
                let correction = c.correctionDB(at: grid)
                report += String(format: "max boost %.2f dB; max boost below roll-off %.2f dB\n", correction.max()!,
                                 zip(grid, correction).filter { $0.0 < c.rollOffHz }.map(\.1).max() ?? 0)
            }
            let preview = RoomCorrectionPreview(design: design)
            try preview.renderPNG(title: "Room correction, predicted: \(run.lastPathComponent) (\(name))")
                .write(to: out.appendingPathComponent("predicted-\(name).png"))
            // Bound to the output and microphone the run recorded (session.json), as the app binds a new measurement.
            let session = try? RoomCorrectionCoding.decodeSession(Data(contentsOf: run.appendingPathComponent("session.json")))
            var profile = design.profile(name: "\(env["VESPERTINE_ROOM_DESIGN_NAME"] ?? "Room") · \(run.lastPathComponent) · \(name)",
                                         sessionID: session?.id ?? UUID(), deviceUID: session?.deviceUID ?? "unknown",
                                         channelMap: session?.channelMap ?? .standard(.stereo), micSerial: session?.mic.serial ?? "unknown",
                                         calibrationSHA256: session?.mic.calibrationSHA256)
            profile.measured = curves
            profile.designOptions = options
            try RoomCorrectionCoding.encode(profile).write(to: out.appendingPathComponent("profile-\(name).json"))
            for speaker in [RoomSpeaker.left, .right] {
                try EQPreset(name: speaker.rawValue, preampDB: design.preampDB, bands: design.channels[speaker]!.bands).apoText
                    .write(to: out.appendingPathComponent("apo-\(name)-\(speaker.rawValue).txt"), atomically: true, encoding: .utf8)
            }
        }
        try report.write(to: out.appendingPathComponent("designs.md"), atomically: true, encoding: .utf8)
    }
}
