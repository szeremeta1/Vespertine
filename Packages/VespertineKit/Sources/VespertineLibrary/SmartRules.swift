//
// Vespertine — smart playlist rules, compiled to SQL.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB

public struct SmartRules: Codable, Sendable, Hashable {
    public enum Match: String, Codable, Sendable, CaseIterable { case all, any }
    public enum Sort: String, Codable, Sendable, CaseIterable {
        case album, recentlyAdded, mostPlayed, recentlyPlayed, random
    }

    public var match: Match
    public var rules: [SmartRule]
    public var limit: Int?
    public var sort: Sort

    public init(match: Match = .all, rules: [SmartRule], limit: Int? = nil, sort: Sort = .album) {
        self.match = match
        self.rules = rules
        self.limit = limit
        self.sort = sort
    }

    /// WHERE clause + arguments for the `track` table.
    public func sql() -> (clause: String, arguments: StatementArguments) {
        // A rule that can't be understood (no value, a value that isn't a number…) matches nothing,
        // rather than being dropped: dropping it would make "match all" match more than asked for.
        let parts = rules.map { $0.sql() ?? ("0", StatementArguments()) }
        guard !parts.isEmpty else { return ("1", []) }
        let joiner = match == .all ? " AND " : " OR "
        let clause = parts.map { "(\($0.0))" }.joined(separator: joiner)
        var args = StatementArguments()
        for part in parts { args += part.1 }
        return (clause, args)
    }

    public var orderBy: String {
        switch sort {
        case .album: "albumArtistSortKey, albumSortKey, discNumber, trackNumber, location"
        case .recentlyAdded: "addedAt DESC"
        case .mostPlayed: "playCount DESC, lastPlayedAt DESC"
        case .recentlyPlayed: "lastPlayedAt DESC"
        case .random: "RANDOM()"
        }
    }
}

