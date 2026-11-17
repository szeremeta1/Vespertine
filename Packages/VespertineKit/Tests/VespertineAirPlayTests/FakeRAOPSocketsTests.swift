//
// Vespertine: stopping a fake receiver must never shut down a socket whose descriptor has been reused by another
// receiver. Unix socket pairs keep this deterministic and need no network listener or real receiver.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Testing

@Suite("Fake receiver socket ownership")
struct FakeRAOPSocketsTests {
    @Test("A closed client's descriptor can be reused without the old receiver shutting down its new owner")
    func reusedDescriptor() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        let sockets = FakeRAOPSockets()
        // Reserve a high descriptor so unrelated test activity does not take it between close and duplication.
        let old = fcntl(pair[0], F_DUPFD, 200)
        try #require(old >= 0)
        try #require(sockets.insert(old))
        sockets.close(old)
        let replacement = fcntl(pair[0], F_DUPFD, old)
        try #require(replacement >= 0)
        defer { Darwin.close(replacement) }
        try #require(replacement == old)

        sockets.stop()
        var byte: UInt8 = 42
        #expect(send(replacement, &byte, 1, MSG_NOSIGNAL) == 1)
        var received: UInt8 = 0
        #expect(recv(pair[1], &received, 1, MSG_DONTWAIT) == 1)
        #expect(received == byte)
    }

    @Test("Stopping wakes a live client, and a worker can close it after repeated stops")
    func liveClient() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[1]) }
        let sockets = FakeRAOPSockets()
        try #require(sockets.insert(pair[0]))
        sockets.stop()
        sockets.stop()
        var byte: UInt8 = 0
        #expect(recv(pair[1], &byte, 1, MSG_DONTWAIT) == 0)
        sockets.close(pair[0])
    }

    @Test("A client accepted after stopping is closed instead of escaping cleanup")
    func lateClient() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[1]) }
        let sockets = FakeRAOPSockets()
        sockets.stop()
        #expect(!sockets.insert(pair[0]))
        var byte: UInt8 = 0
        #expect(recv(pair[1], &byte, 1, MSG_DONTWAIT) == 0)
    }
}
