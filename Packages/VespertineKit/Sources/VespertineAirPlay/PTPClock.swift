//
// Vespertine: a PTP clock that leads: it tells the receivers of a session what time it is, so that they can play a
// buffered stream at the moments the sender names.
//
// The time it tells is this Mac's uptime in nanoseconds: a clock of its own, which is all a session needs (every moment
// the sender names is read from the same clock).
//
// Eight times a second, to every peer: a Sync from the event port to the peer's event port, then a Follow_Up from the
// general port to the peer's general port with the moment the Sync was handed to the network. Once a second, an Announce.
// A peer's Delay_Req (to the event port) is answered from the general port with the moment it was read. Messages go from
// the port they go to, as receivers expect (Shairport Sync's clock drops any that don't).
//
// One step of that is `tick()`, which a timer calls every eighth of a second once the clock is started; tests call it
// themselves. The moments are taken in software, so they are good to a fraction of a millisecond, not to the microsecond
// a network card's own stamps would give.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public final class PTPClock: @unchecked Sendable {
    /// A receiver that follows this clock, and the ports it takes the clock's messages on.
    public struct Peer: Hashable, Sendable {
        public var host: String
        public var eventPort: UInt16
        public var generalPort: UInt16

        public init(host: String, eventPort: UInt16 = 319, generalPort: UInt16 = 320) {
            self.host = host
            self.eventPort = eventPort
            self.generalPort = generalPort
        }
    }

    /// What the clock is called in its messages, and in the SETRATEANCHORTIME that names a moment on it.
    public let identity: UInt64
    public var eventPort: UInt16 { event.port }
    public var generalPort: UInt16 { general.port }

    private let event: UDPSocket
    private let general: UDPSocket
    private let now: @Sendable () -> UInt64

    private struct State {
        var peers: [Peer] = []
        var ticks = 0
        var syncs: UInt16 = 0
        var announces: UInt16 = 0
        var timer: DispatchSourceTimer?
    }
    private let state = Locked(State())
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.airplay.ptp", qos: .userInteractive)

    /// Ticks to an Announce: eight eighths of a second.
    static let ticksPerAnnounce = 8
    static var tickInterval: DispatchTimeInterval { .milliseconds(125) }

    /// `eventPort`, `generalPort`: 319 and 320 for a real session; 0 for any free ones (tests). `now`: the clock read,
    /// in nanoseconds. Throws when a port can't be had.
    public init(identity: UInt64, eventPort: UInt16 = 319, generalPort: UInt16 = 320,
                now: @escaping @Sendable () -> UInt64 = { NTPClock.nanosecondsNow() }) throws {
        self.identity = identity
        self.now = now
        event = try UDPSocket(port: eventPort)
        do { general = try UDPSocket(port: generalPort) } catch { event.close(); throw error }
        event.startReceiving(name: "ptp event") { [weak self] data, host, _ in self?.asked(data, from: host) }
    }

    deinit { stop() }

    /// The moment `uptime` (a `NTPClock.nanosecondsNow()` reading) is on this clock.
    static func time(uptime: UInt64) -> PTPTimestamp { PTPTimestamp(totalNanoseconds: uptime) }

    /// Who is told the time from now on.
    public func setPeers(_ peers: [Peer]) {
        state.withLock { $0.peers = peers }
    }

    public var peers: [Peer] { state.withLock { $0.peers } }

    /// One eighth of a second's work: an Announce if one is due, then a Sync and its Follow_Up, to every peer.
    public func tick() {
        let (peers, sync, announce) = state.withLock { s -> ([Peer], UInt16, UInt16?) in
            let due = s.ticks % Self.ticksPerAnnounce == 0
            s.ticks += 1
            let sync = s.syncs
            s.syncs &+= 1
            guard due else { return (s.peers, sync, nil) }
            let announce = s.announces
            s.announces &+= 1
            return (s.peers, sync, announce)
        }
        for peer in peers {
            if let announce {
                general.send(PTPMessage.announce(clock: identity, sequence: announce), to: peer.host, port: peer.generalPort)
            }
            event.send(PTPMessage.sync(clock: identity, sequence: sync), to: peer.host, port: peer.eventPort)
            let sent = PTPTimestamp(totalNanoseconds: now())
            general.send(PTPMessage.followUp(clock: identity, sequence: sync, sent: sent), to: peer.host, port: peer.generalPort)
        }
    }

    /// Ticks every eighth of a second from now until `stop()`. Once started, starting again does nothing.
    public func start() {
        state.withLock { s in
            guard s.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            s.timer = timer
            timer.resume()
        }
    }

    /// Stops ticking and gives the ports back. The clock is of no more use.
    public func stop() {
        let timer = state.withLock { s -> DispatchSourceTimer? in
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        event.close()
        general.close()
    }

    /// A datagram on the event port: a peer's Delay_Req is answered with the moment it was read, to the general port
    /// of the peer at that address (the standard's port when the address is not a peer's).
    private func asked(_ data: Data, from host: String) {
        let received = PTPTimestamp(totalNanoseconds: now())
        guard let request = PTPMessage.delayRequest(data), request.clock != identity else { return }
        let port = state.withLock { $0.peers.first { $0.host == host }?.generalPort } ?? PTPMessage.generalPort
        general.send(PTPMessage.delayResponse(clock: identity, to: request, received: received), to: host, port: port)
    }
}
