//
// Nocturne — keeps network-share sources connected: connects at launch, after sleep, when the
// network (or a VPN such as Tailscale) comes and goes, and when a share is unmounted; owns the
// local cache of network files.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Network
import NocturneLibrary
import Observation

@Observable
@MainActor
final class NetworkShareManager {
    enum Status: Equatable {
        case connecting
        case connected
        case offline(String)

        var isConnected: Bool { self == .connected }
    }

    private(set) var status: [Int64: Status] = [:]
    private(set) var cacheUsage = NetworkCache.Usage()
    let cache: NetworkCache
    /// Where Nocturne mounts shares (private, so library paths stay stable).
    let mountBase: URL

    private let library: LibraryStore
    private let settings: AppSettings
    private let pathMonitor = NWPathMonitor()
    private var connecting: Set<Int64> = []
    private var healthTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var networkWasUp = true

    init(library: LibraryStore, settings: AppSettings, dataDirectory: URL? = nil) {
        self.library = library
        self.settings = settings
        let data = dataDirectory ?? settings.dataDirectory
        mountBase = data.appendingPathComponent("Shares", isDirectory: true)
        cache = NetworkCache(directory: data.appendingPathComponent("Network Cache", isDirectory: true),
                             limitBytes: settings.networkCacheLimitBytes)
        cache.onChange = { @Sendable [weak self] in
            Task { @MainActor in self?.refreshUsage() }
        }
        refreshUsage()
    }

    var sources: [LibrarySource] { library.sources.filter(\.isNetwork) }

    func isNetwork(_ track: Track) -> Bool {
        guard let id = track.sourceId else { return false }
        return library.sources.first { $0.id == id }?.isNetwork ?? false
    }

    func status(of source: LibrarySource) -> Status {
        guard let id = source.id else { return .offline("") }
        return status[id] ?? (source.isOnline ? .connected : .offline("Not connected yet."))
    }

    func isReachable(_ track: Track) -> Bool {
        guard let id = track.sourceId, let source = library.sources.first(where: { $0.id == id }), source.isNetwork else { return true }
        return status(of: source).isConnected
    }

    func refreshUsage() { cacheUsage = cache.usage() }

    // MARK: Lifecycle

    func start() {
        Task { await reconnectAll() }

        pathMonitor.pathUpdateHandler = { @Sendable [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.nocturne.network-path"))

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4)) // let Wi-Fi and VPNs come back first
                await self?.checkAll()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { @Sendable [weak self] note in
            let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.standardizedFileURL.path
            Task { @MainActor in self?.volumeUnmounted(volume) }
        })

        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                await self?.checkAll()
            }
        }
    }

    private func networkChanged(up: Bool) {
        defer { networkWasUp = up }
        guard up != networkWasUp || up else { return }
        // Interfaces changed (Wi-Fi, Ethernet, a VPN such as Tailscale connecting): re-check soon.
        Task {
            try? await Task.sleep(for: .seconds(up ? 2 : 0))
            await checkAll()
        }
    }

    private func volumeUnmounted(_ volume: String?) {
        guard let volume else { return }
        for source in sources where source.path == volume || source.path.hasPrefix(volume + "/") {
            guard let id = source.id else { continue }
            status[id] = .offline("The share was disconnected.")
            try? library.database.setSourceOnline(id, false)
            Task {
                try? await Task.sleep(for: .seconds(2))
                await connect(source)
            }
        }
    }

    /// Connected shares: confirm the server still answers. Offline ones: try to reconnect.
    func checkAll() async {
        for source in sources {
            guard let id = source.id, let share = source.networkShare, !connecting.contains(id) else { continue }
            if status(of: source).isConnected {
                if await NetworkVolume.isReachable(share, timeout: 4) { continue }
                status[id] = .offline(NetworkShareError.unreachable(host: share.host).localizedDescription)
                try? library.database.setSourceOnline(id, false)
            } else {
                await connect(source)
            }
        }
    }

    func reconnectAll() async {
        for source in sources { await connect(source) }
    }

    // MARK: Connecting

    /// Mounts the source's share (or adopts an existing mount), repoints the library if the mount
    /// moved, and indexes it if it has never been scanned.
    @discardableResult
    func connect(_ source: LibrarySource, scanIfNew: Bool = true) async -> Bool {
        guard let id = source.id, let share = source.networkShare, !connecting.contains(id) else { return false }
        connecting.insert(id)
        defer { connecting.remove(id) }
        if !status(of: source).isConnected { status[id] = .connecting }
        do {
            let password = share.user == nil ? nil : NetworkCredentials.password(for: share)
            let mount = try await NetworkVolume.mount(share, password: password, in: mountBase, readOnly: !source.isWritable)
            let root = share.root(at: mount).standardizedFileURL
            guard Self.isDirectory(root) else { throw NetworkShareError.folderNotFound(share.subpath) }
            try library.database.relinkSource(id, to: root.path)
            try library.database.setSourceOnline(id, true)
            status[id] = .connected
            if scanIfNew, source.lastScannedAt == nil, var fresh = library.sources.first(where: { $0.id == id }) {
                fresh.path = root.path
                await library.scan(fresh)
            }
            return true
        } catch {
            status[id] = .offline(error.localizedDescription)
            try? library.database.setSourceOnline(id, false)
            return false
        }
    }

    /// Connects to a share for the first time and adds it to the library.
    /// A blank password uses the one saved in the keychain (by Nocturne or by Finder).
    func add(_ share: NetworkShare, password: String?, remember: Bool, name: String?, writable: Bool) async throws {
        let typed = password.flatMap { $0.isEmpty ? nil : $0 }
        let secret = typed ?? (share.user == nil ? nil : NetworkCredentials.password(for: share))
        let mount = try await NetworkVolume.mount(share, password: secret, in: mountBase, readOnly: !writable)
        let root = share.root(at: mount).standardizedFileURL
        guard Self.isDirectory(root) else { throw NetworkShareError.folderNotFound(share.subpath) }
        if remember, let typed { NetworkCredentials.save(typed, for: share) }

        if let existing = sources.first(where: { $0.remoteURL == share.urlString }) {
            await connect(existing)
            return
        }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let source = try library.database.addSource(LibrarySource(
            path: root.path, mode: .reference, remoteURL: share.urlString,
            name: trimmed?.isEmpty == false ? trimmed : nil, isWritable: writable))
        if let id = source.id { status[id] = .connected }
        await library.scan(source)
    }

    /// Removes the share from the library and unmounts it if Nocturne mounted it.
    func remove(_ source: LibrarySource) async {
        library.removeSource(source)
        if let id = source.id { status[id] = nil }
        if let share = source.networkShare, let mount = NetworkVolume.existingMount(for: share) {
            await NetworkVolume.unmount(mount, ownedBy: mountBase)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Cache

    /// Copies the playing track and the next few ahead of time (when the cache is on).
    func prefetch(current: Track?, upcoming: [Track]) {
        guard settings.networkCache else { return }
        let wanted = ([current].compactMap { $0 } + upcoming.prefix(max(0, settings.networkPrefetch)))
            .filter { isNetwork($0) && isReachable($0) }
        guard !wanted.isEmpty else { return }
        cache.request(wanted)
        cache.prioritize(wanted)
    }

    func setOffline(_ offline: Bool, tracks: [Track]) {
        cache.setOffline(offline, for: tracks.filter(isNetwork))
    }

    func applyCacheLimit() { cache.limitBytes = settings.networkCacheLimitBytes }
}
