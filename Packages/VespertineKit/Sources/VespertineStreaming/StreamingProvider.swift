//
// Vespertine: what a streaming provider is. A provider reads one account on one service or server: it lists the account's
// music, searches it, and opens a song as bytes the engine plays like a file. The rules every provider is held to are in
// docs/STREAMING.md and are enforced by StreamingCore, not left to each provider.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary

/// What a provider can do. The app shows only what is in here.
public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let search = ProviderCapabilities(rawValue: 1 << 0)
    /// Lists the account's whole library, so its songs can sit beside the files.
    public static let library = ProviderCapabilities(rawValue: 1 << 1)
    public static let playlists = ProviderCapabilities(rawValue: 1 << 2)
    /// Reads and sets favorites (stars) on the account.
    public static let favorites = ProviderCapabilities(rawValue: 1 << 3)
    /// Can be told what was played. Off unless the listener turns it on.
    public static let playReports = ProviderCapabilities(rawValue: 1 << 4)
    /// Streams can be read from the middle (seeking without fetching everything before).
    public static let rangeRequests = ProviderCapabilities(rawValue: 1 << 5)
    /// Several accounts (servers) under the provider's one switch.
    public static let severalAccounts = ProviderCapabilities(rawValue: 1 << 6)
}

/// Who turns the provider's bytes into sound.
public enum ProviderPlaybackMode: Sendable, Equatable {
    /// The provider hands over the stream's bytes and Vespertine's engine plays them: the signal path is the engine's.
    case engine
    /// The provider's own player makes the sound (an SDK that gives no bytes). Vespertine never sees the samples, so such a
    /// song is never called bit-perfect, whatever the provider says of it.
    case external
}

/// Whether a provider's audio may be kept on disk.
public enum ProviderStoragePolicy: Sendable, Equatable {
    /// Only the transient playback cache, which is emptied as songs end and at quit. No offline copy, pin, copy or export.
    case transientCacheOnly
    /// The provider's terms allow keeping a copy. `termsReference` says where they do (a URL or a licence's name).
    case offlineAllowed(termsReference: String)

    public var allowsKeeping: Bool { if case .offlineAllowed = self { true } else { false } }
}

public enum ProviderSession: Sendable, Equatable {
    case signedOut
    /// `user` is the name the account goes by, for display.
    case signedIn(user: String)
}

/// What the listener types to sign in. Never stored as it is: the provider keeps what it needs in the Keychain.
public struct ProviderSignIn: Sendable {
    public enum Secret: Sendable {
        case apiKey(String)
        case password(String)
    }
    /// The server's address, for providers the listener runs themselves.
    public var server: String
    public var user: String
    public var secret: Secret

    public init(server: String, user: String, secret: Secret) {
        self.server = server
        self.user = user
        self.secret = secret
    }
}

/// An account's whole library as its provider lists it.
public struct ProviderLibrary: Sendable {
    public var songs: [StreamedSong]
    public var playlists: [StreamedPlaylist]
    /// The ids of the songs the account has starred.
    public var starred: Set<String>

    public init(songs: [StreamedSong] = [], playlists: [StreamedPlaylist] = [], starred: Set<String> = []) {
        self.songs = songs
        self.playlists = playlists
        self.starred = starred
    }
}

/// What a server lists for a song's file, which the stream that arrives is held against.
public struct StreamListing: Sendable, Equatable {
    public var size: Int64
    public var suffix: String?

    public init(size: Int64 = 0, suffix: String? = nil) {
        self.size = size
        self.suffix = suffix
    }
}

/// A provider whose own player makes the sound (`ProviderPlaybackMode.external`). No provider in the app is one yet; the
/// shape is here so that the verdict rule for it is written and tested before one arrives.
public protocol ExternalPlayer: AnyObject, Sendable {
    func play(songID: String) async throws
    func pause() async
    func resume() async
    func stop() async
    func seek(to seconds: TimeInterval) async
}

public protocol StreamingProvider: AnyObject, Sendable {
    /// The provider's id ("opensubsonic"): lower-case letters, digits and "-".
    var id: String { get }
    /// Which of the provider's accounts this one reads (a random id made when the account was added).
    var account: String { get }
    var capabilities: ProviderCapabilities { get }
    var playbackMode: ProviderPlaybackMode { get }
    var storagePolicy: ProviderStoragePolicy { get }

    /// Whether the account has a credential. Reads the Keychain, never the network.
    func session() async -> ProviderSession
    /// Checks what the listener typed with the server and, when it is accepted, keeps what is needed in the Keychain.
    func signIn(_ request: ProviderSignIn) async throws -> ProviderSession
    /// Deletes the account's Keychain item. The account's songs stay in the library until the account is removed.
    func signOut() async
    /// The address and name last signed in with, for filling the sign-in fields again. Read from the Keychain item only.
    func rememberedSignIn() async -> (server: String, user: String)?

