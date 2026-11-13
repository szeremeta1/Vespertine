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
    /// A web browser rather than the app: `key` is then the SHA-256 of the browser's cookie, not a TLS key.
    var web: Bool?

    var isWeb: Bool { web == true }
}

/// The remote server's switches (UserDefaults, all off by default) and its files in the library's data folder: this Mac's
/// server ID and the paired phones. The files sit beside the library, so a test library (`-VespertineDataDirectory`)
/// has its own server ID and pairings and never shows up as, or accepts the phones of, the real one.
@Observable
final class RemoteStore {
    /// The remote server runs (Settings › Remote). Off by default.
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    /// Web browsers on this network can use the remote too (a page served by this Mac). Off by default.
    var webEnabled: Bool { didSet { defaults.set(webEnabled, forKey: Keys.webEnabled) } }
    /// Phones may play songs from this Mac's library themselves (the stream channel, protocol 2). Off by default. There is no
    /// switch for it in Settings yet (its text needs the 44 translations): `defaults write org.szeremeta.Vespertine remoteStreamEnabled -bool YES`.
    var streamEnabled: Bool { didSet { defaults.set(streamEnabled, forKey: Keys.streamEnabled) } }
    /// Hold off idle sleep while the server runs, so a paused Mac stays reachable. Off by default.
    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Keys.keepAwake) } }
    /// Settings › Remote turned on macOS's Wake for network access (and what it was before, to put back). Off by default.
    var wakeForNetwork: Bool { didSet { defaults.set(wakeForNetwork, forKey: Keys.wakeForNetwork) } }
    var wakeForNetworkBefore: Bool? {
        didSet { if let wakeForNetworkBefore { defaults.set(wakeForNetworkBefore, forKey: Keys.wakeBefore) } else { defaults.removeObject(forKey: Keys.wakeBefore) } }
    }

    private(set) var devices: [PairedRemote] = []
    let serverID: String
    /// The port the server listened on last. It tries this one first the next time, so a phone that knows the Mac's
    /// address keeps reaching it across restarts (a file beside `server-id`, so each library has its own).
    private(set) var port: UInt16?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folder: URL

    private enum Keys {
        static let enabled = "remoteEnabled"
        static let webEnabled = "remoteWebEnabled"
        static let streamEnabled = "remoteStreamEnabled"
        static let keepAwake = "remoteKeepAwake"
        static let wakeForNetwork = "remoteWakeForNetwork"
        static let wakeBefore = "remoteWakeForNetworkBefore"
    }

    init(dataDirectory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.enabled: false, Keys.webEnabled: false, Keys.streamEnabled: false, Keys.keepAwake: false, Keys.wakeForNetwork: false])
        enabled = defaults.bool(forKey: Keys.enabled)
        webEnabled = defaults.bool(forKey: Keys.webEnabled)
        streamEnabled = defaults.bool(forKey: Keys.streamEnabled)
        keepAwake = defaults.bool(forKey: Keys.keepAwake)
        wakeForNetwork = defaults.bool(forKey: Keys.wakeForNetwork)
        wakeForNetworkBefore = defaults.object(forKey: Keys.wakeBefore) as? Bool
        folder = dataDirectory.appendingPathComponent("Remote", isDirectory: true)
        serverID = Self.loadServerID(in: folder)
        devices = Self.loadDevices(in: folder)
        port = Self.loadPort(in: folder)
    }

    /// Remembers the port the server is listening on.
    func setPort(_ new: UInt16) {
        guard new != port else { return }
        port = new
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(String(new).utf8).write(to: portURL, options: [.atomic])
        } catch {
            NSLog("Vespertine remote: couldn't save the port: \(error.localizedDescription)")
        }
    }

    private var portURL: URL { folder.appendingPathComponent("port") }

    private static func loadPort(in folder: URL) -> UInt16? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("port"), encoding: .utf8) else { return nil }
        return UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
