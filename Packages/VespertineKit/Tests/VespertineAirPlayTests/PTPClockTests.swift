//
// Vespertine: the PTP clock against a follower on this machine: what a tick sends and where from, the numbers counting
// up, the moment in a Follow_Up, a Delay_Req answered, and the timer that ticks by itself.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineAirPlay

/// A receiver's side of the clock: two ports, and everything that arrives on each with the port it came from.
final class FakePTPFollower: @unchecked Sendable {
    struct Arrival: Sendable {
        var data: Data
        var from: UInt16
    }
    let event: UDPSocket
    let general: UDPSocket
    private let arrivals = Locked((event: [Arrival](), general: [Arrival]()))

    init() throws {
        event = try UDPSocket(bind: "127.0.0.1")
        general = try UDPSocket(bind: "127.0.0.1")
        event.startReceiving(name: "fake ptp event") { [weak self] data, _, port in self?.arrivals.withLock { $0.event.append(Arrival(data: data, from: port)) } }
        general.startReceiving(name: "fake ptp general") { [weak self] data, _, port in self?.arrivals.withLock { $0.general.append(Arrival(data: data, from: port)) } }
    }

    var onEvent: [Arrival] { arrivals.withLock { $0.event } }
    var onGeneral: [Arrival] { arrivals.withLock { $0.general } }
    var peer: PTPClock.Peer { PTPClock.Peer(host: "127.0.0.1", eventPort: event.port, generalPort: general.port) }

    func stop() {
        event.close()
        general.close()
    }
}

@Suite("PTP clock", .serialized)
@MainActor
struct PTPClockTests {
    let identity = PTPMessage.identity(address: [0x02, 0x1A, 0xFF, 0x00, 0x9C, 0x07])

    /// A clock on free ports whose time is whatever `time` holds.
    func makeClock(_ time: Locked<UInt64>) throws -> PTPClock {
        try PTPClock(identity: identity, eventPort: 0, generalPort: 0, now: { time.withLock { $0 } })
    }

    @Test("The first tick announces the clock, then says the time: Sync from the event port, Follow_Up from the general one with the moment")
    func firstTick() async throws {
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        let time = Locked(UInt64(1_763_400_000_123_456_789))
        let clock = try makeClock(time)
        defer { clock.stop() }
        clock.setPeers([follower.peer])
        clock.tick()
        await untilTrue { follower.onEvent.count == 1 && follower.onGeneral.count == 2 }

        let sync = try #require(PTPMessage.read(follower.onEvent[0].data))
        #expect(sync.kind == .sync)
        #expect(sync.clock == identity)
        #expect(sync.sequence == 0)
        #expect(follower.onEvent[0].from == clock.eventPort)

        let kinds = follower.onGeneral.compactMap { PTPMessage.read($0.data)?.kind }
        #expect(Set(kinds) == [.announce, .followUp])
        #expect(follower.onGeneral.allSatisfy { $0.from == clock.generalPort })
        let follow = try #require(follower.onGeneral.compactMap { PTPMessage.read($0.data) }.first { $0.kind == .followUp })
        #expect(follow.sequence == 0)
        #expect(follow.time == PTPTimestamp(seconds: 1_763_400_000, nanoseconds: 123_456_789))
        #expect(PTPClock.time(uptime: 1_763_400_000_123_456_789) == follow.time)
    }

    @Test("Eight ticks are a second: one Announce, eight Syncs numbered in order, each Follow_Up with the time of its own tick")
    func aSecond() async throws {
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        let time = Locked(UInt64(5_000_000_000))
        let clock = try makeClock(time)
        defer { clock.stop() }
        clock.setPeers([follower.peer])
        for _ in 0..<9 {
            clock.tick()
            time.withLock { $0 += 125_000_000 }
        }
        await untilTrue { follower.onEvent.count == 9 && follower.onGeneral.count == 11 }
        // Datagrams may arrive in any order: counted and matched by their numbers.
        let syncs = follower.onEvent.compactMap { PTPMessage.read($0.data) }
        #expect(Set(syncs.map { $0.sequence }) == Set(UInt16(0)..<9))
        let general = follower.onGeneral.compactMap { PTPMessage.read($0.data) }
        let announces = general.filter { $0.kind == .announce }
        #expect(Set(announces.map { $0.sequence }) == [0, 1])
        let follows = general.filter { $0.kind == .followUp }
        #expect(follows.count == 9)
        for follow in follows {
            #expect(follow.time.totalNanoseconds == 5_000_000_000 + UInt64(follow.sequence) * 125_000_000)
        }
    }

