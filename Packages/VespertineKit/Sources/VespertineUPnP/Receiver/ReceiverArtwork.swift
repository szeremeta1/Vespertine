//
// Vespertine: the picture a control app names for its song (upnp:albumArtURI), fetched under the same rules as the song: http or
// https only, never from this Mac itself or a link-local address, no redirect to one, and no more than a cover's worth of bytes.
// The bytes go to whoever asked and nowhere else: nothing is written to disk.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public enum ReceiverArtwork {
    /// The largest picture taken.
    public static let maximumBytes = 8 << 20

    /// The picture's bytes, or nil: the address is refused, doesn't answer within ten seconds, isn't a 200, or is too large.
    public static func fetch(_ url: URL, policy: StreamAddressPolicy = .fromTheNetwork, limit: Int = maximumBytes) async -> Data? {
        // Resolving a name can take a moment: not on a thread that has other work.
        let allowed = await Task.detached(priority: .utility) { (try? policy.check(url)) != nil }.value
        guard allowed else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: Redirects(policy: policy), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if http.expectedContentLength > Int64(limit) { return nil }
            var data = Data()
            data.reserveCapacity(http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 256 << 10)
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    /// A redirect is followed only to an address the policy admits.
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let policy: StreamAddressPolicy
        init(policy: StreamAddressPolicy) { self.policy = policy }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let target = request.url, (try? policy.check(target, redirect: true)) != nil else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
}
