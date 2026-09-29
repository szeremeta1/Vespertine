//
// Vespertine — one-time move from the app's old name, Nocturne. Settings and the library folder are
// copied (APFS clones, so no extra disk space); the originals stay where they were as a backup.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import OSLog

private let migrationLog = Logger(subsystem: "org.szeremeta.vespertine.player", category: "migration")

enum LegacyMigration {
    static let doneKey = "migratedFromNocturne"

    /// Runs before the library opens. Does nothing for new users, test runs and libraries in a custom folder.
    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let bundleID, bundleID.hasPrefix("org.szeremeta.Vespertine"), defaults.object(forKey: doneKey) == nil,
              defaults.string(forKey: "VespertineDataDirectory") == nil else { return }
        let dev = bundleID.hasSuffix(".dev")
        let legacyID = dev ? "org.nocturne.Nocturne.dev" : "org.nocturne.Nocturne"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyDir = support.appendingPathComponent(dev ? "Nocturne Dev" : "Nocturne", isDirectory: true)
        let newDir = support.appendingPathComponent(dev ? "Vespertine Dev" : "Vespertine", isDirectory: true)
        let legacyPrefs = CFPreferencesCopyMultiple(nil, legacyID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any] ?? [:]
        let fm = FileManager.default
        let legacyLibrary = fm.fileExists(atPath: legacyDir.appendingPathComponent("Library.sqlite").path)
        guard legacyLibrary || !legacyPrefs.isEmpty,
              !fm.fileExists(atPath: newDir.appendingPathComponent("Library.sqlite").path) else {
            defaults.set(Date(), forKey: doneKey)
            return
        }
        // Opening now would start an empty library and the old one would never be brought over.
        guard legacyAppIsClosed(legacyID) else { exit(0) }

        if legacyLibrary {
            do { try copyLibrary(from: legacyDir, to: newDir) }
            catch {
                migrationLog.error("Library copy failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Couldn’t bring over your Nocturne library"
                alert.informativeText = "\(error.localizedDescription)\n\nNothing was changed in the Nocturne folder. Vespertine will quit and try again next time it opens."
                alert.runModal()
                exit(0)
            }
        }
        for (key, value) in legacyPrefs where defaults.object(forKey: key) == nil && !skippedKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        // Music imported by Nocturne keeps going to the same folder; new installs use ~/Music/Vespertine.
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let legacyMusic = music.appendingPathComponent("Nocturne", isDirectory: true)
        if legacyPrefs["managedFolder"] == nil, defaults.string(forKey: "managedFolder") == nil, fm.fileExists(atPath: legacyMusic.path) {
            defaults.set(legacyMusic.path, forKey: "managedFolder")
        }
        defaults.set(Date(), forKey: doneKey)
        migrationLog.notice("Brought over \(legacyPrefs.count) settings\(legacyLibrary ? " and the library" : "", privacy: .public) from Nocturne")
    }

    /// Settings not worth carrying over: update-check timing and testing overrides.
    static let skippedKeys: Set<String> = ["SULastCheckTime", "SUHasLaunchedBefore", "NocturneDataDirectory"]

    /// Everything in the old library folder except `Shares` (mount points, recreated on demand). Copied
    /// into a staging folder first, so an interrupted copy never looks like a finished library.
    static func copyLibrary(from legacy: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".migrating")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) where item.lastPathComponent != "Shares" {
            try fm.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
        }
        if fm.fileExists(atPath: destination.path) {
            // Only an empty folder (or one without a library) is replaced; its contents are kept inside.
            for item in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
                let target = staging.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: item, to: target) }
            }
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
    }

    /// The old app must not be writing its library while it's copied.
    @MainActor
    private static func legacyAppIsClosed(_ legacyID: String) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyID)
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Nocturne is still open"
        alert.informativeText = "Vespertine is Nocturne’s new name. Quit Nocturne so your library, playlists and settings can be brought over. Nocturne’s own files are left as they are."
        alert.addButton(withTitle: "Quit Nocturne")
        alert.addButton(withTitle: "Quit Vespertine")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return running.allSatisfy(\.isTerminated)
    }
}
