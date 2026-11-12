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
    func close()
}
