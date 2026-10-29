//
// Vespertine — room correction filter design: parametric bands fitted per speaker to bring a measured in-room
// response toward a target curve. Offline and deterministic: the same measurement and options give the same filters.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The method, in order:
//  1. Smooth the measurement (power average over a sixth of an octave) and read it on a 48-per-octave log grid.
//  2. Find the speaker's low-frequency roll-off: going down from 200 Hz, the first point more than 6 dB below the
//     mean level from 200 Hz to 2 kHz. Nothing below it is boosted (a speaker can't be made to play lower).
//  3. Target = the chosen curve (Warm by default), anchored to the measurement's level from
//     200 Hz to 2 kHz, so correcting the bass never changes the overall level of the midrange.
//  4. Fit within the correction range (20 to 500 Hz by default; 20 Hz to 16 kHz for full range), above the roll-off:
//     repeatedly place a peaking band on the largest remaining error, then refine its centre, gain and Q by
//     coordinate descent on the squared error (a place where a band doesn't lower the error by 2% isn't tried again),
//     and refine all bands together once more at the end. Peaks above the
//     target get cuts (up to 18 dB, Q 0.5 to 6). Dips get boosts only when they are broad (a third of an octave
//     smoothing still shows them) and not deep nulls (more than 6 dB under the target at the narrow smoothing), and
//     never more than +3 dB, Q at most 2. The whole correction curve is held to +3 dB anywhere and +0.5 dB below the
//     roll-off by a penalty in the fit and by a final check that scales boosts down.
//  5. Values are rounded (0.1 Hz, 0.1 dB, 0.01 Q); bands under 0.3 dB are dropped.
//  6. Preamp: minus the peak of the combined response from 10 Hz to 20 kHz at 44.1 to 192 kHz, plus 0.5 dB margin
//     when that peak is above 0 dB. With cuts only it is 0 dB. Stereo shares the lower preamp so the balance holds.
//

import Foundation

public enum RoomFilterDesignError: Error, Equatable, LocalizedError {
    case mismatchedLengths
    case tooFewPoints
    case notFinite(index: Int)
    case notAscending(index: Int)
    case unreadableCSV(line: Int)
    case nothingInRange

    public var errorDescription: String? {
        switch self {
        case .mismatchedLengths: String(localized: "The measurement has a different number of frequencies and levels.")
        case .tooFewPoints: String(localized: "The measurement has too few points to design filters from.")
        case .notFinite(let i): String(localized: "The measurement has an unusable value at point \(i + 1).")
        case .notAscending(let i): String(localized: "The measurement's frequencies don't rise at point \(i + 1).")
        case .unreadableCSV(let line): String(localized: "Line \(line) of the response file couldn't be read.")
        case .nothingInRange: String(localized: "The measurement doesn't cover the correction range.")
        }
    }
}

/// A magnitude response: levels (dB) at rising frequencies (Hz).
public struct RoomCurve: Sendable, Hashable, Codable {
    public let frequencies: [Double]
    public let db: [Double]

    public init(frequencies: [Double], db: [Double]) throws {
        guard frequencies.count == db.count else { throw RoomFilterDesignError.mismatchedLengths }
        guard frequencies.count >= 2 else { throw RoomFilterDesignError.tooFewPoints }
        for i in frequencies.indices {
            guard frequencies[i].isFinite, frequencies[i] > 0, db[i].isFinite else { throw RoomFilterDesignError.notFinite(index: i) }
            if i > 0, frequencies[i] <= frequencies[i - 1] { throw RoomFilterDesignError.notAscending(index: i) }
        }
        self.frequencies = frequencies
        self.db = db
    }

