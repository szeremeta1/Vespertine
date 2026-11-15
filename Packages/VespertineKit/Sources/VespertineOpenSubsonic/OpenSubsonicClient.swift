//
// Vespertine: the requests an OpenSubsonic server is sent. The API is the open one at opensubsonic.netlify.app, which the
// listener's own server (Navidrome, Gonic, Airsonic and the like) speaks. The credential rides in each request's query, as the
// API has it, so a request's address is never logged, cached or written anywhere.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import VespertineAudio
import VespertineStreaming

/// What is kept in the Keychain for one account: the server's address and the least that signs in again. The password itself
/// is kept only for a server that takes neither an API key nor a token made from it.
public struct OpenSubsonicCredential: Codable, Sendable, Equatable {
    public var server: String
    public var user: String
    public var apiKey: String?
    public var token: String?
    public var salt: String?
    public var password: String?

    public init(server: String, user: String, apiKey: String? = nil, token: String? = nil, salt: String? = nil, password: String? = nil) {
        self.server = server
        self.user = user
        self.apiKey = apiKey
        self.token = token
        self.salt = salt
        self.password = password
    }

    /// Whether anything in it can sign in. An item whose secret was taken out (the server refused it) keeps the address only.
    public var canSignIn: Bool { apiKey != nil || (token != nil && salt != nil) || password != nil }

    /// The same without its secret: what stays when the server no longer accepts it.
    var withoutSecret: OpenSubsonicCredential { OpenSubsonicCredential(server: server, user: user) }

    /// The query items that carry the credential.
    var query: [(String, String)] {
        if let apiKey { return [("apiKey", apiKey)] }
        if let token, let salt { return [("u", user), ("t", token), ("s", salt)] }
        if let password { return [("u", user), ("p", "enc:" + Data(password.utf8).map { String(format: "%02x", $0) }.joined())] }
        return []
    }

    /// The token the API asks for: the MD5 of the password followed by the salt, in hex. (MD5 is the API's choice, not ours.)
    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func newSalt() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// A server's address as the listener typed it, made into the address requests go to.
public enum OpenSubsonicAddress {
    /// "music.example" becomes "https://music.example". A trailing "/" or "/rest" is dropped. Only http and https are taken.
    public static func parse(_ text: String) throws -> URL {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(" ") else { throw StreamingError.badAddress }
        if !typed.contains("://") { typed = "https://" + typed }
        guard var parts = URLComponents(string: typed), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { throw StreamingError.badAddress }
        // A name and password in the address would be kept with it: they belong in the fields for them.
        guard parts.user == nil, parts.password == nil else { throw StreamingError.badAddress }
        parts.scheme = scheme
        parts.query = nil
        parts.fragment = nil
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/rest") { path.removeLast(5) }
        parts.path = path
        guard let url = parts.url else { throw StreamingError.badAddress }
        return url
    }

    /// Whether an address is on the listener's own network: this Mac, a link-local address, a private range (10/8, 172.16/12,
    /// 192.168/16), the range overlay networks hand out (100.64/10) or an IPv6 unique local address (fc00::/7).
    public static func isLocal(_ address: [UInt8]) -> Bool {
        if address.count == 4 {
            switch StreamAddressPolicy.kind(ofIPv4: address) {
            case .loopback, .linkLocal: return true
            case .unusable: return false
            case .routable: break
            }
            if address[0] == 10 { return true }
            if address[0] == 172, address[1] & 0xf0 == 16 { return true }
            if address[0] == 192, address[1] == 168 { return true }
            if address[0] == 100, address[1] & 0xc0 == 64 { return true }
            return false
        }
        guard address.count == 16 else { return false }
        // An IPv4 address written as IPv6 is judged as the IPv4 address it is.
        if address[0..<10].allSatisfy({ $0 == 0 }), address[10] == 0xff, address[11] == 0xff { return isLocal(Array(address[12..<16])) }
        switch StreamAddressPolicy.kind(ofIPv6: address) {
        case .loopback, .linkLocal: return true
        case .unusable: return false
        case .routable: return address[0] & 0xfe == 0xfc
        }
    }

    /// Whether `url` is an http address, which sends the credential unencrypted.
    public static func isUnencrypted(_ url: URL) -> Bool { url.scheme?.lowercased() == "http" }

