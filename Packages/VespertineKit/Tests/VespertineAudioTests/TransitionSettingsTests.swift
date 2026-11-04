//
// Vespertine — the transitions settings: defaults, ranges, and loading whatever an older or newer version stored.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transition settings")
struct TransitionSettingsTests {
    /// A suite named by absolute path keeps its plist in a scratch folder, not in ~/Library/Preferences.
    private func defaults() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("transition-settings-\(UUID().uuidString).plist").path
        return UserDefaults(suiteName: path)!
    }

    private func load(_ json: String) -> TransitionSettings {
        let d = defaults()
        d.set(json.data(using: .utf8), forKey: TransitionSettings.defaultsKey)
        return TransitionSettings.load(from: d)
    }

    @Test("Defaults: off; when first turned on, a 6 s equal-power crossfade, skips fade quickly, four genres left alone")
    func defaultsAreOff() {
        let s = TransitionSettings.load(from: defaults())
        #expect(s == TransitionSettings())
        #expect(!s.enabled && !s.explainerSeen)
        #expect(s.style == .crossfade && s.crossfadeSeconds == 6 && s.curve == .equalPower && s.skip == .quickFade)
        #expect(s.excludedGenres == ["Classical", "Opera", "Soundtrack", "Spoken Word"])
        #expect(s.albumsGapless)
    }

    @Test("The choices on offer")
    func choices() {
        #expect(TransitionStyle.allCases == [.crossfade, .smartMix, .liveSet])
        #expect(TransitionCurve.allCases == [.equalPower, .linear, .sCurve])
        #expect(SkipTransition.allCases == [.instant, .quickFade, .crossfade])
        #expect(TransitionSettings.crossfadeRange == 1...12 && TransitionSettings.crossfadeStep == 0.5)
    }

    @Test("Everything chosen comes back, the master switch included")
    func roundTrip() {
        let d = defaults()
        var s = TransitionSettings()
        s.enabled = true
        s.style = .liveSet
        s.crossfadeSeconds = 9.5
        s.curve = .sCurve
        s.skip = .crossfade
        s.excludedGenres = ["Jazz", "Ambient"]
        s.explainerSeen = true
        s.save(to: d)
        #expect(TransitionSettings.load(from: d) == s)
        // Turned off, the choices stay.
        s.enabled = false
        s.save(to: d)
        let off = TransitionSettings.load(from: d)
        #expect(!off.enabled && off.style == .liveSet && off.crossfadeSeconds == 9.5 && off.curve == .sCurve && off.explainerSeen)
    }

    @Test("Every style, curve and skip choice round-trips", arguments: TransitionStyle.allCases)
    func everyValue(style: TransitionStyle) {
        for curve in TransitionCurve.allCases {
            for skip in SkipTransition.allCases {
                let d = defaults()
                var s = TransitionSettings()
                s.style = style; s.curve = curve; s.skip = skip
                s.save(to: d)
                #expect(TransitionSettings.load(from: d) == s)
            }
        }
    }

    @Test("Stored as named values, so another version can read them")
    func storedNames() throws {
        let d = defaults()
        var s = TransitionSettings()
        s.style = .smartMix; s.curve = .sCurve; s.skip = .instant
        s.save(to: d)
        let data = try #require(d.data(forKey: "transitions"))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""style":"smartMix""#) && json.contains(#""curve":"sCurve""#) && json.contains(#""skip":"instant""#))
        #expect(json.contains(#""enabled":false"#))
        #expect(!json.contains("albumsGapless"))
    }

    @Test("Lengths snap to half seconds within 1…12", arguments: [
        (6.0, 6.0), (1.0, 1.0), (12.0, 12.0), (0.0, 1.0), (-3.0, 1.0), (40.0, 12.0), (12.2, 12.0), (2.24, 2.0), (2.26, 2.5),
        (7.75, 8.0), (.nan, 6.0), (.infinity, 6.0), (-.infinity, 6.0),
    ])
    func lengths(stored: Double, loaded: Double) {
        #expect(TransitionSettings.crossfadeLength(stored) == loaded)
        var s = TransitionSettings()
        s.crossfadeSeconds = stored
        #expect(s.normalized.crossfadeSeconds == loaded)
    }

    @Test("A length out of range in the stored settings loads in range")
    func storedLength() {
        #expect(load(#"{"crossfadeSeconds":30}"#).crossfadeSeconds == 12)
        #expect(load(#"{"crossfadeSeconds":0.2}"#).crossfadeSeconds == 1)
        #expect(load(#"{"crossfadeSeconds":4.4}"#).crossfadeSeconds == 4.5)
    }

    @Test("Settings from another version: missing values take their defaults, unknown ones are ignored")
    func otherVersions() {
        #expect(load("{}") == TransitionSettings())
        let older = load(#"{"enabled":true}"#)
        #expect(older.enabled && older.style == .crossfade && older.crossfadeSeconds == 6 && older.skip == .quickFade)
        let newer = load(#"{"enabled":true,"style":"djBattle","curve":"logarithmic","skip":"scratch","gapSeconds":4,"future":{"a":1}}"#)
        #expect(newer.enabled && newer.style == .crossfade && newer.curve == .equalPower && newer.skip == .quickFade)
        // A value of the wrong type is a default too, without losing the rest.
        let wrong = load(#"{"enabled":"yes","crossfadeSeconds":"long","curve":"linear","excludedGenres":"Jazz"}"#)
        #expect(!wrong.enabled && wrong.crossfadeSeconds == 6 && wrong.curve == .linear && wrong.excludedGenres == TransitionSettings.defaultExcludedGenres)
    }

    @Test("Stored data that isn't settings at all loads the defaults")
    func garbage() {
        #expect(load("not json") == TransitionSettings())
        #expect(load("[1,2,3]") == TransitionSettings())
        let d = defaults()
        d.set("a string, not data", forKey: TransitionSettings.defaultsKey)
        #expect(TransitionSettings.load(from: d) == TransitionSettings())
    }

    @Test("Album tracks stay gapless whatever a hand-edited file says")
    func albumsAlwaysGapless() {
        #expect(load(#"{"albumsGapless":false}"#).albumsGapless)
    }

    @Test("An empty genre list is kept: nothing is excluded")
    func noExclusions() {
        let s = load(#"{"excludedGenres":[]}"#)
        #expect(s.excludedGenres.isEmpty)
        #expect(!s.excludes(genre: "Classical"))
    }

    @Test("Genre names are tidied: blanks dropped, duplicates (by case and accents) once, order kept")
    func tidyGenres() {
        let s = load(#"{"excludedGenres":["  Opera ","","opera","Classical","Musique concrète","MUSIQUE CONCRETE","\n"]}"#)
        #expect(s.excludedGenres == ["Opera", "Classical", "Musique concrète"])
    }

    @Test("The explainer is due only the first time the switch is turned on, and survives a relaunch as seen")
    func explainerOnce() {
        let d = defaults()
        var s = TransitionSettings.load(from: d)
        var due = s.setEnabled(false)                 // turning it off never shows it
        #expect(!due && !s.explainerSeen)
        due = s.setEnabled(true)
        #expect(due && s.enabled && s.explainerSeen)
        due = s.setEnabled(false)
        #expect(!due && !s.enabled)
        due = s.setEnabled(true)                      // the second time on: not again
        #expect(!due && s.enabled)
        s.save(to: d)
        var relaunched = TransitionSettings.load(from: d)
        relaunched.setEnabled(false)
        due = relaunched.setEnabled(true)
        #expect(!due)
        // Settings from before the explainer existed, already on: it's still due the next time it's turned on.
        var older = load(#"{"enabled":true}"#)
        #expect(older.enabled && !older.explainerSeen)
        due = older.setEnabled(true)
        #expect(due)
    }

    @Test("Excluded genres match as the library matches genres")
    func excludes() {
        let s = TransitionSettings()
        #expect(s.excludes(genre: "Classical"))
        #expect(s.excludes(genre: "classical"))
        #expect(s.excludes(genre: "  Spoken Word "))
        #expect(s.excludes(genre: "Rock; Opera"))
        #expect(s.excludes(genre: "Jazz|Soundtrack"))
        #expect(s.excludes(genre: "Pop, CLASSICAL"))
        #expect(!s.excludes(genre: "Modern Classical"))
        #expect(!s.excludes(genre: "Classical/Crossover"))       // "/" is part of a name, as in Genres.split
        #expect(!s.excludes(genre: "Rock"))
        #expect(!s.excludes(genre: ""))
        #expect(!s.excludes(genre: nil))
        var accents = TransitionSettings()
        accents.excludedGenres = ["Chanson française"]
        #expect(accents.excludes(genre: "chanson francaise"))
    }
}