    private enum CodingKeys: String, CodingKey { case frequencies, db }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(frequencies: try c.decode([Double].self, forKey: .frequencies), db: try c.decode([Double].self, forKey: .db))
    }

    /// Several measurements of one speaker (from different microphone positions) averaged in power, on the first
    /// one's frequencies. Never use it across speakers.
    public static func powerAverage(_ curves: [RoomCurve]) throws -> RoomCurve {
        guard let first = curves.first else { throw RoomFilterDesignError.tooFewPoints }
        guard curves.count > 1 else { return first }
        let db = first.frequencies.map { f in
            10 * Foundation.log10(curves.map { pow(10, $0.value(at: f) / 10) }.reduce(0, +) / Double(curves.count))
        }
        return try RoomCurve(frequencies: first.frequencies, db: db)
    }

    public init(_ response: RoomMagnitudeResponse) throws {
        try self.init(frequencies: response.frequencies, db: response.normalisedDB)
    }

    /// Reads a measurement's `response-<speaker>.csv`: the first column and the last (`calibrated_normalised_db`).
    public static func parseCSV(_ text: String) throws -> RoomCurve {
        var f: [Double] = [], d: [Double] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || (n == 0 && line.lowercased().hasPrefix("frequency")) { continue }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, let hz = Double(fields[0]), let level = Double(fields[fields.count - 1]) else {
                throw RoomFilterDesignError.unreadableCSV(line: n + 1)
            }
            f.append(hz)
            d.append(level)
        }
        return try RoomCurve(frequencies: f, db: d)
    }

    /// Level at `hz`, linear in dB over log frequency, held at the ends.
    public func value(at hz: Double) -> Double {
        if hz <= frequencies[0] { return db[0] }
        if hz >= frequencies[frequencies.count - 1] { return db[db.count - 1] }
        var lo = 0, hi = frequencies.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= hz { lo = mid } else { hi = mid }
        }
        let t = Foundation.log(hz / frequencies[lo]) / Foundation.log(frequencies[hi] / frequencies[lo])
        return db[lo] + t * (db[hi] - db[lo])
    }

    /// Power average over `octaves` (total width) around each point.
    public func smoothed(octaves: Double) -> RoomCurve {
        let half = octaves / 2
        let power = db.map { pow(10, $0 / 10) }
        let out = frequencies.indices.map { i -> Double in
            let lo = frequencies[i] * pow(2, -half), hi = frequencies[i] * pow(2, half)
            var sum = 0.0, n = 0.0
            for j in frequencies.indices where frequencies[j] >= lo && frequencies[j] <= hi { sum += power[j]; n += 1 }
            return 10 * Foundation.log10(max(sum / max(n, 1), 1e-30))
        }
        // Same frequencies, all finite: can't fail.
        return (try? RoomCurve(frequencies: frequencies, db: out)) ?? self
    }

    /// Mean level (dB) over `band`, or over everything when nothing falls in it.
    func meanDB(in band: ClosedRange<Double>) -> Double {
        let picked = frequencies.indices.filter { band.contains(frequencies[$0]) }
        let use = picked.isEmpty ? Array(frequencies.indices) : picked
        return use.map { db[$0] }.reduce(0, +) / Double(use.count)
    }
}

/// The response the correction aims for, relative to the level at 1 kHz: a straight tilt in dB per octave plus an
/// optional low shelf for extra bass. Stored with the profile as anchors (`roomTarget`).
public struct RoomTargetCurve: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var tiltDBPerOctave: Double
    /// Extra level at the bottom (dB), reached below `bassCornerHz` with a gentle (first-order-like) transition.
    public var bassLiftDB: Double
    public var bassCornerHz: Double

    public var id: String { name }

    public init(name: String, tiltDBPerOctave: Double, bassLiftDB: Double = 0, bassCornerHz: Double = 100) {
        self.name = name
        self.tiltDBPerOctave = tiltDBPerOctave
        self.bassLiftDB = bassLiftDB
        self.bassCornerHz = bassCornerHz
    }

    /// Flat: correct to a straight line.
    public static let flat = RoomTargetCurve(name: "Flat", tiltDBPerOctave: 0)
    /// The default: −0.8 dB per octave, about +2.7 dB at 100 Hz and −2.7 dB at 10 kHz relative to 1 kHz.
    public static let gentleTilt = RoomTargetCurve(name: "Gentle tilt", tiltDBPerOctave: -0.8)
    /// A warmer alternative: −1 dB per octave plus a 3 dB bass lift below about 100 Hz.
    public static let warm = RoomTargetCurve(name: "Warm", tiltDBPerOctave: -1.0, bassLiftDB: 3, bassCornerHz: 100)

    public static let presets = [gentleTilt, flat, warm]

    /// The target (dB) at `hz`, 0 at 1 kHz without bass lift.
    public func db(at hz: Double) -> Double {
        guard hz > 0 else { return 0 }
        let tilt = tiltDBPerOctave * Foundation.log2(hz / 1_000)
        guard bassLiftDB != 0 else { return tilt }
        let r = (bassCornerHz / hz) * (bassCornerHz / hz)
        return tilt + bassLiftDB * r / (1 + r)
    }

    /// As stored in a profile: anchors every octave from 20 Hz to 20 kHz.
    public var roomTarget: RoomTarget {
        let anchors = (0...10).map { i -> RoomTarget.Anchor in
            let hz = 20 * pow(2, Double(i)) > 20_000 ? 20_000 : 20 * pow(2, Double(i))
            return RoomTarget.Anchor(hz: hz, db: (db(at: hz) * 100).rounded() / 100)
        }
        return RoomTarget(name: name, version: 1, anchors: anchors)
    }
}

