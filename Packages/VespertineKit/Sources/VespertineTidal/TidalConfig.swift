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
