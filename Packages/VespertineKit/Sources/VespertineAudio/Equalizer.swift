//
// Vespertine — parametric equalizer: presets, filter design, and AutoEQ / Equalizer APO import and export.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A preset is a preamp and up to NRT_EQ_MAX_SECTIONS bands. Each band becomes one biquad section designed for the
// device's actual sample rate (Robert Bristow-Johnson's Audio EQ Cookbook), and the I/O thread runs them in 64-bit
// floating point before gain and dither (`nrt_context_set_eq`). Anything that changes the samples ends bit-perfect
// playback, so a preset that changes nothing is treated as no equalizer at all.
//

import CVespertineRT
import Foundation

public struct EQBand: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case peak, lowShelf, highShelf, lowPass, highPass
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .peak: "Peak"
            case .lowShelf: "Low shelf"
            case .highShelf: "High shelf"
            case .lowPass: "Low pass"
            case .highPass: "High pass"
            }
        }

        /// Whether the band has a gain (passes don't).
        public var hasGain: Bool { self != .lowPass && self != .highPass }
    }

    public var id: UUID
    public var kind: Kind
    /// Centre, mid-shelf or corner frequency, in Hz.
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool

    public static let frequencyRange: ClosedRange<Double> = 10...40_000
    public static let gainRange: ClosedRange<Double> = -30...30
    public static let qRange: ClosedRange<Double> = 0.05...30

    public init(id: UUID = UUID(), kind: Kind = .peak, frequency: Double = 1000, gainDB: Double = 0, q: Double = 0.707, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
    }

    /// Whether the band does anything at all.
    public var isActive: Bool { enabled && (!kind.hasGain || gainDB != 0) }

    /// The band's biquad at `sampleRate`, or nil when it does nothing there (no gain, or a frequency at or above
    /// Nyquist that a peak, a high shelf or a low pass can't reach).
    func section(sampleRate fs: Double) -> NRTBiquad? {
        guard isActive, fs > 0, frequency.isFinite, gainDB.isFinite, q.isFinite else { return nil }
        let q = min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound)
        let gain = min(max(gainDB, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        let f0 = max(frequency, Self.frequencyRange.lowerBound)
        if f0 >= 0.49 * fs {
            // Above what this rate carries: a low shelf there lifts everything below it, which is a plain gain.
            switch kind {
            case .lowShelf: return NRTBiquad(b0: pow(10, gain / 20), b1: 0, b2: 0, a1: 0, a2: 0)
            case .peak, .highShelf, .lowPass, .highPass: return nil
            }
        }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosW; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - s)
            a0 = (a + 1) + (a - 1) * cosW + s
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - s
        case .highShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - s)
            a0 = (a + 1) - (a - 1) * cosW + s
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - s
        case .lowPass:
            b0 = (1 - cosW) / 2; b1 = 1 - cosW; b2 = (1 - cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosW) / 2; b1 = -(1 + cosW); b2 = (1 + cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        }
        return NRTBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

public struct EQPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var preampDB: Double
    public var bands: [EQBand]

    /// As many bands as the I/O thread runs.
    public static let maxBands = Int(NRT_EQ_MAX_SECTIONS)
    public static let preampRange: ClosedRange<Double> = -30...12

    public init(id: UUID = UUID(), name: String, preampDB: Double = 0, bands: [EQBand] = []) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }

    /// Changes nothing: no preamp and no band with an effect. Played as no equalizer, so bit-perfect stays possible.
    public var isFlat: Bool { preampDB == 0 && !bands.contains { $0.isActive } }

    public var preampGain: Double { pow(10, min(max(preampDB, Self.preampRange.lowerBound), Self.preampRange.upperBound) / 20) }

    /// The sections the I/O thread runs at `sampleRate`, in band order.
    func sections(sampleRate: Double) -> [NRTBiquad] {
        Array(bands.compactMap { $0.section(sampleRate: sampleRate) }.prefix(Self.maxBands))
    }

    /// The overall response in dB, preamp included, at each of `frequencies` (Hz).
    public func responseDB(at frequencies: [Double], sampleRate: Double) -> [Double] {
        let sections = sections(sampleRate: sampleRate)
        let preamp = 20 * log10(preampGain)
        return frequencies.map { f in
            guard f > 0, f < sampleRate / 2 else { return preamp }
            let w = 2 * Double.pi * f / sampleRate
            return preamp + sections.reduce(0) { $0 + Self.magnitudeDB($1, w: w) }
        }
    }

    /// The highest point of the response from 20 Hz to 20 kHz (or Nyquist), in dB. Above 0, loud music can clip.
    public func peakDB(sampleRate: Double = 48_000) -> Double {
        let top = min(20_000, sampleRate * 0.49)
        let grid = (0...240).map { 20 * pow(top / 20, Double($0) / 240) }
        return responseDB(at: grid, sampleRate: sampleRate).max() ?? 0
    }

    /// The preamp that brings the peak of the response down to 0 dB (never above 0 dB of preamp).
    public func preampForNoClipping(sampleRate: Double = 48_000) -> Double {
        let withoutPreamp = EQPreset(name: name, preampDB: 0, bands: bands).peakDB(sampleRate: sampleRate)
        return min(0, -(withoutPreamp * 10).rounded(.up) / 10)
    }

    private static func magnitudeDB(_ b: NRTBiquad, w: Double) -> Double {
        // |H(e^jw)|, with z⁻¹ = cos w − j sin w and z⁻² = cos 2w − j sin 2w.
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b.b0 + b.b1 * c1 + b.b2 * c2, ni = -(b.b1 * s1 + b.b2 * s2)
        let dr = 1 + b.a1 * c1 + b.a2 * c2, di = -(b.a1 * s1 + b.a2 * s2)
        let num = nr * nr + ni * ni, den = dr * dr + di * di
        guard num > 0, den > 0 else { return -120 }
        return 10 * log10(num / den)
    }
}