public struct RoomFilterDesignOptions: Codable, Hashable, Sendable {
    public var target: RoomTargetCurve
    /// Frequencies the correction acts on (Hz). Clipped to what was measured and to the speaker's roll-off.
    public var range: ClosedRange<Double>
    public var maxBoostDB: Double
    public var maxCutDB: Double
    public var maxBands: Int
    public var minQ: Double
    public var maxCutQ: Double
    public var maxBoostQ: Double
    /// Stop adding bands once no error is larger than this (dB).
    public var toleranceDB: Double
    /// Smoothing for the fit (total width in octaves).
    public var smoothingOctaves: Double

    public static let defaultRange: ClosedRange<Double> = 20...500
    public static let fullRange: ClosedRange<Double> = 20...16_000

    public init(target: RoomTargetCurve = .warm, range: ClosedRange<Double> = defaultRange, maxBoostDB: Double = 3,
                maxCutDB: Double = 18, maxBands: Int = 10, minQ: Double = 0.5, maxCutQ: Double = 6, maxBoostQ: Double = 2,
                toleranceDB: Double = 1, smoothingOctaves: Double = 1.0 / 6) {
        self.target = target
        self.range = range
        self.maxBoostDB = maxBoostDB
        self.maxCutDB = maxCutDB
        self.maxBands = maxBands
        self.minQ = minQ
        self.maxCutQ = maxCutQ
        self.maxBoostQ = maxBoostQ
        self.toleranceDB = toleranceDB
        self.smoothingOctaves = smoothingOctaves
    }

    public static let `default` = RoomFilterDesignOptions()

    /// Full range allows more bands, the default range fewer.
    public var isFullRange: Bool { range.upperBound > 1_000 }
}

/// One speaker's correction: the bands, and the curves they were fitted on, for plotting and checks.
public struct RoomChannelDesign: Sendable {
    public let bands: [EQBand]
    /// Preamp this channel alone would need (dB, ≤ 0).
    public let preampDB: Double
    public let rollOffHz: Double
    /// The band the fit worked on (Hz).
    public let fitBand: ClosedRange<Double>
    /// The measurement, sixth-octave smoothed, as fitted.
    public let measured: RoomCurve
    /// The target on the measurement's frequencies, at the measurement's level.
    public let targetDB: [Double]

    /// The correction alone (dB, no preamp) at each of `frequencies`.
    public func correctionDB(at frequencies: [Double]) -> [Double] {
        EQPreset(name: "", bands: bands).responseDB(at: frequencies, sampleRate: RoomFilterDesigner.designRate)
    }

    /// Smoothed measurement plus correction (no preamp): what the speaker should measure after correction.
    public var predicted: RoomCurve {
        let c = correctionDB(at: measured.frequencies)
        return (try? RoomCurve(frequencies: measured.frequencies, db: zip(measured.db, c).map { $0 + $1 })) ?? measured
    }

    /// The root-mean-square distance (dB) from the target within `band`, leaving out deep nulls (more than 6 dB under
    /// the target in the measurement), which the design leaves alone on purpose.
    public func rmsErrorDB(in band: ClosedRange<Double>, corrected: Bool) -> Double {
        let curve = corrected ? predicted : measured
        let picked = curve.frequencies.indices.filter { band.contains(curve.frequencies[$0]) && measured.db[$0] - targetDB[$0] >= -RoomFilterDesigner.nullDepthDB }
        guard !picked.isEmpty else { return 0 }
        return (picked.map { pow(curve.db[$0] - targetDB[$0], 2) }.reduce(0, +) / Double(picked.count)).squareRoot()
    }

