//
// Vespertine: the password of an AirPlay receiver that has one (`pw=true`). The receiver answers the first request with
// 401 and a challenge (`WWW-Authenticate: Digest realm="…", nonce="…"`); every request after carries
// `Authorization: Digest …` with MD5(MD5(user:realm:password):nonce:MD5(method:uri)), as HTTP digest (RFC 2617) without
// qop. The user name is not asked for: senders say "iTunes". Receivers differ on the case of the hex digits (iTunes sends
// capitals and some receivers compare the text), so a sender that is refused once tries the other.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

public enum RTSPDigest {
    public static let username = "iTunes"

    public struct Challenge: Sendable, Equatable {
        public var realm: String
        public var nonce: String

        public init(realm: String, nonce: String) {
            self.realm = realm
            self.nonce = nonce
        }

        /// From a `WWW-Authenticate` header; nil unless it is a Digest challenge with a nonce.
        public static func parse(_ header: String) -> Challenge? {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("digest") else { return nil }
            let fields = parameters(String(trimmed.dropFirst("digest".count)))
            guard let nonce = fields["nonce"], !nonce.isEmpty else { return nil }
            return Challenge(realm: fields["realm"] ?? "", nonce: nonce)
        }
    }

    /// `key="value", key=value` pairs, keys lower-cased; commas inside quotes belong to the value.
    static func parameters(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inValue = false, quoted = false
        func keep() {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { out[k] = value.trimmingCharacters(in: .whitespaces) }
        }
        for c in text {
            if quoted {
                if c == "\"" { quoted = false } else { value.append(c) }
            } else if c == "\"", inValue {
                quoted = true
            } else if c == "=", !inValue {
                inValue = true
            } else if c == "," {
                keep()
                key = ""; value = ""; inValue = false
            } else if inValue {
                value.append(c)
            } else {
                key.append(c)
            }
        }
        keep()
        return out
    }

    static func md5(_ text: String, uppercase: Bool) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
    }

    public static func response(_ challenge: Challenge, password: String, method: String, uri: String, uppercase: Bool) -> String {
        let ha1 = md5("\(username):\(challenge.realm):\(password)", uppercase: uppercase)
        let ha2 = md5("\(method):\(uri)", uppercase: uppercase)
        return md5("\(ha1):\(challenge.nonce):\(ha2)", uppercase: uppercase)
    }

    /// The `Authorization` header's value for one request.
    public static func authorization(_ challenge: Challenge, password: String, method: String, uri: String, uppercase: Bool) -> String {
        let answer = response(challenge, password: password, method: method, uri: uri, uppercase: uppercase)
        return "Digest username=\"\(username)\", realm=\"\(challenge.realm)\", nonce=\"\(challenge.nonce)\", uri=\"\(uri)\", response=\"\(answer)\""
    }
}