// MARK: - AutoEQ and Equalizer APO text

public enum EQImportError: Error, Equatable, LocalizedError {
    case noFilters
    case tooManyFilters(Int)
    case graphicEQ
    case unsupportedFilter(line: Int, type: String)
    case unreadable(line: Int)

    public var errorDescription: String? {
        switch self {
        case .noFilters:
            "The file has no filters. Choose an AutoEQ \u{201C}ParametricEQ.txt\u{201D} or an Equalizer APO configuration."
        case .tooManyFilters(let n):
            "The file has \(n) filters; Vespertine runs up to \(EQPreset.maxBands)."
        case .graphicEQ:
            "This is a graphic EQ. Choose the \u{201C}ParametricEQ.txt\u{201D} file from AutoEQ for the same headphones instead."
        case .unsupportedFilter(let line, let type):
            "Line \(line) uses a filter type Vespertine doesn't have (\(type)). Peak, shelf, low-pass and high-pass filters are supported."
        case .unreadable(let line):
            "Line \(line) couldn't be read as a filter."
        }
    }
}

extension EQPreset {
    /// Reads AutoEQ's ParametricEQ.txt, or an Equalizer APO configuration made of `Preamp:` and `Filter:` lines:
    ///
    ///     Preamp: -6.4 dB
    ///     Filter 1: ON LSC Fc 105 Hz Gain 6.0 dB Q 0.70
    ///     Filter 2: ON PK Fc 2400 Hz Gain -3.1 dB Q 1.41
    ///
    /// Filters that are OFF come in turned off. Other APO commands (Device:, Channel:, Include: …) are ignored.
    public static func parse(_ text: String, name: String) throws -> EQPreset {
        var preset = EQPreset(name: name)
        var lineNumber = 0
        for raw in text.components(separatedBy: .newlines) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let command = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let tokens = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
            if command == "preamp" {
                guard let db = tokens.first.flatMap(number) else { throw EQImportError.unreadable(line: lineNumber) }
                preset.preampDB += db
            } else if command == "graphiceq" {
                throw EQImportError.graphicEQ
            } else if command == "filter" || (command.hasPrefix("filter") && Int(command.dropFirst(6).trimmingCharacters(in: .whitespaces)) != nil) {
                preset.bands.append(try band(tokens, line: lineNumber))
            }
        }
        guard !preset.bands.isEmpty else { throw EQImportError.noFilters }
        guard preset.bands.count <= maxBands else { throw EQImportError.tooManyFilters(preset.bands.count) }
        preset.preampDB = min(max(preset.preampDB, preampRange.lowerBound), preampRange.upperBound)
        return preset
    }

    /// The preset as Equalizer APO / AutoEQ text, which `parse` reads back.
    public var apoText: String {
        var lines = [String(format: "Preamp: %.1f dB", preampDB)]
        for (i, b) in bands.enumerated() {
            let type = switch b.kind {
            case .peak: "PK"
            case .lowShelf: "LSC"
            case .highShelf: "HSC"
            case .lowPass: "LPQ"
            case .highPass: "HPQ"
            }
            let gain = b.kind.hasGain ? String(format: " Gain %.1f dB", b.gainDB) : ""
            lines.append(String(format: "Filter %d: %@ %@ Fc %.0f Hz%@ Q %.2f", i + 1, b.enabled ? "ON" : "OFF", type, b.frequency, gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func band(_ tokens: [String], line: Int) throws -> EQBand {
        guard tokens.count >= 2 else { throw EQImportError.unreadable(line: line) }
        let enabled: Bool
        switch tokens[0].uppercased() {
        case "ON": enabled = true
        case "OFF": enabled = false
        default: throw EQImportError.unreadable(line: line)
        }
        let type = tokens[1].uppercased()
        let kind: EQBand.Kind
        switch type {
        case "PK", "PEQ", "MODAL": kind = .peak
        case "LS", "LSC", "LSQ": kind = .lowShelf
        case "HS", "HSC", "HSQ": kind = .highShelf
        case "LP", "LPQ": kind = .lowPass
        case "HP", "HPQ": kind = .highPass
        default: throw EQImportError.unsupportedFilter(line: line, type: tokens[1])
        }
        var frequency: Double?, gain = 0.0, q: Double?
        var i = 2
        while i < tokens.count {
            let key = tokens[i].lowercased()
            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            switch key {
            case "fc":
                frequency = number(next); i += 2
            case "gain":
                gain = number(next) ?? 0; i += 2
            case "q":
                q = number(next); i += 2
            case "bw" where next.lowercased() == "oct":
                // Bandwidth in octaves: Q = 1 / (2 sinh(ln 2 / 2 · BW)).
                if let bw = i + 2 < tokens.count ? number(tokens[i + 2]) : nil, bw > 0 { q = 1 / (2 * sinh(log(2) / 2 * bw)) }
                i += 3
            default:
                i += 1
            }
        }
        guard let frequency, frequency > 0 else { throw EQImportError.unreadable(line: line) }
        return EQBand(kind: kind, frequency: frequency, gainDB: min(max(gain, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound),
                      q: min(max(q ?? 0.707, EQBand.qRange.lowerBound), EQBand.qRange.upperBound), enabled: enabled)
    }

    /// "6.4", "-3,1" (a decimal comma), "105Hz" or "6dB": the number at the start.
    private static func number(_ token: String) -> Double? {
        let cleaned = token.replacingOccurrences(of: ",", with: ".")
        let prefix = cleaned.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
        return Double(prefix).flatMap { $0.isFinite ? $0 : nil }
    }
}
