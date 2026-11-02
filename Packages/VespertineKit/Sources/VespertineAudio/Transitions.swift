//
// Vespertine — song transitions: what the listener chose (crossfade, Smart Mix, Live Set).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The settings, the gain curves, and the planner that decides what happens at each boundary between two songs
// (`TransitionPlanner`). The mixing itself is in TransitionMixer.swift; the engine calls both only while the master
// switch is on, so with it off playback is exactly as without transitions (the golden PCM tests hold that).
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

    /// Its name in the signal path and Settings ("equal-power").
    public var name: String {
        switch self {
        case .equalPower: String(localized: "equal-power", comment: "Crossfade curve: constant power (sine/cosine). Lowercase, inside a sentence.")
        case .linear: String(localized: "linear", comment: "Crossfade curve: constant amplitude. Lowercase, inside a sentence.")
        case .sCurve: String(localized: "S-curve", comment: "Crossfade curve: gentle at both ends, quick in the middle. Inside a sentence.")
        }
    }

    /// The gains of the outgoing and incoming song at `t` (0 at the start of the crossfade, 1 at its end). Exactly
    /// (1, 0) at 0 and (0, 1) at 1. Equal-power keeps out² + in² = 1, linear out + in = 1, and the S-curve is the linear
    /// pair shaped by a raised cosine (out + in = 1 too, slow at both ends).
    public func gains(at t: Double) -> (out: Double, in: Double) {
        guard t > 0 else { return (1, 0) }
        guard t < 1 else { return (0, 1) }
        switch self {
        case .equalPower: return (cos(t * .pi / 2), sin(t * .pi / 2))
        case .linear: return (1 - t, t)
        case .sCurve:
            let rise = (1 - cos(t * .pi)) / 2
            return (1 - rise, rise)
        }
    }
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

/// What may change about the output to make a transition happen.
public enum TransitionPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Never change the output format for a transition: a dip or no transition instead (the default).
    case bitPerfectFirst
    /// While transitions are on: the next song is resampled to the rate playing, DSD is converted to PCM, and the
    /// integer and 16-bit modes aren't used, so more boundaries can blend.
    case transitionsFirst
    public var id: String { rawValue }
}

/// A playlist's own transitions, overriding the app's style while the master switch is on (off, nothing changes).
public enum TransitionOverride: Sendable, Hashable {
    /// The playlist plays without transitions.
    case off
    /// A plain crossfade of this many seconds.
    case crossfade(seconds: Double)
    case smartMix
    case liveSet

    /// How the library stores it ("off", "crossfade:6", "smartMix", "liveSet").
    public var storedValue: String {
        switch self {
        case .off: "off"
        case .crossfade(let seconds): "crossfade:\(TransitionSettings.crossfadeLength(seconds).formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never)))"
        case .smartMix: TransitionStyle.smartMix.rawValue
        case .liveSet: TransitionStyle.liveSet.rawValue
        }
    }

    /// nil for nil (follow the app) and for anything unknown.
    public init?(storedValue: String?) {
        guard let value = storedValue else { return nil }
        switch value {
        case "off": self = .off
        case TransitionStyle.smartMix.rawValue: self = .smartMix
        case TransitionStyle.liveSet.rawValue: self = .liveSet
        default:
            guard value.hasPrefix("crossfade:"), let seconds = Double(value.dropFirst("crossfade:".count)), seconds.isFinite else { return nil }
            self = .crossfade(seconds: TransitionSettings.crossfadeLength(seconds))
        }
    }

    /// `settings` with this override applied; nil when the playlist plays without transitions. The master switch
    /// still rules: off stays off.
    public func applied(to settings: TransitionSettings) -> TransitionSettings? {
        guard settings.enabled else { return settings }
        var s = settings
        switch self {
        case .off: return nil
        case .crossfade(let seconds): s.style = .crossfade; s.crossfadeSeconds = TransitionSettings.crossfadeLength(seconds)
        case .smartMix: s.style = .smartMix
        case .liveSet: s.style = .liveSet
        }
        return s
    }
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
    /// Silence at the end of a song and at the start of the next (below about −60 dBFS) is left out of a crossfade, so
    /// six seconds of fade aren't four of silence.
    public var trimSilence = true
    /// Seconds of silence put between songs instead of a crossfade (0: none), never inside albums.
    public var gapSeconds: Double = 0
    public var policy: TransitionPolicy = .bitPerfectFirst

