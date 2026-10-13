//
// Vespertine — the loopback self-test's report as Markdown, and its results saved per device, format, settings, macOS
// version and app version, so the signal path can say a format's software path was checked on this Mac and version.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAnalysisCore

extension LoopbackCaseResult.Status {
    public var label: String {
        switch self {
        case .bitExact: "Bit-exact"
        case .failed: "Failed"
        case .setupProblem: "Test setup problem"
        case .skipped: "Skipped"
        }
    }
}

extension LoopbackReport {
    /// The report to paste into an issue or a forum post. Always labelled as a software check.
    public var markdown: String {
        var md = "## \(Self.label)\n\n\(Self.scope)\n\n"
        let date = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        md += "- Result: **\(status.label)**\n"
        md += "- Output: \(outputDevice), recorded from \(inputDevice)\n"
        md += "- \(mode == .quick ? "Quick" : "Full") test, \(date)\n"
        md += "- Vespertine \(appVersion), macOS \(macOS)\n\n"
        md += "| Case | Result | Device format | Details |\n|---|---|---|---|\n"
        for c in cases {
            let details = [c.summary, c.sixteenBitNote].compactMap { $0 }.joined(separator: "; ")
            md += "| \(Self.cell(c.testCase.name)) | \(c.status.label) | \(Self.cell(c.deviceFormat ?? "–")) | \(Self.cell(details)) |\n"
        }
        let settings = cases.lazy.map(\.settings).first { !$0.isEmpty } ?? [:]
        if !settings.isEmpty {
            md += "\n### Settings used\n\n"
            for key in settings.keys.sorted() { md += "- \(key): \(settings[key]!)\n" }
        }
        let flagged = cases.filter { $0.status == .failed || $0.status == .setupProblem }
        if !flagged.isEmpty {
            md += "\n### Per channel\n"
            for c in flagged {
                md += "\n**\(c.testCase.name)**"
                if c.engineUnderruns > 0 || c.recorderDiscontinuities > 0 {
                    md += " (engine underruns \(c.engineUnderruns), recorder discontinuities \(c.recorderDiscontinuities))"
                }
                md += "\n\n"
                for a in c.analyses {
                    for ch in a.channels { md += "- \(Self.describe(ch))\n" }
                    for f in a.findings { md += "- \(f.isSetupProblem ? "Test setup problem: " : "")\(f.summary)\n" }
                }
            }
        }
        return md
    }

    /// One channel's line, for the report and the results sheet.
    public static func describe(_ ch: LoopbackChannelResult) -> String {
        let name = ch.channel == 0 ? "Left" : ch.channel == 1 ? "Right" : "Channel \(ch.channel + 1)"
        guard let captured = ch.capturedChannel else { return "\(name): no lock (peak \(String(format: "%.2f", ch.lock)))" }
        if ch.bitExact { return "\(name): bit-exact, \(ch.comparedFrames) frames" }
        var parts = ["\(name) (captured on \(captured + 1))"]
        if ch.inverted { parts.append("inverted") }
        if ch.mismatchedFrames > 0 { parts.append("\(ch.mismatchedFrames) of \(ch.comparedFrames) frames differ") }
        if let first = ch.firstMismatch { parts.append("first at frame \(first)") }
        if ch.maxErrorLSB > 0 { parts.append(String(format: "up to %g LSB", ch.maxErrorLSB)) }
        if let drift = ch.driftFrames, drift != 0 { parts.append("end sync \(drift > 0 ? "+" : "")\(drift) frames") }
        return parts.joined(separator: ", ")
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}

/// What a saved result is filed under: the same device, format, settings, macOS and Vespertine version replace it.
public struct LoopbackResultKey: Sendable, Hashable, Codable {
    public var deviceUID: String
    /// The case: format, rate and kind ("24-bit at 96 kHz").
    public var format: String
    /// The settings the case forced, as "key=value" lines in key order.
    public var settings: String
    public var macOS: String
    public var appVersion: String

    public init(deviceUID: String, format: String, settings: [String: String], macOS: String, appVersion: String) {
        self.deviceUID = deviceUID
        self.format = format
        self.settings = settings.keys.sorted().map { "\($0)=\(settings[$0]!)" }.joined(separator: "\n")
        self.macOS = macOS
        self.appVersion = appVersion
    }
}

public struct LoopbackSavedResult: Sendable, Hashable, Codable {
    public var key: LoopbackResultKey
    public var deviceName: String
    public var date: Date
    public var mode: LoopbackMode
    public var result: LoopbackCaseResult
}

/// Saved results, one JSON file. The newest run of a key replaces the older one; skipped cases aren't kept.
public struct LoopbackResultStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [LoopbackSavedResult] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LoopbackSavedResult].self, from: data)) ?? []
    }

    @discardableResult
    public func save(_ report: LoopbackReport) throws -> [LoopbackSavedResult] {
        var saved = load()
        for c in report.cases where c.status != .skipped {
            let key = LoopbackResultKey(deviceUID: report.outputUID, format: c.testCase.id, settings: c.settings,
                                        macOS: report.macOS, appVersion: report.appVersion)
            saved.removeAll { $0.key == key }
            saved.append(LoopbackSavedResult(key: key, deviceName: report.outputDevice, date: report.date, mode: report.mode, result: c))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(saved).write(to: url, options: .atomic)
        return saved
    }

    /// The newest saved result of a single-file case with this format and these modes, from this macOS and Vespertine
    /// version. Older versions' results don't count: a later build or macOS could behave differently.
    public static func latest(in saved: [LoopbackSavedResult], sampleRate: Double, bits: Int, matchSixteenBit: Bool = false,
                              integerMode: Bool = false, macOS: String, appVersion: String) -> LoopbackSavedResult? {
        saved.filter {
            let c = $0.result.testCase
            return $0.key.macOS == macOS && $0.key.appVersion == appVersion && c.kind == .single
                && abs(c.sampleRate - sampleRate) < 0.5 && c.bits == bits
                && c.matchSixteenBit == (bits == 16 && matchSixteenBit) && c.integerMode == (bits == 32 && integerMode)
        }
        .max { $0.date < $1.date }
    }

    /// The saved result for what a signal path plays, when its source format was checked on this macOS and
    /// Vespertine version. Only for paths that leave the samples alone: the test forces every processing step off.
    public static func latest(in saved: [LoopbackSavedResult], for path: SignalPath, macOS: String,
                              appVersion: String) -> LoopbackSavedResult? {
        guard path.plan.mode == .pcm, !path.modifiesSamples, !path.isResampling, !path.plan.dsdConvertedToPCM,
              path.plan.spatial == .off, path.plan.channels == path.source.channels, let bits = path.source.bitDepth else { return nil }
        return latest(in: saved, sampleRate: path.source.sampleRate, bits: bits, matchSixteenBit: path.plan.sixteenBit != nil,
                      integerMode: path.applied.integerMode, macOS: macOS, appVersion: appVersion)
    }

}