public struct SmartRule: Codable, Sendable, Hashable, Identifiable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case title, artist, album, albumArtist, composer, genre, codec, year
        case sampleRate, bitDepth, isDSD, isLossless, playCount, rating, addedDaysAgo, verdict, channels, isFavorite

        public var label: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .albumArtist: "Album Artist"
            case .composer: "Composer"
            case .genre: "Genre"
            case .codec: "Format"
            case .year: "Year"
            case .sampleRate: "Sample Rate (kHz)"
            case .bitDepth: "Bit Depth"
            case .isDSD: "Is DSD"
            case .isLossless: "Is Lossless"
            case .playCount: "Plays"
            case .rating: "Rating"
            case .addedDaysAgo: "Added (days ago)"
            case .verdict: "Analysis Verdict"
            case .channels: "Channels"
            case .isFavorite: "Is Favorite"
            }
        }

        var isNumeric: Bool {
            switch self {
            case .year, .sampleRate, .bitDepth, .playCount, .rating, .addedDaysAgo, .channels: true
            default: false
            }
        }

        var isBoolean: Bool { self == .isDSD || self == .isLossless || self == .isFavorite }

        /// The comparisons that make sense for this field (the editor offers only these).
        public var operators: [Operator] {
            if isBoolean { return [.isTrue, .isFalse] }
            switch self {
            case .addedDaysAgo: return [.lessOrEqual, .greaterOrEqual]
            case .verdict: return [.equals, .notEquals]
            default: return isNumeric ? [.equals, .notEquals, .greaterOrEqual, .lessOrEqual] : [.contains, .notContains, .equals, .notEquals]
            }
        }

        /// Hint for the value field.
        public var placeholder: String {
            switch self {
            case .sampleRate: "kHz, e.g. 48 or 44.1"
            case .bitDepth: "bits, e.g. 24"
            case .year: "e.g. 1977"
            case .channels: "e.g. 6 for 5.1"
            case .addedDaysAgo: "days"
            case .rating: "0–5"
            case .playCount: "plays"
            case .codec: "e.g. FLAC"
            default: "value"
            }
        }
    }

    public enum Operator: String, Codable, Sendable, CaseIterable {
        case contains, notContains, equals, notEquals, greaterOrEqual, lessOrEqual, isTrue, isFalse

        public var label: String {
            switch self {
            case .contains: "contains"
            case .notContains: "does not contain"
            case .equals: "is"
            case .notEquals: "is not"
            case .greaterOrEqual: "≥"
            case .lessOrEqual: "≤"
            case .isTrue: "is true"
            case .isFalse: "is false"
            }
        }
    }

    public var id = UUID()
    public var field: Field
    public var op: Operator
    public var value: String

    public init(field: Field, op: Operator, value: String = "") {
        self.field = field
        self.op = op
        self.value = value
    }

    /// A number from what people type: "48", "44.1", "48k", "48 kHz", "24-bit", "1,000".
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "khz", with: "").replacingOccurrences(of: "hz", with: "")
            .replacingOccurrences(of: "-bit", with: "").replacingOccurrences(of: "bit", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " k"))
        return Double(cleaned)
    }

    func sql() -> (String, StatementArguments)? {
        let column: String
        switch field {
        case .addedDaysAgo:
            // Compare age in days.
            guard let days = Double(value) else { return nil }
            let cutoff = Date().addingTimeInterval(-days * 86_400)
            switch op {
            case .lessOrEqual: return ("addedAt >= ?", [cutoff])
            case .greaterOrEqual: return ("addedAt <= ?", [cutoff])
            default: return nil
            }
        case .verdict: column = "analysisVerdict"
        default: column = field.rawValue
        }
        if field == .isFavorite {
            switch op {
            case .isTrue: return ("id IN (SELECT trackId FROM favorite)", [])
            case .isFalse: return ("id NOT IN (SELECT trackId FROM favorite)", [])
            default: return nil
            }
        }
        if field.isBoolean {
            switch op {
            case .isTrue: return ("\(column) = 1", [])
            case .isFalse: return ("\(column) = 0", [])
            default: return nil
            }
        }
        if field.isNumeric {
            guard var number = Self.number(value) else { return nil }
            // Sample rates are shown in kHz everywhere, so "48" or "44.1" means kHz; values of 1000
            // and up are hertz (rules saved by older versions). Compare within half a hertz.
            var tolerance = 0.0
            if field == .sampleRate {
                if number < 1000 { number = (number * 1000).rounded() }
                tolerance = 0.5
            }
            switch op {
            case .equals: return tolerance > 0 ? ("\(column) BETWEEN ? AND ?", [number - tolerance, number + tolerance]) : ("\(column) = ?", [number])
            case .notEquals: return tolerance > 0 ? ("(\(column) IS NULL OR \(column) NOT BETWEEN ? AND ?)", [number - tolerance, number + tolerance]) : ("\(column) IS NOT ?", [number])
            case .greaterOrEqual: return ("\(column) >= ?", [number - tolerance])
            case .lessOrEqual: return ("\(column) <= ?", [number + tolerance])
            default: return nil
            }
        }
        switch op {
        case .contains: return ("\(column) LIKE ? ESCAPE '\\'", ["%\(escapeLike(value))%"])
        case .notContains: return ("IFNULL(\(column), '') NOT LIKE ? ESCAPE '\\'", ["%\(escapeLike(value))%"])
        case .equals: return ("\(column) = ? COLLATE NOCASE", [value])
        case .notEquals: return ("IFNULL(\(column), '') != ? COLLATE NOCASE", [value])
        default: return nil
        }
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

public extension SmartRules {
    static let hiRes = SmartRules(match: .any, rules: [
        SmartRule(field: .sampleRate, op: .greaterOrEqual, value: "88200"),
        SmartRule(field: .isDSD, op: .isTrue),
    ])
    static let suspect = SmartRules(match: .any, rules: [
        SmartRule(field: .verdict, op: .equals, value: "upsampled"),
        SmartRule(field: .verdict, op: .equals, value: "paddedBitDepth"),
        SmartRule(field: .verdict, op: .equals, value: "possibleLossyOrigin"),
        SmartRule(field: .verdict, op: .equals, value: "bandwidthExtended"),
    ])
}