    /// Consecutive tracks of one album, the tracks of one CUE sheet and adjacent SACD tracks always play gaplessly,
    /// in playlists too. A rule, not a choice: there's no setting that turns it off.
    public var albumsGapless: Bool { true }

    public static let crossfadeRange = 1.0...12.0
    public static let crossfadeStep = 0.5
    public static let gapRange = 0.0...10.0
    public static let defaultExcludedGenres = ["Classical", "Opera", "Soundtrack", "Spoken Word"]

    /// Fades the real-time stage plays around a listener's action (only with the master switch on, and never on native
    /// DSD, bitstream or integer output): in from silence on play, resume and seek; out before a pause or stop; out
    /// before a skip ("quick fade").
    public static let startFadeSeconds = 0.25
    public static let pauseFadeSeconds = 0.4
    public static let skipFadeSeconds = 0.3

    /// What the engine acts on: everything but the explainer flag (seeing the explainer changes no boundary).
    public var engineRelevant: TransitionSettings {
        var s = normalized
        s.explainerSeen = false
        return s
    }

    /// The fade-out before a skip, a pause or a stop, in seconds; 0 = cut at once (as with transitions off).
    public func fadeOutSeconds(pausing: Bool) -> Double {
        guard enabled else { return 0 }
        if pausing { return Self.pauseFadeSeconds }
        return skip == .instant ? 0 : Self.skipFadeSeconds
    }

    /// The fade-in when playback starts, resumes or jumps; 0 = none.
    public var startFadeSeconds: Double { enabled ? Self.startFadeSeconds : 0 }

    public init() {}

    /// Smart Mix or Live Set: chosen per pair of songs.
    public var isSmart: Bool { style != .crossfade }

    /// What a skip does: Live Set always blends.
    public var effectiveSkip: SkipTransition { style == .liveSet ? .crossfade : skip }

    enum CodingKeys: String, CodingKey {
        case enabled, style, crossfadeSeconds, curve, skip, excludedGenres, explainerSeen, trimSilence, gapSeconds, policy
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
        trimSilence = (try? c.decodeIfPresent(Bool.self, forKey: .trimSilence)) ?? d.trimSilence
        gapSeconds = (try? c.decodeIfPresent(Double.self, forKey: .gapSeconds)) ?? d.gapSeconds
        policy = (try? c.decodeIfPresent(TransitionPolicy.self, forKey: .policy)) ?? d.policy
        self = normalized
    }

