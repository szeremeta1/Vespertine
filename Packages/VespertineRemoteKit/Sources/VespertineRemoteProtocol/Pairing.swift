//
// Vespertine: pairing a remote with a Mac.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// The Mac's Settings › Remote shows a QR code holding a `PairingLink`, and the same window's 6-digit code for typing.
// Either is a short-lived secret that both sides turn into a TLS pre-shared key (`PairingKey.derive`), so only a phone
// that saw the Mac's screen completes the handshake. Over that connection the phone sends `pair`, and the Mac answers with
// the phone's own long-term key (32 random bytes) and device ID, which the phone keeps in its Keychain and uses as its
// TLS identity and key from then on. Removing the phone on the Mac drops its key, so it can't connect again.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// What the QR code says: `vespertine-remote://pair?v=1&id=<server ID>&name=<Mac name>&secret=<secret>`.
public struct PairingLink: Sendable, Equatable {
    public static let scheme = "vespertine-remote"

    public var serverID: String
    public var name: String
    public var secret: String
    public var protocolVersion: Int

    public init(serverID: String, name: String, secret: String, protocolVersion: Int = RemoteProtocol.version) {
        self.serverID = serverID
        self.name = name
        self.secret = secret
        self.protocolVersion = protocolVersion
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(protocolVersion)),
            URLQueryItem(name: "id", value: serverID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "secret", value: secret),
        ]
        // URLComponents leaves "+" alone in a query, which some readers take for a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// nil for anything that isn't a complete pairing link.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme, components.host?.lowercased() == "pair" else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard let id = value("id"), !id.isEmpty, let secret = value("secret"), !secret.isEmpty else { return nil }
        serverID = id
        name = value("name") ?? ""
        self.secret = secret
        protocolVersion = value("v").flatMap(Int.init) ?? 1
    }
}

public enum PairingSecret {
    /// A secret for a pairing link: 128 random bits as 26 lowercase base32 letters and digits.
    public static func makeLinkSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return base32(bytes)
    }

    /// A code for typing: 6 digits, the first never 0 so it reads as six.
    public static func makeTypedCode() -> String {
        String(Int.random(in: 100_000...999_999))
    }

    /// A typed code as the Mac compares it: digits only (the phone may show "123 456").
    public static func normalizedCode(_ text: String) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber))
    }

    static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = "", buffer = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}

/// A new device's ID and key, made by the Mac when a phone pairs.
public struct DeviceCredential: Codable, Sendable, Equatable {
    public var device: String
    public var key: Data

    public init(device: String, key: Data) {
        self.device = device
        self.key = key
    }

    public static func make() -> DeviceCredential {
        var generator = SystemRandomNumberGenerator()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return DeviceCredential(device: "phone-" + UUID().uuidString.lowercased(), key: key)
    }
}

#if canImport(CryptoKit)
public enum PairingKey {
    /// The TLS pre-shared key both sides use while pairing with `secret` (a link's secret, or a typed code as
    /// `PairingSecret.normalizedCode` gives it) with the Mac whose server ID is `serverID`.
    public static func derive(secret: String, serverID: String) -> Data {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data("vespertine-remote-pairing\u{1F}\(serverID)".utf8), using: key)
        return Data(code)
    }
}
#endif