    func search(_ text: String, limit: Int) async throws -> [StreamedSong]
    /// The account's whole library. `progress` is told how many songs have been listed so far.
    func library(progress: @escaping @Sendable (Int) -> Void) async throws -> ProviderLibrary
    func tracks(of albumID: String) async throws -> [StreamedSong]
    /// The song's bytes, for the transient playback cache. Blocks while it asks the server: never called on the main thread.
    /// `.engine` providers only.
    func openStream(_ songID: String) throws -> any RemoteCacheReader
    /// `.external` providers only.
    var externalPlayer: (any ExternalPlayer)? { get }

    func setStarred(_ starred: Bool, songID: String) async throws
    func reportPlayed(songID: String, at date: Date) async throws
    /// A cover's bytes.
    func artwork(_ coverArt: String) async throws -> Data
    /// When the server asked Vespertine to wait, until when; nil while requests flow.
    var waitingUntil: Date? { get }
    /// Stops everything in flight. Called when the provider's switch goes off, before the provider is let go.
    func stop()
}

public extension StreamingProvider {
    var externalPlayer: (any ExternalPlayer)? { nil }
    func rememberedSignIn() async -> (server: String, user: String)? { nil }
    func setStarred(_ starred: Bool, songID: String) async throws { throw StreamingError.unsupported }
    func reportPlayed(songID: String, at date: Date) async throws { throw StreamingError.unsupported }
    func stop() {}
}

/// What goes wrong with a provider, in words the listener reads.
public enum StreamingError: Error, LocalizedError, Equatable, Sendable {
    /// The provider's switch is off.
    case off
    /// No credential, or the server no longer accepts it.
    case signedOut
    /// The server asked to wait.
    case askedToWait(seconds: TimeInterval)
    /// An http address that is not on the listener's own network.
    case insecureAddress
    case badAddress
    /// The server's own words.
    case server(String)
    case status(Int)
    /// The system's reason.
    case notAnswering(String)
    case malformedAnswer
    /// The provider's terms don't allow keeping its audio.
    case keepingRefused
    /// The provider needs something this build was made without.
    case notAvailableInThisBuild
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .off:
            String(localized: "This music server is turned off in Settings.", comment: "A streamed song was asked for while its provider's switch is off.")
        case .signedOut:
            String(localized: "The server didn’t accept the sign-in. Sign in again in Settings.", comment: "A music server (OpenSubsonic) refused the stored credential, or there is none.")
        case .askedToWait(let seconds):
            String(localized: "The server asked Vespertine to wait. It will try again in \(Self.wait(seconds)).", comment: "A music server answered “too many requests”. %@ is a duration such as “1 minute”.")
        case .insecureAddress:
            String(localized: "An http address is only allowed for a server on your own network. Use https for this one.", comment: "The listener typed an unencrypted address for a music server that is not on the local network.")
        case .badAddress:
            String(localized: "That isn’t a server address. It should look like https://music.example.", comment: "The listener typed something that is not a URL for a music server.")
        case .server(let message):
            String(localized: "The server said: \(message)", comment: "%@ is an error message from a music server, in the server's own words.")
        case .status(let code):
            String(localized: "The server answered with HTTP status \(String(code)).", comment: "A stream’s server answered with an error. %@ is the HTTP status code, such as 404.")
        case .notAnswering(let reason):
            String(localized: "The server didn’t answer: \(reason)", comment: "%@ is the system's reason, such as “Could not connect to the server.”")
        case .malformedAnswer:
            String(localized: "The server’s answer couldn’t be read. It may not be an OpenSubsonic server.", comment: "A music server answered with something that is not the OpenSubsonic API.")
        case .keepingRefused:
            String(localized: "This service doesn’t allow keeping its music on disk, so it is only streamed.", comment: "A streamed song can't be kept offline, copied or exported.")
        case .notAvailableInThisBuild:
            String(localized: "Not available in this build.", comment: "A streaming provider needs something this copy of the app was built without.")
        case .unsupported:
            String(localized: "The server can’t do that.", comment: "A music server lacks the feature that was asked for.")
        }
    }

    static func wait(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 90 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 1
        return formatter.string(from: max(1, seconds.rounded(.up))) ?? "\(Int(seconds)) s"
    }
}

/// The honest verdict for streamed songs.
public enum StreamVerdict {
    /// Whether a song from a provider may be called bit-perfect at all, before the engine's own check of its path: never
    /// when the provider's own player makes the sound, and never when the server sent something other than its file.
    public static func mayBeBitPerfect(mode: ProviderPlaybackMode, converted: Bool) -> Bool {
        mode == .engine && !converted
    }

    /// Whether the stream that arrived is something other than the file the server lists: another size, or another container.
    /// What can't be told (the server lists neither) is not called converted.
    public static func isConverted(listed: StreamListing, size: Int64, fileExtension: String) -> Bool {
        if listed.size > 0, size != listed.size { return true }
        if let suffix = listed.suffix, !suffix.isEmpty, family(suffix) != family(fileExtension) { return true }
        return false
    }

    /// Extensions that name one container read as one.
    static func family(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wave": "wav"
        case "aif", "aifc": "aiff"
        case "oga": "ogg"
        case "mp4", "m4b", "alac": "m4a"
        case let other: other
        }
    }
}