    /// The largest distance (dB) between the smoothed measurement (or the prediction) and the target within `band`.
    public func maxErrorDB(in band: ClosedRange<Double>, corrected: Bool) -> Double {
        let curve = corrected ? predicted : measured
        return curve.frequencies.indices.filter { band.contains(curve.frequencies[$0]) }
            .map { abs(curve.db[$0] - targetDB[$0]) }.max() ?? 0
    }
}

/// A stereo (or larger) correction: one design per speaker and one preamp for all.
public struct RoomCorrectionDesign: Sendable {
    public let channels: [RoomSpeaker: RoomChannelDesign]
    public let options: RoomFilterDesignOptions
    /// The lowest of the channels' preamps, applied to every channel.
    public var preampDB: Double { channels.values.map(\.preampDB).min() ?? 0 }

    public var filterSet: RoomFilterSet {
        RoomFilterSet(version: RoomFilterDesigner.version, channels: channels.mapValues(\.bands), preampDB: preampDB)
    }

    public func profile(name: String, sessionID: UUID, deviceUID: String, channelMap: RoomChannelMap, micSerial: String,
                        calibrationSHA256: String?, createdAt: Date = Date(), id: UUID = UUID()) -> RoomProfile {
        RoomProfile(id: id, name: name, createdAt: createdAt, sessionID: sessionID, deviceUID: deviceUID,
                    layout: channelMap.entries.count > 2 ? .surround51 : .stereo, channelMap: channelMap, micSerial: micSerial,
                    calibrationSHA256: calibrationSHA256, target: options.target.roomTarget, filters: filterSet)
    }
}

