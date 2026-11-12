//
// Vespertine: Mac Sound Output (beta): a speaker group as an output every app on the Mac can play to. What the user chose per group
// (off for every group until turned on), installing and removing Vespertine's audio driver, and the helper that plays the groups
// with Vespertine closed. The helper is told everything through one file (`SystemOutputSnapshot`), written whenever a choice, a
// group or its room correction changes.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import Observation
import ServiceManagement
import VespertineAudio

@MainActor @Observable
final class SystemOutputModel {
    enum DriverState: Equatable {
        case notInstalled
        /// Installed, but the Mac's audio server hasn't loaded it (it loads it when it starts again).
        case notLoaded
        /// An older driver than the one inside this Vespertine.
        case outdated
        case ready
    }

    enum HelperState: Equatable {
        case off
        case on
        /// macOS asks the user to allow the helper (System Settings › General › Login Items).
        case needsApproval
        case failed(String)
    }

    private(set) var choices: [UUID: SystemOutputChoice]
    var menuBarItem: Bool { didSet { defaults.set(menuBarItem, forKey: Self.menuBarKey); resync() } }
    private(set) var driver: DriverState = .notInstalled
    private(set) var helper: HelperState = .off
    private(set) var status: SystemOutputStatus?
    private(set) var working = false
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    /// A QA run on a test library (`-VespertineDataDirectory`) never installs, registers or publishes anything.
    @ObservationIgnored let isolated: Bool
    @ObservationIgnored private var lastSnapshot: SystemOutputSnapshot?
    @ObservationIgnored private var lastInputs: (groups: [SpeakerGroup], settings: EngineSettings)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    static let choicesKey = "systemOutputChoices"
    static let menuBarKey = "systemOutputMenuBarItem"
    static let helperBundleSuffix = ".SoundHelper"