    /// Values pulled into range (a hand-edited or older file can hold anything).
    public var normalized: TransitionSettings {
        var s = self
        s.crossfadeSeconds = Self.crossfadeLength(s.crossfadeSeconds)
        s.gapSeconds = Self.gapLength(s.gapSeconds)
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

    /// `seconds` of gap: within 0…10, on a half second; 0 when it isn't a number.
    public static func gapLength(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let stepped = (seconds / crossfadeStep).rounded() * crossfadeStep
        return min(max(stepped, gapRange.lowerBound), gapRange.upperBound)
    }

    /// Integer mode and Match 16-bit aren't used (so songs can blend): the switch is on with "transitions first".
    public var avoidsUnmixableModes: Bool { enabled && policy == .transitionsFirst }

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

// MARK: - Boundaries

/// What the app knows about a queued song that decides how it joins its neighbours: its album, place on the album and
/// genre. nil fields are unknown.
public struct TransitionContext: Sendable, Hashable {
    /// The library's album identity (`Track.albumKey`).
    public var albumKey: String?
    public var discNumber: Int?
    public var trackNumber: Int?
    public var genre: String?
    /// The transitions of the playlist the song was queued from, when it has its own (nil: the app's setting).
    public var override: TransitionOverride?

    public init(albumKey: String? = nil, discNumber: Int? = nil, trackNumber: Int? = nil, genre: String? = nil,
                override: TransitionOverride? = nil) {
        self.albumKey = albumKey
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.genre = genre
        self.override = override
    }

    /// `next` is the track after this one on the same album (the next number on this disc, or the first on the next
    /// disc). Tracks of one album without numbers count as consecutive: nothing says they aren't, and a gapless join is
    /// the safe choice.
    public func isFollowed(onAlbumBy next: TransitionContext) -> Bool {
        guard let album = albumKey, !album.isEmpty, album == next.albumKey else { return false }
        guard let a = trackNumber, let b = next.trackNumber, a > 0, b > 0 else { return true }
        let discA = discNumber ?? 1, discB = next.discNumber ?? 1
        return (discA == discB && b == a + 1) || (discB == discA + 1 && b == 1)
    }
}

/// How the output plays one side of a boundary, as far as transitions care.
public enum BoundaryFormat: Sendable, Hashable {
    /// Vespertine's own output, with this plan.
    case plan(OutputPlan)
    /// macOS renders it (Dolby Atmos): a separate renderer, never mixed with Vespertine's output.
    case systemRenderer
    /// Not known yet (the next song isn't opened): only the rules that don't need the format apply.
    case unknown
}

/// What happens where one song meets the next.
public enum TransitionDecision: Sendable, Hashable {
    /// Joined exactly as with transitions off.
    case gapless(GaplessReason)
    /// A rule forbids touching the samples here: exactly as with transitions off.
    case cut(CutReason)
    /// The output has to be set up again (another rate or channel count): the end of the song fades out, then the short
    /// gap that's there anyway, then the next one fades in.
    case dip(seconds: Double, curve: TransitionCurve)
    /// The two songs overlap and crossfade.
    case overlap(seconds: Double, curve: TransitionCurve)
    /// Smart Mix's choice for this pair of songs.
    case mix(SmartMix)
    /// Silence between the songs (each plays whole and untouched).
    case gap(seconds: Double)

    public enum GaplessReason: String, Sendable, Hashable, CaseIterable {
        /// The master switch is off.
        case off
        /// Consecutive tracks of one album.
        case sameAlbum
        /// Adjacent regions of one file (the tracks of a CUE sheet, a DVD title).
        case cueSheet
        /// Adjacent tracks of one SACD image.
        case sacd
        /// One of the two is of a genre that plays without transitions.
        case excludedGenre
        /// The next song is read from a network share: it may not be ready to mix in time.
        case network
        /// The songs run into each other (Smart Mix heard no silence between them).
        case segue
        /// The playlist plays without transitions.
        case playlist
    }

    public enum CutReason: String, Sendable, Hashable, CaseIterable {
        case nativeDSD
        case bitstream
        case atmos
        case integerMode
        case sixteenBit
        /// The song's length isn't known, so there's no telling where a crossfade would start.
        case unknownLength
    }

    /// One line for the signal path ("Crossfade, 6 s, equal-power", "Gapless: same album", "Cut: bitstream").
    public var summary: String {
        switch self {
        case .overlap(let seconds, let curve):
            let length = seconds.formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "Crossfade, \(length) s, \(curve.name)", comment: "Signal path, next transition: the length in seconds, then the curve, e.g. “Crossfade, 6 s, equal-power”.")
        case .mix(let mix):
            return mix.summary
        case .gap(let seconds):
            let length = seconds.formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "Gap, \(length) s of silence", comment: "Signal path, next transition: silence of this many seconds between the two songs, e.g. “Gap, 3 s of silence”.")
        case .dip:
            return String(localized: "Fade out and in (the output changes format)", comment: "Signal path, next transition: the next song needs another sample rate or channel count, so the song fades out, the output is set up again, and the next one fades in.")
        case .gapless(let reason):
            switch reason {
            case .off: return String(localized: "Gapless", comment: "Signal path, next transition: joined with no gap and no fade.")
            case .sameAlbum: return String(localized: "Gapless: same album", comment: "Signal path, next transition.")
            case .cueSheet: return String(localized: "Gapless: one file (CUE sheet)", comment: "Signal path, next transition: the next track is the next part of the same file.")
            case .sacd: return String(localized: "Gapless: same SACD", comment: "Signal path, next transition.")
            case .excludedGenre: return String(localized: "Gapless: genre plays without transitions", comment: "Signal path, next transition: one of the songs is of a genre set to play without transitions (Classical…).")
            case .network: return String(localized: "Gapless: next song is on a network share", comment: "Signal path, next transition: the next song is read live from a network share, so it isn't mixed.")
            case .segue: return String(localized: "Gapless: the songs run into each other", comment: "Signal path, next transition: Smart Mix found that one song continues into the next (no silence between them), so they are joined untouched.")
            case .playlist: return String(localized: "Gapless: this playlist plays without transitions", comment: "Signal path, next transition: the playlist's own setting turns transitions off.")
            }
        case .cut(let reason):
            switch reason {
            case .nativeDSD: return String(localized: "No transition: native DSD", comment: "Signal path, next transition: DSD sent as DoP is never mixed or faded.")
            case .bitstream: return String(localized: "No transition: bitstream", comment: "Signal path, next transition: Dolby or DTS sent to a receiver is never mixed or faded.")
            case .atmos: return String(localized: "No transition: Dolby Atmos", comment: "Signal path, next transition: macOS renders Dolby Atmos itself, so it isn't mixed.")
            case .integerMode: return String(localized: "No transition: integer mode", comment: "Signal path, next transition: samples sent as integers untouched are never mixed or faded.")
            case .sixteenBit: return String(localized: "No transition: 16-bit output", comment: "Signal path, next transition: a 16-bit source sent as 16-bit (Match 16-bit sources) isn't mixed.")
            case .unknownLength: return String(localized: "No transition: length unknown", comment: "Signal path, next transition: the song's length isn't known, so no crossfade can be placed.")
            }
        }
    }

