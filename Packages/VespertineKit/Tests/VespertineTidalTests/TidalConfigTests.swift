//
// Vespertine: the TIDAL client credentials file (read from disk, written with owner-only permissions).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL credentials config")
struct TidalConfigTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidalcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sample = TidalClientCredentials(clientId: "test-client", clientSecret: "test-secret",
                                                pkceClientId: "test-pkce-client", pkceClientSecret: "test-pkce-secret")

    @Test("a missing file loads as nil")
    func missingFile() throws {
        let url = TidalConfig.credentialsURL(base: try directory())
        #expect(try TidalConfig.loadCredentials(at: url) == nil)
    }

    @Test("save then load round-trips")
    func roundTrip() throws {
        let url = TidalConfig.credentialsURL(base: try directory())
        try TidalConfig.saveCredentials(sample, to: url)
        #expect(try TidalConfig.loadCredentials(at: url) == sample)
    }

    @Test("the file is written under Vespertine/tidal-client.json")
    func location() throws {
        let base = try directory()
        let url = TidalConfig.credentialsURL(base: base)
        #expect(url.path.hasSuffix("/Vespertine/tidal-client.json"))
        try TidalConfig.saveCredentials(sample, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the saved file is readable by its owner only (0600)")
    func permissions() throws {
        let url = TidalConfig.credentialsURL(base: try directory())
        try TidalConfig.saveCredentials(sample, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("overwriting keeps 0600")
    func overwrite() throws {
        let url = TidalConfig.credentialsURL(base: try directory())
        try TidalConfig.saveCredentials(sample, to: url)
        try TidalConfig.saveCredentials(sample, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("a file that isn't valid credentials throws, it doesn't load as nil")
    func malformed() throws {
        let url = TidalConfig.credentialsURL(base: try directory())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"clientId\":1}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try TidalConfig.loadCredentials(at: url) }
    }
}
