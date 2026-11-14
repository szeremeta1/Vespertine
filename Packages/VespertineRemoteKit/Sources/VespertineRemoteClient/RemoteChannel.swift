//
// Vespertine Remote: what a session talks to: a real Mac over the network (RemoteLink), or the built-in demo (DemoMac).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public enum RemoteLinkError: Error, Equatable, Sendable {
    /// The Mac couldn't be reached, or refused the key (a wrong pairing code shows up here too).
    case couldNotConnect(String)
    /// No reply in time.
    case timedOut
    /// The connection closed before the reply came.
    case closed
    /// The Mac refused a stream read, with its reason.
    case readFailed(String)
}

@MainActor
public protocol RemoteChannel: AnyObject {
    /// Everything the Mac sends that isn't a reply: playback, queue and output updates, and goodbye.
    var onPush: (@MainActor (ServerMessage) -> Void)? { get set }
    /// The connection ended (with the reason, if any).
    var onClose: (@MainActor (String?) -> Void)? { get set }
    /// Connects, and returns once the channel can carry requests.
    func open(timeout: Duration) async throws
    /// Sends `command` and waits for the reply.
    func request(_ command: RemoteCommand, timeout: Duration) async throws -> RemoteReply
    /// Reads a range of an open stream (protocol 2): the Mac answers with a binary frame.
    func read(stream: Int, offset: Int64, length: Int, timeout: Duration) async throws -> StreamFrame
    func close()
    /// Where the channel ended up connected, once open (nil when that means nothing: the demo).
    var remoteAddress: RemoteAddress? { get }
}

public extension RemoteChannel {
    var remoteAddress: RemoteAddress? { nil }
    func read(stream: Int, offset: Int64, length: Int, timeout: Duration) async throws -> StreamFrame { throw RemoteLinkError.readFailed("") }
}

#if canImport(Network)
import Network

/// One way to reach a paired Mac.
public struct RemoteRoute: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Found on this network by Bonjour.
        case nearby
        /// The address the user typed for the Mac.
        case address
        /// Where the Mac answered last time.
        case lastKnown
    }

    public var kind: Kind
    public var endpoint: NWEndpoint
    /// The typed or remembered address behind `endpoint` (nil for Bonjour).
    public var address: RemoteAddress?

    public init(kind: Kind, endpoint: NWEndpoint, address: RemoteAddress? = nil) {
        self.kind = kind
        self.endpoint = endpoint
        self.address = address
    }

    /// A route to a typed or remembered address; nil while its port isn't known.
    public init?(kind: Kind, address: RemoteAddress) {
        guard let number = address.port, let port = NWEndpoint.Port(rawValue: number) else { return nil }
        self.init(kind: kind, endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: port), address: address)
    }
}

public extension SavedPairing {
    /// Every way to try this Mac now: Bonjour's endpoint if it's on this network, then the saved addresses.
    func routes(nearby: NWEndpoint?) -> [RemoteRoute] {
        var out: [RemoteRoute] = []
        if let nearby { out.append(RemoteRoute(kind: .nearby, endpoint: nearby)) }
        // An address at the typed host is the typed address (whatever port it has); the rest is where the Mac was seen.
        for saved in savedAddresses {
            if let route = RemoteRoute(kind: saved.host == address?.host ? .address : .lastKnown, address: saved) { out.append(route) }
        }
        return out
    }
}
#endif
