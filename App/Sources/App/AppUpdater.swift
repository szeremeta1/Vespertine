//
// Nocturne — automatic updates via Sparkle (EdDSA-signed appcast on GitHub Releases).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import Sparkle

@Observable
@MainActor
final class AppUpdater: NSObject {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private(set) var canCheckForUpdates = false
    let isEnabled: Bool

    override init() {
        // Isolated test libraries (QA runs) never phone home.
        isEnabled = UserDefaults.standard.string(forKey: "NocturneDataDirectory") == nil
            || UserDefaults.standard.string(forKey: "NocturneUpdateFeedOverride") != nil
        super.init()
        guard isEnabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        if UserDefaults.standard.bool(forKey: "NocturneCheckForUpdatesInBackground") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkInBackground() }
        }
        observations.append(controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        })
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    var automaticallyDownloads = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    /// Testing aid for `-NocturneCheckForUpdatesInBackground YES`.
    func checkInBackground() { controller?.updater.checkForUpdatesInBackground() }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Testing aid: `-NocturneUpdateFeedOverride <url>` points the updater at another appcast.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "NocturneUpdateFeedOverride")
    }
}
