//
// Vespertine — song transitions: what the listener chose (crossfade, Smart Mix, Live Set).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings only. Nothing here reaches the engine yet: with the master switch off, and for now with it on too,
// playback is exactly as without it (the golden PCM tests hold that).
//

import Foundation

/// How songs blend into each other while transitions are on.
public enum TransitionStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A plain crossfade of the chosen length and curve.
    case crossfade
    /// Chosen per pair of songs: silence trimmed, fade-outs followed, loudness matched.
    case smartMix
    /// Smart Mix on every boundary, for hosting: one output rate, a loudness target, skips always blend.
    case liveSet
    public var id: String { rawValue }
}

/// The gain curve of a crossfade.
public enum TransitionCurve: String, CaseIterable, Codable, Sendable, Identifiable {
    /// sin/cos: constant power, the usual choice for unrelated songs.
    case equalPower
    /// Constant amplitude: dips about 3 dB mid-fade on unrelated songs.
    case linear
    /// Raised cosine: gentle at both ends, quick in the middle.
    case sCurve
    public var id: String { rawValue }
}

/// What a skip to another song does while transitions are on.
public enum SkipTransition: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Cut at once, as with transitions off.
    case instant
    /// A short fade out, then the next song.
    case quickFade
    /// A crossfade into the next song.
    case crossfade
    public var id: String { rawValue }
}

/// Everything about transitions the app remembers. Stored as JSON; a missing or unknown value falls back to its
/// default, so settings from another version still load.
public struct TransitionSettings: Codable, Sendable, Equatable {
    /// The master switch. Off by default: playback is then exactly as without transitions. The choices below are kept
    /// while it's off.
    public var enabled = false
    public var style: TransitionStyle = .crossfade
    /// Crossfade length in seconds, 1…12 in half seconds.
    public var crossfadeSeconds: Double = 6
    public var curve: TransitionCurve = .equalPower
    public var skip: SkipTransition = .quickFade
    /// Genres that always play without transitions (see `excludes(genre:)`).
    public var excludedGenres: [String] = TransitionSettings.defaultExcludedGenres
    /// The one-time explainer ("Transitions change the sound only during each fade…") has been shown.
    public var explainerSeen = false

    /// Consecutive tracks of one album, the tracks of one CUE sheet and adjacent SACD tracks always play gaplessly,
    /// in playlists too. A rule, not a choice: there's no setting that turns it off.
    public var albumsGapless: Bool { true }

    public static let crossfadeRange = 1.0...12.0
    public static let crossfadeStep = 0.5
    public static let defaultExcludedGenres = ["Classical", "Opera", "Soundtrack", "Spoken Word"]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, style, crossfadeSeconds, curve, skip, excludedGenres, explainerSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TransitionSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        style = (try? c.decodeIfPresent(TransitionStyle.self, forKey: .style)) ?? d.style
        crossfadeSeconds = (try? c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds)) ?? d.crossfadeSeconds
        curve = (try? c.decodeIfPresent(TransitionCurve.self, forKey: .curve)) ?? d.curve
        skip = (try? c.decodeIfPresent(SkipTransition.self, forKey: .skip)) ?? d.skip
        excludedGenres = (try? c.decodeIfPresent([String].self, forKey: .excludedGenres)) ?? d.excludedGenres
        explainerSeen = (try? c.decodeIfPresent(Bool.self, forKey: .explainerSeen)) ?? d.explainerSeen
        self = normalized
    }

    /// Values pulled into range (a hand-edited or older file can hold anything).
    public var normalized: TransitionSettings {
        var s = self
        s.crossfadeSeconds = Self.crossfadeLength(s.crossfadeSeconds)
        var seen = Set<String>()
        s.excludedGenres = s.excludedGenres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(Self.genreKey($0)).inserted }
        return s
    }

    /// `seconds` on the crossfade slider: within 1…12, on a half second; 6 when it isn't a number.
    public static func crossfadeLength(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 6 }
        let stepped = (seconds / crossfadeStep).rounded() * crossfadeStep
        return min(max(stepped, crossfadeRange.lowerBound), crossfadeRange.upperBound)
    }

    /// Turns the master switch on or off. Returns true the first time it's turned on, when the explainer is due (and
    /// is then marked seen, so it's shown once).
    @discardableResult
    public mutating func setEnabled(_ on: Bool) -> Bool {
        enabled = on
        guard on, !explainerSeen else { return false }
        explainerSeen = true
        return true
    }

    /// Whether a song of `genre` plays without transitions. A tag holding several genres ("Classical; Opera") is
    /// excluded when any of them is; split and compared as the library does (`Genres.split`: on ; | , and NUL, "/"
    /// kept as part of a name; case and accents don't matter).
    public func excludes(genre: String?) -> Bool {
        guard let genre, !excludedGenres.isEmpty else { return false }
        let excluded = Set(excludedGenres.map(Self.genreKey))
        return genre.split(whereSeparator: { ";|,\u{0}".contains($0) }).contains { excluded.contains(Self.genreKey(String($0))) }
    }

    private static func genreKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static let defaultsKey = "transitions"

    public static func load(from defaults: UserDefaults) -> TransitionSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TransitionSettings.self, from: data) else { return TransitionSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(normalized), forKey: Self.defaultsKey)
    }
}
