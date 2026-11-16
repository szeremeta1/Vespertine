//
// Vespertine: music servers in the app. One switch per provider, off by default (`streaming.<id>.enabled`). Off, the
// provider is never made, nothing is sent, its Keychain item is not read, and its songs are in no list. The rules are the
// streaming core's (docs/STREAMING.md); this is what Settings and the library talk to.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineLibrary
import VespertineOpenSubsonic
import VespertineStreaming

@Observable
@MainActor
final class StreamingModel {
    /// Every provider the app has. A provider is made from its descriptor only while its switch is on.
    nonisolated static let descriptors: [ProviderDescriptor] = [OpenSubsonicProvider.descriptor]
    nonisolated static var ids: [String] { descriptors.map(\.id) }

    /// The providers whose switch is on, as stored. Read before the library is, so that the first list drawn already
    /// leaves out those that are off.
    nonisolated static func enabled(in defaults: UserDefaults) -> Set<String> {
        Set(ids.filter { defaults.bool(forKey: StreamingCore.enabledKey($0)) })
    }

    /// What is known of one account while its provider is on.
    struct AccountState: Equatable {
        var session: ProviderSession?
        var server: String?
        var syncing = false
        /// Songs listed so far in the sync that is running.
        var listed = 0
        var problem: String?
        var lastSync: StreamSyncSummary?
    }

    let core: StreamingCore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var player: PlayerController?

    private(set) var enabled: Set<String>
    private(set) var reporting: Set<String>
    /// By the account's source path.
    private(set) var states: [String: AccountState] = [:]

    init(library: LibraryStore, defaults: UserDefaults, player: PlayerController?, credentials: any CredentialStore = KeychainCredentialStore(),
         descriptors: [ProviderDescriptor] = StreamingModel.descriptors) {
        self.library = library
        self.defaults = defaults
        self.player = player
        core = StreamingCore(database: library.database, credentials: credentials)
        for descriptor in descriptors { core.register(descriptor) }
        let ids = descriptors.map(\.id)
        enabled = Set(ids.filter { defaults.bool(forKey: StreamingCore.enabledKey($0)) })
        reporting = Set(ids.filter { defaults.bool(forKey: StreamingCore.playReportsKey($0)) })
        core.setEnabled(enabled)
        core.playReports = reporting.intersection(enabled)
        for id in enabled { refresh(id) }
    }

    var anyOn: Bool { !enabled.isEmpty }
    func isOn(_ id: String) -> Bool { enabled.contains(id) }

    /// Turns a provider on or off. Off: its work is cancelled, a song of its that is playing stops, its songs leave the queue
    /// and every list, and nothing more is sent. Nothing is deleted: the accounts, their songs and their Keychain items are
    /// there again when it is turned back on.
    func setOn(_ on: Bool, _ id: String) {
        guard core.descriptor(id) != nil, enabled.contains(id) != on else { return }
        defaults.set(on, forKey: StreamingCore.enabledKey(id))
        if on { enabled.insert(id) } else { enabled.remove(id) }
        if !on { player?.providerTurnedOff(id) }
        core.setEnabled(enabled)
        core.playReports = reporting.intersection(enabled)
        library.streamingVisibilityChanged()
        if on {
            refresh(id)
        } else {
            states = states.filter { StreamLocation.account(of: $0.key)?.provider != id }
        }
    }

    /// The provider's accounts; none while it is off.
    func accounts(_ id: String) -> [LibrarySource] {
        guard enabled.contains(id) else { return [] }
        return library.streamedAccounts.filter { $0.streamedAccount?.provider == id }
    }

    func state(_ source: LibrarySource) -> AccountState { states[source.path] ?? AccountState() }

    /// The account a song comes from, while its provider is on.
    func account(of track: Track) -> LibrarySource? {
        guard let ref = track.streamRef, enabled.contains(ref.provider) else { return nil }
        let path = StreamLocation.sourcePath(provider: ref.provider, account: ref.account)
        return library.streamedAccounts.first { $0.path == path }
    }

    /// When the account's server asked to wait, until when.
    func waitingUntil(_ source: LibrarySource) -> Date? {
        guard let account = source.streamedAccount, let until = core.provider(account.provider, account: account.account)?.waitingUntil,
              until > .now else { return nil }
        return until
    }

    // MARK: Accounts

    /// Reads, from the Keychain only, whether each of the provider's accounts is signed in.
    private func refresh(_ id: String) {
        for source in (try? core.accounts(id)) ?? [] { refresh(source) }
    }

    private func refresh(_ source: LibrarySource) {
        guard let account = source.streamedAccount, let provider = core.provider(account.provider, account: account.account) else { return }
        let path = source.path
        Task { [weak self] in
            let session = await provider.session()
            let remembered = await provider.rememberedSignIn()
            self?.states[path, default: AccountState()].session = session
            self?.states[path, default: AccountState()].server = remembered?.server
        }
    }

    /// What was last signed in with, for filling the fields again. From the Keychain item; never the secret.
    func remembered(_ source: LibrarySource) async -> (server: String, user: String)? {
        guard let account = source.streamedAccount else { return nil }
        return await core.provider(account.provider, account: account.account)?.rememberedSignIn()
    }