    /// Throws unless `url` is https, or http to a server every one of whose addresses is on the listener's own network.
    /// Asks the resolver, so never on the main thread.
    public static func check(_ url: URL) throws {
        guard isUnencrypted(url) else { return }
        guard var host = url.host, !host.isEmpty else { throw StreamingError.badAddress }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let addresses = StreamAddressPolicy.addresses(of: host)
        guard !addresses.isEmpty else {
            throw StreamingError.notAnswering(String(localized: "Its name couldn’t be found on the network.", comment: "A whole sentence shown after “The address didn’t answer:” when a host name doesn't resolve."))
        }
        guard addresses.allSatisfy(isLocal) else { throw StreamingError.insecureAddress }
    }
}

/// Sends the API's requests to one server with one credential. It holds no state: the gate and the Keychain are the provider's.
struct OpenSubsonicClient: Sendable {
    static let clientName = "Vespertine"
    static let apiVersion = "1.16.1"

    let base: URL
    let credential: OpenSubsonicCredential
    let session: URLSession

    /// The address of an API method with the credential and `items` in its query. Never logged, never written to disk.
    func url(_ method: String, _ items: [(String, String)] = [], json: Bool = true) -> URL {
        var all = credential.query + [("v", Self.apiVersion), ("c", Self.clientName)]
        if json { all.append(("f", "json")) }
        all += items
        let query = all.map { "\(Self.encoded($0.0))=\(Self.encoded($0.1))" }.joined(separator: "&")
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path += "/rest/\(method)"
        parts.percentEncodedQuery = query
        return parts.url!
    }

    /// Unreserved characters stay; everything else, "+" and "&" among it, is percent-encoded.
    static func encoded(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// What one request came back as.
    enum Outcome: Sendable {
        case answer(Data, type: String?)
        /// 429, or 503 with a Retry-After: the server asked to wait.
        case wait(TimeInterval?)
    }

    func fetch(_ url: URL) async throws -> Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The system's reason only: the request's address, which carries the credential, stays out of it.
            throw StreamingError.notAnswering(Self.reason(error, credential: credential))
        }
        guard let http = response as? HTTPURLResponse else { throw StreamingError.malformedAnswer }
        let retry = RequestGate.retryAfter(http)
        if http.statusCode == 429 || (http.statusCode == 503 && retry != nil) { return .wait(retry) }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamingError.signedOut }
        guard (200..<300).contains(http.statusCode) else { throw StreamingError.status(http.statusCode) }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return .answer(data, type: type)
    }

    /// The system's sentence for a failed request ("Could not connect to the server."). Should it ever carry an address or
    /// anything of the credential, the plain name of the failure is given in its place.
    static func reason(_ error: any Error, credential: OpenSubsonicCredential) -> String {
        let text = error.localizedDescription
        let secrets = [credential.apiKey, credential.token, credential.salt, credential.password].compactMap { $0 }.filter { !$0.isEmpty }
        if text.contains("://") || text.contains("?") || secrets.contains(where: { text.contains($0) }) {
            return (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: type(of: error))
        }
        return text
    }

    /// Reads an answer. A failure the server reports becomes the error the listener reads.
    static func answer(_ data: Data) throws -> SubsonicAnswer {
        guard let envelope = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data) else { throw StreamingError.malformedAnswer }
        let answer = envelope.response
        if answer.status?.text == "ok" { return answer }
        guard answer.status?.text == "failed" || answer.error != nil else { throw StreamingError.malformedAnswer }
        let code = answer.error?.code?.int ?? 0
        let message = answer.error?.message?.text ?? ""
        switch code {
        case 40, 44: throw StreamingError.signedOut
        case 41, 42, 43: throw OpenSubsonicRefusal.mechanism(code: code, message: message)
        default: throw StreamingError.server(message.isEmpty ? "\(code)" : message)
        }
    }
}

/// The server refused the way of signing in, not the credential: another way may be accepted.
enum OpenSubsonicRefusal: Error {
    case mechanism(code: Int, message: String)

    var asStreamingError: StreamingError {
        switch self {
        case .mechanism(let code, let message): .server(message.isEmpty ? "\(code)" : message)
        }
    }
}

/// Follows a redirect only to the same host, and never from https to http: a credential is not sent on to somewhere else.
final class OpenSubsonicRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url, from.host?.lowercased() == to.host?.lowercased(),
              !(from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https") else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
