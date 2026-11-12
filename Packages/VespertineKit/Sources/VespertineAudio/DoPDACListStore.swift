//
// Vespertine: holds the DAC list in use: the bundled one, with a cached and signature-checked online update on top.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

/// The list the app uses, and how it is kept up to date. Rules that keep it from ever mattering to playback:
/// - The bundled list is always there. Any failure (offline, a bad signature, a bad file, an older revision) leaves it.
/// - Reading `list` is a lock and a copy; the fetch runs off the caller's thread, and nothing waits for it.
/// - Nothing online is believed without an Ed25519 signature that checks against the pinned key (the app passes the same
///   `SUPublicEDKey` its Sparkle updates are pinned to). The cache is checked again on every read, so a file edited on
///   disk is ignored like any other.
public final class DoPDACListStore: @unchecked Sendable {
    public struct Endpoints: Sendable {
        public var list: URL
        public var signature: URL
        public init(list: URL, signature: URL) { self.list = list; self.signature = signature }

        /// Release assets of the latest GitHub release, the place the update feed is published (`SUFeedURL`).
        public static let latestRelease = Endpoints(
            list: URL(string: "https://github.com/szeremeta1/Vespertine/releases/latest/download/dop-dacs.json")!,
            signature: URL(string: "https://github.com/szeremeta1/Vespertine/releases/latest/download/dop-dacs.json.sig")!)
    }

    public enum Outcome: Equatable, Sendable {
        case updated(revision: Int)
        /// Checked recently; nothing was fetched.
        case skipped
        /// The list on offer is not newer than the one held.
        case notNewer
        /// Fetched, but unsigned, wrongly signed, or not a list this build reads.
        case rejected
        /// Couldn't be fetched (offline, no such file yet, a server error).
        case failed
    }

    public static let shared = DoPDACListStore()

    private let bundled: DoPDACList
    private let cacheDirectory: URL
    private let pinnedKey: Locked<Data?>
    private let endpoints: Endpoints
    private let fetch: @Sendable (URL) async throws -> Data
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let minInterval: TimeInterval
    private let current: Locked<DoPDACList>
    private let lastCheckKey = "dopDACListLastCheck"

    /// The default store: the bundled list, a cache under Application Support, no online updates until `pin(publicKey:)` is called
    /// (the app calls it at launch), so unit tests and command-line tools never touch the network.
    public convenience init() {
        self.init(bundled: DoPDACList.bundled, cacheDirectory: Self.defaultCacheDirectory, publicKey: nil, endpoints: .latestRelease)
    }

    public init(bundled: DoPDACList, cacheDirectory: URL, publicKey: Data?, endpoints: Endpoints, defaults: UserDefaults = .standard,
                minInterval: TimeInterval = 24 * 3600, now: @escaping @Sendable () -> Date = { Date() },
                fetch: @escaping @Sendable (URL) async throws -> Data = DoPDACListStore.download) {
        self.bundled = bundled
        self.cacheDirectory = cacheDirectory
        pinnedKey = Locked(publicKey)
        self.endpoints = endpoints
        self.defaults = defaults
        self.minInterval = minInterval
        self.now = now
        self.fetch = fetch
        current = Locked(bundled)
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vespertine", isDirectory: true).appendingPathComponent("DoP", isDirectory: true)
    }

    /// The list to match against now.
    public var list: DoPDACList { current.withLock { $0 } }

    /// The key online lists are checked against (32 raw bytes of an Ed25519 public key). The app sets it once at launch
    /// from its `SUPublicEDKey`; until then no online list is accepted.
    public func pin(publicKey: Data) { pinnedKey.withLock { $0 = publicKey } }

    private var listFile: URL { cacheDirectory.appendingPathComponent("dop-dacs.json") }
    private var signatureFile: URL { cacheDirectory.appendingPathComponent("dop-dacs.json.sig") }

    /// Applies the cached online list, if its signature still checks and it is newer than the bundled one. Cheap (one small
    /// file); safe to call at launch.
    public func loadCache() {
        guard let data = try? Data(contentsOf: listFile), let signature = try? Data(contentsOf: signatureFile),
              let online = verified(data, signature: signature), online.revision > bundled.revision else { return }
        current.withLock { $0 = bundled.merging(online) }
    }

    /// Fetches the online list unless it was checked within `minInterval` (or `force`). Never throws and never blocks
    /// playback: whatever goes wrong, `list` stays as it was.
    @discardableResult
    public func refresh(force: Bool = false) async -> Outcome {
        guard pinnedKey.withLock({ $0 }) != nil else { return .rejected }
        let last = defaults.object(forKey: lastCheckKey) as? Date
        if !force, let last, now().timeIntervalSince(last) < minInterval { return .skipped }
        defaults.set(now(), forKey: lastCheckKey)
        let data: Data, signature: Data
        do {
            data = try await fetch(endpoints.list)
            signature = try await fetch(endpoints.signature)
        } catch { return .failed }
        guard let online = verified(data, signature: signature) else { return .rejected }
        let held = current.withLock { $0.revision }
        guard online.revision > max(bundled.revision, held) else { return .notNewer }
        current.withLock { $0 = bundled.merging(online) }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: listFile, options: .atomic)
            try signature.write(to: signatureFile, options: .atomic)
        } catch { /* The list is in use for this launch; it just isn't kept. */ }
        return .updated(revision: online.revision)
    }

    /// The list in `data` if `signature` (base64, as Sparkle's `sign_update` prints it) is a valid Ed25519 signature of
    /// exactly these bytes under the pinned key.
    private func verified(_ data: Data, signature: Data) -> DoPDACList? {
        guard let publicKey = pinnedKey.withLock({ $0 }), publicKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: data) else { return nil }
        return try? DoPDACList.decode(data)
    }

    /// A plain download with short timeouts and no cookies; sends nothing about the user or the Mac.
    public static let download: @Sendable (URL) async throws -> Data = { url in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        let (data, response) = try await URLSession(configuration: config).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 512 * 1024 else { throw URLError(.badServerResponse) }
        return data
    }
}
