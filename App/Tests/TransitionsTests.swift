import Foundation
import SwiftUI
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

    @Test("The feature is off for a new install and an upgrade; off, a stored playback switch does nothing and nothing is written")
    func featureOffByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "setupCompleted")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.transitionsFeature && !settings.transitionsOn)
        // Nothing stored (`object(forKey:)` would answer with the registered default, false).
        #expect(defaults.persistentDomain(forName: suite)?["transitionsFeature"] == nil)
        // A playback switch left on in a stored value still does nothing without the feature.
        var stored = TransitionSettings()
        stored.setEnabled(true)
        stored.save(to: defaults)
        let again = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(again.transitions.enabled && !again.transitionsOn)
        #expect(again.engineSettings() == AppSettings(defaults: UserDefaults(suiteName: suite + ".other")!, dataDirectory: root).engineSettings())
        again.transitionsFeature = true
        #expect(AppSettings(defaults: defaults, dataDirectory: root).transitionsOn)
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
        // The feature switch in Settings is what makes the playback switch count: without it, nothing reaches the engine.
        settings.transitions.setEnabled(true)
        settings.transitions.style = .liveSet
        #expect(!settings.transitionsOn && settings.engineSettings() == before)
        settings.transitions.setEnabled(false)
        settings.transitions.style = TransitionSettings().style
        settings.transitionsFeature = true
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
        // Smart Mix's gap and "transitions first": off, they don't reach the engine either.
        settings.transitions.gapSeconds = 4
        settings.transitions.policy = .transitionsFirst
        #expect(settings.engineSettings() == before)
        settings.transitions.setEnabled(true)
        let on = settings.engineSettings().transitions
        #expect(on.gapSeconds == 4 && on.policy == .transitionsFirst && on.avoidsUnmixableModes)
        settings.transitions.setEnabled(false)
        #expect(settings.engineSettings() == before)
    }

    @Test("Shortcuts: the style action covers every style")
    func intentStyles() {
        #expect(TransitionStyleOption.allCases.map(\.style) == TransitionStyle.allCases)
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

/// Turning transitions on for the first time shows a note. It belongs in the window the switch was turned on in: shown
/// on the main window while Settings was in use, it raised that window over Settings and Settings seemed to close
/// (QA, 0.15.0: Settings' window order went 0 → 2 the moment the switch was turned on there).
@Suite("Transitions first-time note", .serialized) @MainActor
struct TransitionsNoteTests {
    @Test("Nothing is shown until the switch is turned on for the first time")
    func startsHidden() {
        let note = TransitionsNote()
        #expect(!note.isShown(in: .main) && !note.isShown(in: .settings))
    }

    @Test("Turned on in Settings, the note is Settings' sheet and the main window gets none")
    func fromSettings() {
        var note = TransitionsNote()
        note.show(in: .settings)
        #expect(note.isShown(in: .settings))
        #expect(!note.isShown(in: .main))
        note.dismiss()
        #expect(!note.isShown(in: .settings) && !note.isShown(in: .main))
    }

    @Test("Turned on from the menu, the transport bar or a shortcut, the note is the main window's")
    func fromMain() {
        var note = TransitionsNote()
        note.show(in: .main)
        #expect(note.isShown(in: .main) && !note.isShown(in: .settings))
    }

    @Test("Turning the feature off takes a note that's up away")
    func offTakesItAway() {
        var note = TransitionsNote()
        note.show(in: .settings)
        note.dismiss()
        #expect(note == TransitionsNote())
    }
}

/// The note's logo is Vespertine's one moon (docs/brand/mark-flat.svg), not the Transitions glyph's two crescents.
@Suite("Transitions note logo") @MainActor
struct TransitionsNoteLogoTests {
    /// Connected regions of a shape drawn into a square bitmap.
    static func regions(of shape: some Shape, side: Int = 160) -> Int {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.translateBy(x: 0, y: CGFloat(side)); context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(shape.path(in: CGRect(x: 0, y: 0, width: side, height: side)).cgPath)
            context.fillPath()
        }
        var seen = [Bool](repeating: false, count: side * side)
        var count = 0
        for start in 0..<side * side where pixels[start] > 127 && !seen[start] {
            count += 1
            var stack = [start]
            seen[start] = true
            while let p = stack.popLast() {
                let x = p % side, y = p / side
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                    let q = ny * side + nx
                    if pixels[q] > 127 && !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
        }
        return count
    }

    @Test("The brand moon is one region; the Transitions glyph is two")
    func oneMoon() {
        #expect(Self.regions(of: VespertineMoon()) == 1)
        #expect(Self.regions(of: TransitionsGlyph()) == 2)
    }

    @Test("The note shows the brand moon")
    func noteLogo() {
        #expect(Self.regions(of: TransitionsExplainerSheet.Logo()) == 1)
    }

    @Test("The moon is the brand mark: a crescent, open towards the upper right")
    func shape() {
        let box = VespertineMoon().path(in: CGRect(x: 0, y: 0, width: 512, height: 512)).boundingRect
        #expect(abs(box.minX) < 1 && abs(box.minY) < 1 && abs(box.maxY - 512) < 1 && abs(box.maxX - 474) < 1)
        // The disc's centre is empty (the cut-out), its lower left is moon.
        let path = VespertineMoon().path(in: CGRect(x: 0, y: 0, width: 512, height: 512))
        #expect(!path.contains(CGPoint(x: 330, y: 190)))
        #expect(path.contains(CGPoint(x: 90, y: 400)))
    }
}
