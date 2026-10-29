//
// Vespertine — measurement microphone calibration (miniDSP UMIK-1 style text files).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A file is an optional quoted header ("Sens Factor =-1.203dB, SERNO: 0000001"), optional comment lines, then one
// frequency (Hz) and level (dB) pair per row. The levels are the microphone's own response, which measurements have to
// subtract (REW's convention for .cal files), so `compensationDB` is their negative. The sensitivity factor is only
// recorded here: turning it into absolute SPL needs the input gain too, which this file doesn't know.
//

import CryptoKit
import Foundation

public enum MicCalibrationError: Error, Equatable, LocalizedError {
    case notText
    case malformedHeader
    case malformedRow(line: Int)
    case notFinite(line: Int)
    case invalidFrequency(line: Int)
    case outOfRange(line: Int)
    case conflictingDuplicate(line: Int, hz: Double)
    case tooFewPoints

    public var errorDescription: String? {
        switch self {
        case .notText: String(localized: "The calibration file isn't a text file.")
        case .malformedHeader: String(localized: "The calibration file's first line has a sensitivity that couldn't be read.")
        case .malformedRow(let n): String(localized: "Line \(n) of the calibration file isn't a frequency and a level.")
        case .notFinite(let n): String(localized: "Line \(n) of the calibration file has a level that isn't a number.")
        case .invalidFrequency(let n): String(localized: "Line \(n) of the calibration file has a frequency that isn't above 0 Hz.")
        case .outOfRange(let n): String(localized: "Line \(n) of the calibration file has a level beyond ±\(Int(MicCalibration.maxAbsDB)) dB.")
        case .conflictingDuplicate(let n, let hz):
            String(localized: "Line \(n) of the calibration file repeats \(hz.formatted()) Hz with a different level.")
        case .tooFewPoints: String(localized: "The calibration file needs at least two frequency and level rows.")
        }
    }
}

public struct MicCalibration: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public var hz: Double
        public var db: Double
        public init(hz: Double, db: Double) {
            self.hz = hz
            self.db = db
        }
    }

    /// A microphone response further from flat than this is a damaged file, not a microphone.
    public static let maxAbsDB = 60.0

    public let serial: String?
    public let sensitivityDB: Double?
    /// Ascending in frequency, one per frequency.
    public let points: [Point]
    /// SHA-256 (hex) of the file's bytes as imported.
    public let sha256: String

    public static func parse(_ data: Data) throws -> MicCalibration {
        guard let text = String(data: data, encoding: .utf8) else { throw MicCalibrationError.notText }
        var serial: String?, sensitivity: Double?
        var points: [Point] = []
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("*") { continue }
            if trimmed.hasPrefix("\"") {
                if trimmed.contains("Sens Factor") || trimmed.contains("SERNO") { try header(trimmed, serial: &serial, sensitivity: &sensitivity) }
                continue
            }
            let fields = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count == 2, let hz = number(fields[0]), let db = number(fields[1]) else { throw MicCalibrationError.malformedRow(line: line) }
            guard hz.isFinite, db.isFinite else { throw MicCalibrationError.notFinite(line: line) }
            guard hz > 0 else { throw MicCalibrationError.invalidFrequency(line: line) }
            guard abs(db) <= maxAbsDB else { throw MicCalibrationError.outOfRange(line: line) }
            if let same = points.first(where: { $0.hz == hz }) {
                if same.db != db { throw MicCalibrationError.conflictingDuplicate(line: line, hz: hz) }
                continue
            }
            points.append(Point(hz: hz, db: db))
        }
        guard points.count >= 2 else { throw MicCalibrationError.tooFewPoints }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return MicCalibration(serial: serial, sensitivityDB: sensitivity, points: points.sorted { $0.hz < $1.hz }, sha256: digest)
    }

    /// `"Sens Factor =-1.203dB, SERNO: 0000001"`: either part may be missing.
    private static func header(_ line: String, serial: inout String?, sensitivity: inout Double?) throws {
        if let r = line.range(of: "Sens Factor") {
            let rest = line[r.upperBound...]
            guard let eq = rest.firstIndex(of: "=") else { throw MicCalibrationError.malformedHeader }
            let value = rest[rest.index(after: eq)...].prefix { $0 != "," && $0 != "\"" }
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
            guard let db = number(Substring(value)), db.isFinite else { throw MicCalibrationError.malformedHeader }
            sensitivity = db
        }
        if let r = line.range(of: "SERNO:") {
            let id = line[r.upperBound...].prefix { $0 != "," && $0 != "\"" }.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { serial = id }
        }
    }

    /// Strict decimal text: "+2.5" and "-1" are numbers, "2,5" and "0x10" are not. "nan" and "inf" parse, so they can be refused by name.
    private static func number(_ s: Substring) -> Double? {
        guard !s.isEmpty, s.allSatisfy({ "+-.0123456789eE".contains($0) }) || ["nan", "inf", "-inf", "+inf"].contains(s.lowercased()) else { return nil }
        return Double(s)
    }

    /// The microphone's response at `hz`: linear in dB against log frequency between rows, the end values beyond them.
    public func gainDB(at hz: Double) -> Double {
        guard let first = points.first, let last = points.last, hz.isFinite else { return 0 }
        if hz <= first.hz { return first.db }
        if hz >= last.hz { return last.db }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].hz <= hz { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let t = Foundation.log(hz / a.hz) / Foundation.log(b.hz / a.hz)
        return a.db + (b.db - a.db) * t
    }

    /// What to add to a measurement made with this microphone to remove the microphone's own response.
    public func compensationDB(at hz: Double) -> Double { -gainDB(at: hz) }

    public func compensationDB(at frequencies: [Double]) -> [Double] { frequencies.map { compensationDB(at: $0) } }

    /// The record a session keeps of the microphone it was measured with.
    public func mic(orientation: RoomMicOrientation) -> RoomMic {
        RoomMic(serial: serial ?? "", orientation: orientation, calibrationSHA256: sha256, sensitivityDB: sensitivityDB)
    }
}
