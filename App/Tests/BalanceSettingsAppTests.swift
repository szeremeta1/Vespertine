//
// Vespertine: balance is kept per output, the center is stored as nothing at all, and what is kept reaches the engine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

@Suite("Balance per output", .serialized) @MainActor
struct BalanceSettingsAppTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-balance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A suite named by absolute path keeps its plist in `root`, so nothing is left in ~/Library/Preferences.
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("An output never touched is centered; a value is kept, clamped, and read back after a relaunch")
    func roundTrip() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(settings.balance(for: "DAC") == 0)
        #expect(settings.engineSettings().deviceBalances.isEmpty)

        settings.setBalance(0.2, for: "DAC")
        settings.setBalance(-7, for: "HDMI")
        #expect(settings.balance(for: "DAC") == 0.2)
        #expect(settings.balance(for: "HDMI") == -1)
        #expect(settings.balance(for: "Other") == 0)
        #expect(settings.engineSettings().deviceBalances == ["DAC": 0.2, "HDMI": -1])

        let relaunched = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(relaunched.balance(for: "DAC") == 0.2)
        #expect(relaunched.balance(for: "HDMI") == -1)
        #expect(relaunched.balance(for: "Other") == 0)
    }

    @Test("The center removes the entry, and what isn't a number is the center")
    func centerIsNoEntry() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.setBalance(0.5, for: "DAC")
        settings.setBalance(0, for: "DAC")
        #expect(settings.appBalances["DAC"] == nil)
        #expect((defaults.dictionary(forKey: "appBalances") ?? [:]).isEmpty)
        settings.setBalance(.nan, for: "DAC")
        #expect(settings.appBalances["DAC"] == nil && settings.balance(for: "DAC") == 0)
    }

    @Test("Balance Left, Balance Right and Center Balance move one output and leave the others alone")
    func menuSteps() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.setBalance(0.4, for: "HDMI")
        settings.applyBalance(.left, for: "DAC")
        settings.applyBalance(.left, for: "DAC")
        #expect(settings.balance(for: "DAC") == -0.1)
        settings.applyBalance(.right, for: "DAC")
        settings.applyBalance(.center, for: "DAC")
        #expect(settings.appBalances["DAC"] == nil)
        #expect(settings.balance(for: "HDMI") == 0.4)
    }

    @Test("A DAC that comes back under a new identifier keeps its balance")
    func movedDevice() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.setBalance(0.3, for: "old")
        settings.moveDeviceSettings(from: "old", to: "new")
        #expect(settings.balance(for: "new") == 0.3)
    }
}
