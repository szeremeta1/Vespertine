import Foundation
import VespertineOpenSubsonic
import VespertineStreaming
import Testing
@testable import Vespertine

/// Setup's "More ways to play" step shows what 1.2 added (network players, AirPlay players, Receive from Other Apps, music
/// servers) as the Settings switches they are: the same words, every one off until it is switched on.
@Suite("Setup: More ways to play", .serialized) @MainActor
struct SetupMoreTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-setup-more-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("The step sits between Extras and Remote, has its place in the progress bar, and opens by name")
    func stepOrder() {
        #expect(SetupStep.allCases == [.welcome, .music, .output, .sound, .extras, .more, .remote, .done])
        #expect(SetupStep.named == [.music, .output, .sound, .extras, .more, .remote])
        #expect(SetupStep.extras.next == .more && SetupStep.more.next == .remote)
        #expect(SetupStep.remote.previous == .more && SetupStep.more.previous == .extras)
        #expect(SetupStep(name: "more") == .more)
        #expect(SetupStep.welcome.previous == nil && SetupStep.done.next == nil)
    }

    @Test("Every step can be reached by going forward from Welcome and back from Done")
    func everyStepIsReachable() {
        var forward: [SetupStep] = [], step: SetupStep? = .welcome
        while let current = step { forward.append(current); step = current.next }
        #expect(forward == SetupStep.allCases)
        var back: [SetupStep] = []
        step = .done
        while let current = step { back.append(current); step = current.previous }
        #expect(back == SetupStep.allCases.reversed())
    }

    @Test("Each card is named and explained in its Settings switch's own words")
    func wordsAreTheSettingsSwitches() {
        #expect(SetupMoreSwitch.allCases == [.networkPlayers, .airPlayPlayers, .receiveFromOtherApps, .musicServers])
        #expect(SetupMoreSwitch.networkPlayers.title == RendererSwitch.title)
        #expect(SetupMoreSwitch.networkPlayers.explanation == RendererSwitch.explanation)
        #expect(SetupMoreSwitch.airPlayPlayers.title == AirPlaySwitch.title)
        #expect(SetupMoreSwitch.airPlayPlayers.explanation == AirPlaySwitch.explanation)
        #expect(SetupMoreSwitch.receiveFromOtherApps.title == ReceiverSwitch.title)
        #expect(SetupMoreSwitch.receiveFromOtherApps.explanation == ReceiverSwitch.explanation)
        #expect(SetupMoreSwitch.musicServers.title == StreamingSwitch.title)
        #expect(SetupMoreSwitch.musicServers.explanation == StreamingSwitch.explanation)
        for item in SetupMoreSwitch.allCases {
            #expect(!item.title.isEmpty && !item.explanation.isEmpty && !item.symbol.isEmpty)
        }
    }

    @Test("The rest of each is set up where its switch lives: players in Settings › Playback, servers in Settings › Library")
    func settingsTabs() {
        #expect(SetupMoreSwitch.networkPlayers.settingsTab == .playback)
        #expect(SetupMoreSwitch.airPlayPlayers.settingsTab == .playback)
        #expect(SetupMoreSwitch.receiveFromOtherApps.settingsTab == .playback)
        #expect(SetupMoreSwitch.musicServers.settingsTab == .library)
        #expect(SetupMoreSwitch.musicServerProvider == OpenSubsonicProvider.providerID)
    }

    @Test("On a fresh install every one of them is off: walking through setup switches nothing on")
    func allStartOff() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.upnpRenderersFeature && !settings.airPlayPlayersFeature && !settings.upnpReceiverFeature)
        #expect(!defaults.bool(forKey: StreamingCore.enabledKey(SetupMoreSwitch.musicServerProvider)))
    }
}