    init(defaults: UserDefaults = .standard, isolated: Bool) {
        self.defaults = defaults
        self.isolated = isolated
        let stored = defaults.data(forKey: Self.choicesKey).flatMap { try? JSONDecoder().decode([String: SystemOutputChoice].self, from: $0) } ?? [:]
        choices = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        menuBarItem = defaults.bool(forKey: Self.menuBarKey)
        guard !isolated else { return }
        refreshDriver()
        readStatus()
        observer = DistributedNotificationCenter.default().addObserver(forName: SystemOutputHandOff.statusChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readStatus() }
        }
    }

    // MARK: Choices

    func choice(for group: UUID) -> SystemOutputChoice { choices[group] ?? SystemOutputChoice() }

    /// Called when a group is published or taken back (the engine lets go of a published group sooner when paused).
    @ObservationIgnored var onPublishedChanged: (() -> Void)?

    func setChoice(_ choice: SystemOutputChoice, for group: UUID) {
        let publishedChanged = self.choice(for: group).published != choice.published
        defer { if publishedChanged { onPublishedChanged?() } }
        choices[group] = choice
        let stored = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.choicesKey) }
        resync()
    }

    /// Any group is published (the helper runs while one is).
    func anyPublished(among groups: [SpeakerGroup]) -> Bool { groups.contains { choice(for: $0.id).published } }

    func groupStatus(_ group: UUID) -> SystemOutputStatus.Group? { status?.groups.first { $0.groupID == group } }

    // MARK: Telling the helper

    /// Writes the snapshot when something the helper plays from changed, and runs the helper while a group is published.
    /// `groups` are the saved groups when the Speaker Groups feature is on (none otherwise: nothing is published then).
    func sync(groups: [SpeakerGroup], settings: EngineSettings) {
        lastInputs = (groups, settings)
        guard !isolated else { return }
        let entries = groups.filter { choice(for: $0.id).published && $0.issues.isEmpty }.map { group in
            SystemOutputEntry(group: group, choice: choice(for: group.id), room: settings.roomCorrections[group.outputUID].flatMap { $0.isFlat ? nil : $0 },
                              exclusive: settings.exclusive)
        }
        let snapshot = SystemOutputSnapshot(entries: entries, menuBarItem: menuBarItem)
        if snapshot != lastSnapshot {
            do {
                try snapshot.write(to: SystemOutputSnapshot.url(in: SystemOutputHandOff.directory))
                lastSnapshot = snapshot
                DistributedNotificationCenter.default().postNotificationName(SystemOutputHandOff.snapshotChanged, object: nil, userInfo: nil,
                                                                             deliverImmediately: true)
            } catch {
                lastError = error.localizedDescription
            }
        }
        setHelperRunning(!entries.isEmpty && driver != .notInstalled)
    }

    private func resync() {
        if let lastInputs { sync(groups: lastInputs.groups, settings: lastInputs.settings) }
    }

    // MARK: The helper (a launch agent)

    /// The helper's bundle ID for this Vespertine: `….SoundHelper`, or `….SoundHelper.dev` for Vespertine Dev.
    private var helperIdentifier: String {
        Bundle.main.bundleIdentifier.map { base in
            base.hasSuffix(".dev") ? String(base.dropLast(4)) + Self.helperBundleSuffix + ".dev" : base + Self.helperBundleSuffix
        } ?? "org.szeremeta.Vespertine" + Self.helperBundleSuffix
    }

    /// The helper runs as a launch agent (Contents/Library/LaunchAgents, named after its bundle ID) so launchd starts it again
    /// when it ends any way but cleanly: a crash, or someone killing it.
    private var helperService: SMAppService { SMAppService.agent(plistName: helperIdentifier + ".plist") }

    /// Which build of the helper launchd was given: macOS checks the helper's signature against what it recorded at
    /// registration, so a newer build (an update, or any rebuild of Vespertine Dev) is registered again before it is started.
    private var helperBuild: String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/Vespertine Sound Helper.app/Contents/MacOS/Vespertine Sound Helper")
        let modified = (try? helper.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) \(Int(modified))"
    }
    static let helperBuildKey = "systemOutputHelperBuild"

    private func setHelperRunning(_ on: Bool) {
        let service = helperService
        do {
            // Before 1.1.0's betas the helper was a login item; that registration goes.
            let legacy = SMAppService.loginItem(identifier: helperIdentifier)
            if legacy.status == .enabled || legacy.status == .requiresApproval { try? legacy.unregister() }
            let registered = service.status == .enabled || service.status == .requiresApproval
            if on, registered, defaults.string(forKey: Self.helperBuildKey) != helperBuild {
                // Another build than the one registered: unregistering stops the old helper, registering starts this one.
                try? service.unregister()
            }
            switch (on, service.status) {
            case (true, .enabled): helper = .on
            case (true, .requiresApproval): helper = .needsApproval
            case (true, _):
                try service.register()
                defaults.set(helperBuild, forKey: Self.helperBuildKey)
                helper = service.status == .requiresApproval ? .needsApproval : .on
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
                helper = .off
            case (false, _): helper = .off
            }
        } catch {
            helper = .failed(error.localizedDescription)
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func readStatus() {
        status = SystemOutputStatus.read(from: SystemOutputStatus.url(in: SystemOutputHandOff.directory))
        refreshDriver()
    }

    // MARK: The driver

    func refreshDriver() {
        guard let installed = SystemOutputDriver.buildNumber() else { driver = .notInstalled; return }
        if let bundled = SystemOutputDriver.buildNumber(at: SystemOutputDriver.bundledURL()),
           installed.compare(bundled, options: .numeric) == .orderedAscending {
            driver = .outdated
        } else {
            driver = SystemOutputDriver.isLoaded ? .ready : .notLoaded
        }
    }

    /// Copies the driver inside Vespertine to /Library/Audio/Plug-Ins/HAL and restarts the Mac's audio server so it loads it.
    /// macOS asks for an administrator's password. Every app's sound stops for a moment while the audio server restarts.
    func installDriver() {
        let source = SystemOutputDriver.bundledURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            lastError = String(localized: "This copy of Vespertine has no audio driver inside it.")
            return
        }
        let target = SystemOutputDriver.installedURL.path
        let command = [
            "/bin/mkdir -p \(Self.quoted(SystemOutputDriver.installDirectory.path))",
            "/bin/rm -rf \(Self.quoted(target))",
            "/usr/bin/ditto \(Self.quoted(source.path)) \(Self.quoted(target))",
            "/usr/sbin/chown -R root:wheel \(Self.quoted(target))",
            "/usr/bin/killall coreaudiod",
        ].joined(separator: " && ")
        runAsAdministrator(command)
    }

    /// Takes the driver out (the outputs it showed go with it) and restarts the audio server.
    func removeDriver() {
        // Unpublish first, so the helper stops playing before the audio server goes.
        let groups = lastInputs?.groups ?? []
        for group in groups where choice(for: group.id).published {
            var off = choice(for: group.id)
            off.published = false
            choices[group.id] = off
        }
        let stored = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.choicesKey) }
        resync()
        onPublishedChanged?()
        runAsAdministrator("/bin/rm -rf \(Self.quoted(SystemOutputDriver.installedURL.path)) && /usr/bin/killall coreaudiod")
    }

    private func runAsAdministrator(_ command: String) {
        guard !isolated, !working else { return }
        working = true
        lastError = nil
        let script = "do shell script \"\(Self.appleScriptEscaped(command))\" with administrator privileges"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            var failure: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    // -128: the user cancelled the password prompt.
                    failure = text.contains("-128") ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failure = error.localizedDescription
            }
            // The audio server takes a moment to come back and load the driver.
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { [failure] in
                self.working = false
                self.lastError = failure
                self.refreshDriver()
                self.resync()
            }
        }
    }

    /// `text` in single quotes for the shell.
    nonisolated static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `text` inside an AppleScript string literal.
    nonisolated static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