    /// The samples are changed at this boundary (a dip or an overlap).
    public var changesSamples: Bool {
        switch self {
        case .gapless, .cut, .gap: false
        case .dip, .overlap, .mix: true
        }
    }
}

/// Smart Mix's transition for one pair of songs, chosen from how the first ends and the second starts.
public struct SmartMix: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The first song fades out: the next starts inside its fade.
        case insideFade
        /// Both stop and start at once: a short overlap, no long wash.
        case coldCut
        /// Silence at the end or start, trimmed: then a short crossfade.
        case trimmed
        /// Not sure what the songs do: a plain crossfade of the chosen length.
        case crossfade
    }

    public var kind: Kind
    /// The overlap, in seconds (shorter when the songs are).
    public var seconds: Double
    /// The outgoing song's curve over the overlap; nil leaves it at its own level (it fades out by itself).
    public var outCurve: TransitionCurve?
    /// The incoming song rises from silence over this many seconds from the overlap's start (0: at its own level).
    public var inSeconds: Double
    public var inCurve: TransitionCurve
    /// The outgoing song's level minus the incoming one's (dB, within ±`maximumMatch`): over the overlap the first is
    /// brought down and the second up by this much in all, each back to its own level where it plays alone.
    public var matchDB: Double

    public init(kind: Kind, seconds: Double, outCurve: TransitionCurve?, inSeconds: Double, inCurve: TransitionCurve, matchDB: Double) {
        self.kind = kind
        self.seconds = seconds
        self.outCurve = outCurve
        self.inSeconds = inSeconds
        self.inCurve = inCurve
        self.matchDB = matchDB
    }

    public static let maximumMatch = 6.0

    /// The gains at `t` (0…1 through the overlap) for the outgoing and incoming song, the curves and the loudness
    /// match together. `inFraction`: the incoming song's rise as a fraction of the overlap (0: none).
    public func gains(at t: Double, inFraction: Double) -> (out: Double, in: Double) {
        let out = outCurve.map { $0.gains(at: t).out } ?? 1
        let rise = inFraction > 0 ? inCurve.gains(at: min(1, t / inFraction)).in : 1
        guard matchDB != 0 else { return (out, rise) }
        // The first song goes from its own level at the start to `matchDB` down at the end, the second from
        // `matchDB` up at the start to its own level at the end: always `matchDB` apart, so the two sound at one level
        // all through the overlap, and each is at its own where it plays alone.
        let a = pow(10, -matchDB * t / 20), b = pow(10, matchDB * (1 - t) / 20)
        return (out * a, rise * b)
    }

    /// One line for the signal path.
    public var summary: String {
        let length = seconds.formatted(.number.precision(.fractionLength(0...1)))
        switch kind {
        case .insideFade: return String(localized: "Smart Mix: into the fade, \(length) s", comment: "Signal path, next transition: the song fades out and the next one starts inside its fade; the length in seconds.")
        case .coldCut: return String(localized: "Smart Mix: quick cut", comment: "Signal path, next transition: both songs stop and start abruptly, so they meet in a short overlap of half a second.")
        case .trimmed: return String(localized: "Smart Mix: silence trimmed, \(length) s blend", comment: "Signal path, next transition: the silence at the end or start is left out, then a short crossfade; the length in seconds.")
        case .crossfade: return String(localized: "Smart Mix: crossfade, \(length) s", comment: "Signal path, next transition: Smart Mix couldn't tell how the songs end and start, so it uses a plain crossfade; the length in seconds.")
        }
    }
}

