//
// Vespertine: the remote's saved state: its switches, this Mac's server ID and the paired phones.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineRemoteProtocol

/// A phone or iPad allowed to control this Mac. Its key is the TLS pre-shared key it connects with.
nonisolated struct PairedRemote: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var key: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// The remote server's switches (UserDefaults, all off by default) and its files in the library's data folder: this Mac's
/// server ID and the paired phones. The files sit beside the library, so a test library (`-VespertineDataDirectory`)
/// has its own server ID and pairings and never shows up as, or accepts the phones of, the real one.
@Observable
final class RemoteStore {
    /// The remote server runs (Settings › Remote). Off by default.
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    /// Hold off idle sleep while the server runs, so a paused Mac stays reachable. Off by default.
    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Keys.keepAwake) } }
    /// Settings › Remote turned on macOS's Wake for network access (and what it was before, to put back). Off by default.
    var wakeForNetwork: Bool { didSet { defaults.set(wakeForNetwork, forKey: Keys.wakeForNetwork) } }
    var wakeForNetworkBefore: Bool? {
        didSet { if let wakeForNetworkBefore { defaults.set(wakeForNetworkBefore, forKey: Keys.wakeBefore) } else { defaults.removeObject(forKey: Keys.wakeBefore) } }
    }

    private(set) var devices: [PairedRemote] = []
    let serverID: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folder: URL

    private enum Keys {
        static let enabled = "remoteEnabled"
        static let keepAwake = "remoteKeepAwake"
        static let wakeForNetwork = "remoteWakeForNetwork"
        static let wakeBefore = "remoteWakeForNetworkBefore"
    }

    init(dataDirectory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.enabled: false, Keys.keepAwake: false, Keys.wakeForNetwork: false])
        enabled = defaults.bool(forKey: Keys.enabled)
        keepAwake = defaults.bool(forKey: Keys.keepAwake)
        wakeForNetwork = defaults.bool(forKey: Keys.wakeForNetwork)
        wakeForNetworkBefore = defaults.object(forKey: Keys.wakeBefore) as? Bool
        folder = dataDirectory.appendingPathComponent("Remote", isDirectory: true)
        serverID = Self.loadServerID(in: folder)
        devices = Self.loadDevices(in: folder)
    }

    private var devicesURL: URL { folder.appendingPathComponent("paired-remotes.json") }

    func device(_ id: String) -> PairedRemote? { devices.first { $0.id == id } }

    func add(_ device: PairedRemote) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        save()
    }

    func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    /// Notes when a phone last connected (kept in memory until the next save, so a busy remote doesn't write the file).
    func touch(_ id: String, name: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let renamed = devices[index].name != name && !name.isEmpty
        devices[index].lastSeen = .now
        if renamed { devices[index].name = name }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(devices)
            try data.write(to: devicesURL, options: [.atomic])
            // The keys let a phone in: readable by this user only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesURL.path)
        } catch {
            NSLog("Vespertine remote: couldn't save the paired remotes: \(error.localizedDescription)")
        }
    }

    private static func loadDevices(in folder: URL) -> [PairedRemote] {
        let url = folder.appendingPathComponent("paired-remotes.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PairedRemote].self, from: data)) ?? []
    }

    /// A random ID made the first time, so a phone recognizes this Mac whatever it's called and whichever address it has.
    private static func loadServerID(in folder: URL) -> String {
        let url = folder.appendingPathComponent("server-id")
        if let id = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: url, options: [.atomic])
        return id
    }
}
