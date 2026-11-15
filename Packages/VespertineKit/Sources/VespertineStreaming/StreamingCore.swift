//
// Vespertine: the streaming core. It knows the providers, makes one only while its switch is on, opens their songs for the
// engine, writes their libraries beside the files, and holds every provider to the same rules (docs/STREAMING.md):
// off is off, credentials only in the Keychain, no audio kept unless the terms allow it, an honest verdict, one gate.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary

/// What the core needs to know of a provider before it makes one.
public struct ProviderDescriptor: Sendable {
    public var id: String
    /// The provider's name as its own makers write it ("OpenSubsonic"): never translated.
    public var name: String
    public var capabilities: ProviderCapabilities
    public var playbackMode: ProviderPlaybackMode
    public var storagePolicy: ProviderStoragePolicy
    /// Makes the provider for one account. Called only while the provider's switch is on.
    public var make: @Sendable (_ account: String, _ credentials: any CredentialStore) -> any StreamingProvider

    public init(id: String, name: String, capabilities: ProviderCapabilities, playbackMode: ProviderPlaybackMode,
                storagePolicy: ProviderStoragePolicy,
                make: @escaping @Sendable (_ account: String, _ credentials: any CredentialStore) -> any StreamingProvider) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.playbackMode = playbackMode
        self.storagePolicy = storagePolicy
        self.make = make
    }
}

public struct StreamSyncSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    /// Songs the server no longer lists, hidden as missing.
    public var removed = 0
    public var playlists = 0
    public var covers = 0

    public init() {}
}

/// What reading a stream found, by the song's cache key. In memory only.
public enum StreamFindings {
    public struct Finding: Sendable, Equatable {
        /// The server sent something other than the file it lists.
        public var converted: Bool
        public var fileExtension: String
        public var size: Int64
    }

    private static let table = Locked([String: Finding]())

    static func record(_ finding: Finding, cacheKey: String) {
        table.withLock {
            if $0.count >= 512 { $0.removeAll() }
            $0[cacheKey] = finding
        }
    }

    public static func finding(cacheKey: String) -> Finding? { table.withLock { $0[cacheKey] } }
}

public final class StreamingCore: @unchecked Sendable {
    /// The UserDefaults key of a provider's switch. Registered false: a provider is off until the listener turns it on.
    public static func enabledKey(_ id: String) -> String { "streaming.\(id).enabled" }

    /// The UserDefaults key of "tell the server what was played". Registered false, and separate from the provider's switch.
    public static func playReportsKey(_ id: String) -> String { "streaming.\(id).playReports" }

    /// Registers every provider's switch, and its play reports, as off.
    public static func registerDefaults(_ defaults: UserDefaults, providers ids: [String]) {
        var values: [String: Any] = [:]
        for id in ids {
            values[enabledKey(id)] = false
            values[playReportsKey(id)] = false
        }
        defaults.register(defaults: values)
    }

    public let database: LibraryDatabase
    public let credentials: any CredentialStore

    private struct State {
        var descriptors: [String: ProviderDescriptor] = [:]
        var enabled: Set<String> = []
        var reporting: Set<String> = []
        /// By "<provider>/<account>".
        var providers: [String: any StreamingProvider] = [:]
        var tasks: [String: [UUID: Task<Void, Never>]] = [:]
        var made = 0
    }
    private let state = Locked(State())

    /// What a streamed song says when its server sends nothing for too long.
    public static var notAnsweringMessage: String { StreamScheme.notAnswering }

    public init(database: LibraryDatabase, credentials: any CredentialStore) {
        self.database = database
        self.credentials = credentials
    }

    deinit { StreamScheme.remove(ObjectIdentifier(self)) }

    public func register(_ descriptor: ProviderDescriptor) {
        state.withLock { $0.descriptors[descriptor.id] = descriptor }
    }

    public func descriptor(_ id: String) -> ProviderDescriptor? { state.withLock { $0.descriptors[id] } }

    // MARK: The switches

    /// The providers whose switch is on.
    public var enabled: Set<String> { state.withLock { $0.enabled } }
    public func isEnabled(_ id: String) -> Bool { state.withLock { $0.enabled.contains(id) } }

    /// Sets which providers are on. A provider that goes off is stopped and let go: its work is cancelled, its songs no
    /// longer open, and its rows leave every library query. Nothing is deleted: not its songs, not its Keychain items.
    public func setEnabled(_ ids: Set<String>) {
        let (gone, tasks) = state.withLock { s -> ([any StreamingProvider], [Task<Void, Never>]) in
            s.enabled = ids.filter { s.descriptors[$0] != nil }
            var gone: [any StreamingProvider] = []
            for (key, provider) in s.providers where !s.enabled.contains(provider.id) {
                gone.append(provider)
                s.providers[key] = nil
            }
            var tasks: [Task<Void, Never>] = []
            for (id, running) in s.tasks where !s.enabled.contains(id) {
                tasks += running.values
                s.tasks[id] = nil
            }
            return (gone, tasks)
        }
        for task in tasks { task.cancel() }
        for provider in gone { provider.stop() }
        let on = enabled
        database.shownProviders = on
        StreamScheme.set(self, active: !on.isEmpty)
    }

