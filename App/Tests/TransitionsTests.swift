import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// Transitions in the app: the setting is kept like the others, starts off for everyone, and reaches the engine only
/// while its master switch is on (off, the engine gets exactly what it got before transitions).
@Suite("Transitions setting", .serialized) @MainActor
struct TransitionsTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-transitions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("Off for a new install, and for an existing one that never had the setting")
    func offByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        #expect(AppSettings(defaults: defaults, dataDirectory: root).transitions == TransitionSettings())
        // An install from before transitions: other settings stored, none for transitions.
        defaults.set(true, forKey: "exclusiveMode")
        defaults.set("album", forKey: "replayGain")
        defaults.set(true, forKey: "setupCompleted")
        let upgraded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!upgraded.transitions.enabled && !upgraded.transitions.explainerSeen)
        #expect(upgraded.exclusiveMode && upgraded.replayGain == .album)
        // Loading it writes nothing: an older version opened afterwards finds the defaults as they were.
        #expect(defaults.object(forKey: TransitionSettings.defaultsKey) == nil)
    }

    @Test("What's chosen is kept across launches")
    func persists() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.transitions.setEnabled(true)
        settings.transitions.style = .smartMix
        settings.transitions.crossfadeSeconds = 3.5
        settings.transitions.curve = .linear
        settings.transitions.skip = .instant
        settings.transitions.excludedGenres = ["Opera"]
        let again = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(again.transitions == settings.transitions)
        #expect(again.transitions.enabled && again.transitions.explainerSeen && again.transitions.style == .smartMix)
        settings.transitions.setEnabled(false)
        let off = AppSettings(defaults: defaults, dataDirectory: root).transitions
        #expect(!off.enabled && off.style == .smartMix && off.crossfadeSeconds == 3.5 && off.explainerSeen)
    }

    @Test("A damaged stored value loads as the defaults instead of failing")
    func damaged() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(Data("{\"enabled\": tru".utf8), forKey: TransitionSettings.defaultsKey)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).transitions == TransitionSettings())
        defaults.set(42, forKey: TransitionSettings.defaultsKey)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).transitions == TransitionSettings())
    }

    @Test("Off, the engine gets exactly the settings it got before transitions, whatever is chosen; on, it gets the choices")
    func reachesTheEngineOnlyWhenOn() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let before = settings.engineSettings()
        #expect(before.transitions == TransitionSettings())
        for style in TransitionStyle.allCases {
            for curve in TransitionCurve.allCases {
                for skip in SkipTransition.allCases {
                    settings.transitions.setEnabled(false)
                    settings.transitions.style = style
                    settings.transitions.curve = curve
                    settings.transitions.skip = skip
                    settings.transitions.crossfadeSeconds = 12
                    settings.transitions.trimSilence = false
                    settings.transitions.excludedGenres = ["Jazz"]
                    #expect(settings.engineSettings() == before)
                    settings.transitions.setEnabled(true)
                    let on = settings.engineSettings().transitions
                    #expect(on.enabled && on.style == style && on.curve == curve && on.skip == skip && on.crossfadeSeconds == 12)
                    #expect(!on.trimSilence && on.excludedGenres == ["Jazz"] && !on.explainerSeen)
                    // Nothing but transitions differs.
                    var rest = settings.engineSettings()
                    rest.transitions = TransitionSettings()
                    #expect(rest == before)
                }
            }
        }
        settings.transitions.setEnabled(false)
        #expect(settings.engineSettings() == before)
    }

    @Test("Queued songs carry their album (when they have one), place on it and genre")
    func queueContext() {
        let c = PlayerController.transitionContext(album: "Kind of Blue", albumKey: "miles davis\u{1F}kind of blue", disc: 1, track: 2, genre: "Jazz")
        #expect(c == TransitionContext(albumKey: "miles davis\u{1F}kind of blue", discNumber: 1, trackNumber: 2, genre: "Jazz"))
        // No album tag: every such song of an artist would share "Unknown Album", so none is claimed.
        #expect(PlayerController.transitionContext(album: nil, albumKey: "x\u{1F}Unknown Album", disc: nil, track: 1, genre: nil).albumKey == nil)
        #expect(PlayerController.transitionContext(album: "  ", albumKey: "x\u{1F}  ", disc: nil, track: 1, genre: nil).albumKey == nil)
    }
}