    /// Signs in to a server: a new account when `source` is nil. Answers nil when it worked, else the sentence to show.
    /// What was typed is handed to the provider and kept nowhere else.
    func signIn(_ id: String, source: LibrarySource? = nil, name: String, request: ProviderSignIn) async -> String? {
        do {
            let account: String, made: Bool
            if let existing = source?.streamedAccount?.account {
                (account, made) = (existing, false)
            } else {
                let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                account = try core.addAccount(id, name: typed.isEmpty ? Self.defaultName(server: request.server) : typed)
                made = true
            }
            guard let provider = core.provider(id, account: account) else { throw StreamingError.off }
            let path = StreamLocation.sourcePath(provider: id, account: account)
            do {
                let session = try await provider.signIn(request)
                states[path, default: AccountState()].session = session
                states[path, default: AccountState()].server = await provider.rememberedSignIn()?.server
                states[path, default: AccountState()].problem = nil
            } catch {
                // A server that was never signed in to leaves no empty account behind.
                if made { try? await core.removeAccount(id, account: account) }
                throw error
            }
            sync(id, account: account)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The server's host, for an account the listener gave no name. Kept with the library like a folder's name.
    static func defaultName(server: String) -> String? {
        (try? OpenSubsonicAddress.parse(server))?.host
    }

    /// Deletes the account's Keychain item. Its songs stay listed until it signs in again or is removed.
    func signOut(_ source: LibrarySource) {
        guard let account = source.streamedAccount, let provider = core.provider(account.provider, account: account.account) else { return }
        let path = source.path
        Task { [weak self] in
            await provider.signOut()
            self?.states[path, default: AccountState()].session = .signedOut
        }
    }

    /// Signs the account out and takes it and its songs out of the library.
    func remove(_ source: LibrarySource) {
        guard let account = source.streamedAccount else { return }
        let path = source.path
        player?.accountRemoved(provider: account.provider, account: account.account)
        Task { [weak self] in
            try? await self?.core.removeAccount(account.provider, account: account.account)
            self?.states[path] = nil
        }
    }

    func sync(_ source: LibrarySource) {
        guard let account = source.streamedAccount else { return }
        sync(account.provider, account: account.account)
    }

    /// Lists the account's library again, in the background. Cancelled if its provider is turned off meanwhile.
    private func sync(_ id: String, account: String) {
        let path = StreamLocation.sourcePath(provider: id, account: account)
        guard states[path]?.syncing != true else { return }
        states[path, default: AccountState()].syncing = true
        states[path, default: AccountState()].listed = 0
        states[path, default: AccountState()].problem = nil
        let core = core, artwork = library.artwork
        let progress: @Sendable (Int) -> Void = { [weak self] count in
            guard let self else { return }
            Task { @MainActor in self.listed(count, path) }
        }
        let started = core.start(id) { [weak self] in
            let result: Result<StreamSyncSummary, Error>
            do {
                result = .success(try await core.sync(id, account: account, artwork: artwork, progress: progress))
            } catch {
                result = .failure(error)
            }
            await self?.synced(path, id: id, result)
        }
        if started == nil { states[path]?.syncing = false }
    }

    private func failed(_ message: String, _ path: String) { states[path]?.problem = message }

    private func listed(_ count: Int, _ path: String) {
        if states[path]?.syncing == true { states[path]?.listed = count }
    }

    private func synced(_ path: String, id: String, _ result: Result<StreamSyncSummary, Error>) {
        // Turned off meanwhile: its state is gone and stays gone.
        guard enabled.contains(id), states[path] != nil else { return }
        states[path]?.syncing = false
        switch result {
        case .success(let summary):
            states[path]?.lastSync = summary
        case .failure(let error):
            if error is CancellationError || (error as? StreamingError) == .off { return }
            states[path]?.problem = error.localizedDescription
            if (error as? StreamingError) == .signedOut { states[path]?.session = .signedOut }
        }
    }

    // MARK: What the server is told

    func reports(_ id: String) -> Bool { reporting.contains(id) }

    /// "Tell the server what I play": the provider's own switch, off by default, apart from the one that turns it on.
    func setReports(_ on: Bool, _ id: String) {
        defaults.set(on, forKey: StreamingCore.playReportsKey(id))
        if on { reporting.insert(id) } else { reporting.remove(id) }
        core.playReports = reporting.intersection(enabled)
    }

    /// A song stopped because its server sent nothing for too long: the account says so (in Settings and on its page) until
    /// the server answers again, and the player says the same. Nil when the song's provider is off.
    func unanswered(_ track: Track) -> String? {
        guard let source = account(of: track) else { return nil }
        let message = PlayerController.notAnswering(source.displayName)
        states[source.path, default: AccountState()].problem = message
        return message
    }

    /// What the listener calls the server a song is on.
    func serverName(of track: Track) -> String? { account(of: track)?.displayName }

    /// A song from the server plays: it is answering again.
    func answered(_ track: Track) {
        guard let source = account(of: track), states[source.path]?.problem == PlayerController.notAnswering(source.displayName) else { return }
        states[source.path]?.problem = nil
    }

    /// A streamed song counted as played. Its server hears of it only with the provider's play reports on.
    func played(_ track: Track, at date: Date) {
        guard let ref = track.streamRef, reporting.contains(ref.provider), enabled.contains(ref.provider) else { return }
        let core = core
        core.start(ref.provider) { await core.reportPlayed(track, at: date) }
    }

    /// The library's favorite changed for these songs: those on a server are starred or unstarred there too.
    func favoriteChanged(_ favorite: Bool, tracks: [Track]) {
        for track in tracks {
            guard let ref = track.streamRef, enabled.contains(ref.provider) else { continue }
            let core = core, path = StreamLocation.sourcePath(provider: ref.provider, account: ref.account)
            core.start(ref.provider) { [weak self] in
                do {
                    try await core.setStarred(favorite, track: track)
                } catch {
                    await self?.failed(error.localizedDescription, path)
                }
            }
        }
    }
}
