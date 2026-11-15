//
// Vespertine: how control apps hear that something changed on the receiver without asking again and again (GENA, UPnP Device
// Architecture 1.1, section 4): they subscribe to a service with a callback address, and each change is sent there in order.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// One service's subscribers. Events for a subscriber go out one at a time, numbered, on a queue of its own: a control app
/// that has gone away holds up nobody else.
final class ReceiverSubscriptions: @unchecked Sendable {
    /// Subscriptions kept per service; more are refused (a control app keeps one or two).
    static let maximum = 16
    static let lifetime = 1800
    /// Events waiting for one slow subscriber; past this it is dropped, as one that stopped listening.
    static let maximumBacklog = 64

    private final class Subscriber: @unchecked Sendable {
        let sid: String
        let callback: URL
        var expires: Date
        var sequence: UInt32 = 0
        let feed: AsyncStream<Data>.Continuation
        var task: Task<Void, Never>?
        var backlog = 0
        init(sid: String, callback: URL, expires: Date, feed: AsyncStream<Data>.Continuation) {
            self.sid = sid
            self.callback = callback
            self.expires = expires
            self.feed = feed
        }
    }

    private let lock = NSLock()
    private var subscribers: [String: Subscriber] = [:]
    private let clock: @Sendable () -> Date

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.httpMaximumConnectionsPerHost = 2
        // A callback is never followed anywhere else.
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    var count: Int { lock.withLock { prune(); return subscribers.count } }

    /// The first callback address in a `CALLBACK: <http://…><http://…>` header that is plain http to `peer` itself: events are
    /// only ever sent back to whoever asked for them, never to an address the subscriber merely names.
    static func callback(_ header: String?, peer: String?) -> URL? {
        guard let header, header.utf8.count <= 1024, let peer, let peerBytes = LocalNetworks.bytes(of: peer) else { return nil }
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let text = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            guard let url = URL(string: String(text)), url.scheme?.lowercased() == "http", var host = url.host, url.user == nil else { continue }
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if LocalNetworks.bytes(of: host) == peerBytes { return url }
        }
        return nil
    }

    /// "Second-1800" → 1800, kept within what the receiver grants.
    static func timeout(_ header: String?) -> Int {
        guard let header, header.lowercased().hasPrefix("second-"), let asked = Int(header.dropFirst(7)) else { return lifetime }
        return min(max(asked, 60), lifetime)
    }

    /// A new subscriber; `initial` is the service's whole state, sent as its first event. nil when there is no room.
    func subscribe(callback: URL, seconds: Int, initial: Data) -> String? {
        let sid = "uuid:\(UUID().uuidString.lowercased())"
        let (stream, feed) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let subscriber = Subscriber(sid: sid, callback: callback, expires: clock().addingTimeInterval(TimeInterval(seconds)), feed: feed)
        let added = lock.withLock { () -> Bool in
            prune()
            guard subscribers.count < Self.maximum else { return false }
            subscribers[sid] = subscriber
            subscriber.backlog = 1
            return true
        }
        guard added else { feed.finish(); return nil }
        subscriber.task = Task.detached(priority: .utility) { [weak self] in
            for await body in stream {
                let sequence = self?.lock.withLock { () -> UInt32 in
                    defer { subscriber.sequence = subscriber.sequence == .max ? 1 : subscriber.sequence + 1 }
                    return subscriber.sequence
                } ?? 0
                await Self.notify(subscriber.callback, sid: subscriber.sid, sequence: sequence, body: body)
                self?.lock.withLock { subscriber.backlog -= 1 }
            }
        }
        feed.yield(initial)
        return sid
    }

    /// Extends `sid`; false when there is no such subscription (it expired, or never was).
    func renew(_ sid: String, seconds: Int) -> Bool {
        lock.withLock {
            prune()
            guard let subscriber = subscribers[sid] else { return false }
            subscriber.expires = clock().addingTimeInterval(TimeInterval(seconds))
            return true
        }
    }

    func unsubscribe(_ sid: String) -> Bool {
        let gone = lock.withLock { subscribers.removeValue(forKey: sid) }
        gone?.feed.finish()
        return gone != nil
    }

    /// Sends `body` to every subscriber, after whatever each is still owed.
    func send(_ body: Data) {
        let dropped = lock.withLock { () -> [Subscriber] in
            prune()
            var dropped: [Subscriber] = []
            for subscriber in subscribers.values {
                if subscriber.backlog >= Self.maximumBacklog {
                    dropped.append(subscriber)
                } else {
                    subscriber.backlog += 1
                    subscriber.feed.yield(body)
                }
            }
            for subscriber in dropped { subscribers[subscriber.sid] = nil }
            return dropped
        }
        for subscriber in dropped { subscriber.feed.finish(); subscriber.task?.cancel() }
    }

    /// Ends every subscription: nothing more is sent.
    func removeAll() {
        let all = lock.withLock { () -> [Subscriber] in
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for subscriber in all { subscriber.feed.finish(); subscriber.task?.cancel() }
    }

    /// Call with the lock held.
    private func prune() {
        let now = clock()
        for (sid, subscriber) in subscribers where subscriber.expires <= now {
            subscribers[sid] = nil
            subscriber.feed.finish()
        }
    }

    private static func notify(_ callback: URL, sid: String, sequence: UInt32, body: Data) async {
        var request = URLRequest(url: callback, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "NOTIFY"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue(String(sequence), forHTTPHeaderField: "SEQ")
        request.httpBody = body
        _ = try? await session.data(for: request)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ReceiverEventBody {
    /// A GENA property set: each variable with its value.
    static func propertySet(_ properties: [(String, String)]) -> Data {
        let list = properties.map { "<e:property><\($0.0)>\(SOAP.escape($0.1))</\($0.0)></e:property>" }.joined()
        return Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">\(list)</e:propertyset>".utf8)
    }

    /// The LastChange document AVTransport and RenderingControl event (their other variables travel inside it).
    static func lastChange(namespace: String, variables: [(name: String, value: String, channel: String?)]) -> Data {
        let list = variables.map { variable in
            let channel = variable.channel.map { " channel=\"\(SOAP.escape($0))\"" } ?? ""
            return "<\(variable.name)\(channel) val=\"\(SOAP.escape(variable.value))\"/>"
        }.joined()
        let event = "<Event xmlns=\"\(namespace)\"><InstanceID val=\"0\">\(list)</InstanceID></Event>"
        return propertySet([("LastChange", event)])
    }

    static let avTransportNamespace = "urn:schemas-upnp-org:metadata-1-0/AVT/"
    static let renderingControlNamespace = "urn:schemas-upnp-org:metadata-1-0/RCS/"

    /// The variables in a LastChange event's body, name → value (for the tests' control point, and for nothing else).
    static func variables(inLastChange body: Data) -> [String: String] {
        guard let outer = SOAP.arguments(in: body, element: "property"), let event = outer["LastChange"] else { return [:] }
        let delegate = ValParser()
        let parser = XMLParser(data: Data(event.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.values
    }

    private final class ValParser: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name != "InstanceID", name != "Event", let value = attributes["val"] { values[name] = value }
        }
    }
}
