//
// Vespertine: a stream outlives its connection. When the Mac stops answering (Wi-Fi to cellular, the Mac restarted, a
// tunnel that dropped), the phone waits for the connection, opens the same song again and carries on reading where it was.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

/// A Mac whose connection can drop: streams opened before a drop are gone after it.
private final class FlakyMac: @unchecked Sendable {
    private let lock = NSLock()
    private var live: Set<Int> = []
    private var next = 0
    private var _connected = true
    private var _opens = 0
    private var _closed: [Int] = []
    private var looksUntilBack: Int?
    var tag = "same-bytes"
    let data = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0) })

    var opens: Int { lock.withLock { _opens } }
    var closed: [Int] { lock.withLock { _closed } }
    var connected: Bool {
        get { lock.withLock { _connected } }
        set { lock.withLock { _connected = newValue } }
    }

    /// The connection is lost: every stream is forgotten, and nothing answers until `connected` is true again.
    func drop(reconnecting: Bool = false) { lock.withLock { live = []; _connected = reconnecting } }

    /// The connection comes back by itself the `look`th time the line looks at it. Counted in the line's own looks,
    /// not in milliseconds, so it comes back at the same point of the wait on any machine.
    func comeBack(atLook look: Int) { lock.withLock { looksUntilBack = look } }

    private func look() -> Bool {
        lock.withLock {
            if !_connected, let left = looksUntilBack {
                if left <= 1 { _connected = true; looksUntilBack = nil } else { looksUntilBack = left - 1 }
            }
            return _connected
        }
    }

    func descriptor(_ number: Int) -> StreamDescriptor {
        StreamDescriptor(stream: number, kind: .original, byteSize: Int64(data.count),
                         format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: 44_100, bitDepth: 16, channels: 2, channelLabels: nil, lossless: true),
                         frames: nil, tag: tag, chunkSize: 1000)
    }

    var client: PhoneStreamClient {
        PhoneStreamClient(open: { [self] _, _ in
            lock.withLock {
                guard _connected else { return .failed(reason: "") }
                _opens += 1
                next += 1
                live.insert(next)
                return .streamOpened(descriptor(next))
            }
        }, read: { [self] stream, offset, length in
            let ok = lock.withLock { _connected && live.contains(stream) }
            guard ok else { throw RemoteLinkError.closed }
            let end = min(Int(offset) + length, data.count)
            return StreamFrame(request: 1, stream: stream, offset: offset, endOfStream: end >= data.count, payload: Data(data[Int(offset)..<end]))
        }, close: { [self] stream in
            lock.withLock { _closed.append(stream); live.remove(stream) }
        }, isConnected: { [self] in look() })
    }
}

/// The line's clock in these tests: its time passes only when the line pauses between looks, by exactly that pause. A
/// test's patience is then a number of looks, the same on a machine that holds every test still for a minute (GitHub's
/// three-core Mac did, and a five-second patience on the real clock was spent before the first look).
private final class Paces: @unchecked Sendable {
    private let lock = NSLock()
    private var at = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { at } }
    func rest(_ pause: Duration) async {
        lock.withLock { at = at + pause }
        await Task.yield()
    }
}

@Suite struct StreamLineTests {
    private func opened(_ mac: FlakyMac) async throws -> StreamDescriptor {
        guard case .streamOpened(let descriptor) = await mac.client.open(1, nil) else { throw RemoteLinkError.closed }
        return descriptor
    }

    private func lineTo(_ mac: FlakyMac, patience: Duration = .seconds(5)) async throws -> StreamLine {
        let paces = Paces()
        return StreamLine(client: mac.client, song: 1, descriptor: try await opened(mac), maxSampleRate: nil, patience: patience, pause: .milliseconds(5),
                          now: { paces.now }, rest: { await paces.rest($0) })
    }

    @Test func aReadAfterTheConnectionCameBackOpensTheSongAgainAndCarriesOn() async throws {
        let mac = FlakyMac()
        let line = try await lineTo(mac)
        #expect(try await line.read(offset: 0, length: 1000).payload == mac.data.prefix(1000))
        mac.drop()
        mac.comeBack(atLook: 12)
        let frame = try await line.read(offset: 1000, length: 1000)
        #expect(frame.payload == mac.data[1000..<2000])
        #expect(mac.opens == 2)
        #expect(await line.number == 2)
    }

    @Test func fourReadsThatFailTogetherOpenTheSongOnce() async throws {
        let mac = FlakyMac()
        let line = try await lineTo(mac)
        mac.drop(reconnecting: true)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<4 { group.addTask { try await line.read(offset: Int64(i) * 1000, length: 1000).payload.count } }
            for try await count in group { #expect(count == 1000) }
        }
        #expect(mac.opens == 2)
    }

    @Test func aSongThatChangedOnTheMacIsNotStitchedTogether() async throws {
        let mac = FlakyMac()
        let line = try await lineTo(mac)
        mac.drop(reconnecting: true)
        mac.tag = "other-bytes"
        await #expect(throws: StreamSource.Failure.self) { try await line.read(offset: 0, length: 1000) }
    }

    @Test func aMacThatNeverComesBackEndsTheWaitWithWords() async throws {
        let mac = FlakyMac()
        let line = try await lineTo(mac, patience: .milliseconds(80))
        mac.drop()
        // The read ends by itself once the patience is spent (16 pauses of 5 ms), and what it throws carries the last error's words.
        do {
            _ = try await line.read(offset: 0, length: 1000)
            Issue.record("the read came back from a Mac that is gone")
        } catch StreamSource.Failure.unreachable(let words) {
            #expect(!words.isEmpty)
        }
    }

    @Test func whileItWaitsItSaysSoAndClosingGivesBackTheStreamItHasNow() async throws {
        let mac = FlakyMac()
        let waits = Waits()
        let line = try await lineTo(mac)
        await line.onWaiting { waits.note($0) }
        mac.drop()
        mac.comeBack(atLook: 8)
        _ = try await line.read(offset: 0, length: 10)
        #expect(waits.seen == [true, false])
        await line.close()
        #expect(mac.closed == [2])
    }
}

private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [Bool] = []
    var seen: [Bool] { lock.withLock { _seen } }
    func note(_ waiting: Bool) { lock.withLock { _seen.append(waiting) } }
}
#endif