    @Test("Every peer is told, a peer taken off the list is told no more, and with no peers a tick sends nothing")
    func peers() async throws {
        let first = try FakePTPFollower(), second = try FakePTPFollower()
        defer { first.stop(); second.stop() }
        let clock = try makeClock(Locked(UInt64(1)))
        defer { clock.stop() }
        clock.tick()
        clock.setPeers([first.peer, second.peer])
        #expect(clock.peers == [first.peer, second.peer])
        clock.tick()
        await untilTrue { first.onEvent.count == 1 && second.onEvent.count == 1 }
        // The tick with no peers still counted: this Sync is the second.
        #expect(PTPMessage.read(first.onEvent[0].data)?.sequence == 1)
        clock.setPeers([second.peer])
        clock.tick()
        await untilTrue { second.onEvent.count == 2 }
        #expect(first.onEvent.count == 1)
    }

    @Test("A peer that asks how long the network took is answered on its general port with its own number and the moment it was read")
    func delayRequest() async throws {
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        let time = Locked(UInt64(9_000_000_042))
        let clock = try makeClock(time)
        defer { clock.stop() }
        clock.setPeers([follower.peer])
        let asked = hex("1102002c000004080000000000000000" + "00000000f01898fffe12345680010bb8017f" + "00000000000000000000")
        follower.event.send(asked, to: "127.0.0.1", port: clock.eventPort)
        await untilTrue { follower.onGeneral.count == 1 }
        let answer = try #require(PTPMessage.read(follower.onGeneral[0].data))
        #expect(answer.kind == .delayResponse)
        #expect(answer.clock == identity)
        #expect(answer.sequence == 0x0BB8)
        #expect(answer.time == PTPTimestamp(seconds: 9, nanoseconds: 42))
        #expect(answer.body.suffix(10) == hex("f01898fffe1234568001"))
        #expect(follower.onGeneral[0].from == clock.generalPort)

        // Anything else on the event port is not answered: a Sync, and noise. The next question still is.
        follower.event.send(PTPMessage.sync(clock: 77, sequence: 1), to: "127.0.0.1", port: clock.eventPort)
        follower.event.send(Data([1, 2, 3]), to: "127.0.0.1", port: clock.eventPort)
        follower.event.send(asked, to: "127.0.0.1", port: clock.eventPort)
        await untilTrue { follower.onGeneral.count == 2 }
        #expect(follower.onGeneral.compactMap { PTPMessage.read($0.data)?.kind } == [.delayResponse, .delayResponse])
    }

    @Test("Started, the clock ticks by itself until it is stopped")
    func runs() async throws {
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        let clock = try PTPClock(identity: identity, eventPort: 0, generalPort: 0)
        clock.setPeers([follower.peer])
        clock.start()
        clock.start()
        await untilTrue { follower.onEvent.count >= 3 }
        let times = follower.onGeneral.compactMap { PTPMessage.read($0.data) }.filter { $0.kind == .followUp }.map { $0.time.totalNanoseconds }
        #expect(times.allSatisfy { $0 > 0 })
        clock.stop()
        clock.stop()
    }

    @Test("Two sockets that ask to share a port both hold it, as a Mac whose system has a clock of its own needs; one that doesn't ask is refused")
    func sharedPorts() throws {
        let first = try UDPSocket(bind: "127.0.0.1", shared: true)
        defer { first.close() }
        let second = try UDPSocket(bind: "127.0.0.1", port: first.port)
        defer { second.close() }
        #expect(second.port == first.port)
        #expect(throws: RAOPError.self) { _ = try UDPSocket(bind: "127.0.0.1", port: first.port, shared: false) }
    }
}