    /// The provider for one account, made on first use. Nil while the provider's switch is off: nothing is made, no request
    /// is sent and no Keychain item is read.
    public func provider(_ id: String, account: String) -> (any StreamingProvider)? {
        state.withLock { s -> (any StreamingProvider)? in
            guard s.enabled.contains(id), let descriptor = s.descriptors[id] else { return nil }
            let key = "\(id)/\(account)"
            if let made = s.providers[key] { return made }
            let provider = descriptor.make(account, credentials)
            s.providers[key] = provider
            s.made += 1
            return provider
        }
    }

    /// How many providers were ever made (tests: an off provider makes none).
    public var constructedCount: Int { state.withLock { $0.made } }
    /// Background work still running (tests: turning a provider off leaves none).
    public var runningTaskCount: Int { state.withLock { $0.tasks.values.reduce(0) { $0 + $1.count } } }

    /// Runs `work` for a provider in the background. It is cancelled when the provider's switch goes off, and is not started
    /// at all while it is off.
    @discardableResult
    public func start(_ id: String, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        state.withLock { s -> Task<Void, Never>? in
            guard s.enabled.contains(id) else { return nil }
            let token = UUID()
            let task = Task { [weak self] in
                await work()
                self?.state.withLock { $0.tasks[id]?[token] = nil }
            }
            s.tasks[id, default: [:]][token] = task
            return task
        }
    }

    // MARK: Accounts

    /// The provider's accounts in the library; none while it is off.
    public func accounts(_ id: String) throws -> [LibrarySource] {
        guard isEnabled(id) else { return [] }
        return try database.streamedSources().filter { $0.streamedAccount?.provider == id }
    }

    /// Adds an account and answers its id (random: nothing of the server or the user is in it).
    public func addAccount(_ id: String, name: String?) throws -> String {
        guard isEnabled(id) else { throw StreamingError.off }
        let account = UUID().uuidString.lowercased()
        try database.addStreamedSource(provider: id, account: account, name: name)
        return account
    }

    /// Signs the account out (its Keychain item is deleted) and takes it and its songs out of the library.
    public func removeAccount(_ id: String, account: String) async throws {
        if let provider = provider(id, account: account) {
            await provider.signOut()
            provider.stop()
        } else {
            credentials.delete(provider: id, account: account)
        }
        state.withLock { $0.providers["\(id)/\(account)"] = nil }
        try database.removeStreamedSource(provider: id, account: account)
    }

    // MARK: Playing

    /// Whether this core is the one to open `ref`: its provider is on here and the library has its account.
    func owns(_ ref: StreamLocation.Ref) -> Bool {
        guard isEnabled(ref.provider) else { return false }
        let path = StreamLocation.sourcePath(provider: ref.provider, account: ref.account)
        return ((try? database.streamedSources()) ?? []).contains { $0.path == path }
    }

    /// Opens a song's stream for the transient playback cache, and notes whether what arrived is the file the server lists.
    func open(_ ref: StreamLocation.Ref) throws -> any RemoteCacheReader {
        guard let provider = provider(ref.provider, account: ref.account) else { throw StreamingError.off }
        guard provider.playbackMode == .engine else { throw StreamingError.unsupported }
        if let until = provider.waitingUntil { throw StreamingError.askedToWait(seconds: until.timeIntervalSinceNow) }
        let reader = try provider.openStream(ref.id)
        var listed = StreamListing()
        if let known = try? database.streamedListing(location: ref.location) { listed = StreamListing(size: known.size, suffix: known.suffix) }
        let converted = StreamVerdict.isConverted(listed: listed, size: reader.size, fileExtension: reader.fileExtension)
        StreamFindings.record(.init(converted: converted, fileExtension: reader.fileExtension, size: reader.size), cacheKey: ref.cacheKey)
        return reader
    }

    // MARK: What the server is told

    /// The providers that are told what was played. Empty until the listener turns that on, provider by provider.
    public var playReports: Set<String> {
        get { state.withLock { $0.reporting } }
        set { state.withLock { $0.reporting = newValue } }
    }

    /// Tells the song's server it was played, when the listener turned that on for its provider and the provider can be told.
    /// Returns whether the server was told.
    @discardableResult
    public func reportPlayed(_ track: Track, at date: Date = .now) async -> Bool {
        guard let ref = track.streamRef, state.withLock({ $0.reporting.contains(ref.provider) }),
              let provider = provider(ref.provider, account: ref.account), provider.capabilities.contains(.playReports) else { return false }
        return (try? await provider.reportPlayed(songID: ref.id, at: date)) != nil
    }

