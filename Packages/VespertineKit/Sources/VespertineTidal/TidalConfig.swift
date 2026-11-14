//
// Vespertine: the TIDAL client credentials, read from a file in Application Support. They are never part of the source tree.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The OAuth client the user supplies: the pair used for the legacy device flow and the pair used for PKCE login.
public struct TidalClientCredentials: Codable, Sendable, Equatable {
    public var clientId: String
    public var clientSecret: String
    public var pkceClientId: String
    public var pkceClientSecret: String

    public init(clientId: String, clientSecret: String, pkceClientId: String, pkceClientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.pkceClientId = pkceClientId
        self.pkceClientSecret = pkceClientSecret
    }
}

public enum TidalConfig {
    /// `~/Library/Application Support`.
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// `<base>/Vespertine/tidal-client.json`.
    public static func credentialsURL(base: URL = applicationSupport) -> URL {
        base.appendingPathComponent("Vespertine", isDirectory: true).appendingPathComponent("tidal-client.json")
    }

    /// The resource name of the client credentials built into the app (`TidalClient.json` in its Resources). The file is made
    /// locally and ignored by git, so the repository never holds a client ID or secret; a build without it has none.
    public static let bundledResourceName = "TidalClient"

    /// The client credentials built into the app, if this build carries them: Sign In then works with no setup.
    public static func bundledCredentials(in bundle: Bundle = .main) -> TidalClientCredentials? {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? TidalClientCredentials.parse(data)
    }

    /// The credentials in the file, or nil when there is no file. A file that exists but isn't valid credentials throws.
    public static func loadCredentials(at url: URL) throws -> TidalClientCredentials? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TidalClientCredentials.self, from: Data(contentsOf: url))
    }

    /// Writes the credentials with owner-only (0600) permissions, creating the directory when needed. The file is created with
    /// those permissions from the start, so the secrets are never readable by others, not even briefly.
    public static func saveCredentials(_ credentials: TidalClientCredentials, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credentials)
        let temporary = directory.appendingPathComponent(".tidal-client-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// Why a pasted or imported `tidal-client.json` can't be used.
public enum TidalCredentialsError: Error, Equatable, LocalizedError {
    case notJSON
    /// The keys that are absent or empty, in the file's order of fields.
    case missing([String])

    public var errorDescription: String? {
        switch self {
        case .notJSON:
            String(localized: "This isn't a TIDAL client file (a JSON object with clientId, clientSecret, pkceClientId and pkceClientSecret).",
                   comment: "Settings › TIDAL: the imported or pasted client credentials aren't JSON.")
        case .missing(let keys):
            String(localized: "The client file has no value for \(keys.joined(separator: ", ")).",
                   comment: "Settings › TIDAL: the imported or pasted client credentials lack these keys (key names, not translated).")
        }
    }
}

extension TidalClientCredentials {
    static let keys = ["clientId", "clientSecret", "pkceClientId", "pkceClientSecret"]

    /// The credentials of a `tidal-client.json` (imported or pasted): every value present and not blank, trimmed.
    public static func parse(_ data: Data) throws -> TidalClientCredentials {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TidalCredentialsError.notJSON }
        let values = keys.map { ((object[$0] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let missing = zip(keys, values).filter { $0.1.isEmpty }.map(\.0)
        guard missing.isEmpty else { throw TidalCredentialsError.missing(missing) }
        return TidalClientCredentials(clientId: values[0], clientSecret: values[1], pkceClientId: values[2], pkceClientSecret: values[3])
    }
}