/// Chooses Smart Mix's transition from the end of one song and the start of the next (their profiles, as measured
/// by `TransitionAnalyzer`). Pure: the same inputs give the same choice.
public enum SmartMixPlanner {
    public static let coldCutSeconds = 0.5
    public static let coldCutRise = 0.1
    public static let trimmedSeconds = 1.0
    public static let fadeRange = 2.0...12.0
    /// A fade with a confidence between these is unclear: Smart Mix then doesn't guess.
    public static let unsureFade = 0.3..<TransitionAnalyzer.fadeConfidenceNeeded

    /// `gainA`/`gainB`: the ReplayGain (dB) each song plays at, added to its measured loudness. nil means a segue
    /// (gapless) when both songs run into each other.
    public static func plan(_ settings: TransitionSettings, tail: TransitionProfile.Edge?, head: TransitionProfile.Edge?,
                            gainA: Double = 0, gainB: Double = 0) -> SmartMix? {
        let plain = SmartMix(kind: .crossfade, seconds: settings.crossfadeSeconds, outCurve: settings.curve,
                             inSeconds: settings.crossfadeSeconds, inCurve: settings.curve, matchDB: 0)
        guard let tail, let head else { return plain }
        var match = 0.0
        if let a = tail.loudness, let b = head.loudness, a.isFinite, b.isFinite {
            match = min(max((a + gainA) - (b + gainB), -SmartMix.maximumMatch), SmartMix.maximumMatch)
            match = (match * 10).rounded() / 10
        }
        if unsureFade.contains(tail.fadeConfidence) || unsureFade.contains(head.fadeConfidence) {
            var mix = plain
            mix.matchDB = match
            return mix
        }
        let startsQuiet = head.type == .fade || head.type == .silence
        switch (tail.type, head.type) {
        case (.fade, _):
            let seconds = min(max(tail.fade ?? fadeRange.lowerBound, fadeRange.lowerBound), fadeRange.upperBound)
            return SmartMix(kind: .insideFade, seconds: seconds, outCurve: nil, inSeconds: startsQuiet ? 0 : max(1, seconds / 2),
                            inCurve: settings.curve, matchDB: match)
        case (.segue, .segue):
            return nil
        case (.silence, _), (_, .silence):
            return SmartMix(kind: .trimmed, seconds: trimmedSeconds, outCurve: settings.curve, inSeconds: startsQuiet ? 0 : trimmedSeconds,
                            inCurve: settings.curve, matchDB: match)
        case (_, .fade):
            return SmartMix(kind: .trimmed, seconds: trimmedSeconds, outCurve: settings.curve, inSeconds: 0, inCurve: settings.curve, matchDB: match)
        case (.cold, _), (.segue, _):
            return SmartMix(kind: .coldCut, seconds: coldCutSeconds, outCurve: settings.curve, inSeconds: coldCutRise,
                            inCurve: settings.curve, matchDB: match)
        }
    }
}

