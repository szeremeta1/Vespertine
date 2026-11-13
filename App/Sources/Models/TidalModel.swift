//
// Vespertine: the TIDAL account in the app: credentials, sign-in, the session's services (gate, catalog, stream resolver, library
// sync, the one downloader), the network's reachability and TIDAL's backoff, and the TIDAL source's online state they decide.
// Nothing here runs while Settings › Online › TIDAL integration is off.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Observation
import VespertineAudio
import VespertineLibrary
import VespertineTidal

/// Whether the network is up, as `NWPathMonitor` says (a fake in tests).
protocol TidalReachability: AnyObject {
    func start(_ onChange: @escaping @MainActor (Bool) -> Void)
    func stop()
}

final class PathReachability: TidalReachability {
    private var monitor: NWPathMonitor?

    func start(_ onChange: @escaping @MainActor (Bool) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in onChange(up) }
        }
        monitor.start(queue: DispatchQueue(label: "org.szeremeta.vespertine.tidal-reachability", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// A QA run's network to TIDAL: every request fails at once, as with no connection.
struct RefusingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

/// One pull of the account into the library (`TidalLibrarySync`; a fake in tests).
protocol TidalRefreshing: Sendable {
    func refresh() async throws -> TidalLibrarySync.Summary
}

extension TidalLibrarySync: TidalRefreshing {}

@MainActor @Observable
final class TidalModel {
    enum State: Equatable {
        /// No `tidal-client.json` (or one that can't be read): Settings › TIDAL asks for it.
        case missingCredentials
        case signedOut
        /// The login sheet is open.
        case signingIn
        case signedIn(name: String)

        var isSignedIn: Bool { if case .signedIn = self { true } else { false } }
    }

    /// What the model reaches the outside through (the real ones at launch; fakes in tests, which never touch the network).
    struct Environment {
        var credentialsURL: URL
        var tokens: TokenStore
        var transport: HTTPTransport
        var reachability: TidalReachability
        /// Registers the `tidal` reader with the playback cache, and forgets it.
        var register: (TidalStreamResolver) -> Void
        var unregister: () -> Void
        /// The library sync for the signed-in user.
        var makeRefresher: (TidalCatalog, LibraryDatabase, Int) -> TidalRefreshing
        /// Sync at launch, then this often while the app runs (decision 208).
        var syncInterval: Duration = .seconds(6 * 3600)
        /// How often the gate's backoff is read while TIDAL is on (no request: it is the gate's own state).
        var backoffPoll: Duration = .seconds(5)

        static var live: Environment {
            Environment(credentialsURL: TidalConfig.credentialsURL(), tokens: KeychainTokenStore(), transport: URLSessionTransport(),
                        reachability: PathReachability(),
                        register: { TidalPlayback.register(resolver: $0) }, unregister: { TidalPlayback.unregister() },
                        makeRefresher: { catalog, database, userId in TidalLibrarySync(catalog: catalog, database: database, userId: userId) })
        }
    }

    private(set) var state: State = .missingCredentials
    private(set) var isReachable = true
    /// The backoff TIDAL asked for, while it runs: until when, and the gate's reason.
    private(set) var backoff: (until: Date, reason: String)?
    var lastSync: Date? { settings.tidalLastSync }
    /// The last refresh's warnings (lists held back because TIDAL sent them much shorter), for Settings › TIDAL › Status.
    private(set) var syncWarnings: [String] = []
    /// What went wrong in the last refresh or sign-in, nil when it went through.
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    /// A credentials file that exists but can't be used: why.
    private(set) var credentialsProblem: String?
    private(set) var isStarted = false
    private(set) var countryCode: String?
    /// Writes the sync queue skipped or dropped (conflicts, playlists deleted on TIDAL), for Settings › TIDAL › Status.
    private(set) var skippedOps: [String] = []
    /// TIDAL doesn't offer this account's mixes to Vespertine: the sidebar leaves My Mixes out.
    private(set) var mixesUnavailable = false
    /// Settings › TIDAL opens the login sheet when it sees this (the switch was just turned on, signed out: one flow).
    var wantsLoginSheet = false

    /// The session's services; nil without credentials.
    private(set) var gate: TidalGate?
    private(set) var catalog: TidalCatalog?
    private(set) var resolver: TidalStreamResolver?
    @ObservationIgnored private var auth: TidalAuth?
    @ObservationIgnored private var refresher: TidalRefreshing?
    /// The app's one downloader (made with the first credentials, kept across sign-outs and credential changes).
    private(set) var downloader: TidalDownloader?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let availability: TidalAvailability
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The online state last written to the TIDAL source, so an unchanged one isn't written again.
    @ObservationIgnored private var writtenOnline: (source: Int64, online: Bool)?

    init(library: LibraryStore, settings: AppSettings, availability: TidalAvailability, environment: Environment = .live) {
        self.library = library
        self.settings = settings
        self.availability = availability
        self.environment = environment
    }

    var isOnline: Bool { state.isSignedIn && isReachable && backoff == nil }

    /// "TIDAL asked Vespertine to wait 12 min (rate limit)", while a backoff runs.
    var backoffNotice: String? {
        guard let backoff else { return nil }
        let minutes = max(1, Int((backoff.until.timeIntervalSinceNow / 60).rounded(.up)))
        let kind = backoff.reason.contains("429") ? String(localized: "rate limit", comment: "Kind of TIDAL backoff: too many requests.")
            : String(localized: "abuse protection", comment: "Kind of TIDAL backoff: TIDAL's abuse detection answered.")
        return String(localized: "TIDAL asked Vespertine to wait \(minutes) min (\(kind))",
                      comment: "Settings › TIDAL › Status while TIDAL's backoff runs. The second value is the kind of backoff.")
    }

    // MARK: Start and stop

    /// Loads the credentials and the stored session, registers the reader, watches the network, and syncs when signed in. Does nothing
    /// while TIDAL is switched off, or when already started.
    func start() {
        guard settings.tidalEnabled, !isStarted else { return }
        isStarted = true
        ArtworkCache.shared.fetchesTidalCovers = true
        loadSession()
        environment.reachability.start { [weak self] up in self?.reachabilityChanged(up) }
        downloader?.isPaused = false
        poll = Task { [weak self, interval = environment.backoffPoll] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.readBackoff()
            }
        }
        if state.isSignedIn { sessionBegan() }
        publish()
    }

    /// TIDAL switched off: the reader goes, the network is no longer watched, the sync timer stops and downloads pause.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        ArtworkCache.shared.fetchesTidalCovers = false
        environment.reachability.stop()
        environment.unregister()
        timer?.cancel(); timer = nil
        poll?.cancel(); poll = nil
        refreshTask?.cancel(); refreshTask = nil
        downloader?.isPaused = true
    }

    /// The services for the credentials in the file, and the state the stored session gives.
    private func loadSession() {
        let credentials: TidalClientCredentials?
        do {
            credentials = try TidalConfig.loadCredentials(at: environment.credentialsURL)
            credentialsProblem = nil
        } catch {
            credentials = nil
            credentialsProblem = String(localized: "The TIDAL client file can’t be read. Import it again.",
                                        comment: "Settings › TIDAL: tidal-client.json exists but isn't valid.")
        }
        guard let credentials else {
            auth = nil; gate = nil; catalog = nil; resolver = nil; refresher = nil
            state = .missingCredentials
            return
        }
        let auth = TidalAuth(credentials: credentials, transport: environment.transport, store: environment.tokens)
        let gate = TidalGate(auth: auth, transport: environment.transport)
        self.auth = auth
        self.gate = gate
        catalog = TidalCatalog(gate: gate)
        makeResolver()
        if let tokens = environment.tokens.load() {
            countryCode = tokens.countryCode
            state = .signedIn(name: accountName(userId: tokens.userId))
        } else {
            state = .signedOut
        }
    }

    /// The resolver for the chosen quality, registered for playback and handed to the downloader.
    private func makeResolver() {
        guard let gate, let catalog else { return }
        let resolver = TidalStreamResolver(gate: gate, quality: settings.tidalQuality)
        self.resolver = resolver
        environment.register(resolver)
        if let downloader {
            downloader.use(resolver: resolver, catalog: catalog)
        } else {
            downloader = TidalDownloader(resolver: resolver, catalog: catalog, database: library.database,
                                         folder: URL(fileURLWithPath: settings.tidalDownloadsFolder, isDirectory: true))
        }
    }

    /// Settings › TIDAL › Streaming quality changed.
    func qualityChanged() {
        guard isStarted else { return }
        makeResolver()
    }

    /// Settings › TIDAL › Downloads folder changed: the next download goes there.
    func downloadsFolderChanged() {
        downloader?.folder = URL(fileURLWithPath: settings.tidalDownloadsFolder, isDirectory: true)
    }

    private func accountName(userId: Int) -> String {
        settings.tidalAccountName ?? String(localized: "TIDAL account \(userId)", comment: "Settings › TIDAL before TIDAL told the account's name.")
    }

    /// Signed in (at launch or just now): the user's sync, its timer, and a first refresh.
    private func sessionBegan() {
        guard let catalog, let tokens = environment.tokens.load() else { return }
        refresher = environment.makeRefresher(catalog, library.database, tokens.userId)
        timer?.cancel()
        timer = Task { [weak self, interval = environment.syncInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
        startRefresh()
        Task { [weak self, userId = tokens.userId] in
            guard let catalog = self?.catalog else { return }
            do { _ = try await catalog.mixes(userId: userId) ; self?.mixesUnavailable = false }
            catch TidalError.http { self?.mixesUnavailable = true }
            catch {}
        }
        if settings.tidalAccountName == nil { Task { await fetchAccountName(userId: tokens.userId) } }
    }

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    /// The account's name for Settings (TIDAL's `users/<id>`), once.
    private func fetchAccountName(userId: Int) async {
        guard let gate, let data = try? await gate.get("users/\(userId)", priority: .interactive),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let first = object["firstName"] as? String, last = object["lastName"] as? String
        let full = [first, last].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        let name = !full.isEmpty ? full : (object["username"] as? String) ?? (object["email"] as? String)
        guard let name, !name.isEmpty else { return }
        settings.tidalAccountName = name
        if state.isSignedIn { state = .signedIn(name: name) }
    }

    // MARK: Credentials and sign-in

    /// Saves pasted or imported client credentials (owner-only file) and starts over with them: signed out, ready to sign in.
    func saveCredentials(_ credentials: TidalClientCredentials) throws {
        try TidalConfig.saveCredentials(credentials, to: environment.credentialsURL)
        guard isStarted else { return }
        loadSession()
        if state.isSignedIn { sessionBegan() }
        publish()
    }

    /// The login page for the sheet; the state is signing in until `finishLogin` or `cancelLogin`.
    func beginLogin() async -> URL? {
        guard let auth else { return nil }
        lastError = nil
        state = .signingIn
        return await auth.loginURL()
    }

    /// Trades the redirect for a session. Throws (the sheet shows it) and goes back to signed out when TIDAL refuses.
    func finishLogin(_ url: URL) async throws {
        guard let auth else { throw TidalError.missingCredentials }
        do {
            try await auth.finishLogin(redirect: url)
        } catch {
            state = .signedOut
            lastError = error.localizedDescription
            publish()
            throw error
        }
        let session = await auth.session
        countryCode = session?.countryCode
        settings.tidalAccountName = nil
        state = .signedIn(name: accountName(userId: session?.userId ?? 0))
        publish()
        sessionBegan()
    }

    /// The sheet was closed, or TIDAL answered the redirect with an error.
    func cancelLogin(error: String? = nil) {
        if state == .signingIn { state = .signedOut }
        lastError = error
        publish()
    }

    /// Ends the session (tokens deleted). The library's TIDAL rows and downloads stay; they gray out until the next sign-in.
    func signOut() {
        timer?.cancel(); timer = nil
        refreshTask?.cancel(); refreshTask = nil
        refresher = nil
        environment.tokens.clear()
        if let auth { Task { await auth.signOut() } }
        settings.tidalAccountName = nil
        countryCode = nil
        state = credentialsProblem == nil && auth != nil ? .signedOut : .missingCredentials
        publish()
    }

    // MARK: The catalog in the library

    /// The signed-in user's id, nil when signed out.
    var userId: Int? { state.isSignedIn ? environment.tokens.load()?.userId : nil }

    /// "Add to Library": the tracks become library rows (origin `added`, which the sync never removes). They aren't made TIDAL
    /// favorites (decision 207).
    func addToLibrary(_ tracks: [TidalTrack], album: TidalAlbum? = nil) throws {
        guard let userId, !tracks.isEmpty else { return }
        let source = try library.database.tidalSource(userId: userId)
        guard let sourceId = source.id else { return }
        try library.database.addTidalTracks(tracks.map { TidalTrackInput($0, album: album) }, sourceId: sourceId)
        publish()
    }

    /// An album's tracks, then "Add to Library".
    func addToLibrary(album: TidalAlbum) async {
        guard let catalog else { return }
        do {
            try addToLibrary(try await catalog.albumTracks(album.id, priority: .interactive), album: album)
        } catch {
            note(error)
        }
    }

    // MARK: Sync

    /// Pulls the account into the library now (Settings › Refresh Now, the timer, sign-in).
    func refresh() async {
        guard isStarted, state.isSignedIn, let refresher, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await refresher.refresh()
            settings.tidalLastSync = Date()
            syncWarnings = summary.warnings
            lastError = nil
        } catch is CancellationError {
        } catch {
            note(error)
        }
        await readBackoff()
        publish()
    }

    /// What a failed request says: a backoff starts the notice, a lost session signs out, anything else is shown in Status.
    func note(_ error: Error) {
        switch error as? TidalError {
        case .backingOff(let remaining, let reason)?:
            setBackoff((Date().addingTimeInterval(remaining), reason))
        case .abuse(let retryAfter)?:
            setBackoff((Date().addingTimeInterval(retryAfter), "abuse detected (HTTP 403)"))
        case .notSignedIn?:
            if state.isSignedIn { signOut() }
        default:
            lastError = error.localizedDescription
        }
    }

    // MARK: Online state

    private func reachabilityChanged(_ up: Bool) {
        guard up != isReachable else { return }
        isReachable = up
        publish()
        if up, state.isSignedIn, lastError != nil { startRefresh() }
    }

    /// The gate's backoff (it refuses requests until it ends).
    private func readBackoff() async {
        guard let gate else { if backoff != nil { setBackoff(nil) }; return }
        let current = await gate.backoff
        if current?.until != backoff?.until || (current == nil) != (backoff == nil) {
            // A backoff the gate doesn't know of (a playback error noted here) runs until its own end.
            if current == nil, let backoff, backoff.until > Date() { return }
            setBackoff(current)
        }
    }

    private func setBackoff(_ value: (until: Date, reason: String)?) {
        backoff = value
        publish()
    }

    /// Hands the state to the playability rule, and to the TIDAL source's online flag (signed in, reachable, not backing off).
    private func publish() {
        if availability.signedIn != state.isSignedIn { availability.signedIn = state.isSignedIn }
        if availability.reachable != isReachable { availability.reachable = isReachable }
        if availability.backingOff != (backoff != nil) { availability.backingOff = backoff != nil }
        let online = isOnline
        let database = library.database
        guard let id = (try? database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [LibrarySource.tidalPath])
        }) ?? nil else { return }
        guard writtenOnline?.source != id || writtenOnline?.online != online else { return }
        writtenOnline = (id, online)
        try? database.setSourceOnline(id, online)
    }
}