    /// Stars or unstars the song on its server. The library's own favorite is the caller's to set.
    public func setStarred(_ starred: Bool, track: Track) async throws {
        guard let ref = track.streamRef else { return }
        guard let provider = provider(ref.provider, account: ref.account) else { throw StreamingError.off }
        guard provider.capabilities.contains(.favorites) else { throw StreamingError.unsupported }
        try await provider.setStarred(starred, songID: ref.id)
    }

    // MARK: Keeping audio

    /// Whether a song's audio may be kept on disk beyond the transient playback cache (an offline copy, a pin, a copy, an
    /// export). A file's may. A streamed song's only when its provider's terms allow it.
    public func mayKeep(_ track: Track) -> Bool {
        guard track.isStreamed else { return true }
        guard let ref = track.streamRef else { return false }
        return state.withLock { $0.descriptors[ref.provider]?.storagePolicy.allowsKeeping ?? false }
    }

    public func checkKeeping(_ track: Track) throws {
        if !mayKeep(track) { throw StreamingError.keepingRefused }
    }

    // MARK: The library

    /// Lists an account's library and writes it beside the files: songs, playlists, favorites, then the covers still
    /// missing (into `artwork`). Songs the server no longer lists are hidden as missing, not deleted.
    public func sync(_ id: String, account: String, artwork: ArtworkStore? = nil,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> StreamSyncSummary {
        guard let provider = provider(id, account: account) else { throw StreamingError.off }
        let listing = try await provider.library(progress: progress)
        var summary = StreamSyncSummary()
        var index = 0
        while index < listing.songs.count {
            try Task.checkCancellation()
            guard isEnabled(id) else { throw StreamingError.off }
            let chunk = Array(listing.songs[index..<min(index + 500, listing.songs.count)])
            let counts = try database.writeStreamedSongs(chunk, provider: id, account: account)
            summary.added += counts.added
            summary.updated += counts.updated
            index += 500
        }
        try Task.checkCancellation()
        guard isEnabled(id) else { throw StreamingError.off }
        summary.removed = try database.finishStreamedSync(provider: id, account: account, keeping: Set(listing.songs.map(\.id)))
        if provider.capabilities.contains(.playlists) {
            try database.writeStreamedPlaylists(listing.playlists, provider: id, account: account)
            summary.playlists = listing.playlists.count
        }
        if provider.capabilities.contains(.favorites) {
            try database.writeStreamedFavorites(starred: listing.starred, provider: id, account: account)
        }
        if let artwork {
            for cover in try database.streamedCoversNeeded(provider: id, account: account) {
                try Task.checkCancellation()
                guard isEnabled(id) else { throw StreamingError.off }
                guard let data = try? await provider.artwork(cover), let key = artwork.store(data) else { continue }
                try database.setStreamedArtwork(key, coverArt: cover, provider: id, account: account)
                summary.covers += 1
            }
        }
        return summary
    }
}

/// The engine opens a streamed song by a URL of the scheme "vespertine-stream". The scheme is registered with the playback
/// cache while any core has a provider on, and forgotten when none has.
enum StreamScheme {
    private struct Entry { weak var core: StreamingCore? }
    private static let cores = Locked([ObjectIdentifier: Entry]())

    static func set(_ core: StreamingCore, active: Bool) {
        cores.withLock { table in
            let had = !table.isEmpty
            table[ObjectIdentifier(core)] = active ? Entry(core: core) : nil
            table = table.filter { $0.value.core != nil }
            update(had: had, has: !table.isEmpty)
        }
    }

    static func remove(_ id: ObjectIdentifier) {
        cores.withLock { table in
            let had = !table.isEmpty
            table[id] = nil
            update(had: had, has: !table.isEmpty)
        }
    }

    private static func update(had: Bool, has: Bool) {
        if has, !had {
            NetworkPlaybackCache.registerRemoteReader(scheme: StreamLocation.scheme, notAnsweringMessage: notAnswering) { try open($0) }
        } else if had, !has {
            NetworkPlaybackCache.unregisterRemoteReader(scheme: StreamLocation.scheme)
        }
    }

    static func open(_ url: URL) throws -> any RemoteCacheReader {
        guard let ref = StreamLocation.ref(url) else { throw StreamingError.off }
        let candidates = cores.withLock { $0.values.compactMap(\.core) }
        guard let core = candidates.first(where: { $0.owns(ref) }) else { throw StreamingError.off }
        return try core.open(ref)
    }

    static var notAnswering: String {
        String(localized: "The music server stopped answering.", comment: "A song streamed from a music server (OpenSubsonic) stopped arriving for too long.")
    }
}