/// Decides each boundary from the settings and what's known about the two songs. Pure: the same inputs give the same
/// decision, and nothing here touches audio.
public enum TransitionPlanner {
    /// The fade out and the fade in of a dip, each.
    public static let dipSeconds = 1.0

    /// `compatible`: the next song plays on the output as it's set up (`OutputPlan.isDeviceCompatible`), so it can
    /// overlap; false means the output is set up again in between. `lengthKnown`: the outgoing song's end can be found
    /// ahead of time. `nextStreams`: the next song is read live from a network share.
    /// `profiles`: the end of `a` and the start of `b` as measured, for Smart Mix (nil: not measured; Smart Mix then
    /// plans as a crossfade, and the engine measures them before it mixes).
    public static func decide(_ base: TransitionSettings, from a: PlayableItem, format formatA: BoundaryFormat,
                              to b: PlayableItem, format formatB: BoundaryFormat, compatible: Bool = true,
                              lengthKnown: Bool = true, nextStreams: Bool = false,
                              profiles: (tail: TransitionProfile.Edge?, head: TransitionProfile.Edge?)? = nil,
                              gains: (a: Double, b: Double) = (0, 0)) -> TransitionDecision {
        guard base.enabled else { return .gapless(.off) }
        // A playlist's own transitions (the incoming song's, else the outgoing one's).
        guard let settings = effective(base, a: a, b: b) else { return .gapless(.playlist) }
        // Formats nothing may touch, on either side.
        for format in [formatA, formatB] {
            if let reason = cutReason(format) { return .cut(reason) }
        }
        // Albums, CUE sheets and SACDs play as they were made.
        if a.url == b.url, a.sacdArea == b.sacdArea, a.dvd == b.dvd, let start = a.regionStartFrame, let length = a.regionFrameLength,
           let next = b.regionStartFrame, next == start + length {
            return .gapless(a.sacdArea != nil ? .sacd : .cueSheet)
        }
        if let ca = a.context, let cb = b.context, ca.isFollowed(onAlbumBy: cb) { return .gapless(.sameAlbum) }
        if settings.excludes(genre: a.context?.genre) || settings.excludes(genre: b.context?.genre) { return .gapless(.excludedGenre) }
        if nextStreams { return .gapless(.network) }
        if case .unknown = formatB { return blend(settings, profiles: profiles, gains: gains) }
        if !compatible { return .dip(seconds: dipSeconds, curve: settings.curve) }
        if !lengthKnown { return .cut(.unknownLength) }
        return blend(settings, profiles: profiles, gains: gains)
    }

    /// The settings for the boundary into `b`: with its playlist's override (else `a`'s); nil when that's off.
    public static func effective(_ settings: TransitionSettings, a: PlayableItem, b: PlayableItem) -> TransitionSettings? {
        guard let override = b.context?.override ?? a.context?.override else { return settings }
        return override.applied(to: settings)
    }

    /// Where two songs can blend: the gap when one is set, the style's blend otherwise.
    static func blend(_ settings: TransitionSettings, profiles: (tail: TransitionProfile.Edge?, head: TransitionProfile.Edge?)?,
                      gains: (a: Double, b: Double)) -> TransitionDecision {
        if settings.gapSeconds > 0 { return .gap(seconds: settings.gapSeconds) }
        guard settings.isSmart else { return .overlap(seconds: settings.crossfadeSeconds, curve: settings.curve) }
        guard let mix = SmartMixPlanner.plan(settings, tail: profiles?.tail, head: profiles?.head, gainA: gains.a, gainB: gains.b) else {
            return .gapless(.segue)
        }
        return .mix(mix)
    }

    /// Native DSD, bitstream, macOS's Atmos renderer, integer samples and 16-bit words are never mixed or faded.
    static func cutReason(_ format: BoundaryFormat) -> TransitionDecision.CutReason? {
        switch format {
        case .systemRenderer: return .atmos
        case .unknown: return nil
        case .plan(let plan):
            switch plan.mode {
            case .dop: return .nativeDSD
            case .bitstream: return .bitstream
            case .pcm: break
            }
            if plan.integerSamples { return .integerMode }
            if plan.sixteenBit == .requested { return .sixteenBit }
            return nil
        }
    }
}
