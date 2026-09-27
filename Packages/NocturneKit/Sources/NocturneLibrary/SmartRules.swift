//
// Nocturne — smart playlist rules, compiled to SQL.
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
        let parts = rules.compactMap { $0.sql() }
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
        case sampleRate, bitDepth, isDSD, isLossless, playCount, rating, addedDaysAgo, verdict

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
            case .sampleRate: "Sample Rate (Hz)"
            case .bitDepth: "Bit Depth"
            case .isDSD: "Is DSD"
            case .isLossless: "Is Lossless"
            case .playCount: "Plays"
            case .rating: "Rating"
            case .addedDaysAgo: "Added (days ago)"
            case .verdict: "Analysis Verdict"
            }
        }

        var isNumeric: Bool {
            switch self {
            case .year, .sampleRate, .bitDepth, .playCount, .rating, .addedDaysAgo: true
            default: false
            }
        }

        var isBoolean: Bool { self == .isDSD || self == .isLossless }
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
        if field.isBoolean {
            switch op {
            case .isTrue: return ("\(column) = 1", [])
            case .isFalse: return ("\(column) = 0", [])
            default: return nil
            }
        }
        if field.isNumeric {
            guard let number = Double(value) else { return nil }
            switch op {
            case .equals: return ("\(column) = ?", [number])
            case .notEquals: return ("\(column) IS NOT ?", [number])
            case .greaterOrEqual: return ("\(column) >= ?", [number])
            case .lessOrEqual: return ("\(column) <= ?", [number])
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
    ])
}
