//
// Vespertine: what the phone bench found, as numbers to keep (JSON) and as lines to read.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct BenchReport: Codable, Equatable, Sendable {
    /// Two songs of a folder played one after the other, and what was between them.
    public struct Join: Codable, Equatable, Sendable {
        public enum Verdict: String, Codable, Sendable {
            /// One unbroken tone across the join.
            case gapless
            /// The tone stopped at the join.
            case gap
            /// No silence, but the tone is broken at the join: out of step, at another level, or (between lossless
            /// songs) rougher than the rest of the recording.
            case click
            /// Couldn't be told: see `note`.
            case inconclusive
        }

        public var folder: String
        public var first: String
        public var second: String
        public var verdict: Verdict
        /// The longest silence at the join, in milliseconds; 0 when there is none.
        public var gapMilliseconds: Double
        /// The largest residual at the join and everywhere else, in dB relative to the tone (`ToneMeter`).
        public var joinResidual: Double?
        public var elsewhereResidual: Double?
        public var toneHz: Double?
        /// How far the second song's tone is out of step with the first's, in samples of the capture (positive: late).
        public var joinSlip: Double?
        /// The level after the join less the level before it, in dB.
        public var levelStep: Double?
        /// One of the two songs is MP3 or AAC. Each song having been encoded by itself, the encoder leaves a roughness at
        /// its edges that no player can take out; a lossy join is held to no silence, no slip and no change of level.
        public var lossy: Bool
        /// Seconds into the capture where the second song was seen to start.
        public var joinAt: Double?
        /// Silences away from the join: the song waiting for its bytes, or the files' own.
        public var gapsElsewhere: [ToneMeter.Gap]
        /// Times the capture itself skipped audio.
        public var captureBreaks: Int
        public var captureSeconds: Double
        /// The capture's file beside the report, when it was kept.
        public var capture: String?
        public var note: String?
    }

    /// One way of levelling a song, asked for and measured.
    public struct Level: Codable, Equatable, Sendable {
        /// What the file's values and the choice come to, in dB: what the Output screen shows. 0 when nothing is done.
        public var expected: Double
        /// How much the output's level moved from Off, in dB.
        public var measured: Double
        public var heldByPeak: Bool
    }

    /// A song with ReplayGain values, played with ReplayGain off, by track and by album.
    public struct Gain: Codable, Equatable, Sendable {
        public enum Verdict: String, Codable, Sendable {
            /// Each measured change is within `BenchReport.gainTolerance` of the expected one.
            case matches
            case differs
            case skipped
        }

        public var file: String
        public var verdict: Verdict
        public var trackGain: Double?
        public var trackPeak: Double?
        public var albumGain: Double?
        public var albumPeak: Double?
        /// The output's level with ReplayGain off, in dB relative to full scale.
        public var offLevel: Double?
        public var track: Level?
        public var album: Level?
        public var note: String?
    }

    /// How far (dB) a measured change may be from the expected one.
    public static let gainTolerance = 0.15
    /// How far out of step (samples) the second song may be: half a sample is less than any frame left in or dropped.
    public static let slipTolerance = 0.5
    /// How far (dB) the level may move across a join.
    public static let stepTolerance = 0.2
    /// A residual above this (dB relative to the tone) is a click whatever the songs are.
    public static let hardClick = -12.0

    public var version = 1
    public var date: Date
    public var device: String
    public var system: String
    /// The output the phone was playing to, and the rate it ran at.
    public var output: String
    /// The rate of what was captured: the output's, which the mixer brings every song to.
    public var captureRate: Double
    public var folder: String
    public var songs: Int
    public var joins: [Join] = []
    public var gains: [Gain] = []
    public var notes: [String] = []

    public init(date: Date = Date(), device: String, system: String, output: String, captureRate: Double = 0, folder: String, songs: Int = 0) {
        self.date = date
        self.device = device
        self.system = system
        self.output = output
        self.captureRate = captureRate
        self.folder = folder
        self.songs = songs
    }

    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    private static func number(_ value: Double?, _ places: Int = 2) -> String {
        guard let value, value.isFinite else { return "?" }
        return String(format: "%.\(places)f", value)
    }

    /// The report as lines: one for each join and each song levelled.
    public var text: String {
        var lines = ["VTBENCH phone bench: \(device), \(system), output \(output), captured at \(Self.number(captureRate, 0)) Hz, \(songs) songs in \(folder)"]
        for join in joins {
            var line = "VTBENCH JOIN \(join.folder): \(join.first) > \(join.second): \(join.verdict.rawValue.uppercased())"
            line += ", gap \(Self.number(join.gapMilliseconds)) ms"
            line += ", residual at the join \(Self.number(join.joinResidual, 1)) dB, elsewhere \(Self.number(join.elsewhereResidual, 1)) dB"
            line += ", slip \(Self.number(join.joinSlip)) samples, level step \(Self.number(join.levelStep)) dB"
            line += ", tone \(Self.number(join.toneHz, 1)) Hz" + (join.lossy ? ", lossy" : "")
            if !join.gapsElsewhere.isEmpty {
                line += ", silences away from the join: " + join.gapsElsewhere.map { "\(Self.number($0.milliseconds)) ms at \(Self.number($0.at)) s" }.joined(separator: "; ")
            }
            if join.captureBreaks > 0 { line += ", the capture skipped \(join.captureBreaks) times" }
            if let note = join.note { line += " (\(note))" }
            lines.append(line)
        }
        for gain in gains {
            var line = "VTBENCH GAIN \(gain.file): \(gain.verdict.rawValue.uppercased())"
            line += ", tags track \(Self.number(gain.trackGain)) dB peak \(Self.number(gain.trackPeak, 4)), album \(Self.number(gain.albumGain)) dB peak \(Self.number(gain.albumPeak, 4))"
            line += ", off \(Self.number(gain.offLevel)) dBFS"
            if let track = gain.track {
                line += ", Track expected \(Self.number(track.expected)) dB measured \(Self.number(track.measured)) dB" + (track.heldByPeak ? " (held by the peak)" : "")
            }
            if let album = gain.album {
                line += ", Album expected \(Self.number(album.expected)) dB measured \(Self.number(album.measured)) dB" + (album.heldByPeak ? " (held by the peak)" : "")
            }
            if let note = gain.note { line += " (\(note))" }
            lines.append(line)
        }
        for note in notes { lines.append("VTBENCH NOTE \(note)") }
        lines.append("VTBENCH DONE joins \(joins.count), gains \(gains.count)")
        return lines.joined(separator: "\n")
    }

    /// A WAV file (32-bit float) of `channels`, for looking at a capture afterwards.
    public static func wave(_ channels: [[Float]], rate: Double) -> Data {
        let count = channels.count
        let frames = channels.map(\.count).min() ?? 0
        var data = Data()
        func put32(_ value: UInt32) { for shift in [0, 8, 16, 24] { data.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
        func put16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        let bytes = UInt32(frames * count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
        put16(3); put16(UInt16(count)); put32(UInt32(rate)); put32(UInt32(rate) * UInt32(count) * 4); put16(UInt16(count * 4)); put16(32)
        data.append(contentsOf: Array("data".utf8)); put32(bytes)
        data.reserveCapacity(data.count + Int(bytes))
        var frame = 0
        while frame < frames {
            var channel = 0
            while channel < count {
                put32(channels[channel][frame].bitPattern)
                channel += 1
            }
            frame += 1
        }
        return data
    }
}