public enum RoomFilterDesigner {
    /// Filter design version, stored in `RoomFilterSet.version`.
    public static let version = 1
    static let designRate = 48_000.0
    static let pointsPerOctave = 48.0
    static let checkRates = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000]
    static let headroomMarginDB = 0.5
    static let rollOffDropDB = 6.0
    static let nullDepthDB = 6.0

    public static func design(channels: [RoomSpeaker: RoomCurve], options: RoomFilterDesignOptions = .default) throws -> RoomCorrectionDesign {
        var out: [RoomSpeaker: RoomChannelDesign] = [:]
        for speaker in RoomSpeaker.allCases { if let c = channels[speaker] { out[speaker] = try design(c, options: options) } }
        return RoomCorrectionDesign(channels: out, options: options)
    }

    public static func design(_ measurement: RoomCurve, options: RoomFilterDesignOptions = .default) throws -> RoomChannelDesign {
        let smooth = measurement.smoothed(octaves: options.smoothingOctaves)
        let broad = measurement.smoothed(octaves: 1.0 / 3)
        let reference = smooth.meanDB(in: 200...2_000)
        let rollOff = findRollOff(broad, reference: reference)
        let low = max(options.range.lowerBound, rollOff, measurement.frequencies[0])
        let high = min(options.range.upperBound, measurement.frequencies[measurement.frequencies.count - 1])
        guard high > low * 1.1 else { throw RoomFilterDesignError.nothingInRange }

        let offset = targetOffset(smooth, options: options)
        func target(_ hz: Double) -> Double { options.target.db(at: hz) + offset }

        // Fit grid, and a check grid over everything for the boost limits.
        let n = Int((Foundation.log2(high / low) * pointsPerOctave).rounded(.down)) + 1
        let grid = (0..<n).map { low * pow(2, Double($0) / pointsPerOctave) }
        let error0 = grid.map { smooth.value(at: $0) - target($0) }
        let broadError = grid.map { broad.value(at: $0) - target($0) }
        // 10 Hz to 10.24 kHz … and on.
        let lowCheck: [Double] = (0...400).map { (i: Int) -> Double in 10 * pow(2, Double(i) / 40) }
        let highCheck: [Double] = (1...40).map { (i: Int) -> Double in 10_240 * pow(2, Double(i) / 40) }.filter { $0 <= 20_000 }
        let checkGrid: [Double] = lowCheck + highCheck

        var fitter = Fitter(grid: grid, error0: error0, checkGrid: checkGrid, rollOff: rollOff, options: options)
        let maxBands = min(options.maxBands, EQPreset.maxBands)
        // Places where a band was tried and didn't help (a boost the limits forbid, say): not tried again.
        var excluded = Set<Int>()
        var attempts = 0
        while fitter.bands.count < maxBands, attempts < maxBands * 4 {
            attempts += 1
            let e = fitter.residual()
            // The largest peak above the target …
            var best: (index: Int, score: Double, boost: Bool)?
            for i in grid.indices where e[i] > options.toleranceDB && !excluded.contains(i) {
                if best == nil || e[i] > best!.score { best = (i, e[i], false) }
            }
            // … or a broad, shallow dip, counted at half weight (the fit is cut-dominant).
            for i in grid.indices where -e[i] > options.toleranceDB && error0[i] > -nullDepthDB && broadError[i] < -options.toleranceDB
                && !excluded.contains(i) {
                let deficit = min(-e[i], -broadError[i] - fitter.correction(at: i))
                if deficit > options.toleranceDB, best == nil || deficit * 0.5 > best!.score { best = (i, deficit * 0.5, true) }
            }
            guard let pick = best else { break }
            let before = fitter.cost()
            let gain = pick.boost ? min(options.maxBoostDB, pick.score * 2) : -min(options.maxCutDB, e[pick.index])
            let q = initialQ(e, at: pick.index, sign: pick.boost ? -1 : 1, options: options, boost: pick.boost)
            fitter.add(Fitter.Band(logF: Foundation.log2(grid[pick.index]), gain: gain, logQ: Foundation.log2(q), boost: pick.boost))
            fitter.refine(fitter.bands.count - 1)
            if fitter.cost() > before * 0.98 {
                fitter.removeLast()
                // A sixth of an octave either side.
                let reach = Int(pointsPerOctave / 6)
                for i in max(0, pick.index - reach)...min(grid.count - 1, pick.index + reach) { excluded.insert(i) }
            }
        }
        for _ in 0..<2 { for i in fitter.bands.indices { fitter.refine(i) } }
        // Two bands of the same sign within a twelfth of an octave do one band's work: merge them and refit.
        while let (i, j) = fitter.closePair(octaves: 1.0 / 12) {
            fitter.merge(i, j)
            for k in fitter.bands.indices { fitter.refine(k) }
        }

        var bands: [EQBand] = fitter.bands
            .map { b -> EQBand in
                let frequencyHz: Double = (pow(2, b.logF) * 10).rounded() / 10
                let gainDB: Double = (b.gain * 10).rounded() / 10
                let q: Double = (pow(2, b.logQ) * 100).rounded() / 100
                return EQBand(kind: .peak, frequency: frequencyHz, gainDB: gainDB, q: q)
            }
            .filter { abs($0.gainDB) >= 0.3 }
            .sorted { $0.frequency < $1.frequency }
        // Deterministic ids, so the same design compares equal.
        bands = bands.enumerated().map { i, b in
            var b = b
            b.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i + 1))!
            return b
        }
        bands = enforceBoostLimit(bands, checkGrid: checkGrid, rollOff: rollOff, options: options)
        let targetDB = smooth.frequencies.map(target)
        return RoomChannelDesign(bands: bands, preampDB: preamp(for: bands), rollOffHz: rollOff, fitBand: low...high,
                                 measured: smooth, targetDB: targetDB)
    }

    /// Target level: the (smoothed) measurement's mean from 200 Hz to 2 kHz equals the target's mean there.
    static func targetOffset(_ smooth: RoomCurve, options: RoomFilterDesignOptions) -> Double {
        let refBand = smooth.frequencies.filter { $0 >= 200 && $0 <= 2_000 }
        let targetMean = refBand.isEmpty ? 0 : refBand.map { options.target.db(at: $0) }.reduce(0, +) / Double(refBand.count)
        return smooth.meanDB(in: 200...2_000) - targetMean
    }

    /// The target on `smooth`'s frequencies, at its level.
    public static func targetDB(for smooth: RoomCurve, options: RoomFilterDesignOptions) -> [Double] {
        let offset = targetOffset(smooth, options: options)
        return smooth.frequencies.map { options.target.db(at: $0) + offset }
    }

    /// Going down from 200 Hz, where the (third-octave smoothed) response first falls more than 6 dB under the
    /// 200 Hz to 2 kHz level; the lowest measured frequency when it never does.
    static func findRollOff(_ curve: RoomCurve, reference: Double) -> Double {
        let threshold = reference - rollOffDropDB
        var i = curve.frequencies.lastIndex { $0 <= 200 } ?? 0
        while i > 0 {
            if curve.db[i - 1] < threshold {
                // Interpolate the crossing between i-1 and i (log frequency).
                let a = curve.db[i - 1], b = curve.db[i]
                let t = b == a ? 0 : (threshold - a) / (b - a)
                return curve.frequencies[i - 1] * pow(curve.frequencies[i] / curve.frequencies[i - 1], min(max(t, 0), 1))
            }
            i -= 1
        }
        return curve.frequencies[0]
    }

    /// Q from where the error falls to half its value either side of `index` (the band's −6 dB-of-gain width).
    static func initialQ(_ e: [Double], at index: Int, sign: Double, options: RoomFilterDesignOptions, boost: Bool) -> Double {
        let top = sign * e[index]
        var l = index, r = index
        while l > 0, sign * e[l - 1] > top / 2 { l -= 1 }
        while r < e.count - 1, sign * e[r + 1] > top / 2 { r += 1 }
        let octaves = max(Double(r - l + 1) / pointsPerOctave, 1.0 / 24)
        let ratio = pow(2, octaves)
        let q = ratio.squareRoot() / (ratio - 1)
        return min(max(q, options.minQ), boost ? options.maxBoostQ : options.maxCutQ)
    }

    /// Scales boost bands down until the correction stays within the limits everywhere.
    static func enforceBoostLimit(_ bands: [EQBand], checkGrid: [Double], rollOff: Double, options: RoomFilterDesignOptions) -> [EQBand] {
        var bands = bands
        for _ in 0..<20 {
            let c = EQPreset(name: "", bands: bands).responseDB(at: checkGrid, sampleRate: designRate)
            var excess = 0.0
            for (i, f) in checkGrid.enumerated() { excess = max(excess, c[i] - (f < rollOff ? 0.5 : options.maxBoostDB)) }
            guard excess > 0.001 else { break }
            let boosts = bands.indices.filter { bands[$0].gainDB > 0 }
            guard !boosts.isEmpty else { break }
            for i in boosts { bands[i].gainDB = max(0, ((bands[i].gainDB - excess - 0.05) * 10).rounded(.down) / 10) }
        }
        return bands.filter { abs($0.gainDB) >= 0.3 }
    }

    /// Minus the combined response's peak (plus a margin) when it rises above 0 dB at any common rate; else 0.
    static func preamp(for bands: [EQBand]) -> Double {
        guard !bands.isEmpty else { return 0 }
        let peak = checkRates.map { EQPreset(name: "", bands: bands).peakDB(sampleRate: $0) }.max() ?? 0
        guard peak > 0.001 else { return 0 }
        return -((peak + headroomMarginDB) * 10).rounded(.up) / 10
    }

    /// The fit's working state: bands in log-frequency / log-Q form, each band's response on the grid cached.
    struct Fitter {
        struct Band {
            var logF: Double
            var gain: Double
            var logQ: Double
            let boost: Bool
        }

        let grid: [Double]
        let error0: [Double]
        let checkGrid: [Double]
        let rollOff: Double
        let options: RoomFilterDesignOptions
        let logLow: Double, logHigh: Double
        let weights: [Double]
        private(set) var bands: [Band] = []
        private var responses: [[Double]] = []
        private var checkResponses: [[Double]] = []

        init(grid: [Double], error0: [Double], checkGrid: [Double], rollOff: Double, options: RoomFilterDesignOptions) {
            self.grid = grid
            self.error0 = error0
            self.checkGrid = checkGrid
            self.rollOff = rollOff
            self.options = options
            logLow = Foundation.log2(grid[0])
            logHigh = Foundation.log2(grid[grid.count - 1])
            // Deep nulls (more than 6 dB under the target) count little: the fit shouldn't chase them.
            weights = error0.map { $0 < -RoomFilterDesigner.nullDepthDB ? 0.1 : 1 }
        }

        mutating func add(_ b: Band) {
            bands.append(clamped(b))
            responses.append(Self.response(bands[bands.count - 1], grid))
            checkResponses.append(Self.response(bands[bands.count - 1], checkGrid))
        }

        /// The first two bands of the same sign whose centres are closer than `octaves`.
        func closePair(octaves: Double) -> (Int, Int)? {
            for i in bands.indices {
                for j in bands.indices where j > i && bands[i].boost == bands[j].boost && abs(bands[i].logF - bands[j].logF) < octaves {
                    return (i, j)
                }
            }
            return nil
        }

        /// Replaces bands `i` and `j` (i < j) with one at their gain-weighted centre, their combined gain and the
        /// broader of their two Qs.
        mutating func merge(_ i: Int, _ j: Int) {
            let a = bands[i], b = bands[j]
            let weight = abs(a.gain) + abs(b.gain)
            let logF = weight > 0 ? (a.logF * abs(a.gain) + b.logF * abs(b.gain)) / weight : (a.logF + b.logF) / 2
            let merged = clamped(Band(logF: logF, gain: a.gain + b.gain, logQ: min(a.logQ, b.logQ), boost: a.boost))
            bands[i] = merged
            responses[i] = Self.response(merged, grid)
            checkResponses[i] = Self.response(merged, checkGrid)
            bands.remove(at: j); responses.remove(at: j); checkResponses.remove(at: j)
        }

        mutating func removeLast() {
            bands.removeLast(); responses.removeLast(); checkResponses.removeLast()
        }

        func correction(at i: Int) -> Double { responses.reduce(0) { $0 + $1[i] } }

        func residual() -> [Double] { grid.indices.map { i in error0[i] + correction(at: i) } }

        func cost() -> Double { cost(responses: responses, checks: checkResponses) }

        private func cost(responses: [[Double]], checks: [[Double]]) -> Double {
            var sum = 0.0
            for i in grid.indices {
                var e = error0[i]
                for r in responses { e += r[i] }
                // Under the target counts half as much as over it: cut-dominant.
                sum += weights[i] * (e < 0 ? 0.5 : 1) * e * e
            }
            sum /= Double(grid.count)
            // Hard limits on boost, everywhere: +3 dB, and +0.5 dB below the roll-off.
            for (j, f) in checkGrid.enumerated() {
                var c = 0.0
                for r in checks { c += r[j] }
                let over = c - (f < rollOff ? 0.5 : options.maxBoostDB)
                if over > 0 { sum += 1_000 * over * over }
            }
            return sum
        }

        /// Coordinate descent on one band's centre, gain and Q with shrinking steps; keeps only improvements.
        mutating func refine(_ k: Int) {
            var steps = [1.0 / 12, 1.0, 0.25]   // octaves, dB, log2 Q
            let minimum = [1.0 / 384, 0.02, 0.01]
            var current = cost()
            var iterations = 0
            while iterations < 400, zip(steps, minimum).contains(where: { $0 > $1 }) {
                iterations += 1
                var improved = false
                for p in 0..<3 where steps[p] > minimum[p] {
                    for direction in [1.0, -1.0] {
                        var trial = bands[k]
                        switch p {
                        case 0: trial.logF += direction * steps[0]
                        case 1: trial.gain += direction * steps[1]
                        default: trial.logQ += direction * steps[2]
                        }
                        trial = clamped(trial)
                        var r = responses, c = checkResponses
                        r[k] = Self.response(trial, grid)
                        c[k] = Self.response(trial, checkGrid)
                        let value = cost(responses: r, checks: c)
                        if value < current - 1e-12 {
                            bands[k] = trial; responses = r; checkResponses = c; current = value
                            improved = true
                            break
                        }
                    }
                }
                if !improved { steps = steps.map { $0 / 2 } }
            }
        }

        private func clamped(_ b: Band) -> Band {
            var b = b
            b.logF = min(max(b.logF, logLow), logHigh)
            b.gain = b.boost ? min(max(b.gain, 0), options.maxBoostDB) : min(max(b.gain, -options.maxCutDB), 0)
            b.logQ = min(max(b.logQ, Foundation.log2(options.minQ)), Foundation.log2(b.boost ? options.maxBoostQ : options.maxCutQ))
            return b
        }

        static func response(_ b: Band, _ frequencies: [Double]) -> [Double] {
            EQPreset(name: "", bands: [EQBand(kind: .peak, frequency: pow(2, b.logF), gainDB: b.gain, q: pow(2, b.logQ))])
                .responseDB(at: frequencies, sampleRate: RoomFilterDesigner.designRate)
        }
    }
}
