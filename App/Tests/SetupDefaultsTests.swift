import Foundation
import VespertineLibrary
import Testing
@testable import Vespertine

/// What the setup assistant shows as chosen on a fresh install is what the app really starts with, and what its pages
/// say about those choices is true of them.
@Suite("Setup starts on the defaults it describes", .serialized) @MainActor
struct SetupDefaultsTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-setup-defaults-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("A fresh install leaves files where they are until copying is chosen")
    func filesStayInPlaceByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(settings.defaultImportMode == .reference)
        #expect(defaults.object(forKey: "importMode") as? String == ImportMode.reference.rawValue,
                "the registered default is the one the Music step shows as chosen")
    }

    @Test("Copy and organize, once chosen, is kept at the next launch; so is going back")
    func chosenImportModeIsKept() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        AppSettings(defaults: defaults, dataDirectory: root).defaultImportMode = .copyAndOrganize
        let relaunched = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(relaunched.defaultImportMode == .copyAndOrganize)
        relaunched.defaultImportMode = .reference
        #expect(AppSettings(defaults: defaults, dataDirectory: root).defaultImportMode == .reference)
    }

    @Test("A stored import mode this version doesn't know leaves files where they are")
    func unknownImportModeIsInPlace() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("moveAndRename", forKey: "importMode")
        #expect(AppSettings(defaults: defaults, dataDirectory: root).defaultImportMode == .reference)
    }

    @Test("The Music step's folder tile does what its name says: Add a Folder references, Import & Organize copies")
    func folderTileFollowsTheChoice() {
        #expect(SetupFolderTile(mode: .reference) == .addFolder)
        #expect(SetupFolderTile(mode: .copyAndOrganize) == .importAndOrganize)
        #expect(SetupFolderTile.addFolder.mode == .reference)
        #expect(SetupFolderTile.importAndOrganize.mode == .copyAndOrganize)
        for mode in ImportMode.allCases { #expect(SetupFolderTile(mode: mode).mode == mode) }
    }

    /// The Extras heading says the switches that start on are on that page. These are every setting that reaches the
    /// internet by itself: a new one that starts on belongs on the page too, and one that starts off must stay off here.
    @Test("Of the things that reach the internet, only the ones on the Extras page start on")
    func onlyTheExtrasPageStartsOn() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        // On the page, on: cover art (fetched only at a lookup) and the daily list of DoP DACs.
        #expect(settings.fetchArtworkOnline && settings.dopListUpdates)
        // On the page, off: background analysis.
        #expect(!settings.autoAnalyze)
        // Not on the page, so off: everything else that would send or fetch without being asked.
        #expect(!settings.scrobble && !settings.discordPresence)
        #expect(!settings.upnpRenderersFeature && !settings.airPlayPlayersFeature && !settings.upnpReceiverFeature)
        #expect(!settings.watchFolders && !settings.analyzeNetworkShares)
    }
}
