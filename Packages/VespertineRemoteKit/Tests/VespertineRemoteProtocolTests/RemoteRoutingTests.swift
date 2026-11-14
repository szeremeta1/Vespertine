//
// Vespertine Remote: finding a paired Mac by every route it told, and getting the connection back when the network changes.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Testing
import VespertineRemoteClient
@testable import VespertineRemoteProtocol

/// A Mac that welcomes a phone with the addresses it can be reached at, counts what it is asked, and can stop answering pings
/// (a connection that died without either end being told).
private final class RoutedMac: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "remote-routing-test.server")
    private let lock = NSLock()
    private var _commands: [RemoteCommand] = []
    private var _answersPings = true
    var commands: [RemoteCommand] { lock.withLock { _commands } }
    var hellos: Int { commands.filter { if case .hello = $0 { true } else { false } }.count }
    var answersPings: Bool {
        get { lock.withLock { _answersPings } }
        set { lock.withLock { _answersPings = newValue } }
    }

    init(key: RemoteTransport.PresharedKey, addresses: [RemoteAddress]? = nil) throws {
        listener = try NWListener(using: RemoteTransport.parameters(keys: [key]), on: .any)
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            func send(_ message: ServerMessage) {
                let data = try! RemoteProtocol.encoder().encode(message)
                connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { _ in })
            }
            func receive() {
                connection.receiveMessage { content, _, _, error in
                    guard error == nil, let content, let message = try? RemoteProtocol.decoder().decode(ClientMessage.self, from: content), let self else {
                        connection.cancel(); return
                    }
                    self.lock.withLock { self._commands.append(message.command) }
                    switch message.command {
                    case .hello:
                        send(.reply(id: message.id, result: .welcome(ServerInfo(name: "Routed Mac", serverID: "S-TEST", appVersion: "1.2.0", addresses: addresses))))
                    case .ping:
                        if self.answersPings { send(.reply(id: message.id, result: .ok)) }
                    default:
                        send(.reply(id: message.id, result: .ok))
                    }
                    receive()
                }
            }
            receive()
        }
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
            let resumed = NSLock()
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [listener] state in
                resumed.withLock {
                    guard !done else { return }
                    switch state {
                    case .ready: done = true; continuation.resume(returning: listener.port!)
                    case .failed(let error): done = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return condition()
}

@Suite(.serialized) @MainActor struct Routing {
    private static let key = RemoteTransport.PresharedKey(identity: "phone-test", key: Data(repeating: 0x5A, count: 32))

    private static func saved(address: RemoteAddress? = nil, lastKnown: RemoteAddress? = nil, advertised: [RemoteAddress]? = nil) -> SavedPairing {
        SavedPairing(serverID: "S-TEST", name: "Test Mac", device: key.identity, key: key.key, pairedAt: Date(timeIntervalSince1970: 0),
                     address: address, lastKnown: lastKnown, advertised: advertised)
    }

    @Test func whatTheMacToldIsKeptAndTriedFromAway() {
        let home = RemoteAddress(host: "192.168.1.24", port: 52718)
        let tail = RemoteAddress(host: "100.101.102.103", port: 52718)
        let name = RemoteAddress(host: "studio.tail1a2b3.ts.net", port: 52718)
        let info = ServerInfo(name: "Studio Mac", serverID: "S-TEST", appVersion: "1.2.0", addresses: [home, tail, name])
        let paired = Self.saved(lastKnown: home).noting(server: info)
        #expect(paired.name == "Studio Mac")
        #expect(paired.advertised == [home, tail, name])
        // Home first, then Tailscale; the address it last answered at is one of them already.
        #expect(paired.savedAddresses.prefix(3) == [home, tail, name])
        #expect(paired.routes(nearby: nil).prefix(3).map(\.kind) == [.advertised, .advertised, .advertised])
        #expect(paired.hasRouteFromAway)
        #expect(paired.hasTailscaleRoute)
        // Nothing but a home address known: nothing works from away.
        #expect(!Self.saved(lastKnown: home).hasRouteFromAway)
        // An older Mac tells no addresses: what the phone knew stays.
        let silent = ServerInfo(name: "Studio Mac", serverID: "S-TEST", appVersion: "1.1.4")
        #expect(paired.noting(server: silent).advertised == [home, tail, name])
        // The Mac moved to another port: every address it told moves with it.
        #expect(paired.noting(advertisedPort: 47_823).advertised?.map(\.port) == [47_823, 47_823, 47_823])
    }

    @Test func aPairingSavedBeforeAddressesWereToldStillLoads() throws {
        let old = #"{"serverID":"S","name":"Mac","device":"d","key":"WlpaWg==","pairedAt":0}"#
        let pairing = try JSONDecoder().decode(SavedPairing.self, from: Data(old.utf8))
        #expect(pairing.advertised == nil)
        #expect(pairing.savedAddresses.isEmpty)
    }

    @Test func routesStartTogetherWithBonjourALittleAhead() {
        let bonjour = RemoteRoute(kind: .nearby, endpoint: .hostPort(host: "127.0.0.1", port: 1))
        let home = RemoteRoute(kind: .advertised, address: RemoteAddress(host: "192.168.1.24", port: 1))!
        let tail = RemoteRoute(kind: .advertised, address: RemoteAddress(host: "100.101.102.103", port: 1))!
        #expect(bonjour.headStart == .zero)
        #expect(home.headStart < tail.headStart)
        // Everything is under way within half a second: no route waits its turn behind a dead one.
        #expect(tail.headStart <= .milliseconds(500))
    }

    @Test func theNetworkInUseIsReadFromTheAddressThatAnswered() {
        #expect(RemoteSession.reach(route: .nearby, address: nil) == .sameNetwork)
        #expect(RemoteSession.reach(route: .advertised, address: RemoteAddress(host: "192.168.1.24", port: 1)) == .sameNetwork)
        #expect(RemoteSession.reach(route: .advertised, address: RemoteAddress(host: "100.101.102.103", port: 1)) == .tailscale)
        // Bonjour over a tailnet still runs over Tailscale.
        #expect(RemoteSession.reach(route: .nearby, address: RemoteAddress(host: "fd7a:115c:a1e0::9", port: 1)) == .tailscale)
        #expect(RemoteSession.reach(route: .address, address: RemoteAddress(host: "mac.example.org", port: 1)) == .elsewhere)
        #expect(RemoteSession.reach(route: nil, address: nil) == nil)
    }

    @Test func theSessionLearnsTheMacsAddressesAndTellsItsLanguage() async throws {
        let told = [RemoteAddress(host: "192.168.1.24", port: 52718), RemoteAddress(host: "100.101.102.103", port: 52718)]
        let mac = try RoutedMac(key: Self.key, addresses: told)
        let port = try await mac.start()
        let session = RemoteSession(pairing: Self.saved(), clientName: "Test phone") {
            [RemoteRoute(kind: .nearby, endpoint: .hostPort(host: "127.0.0.1", port: port))]
        }
        session.language = "de"
        session.connect()
        #expect(await waitUntil { session.isConnected })
        #expect(session.server?.addresses == told)
        #expect(session.reached?.port == port.rawValue)
        #expect(await waitUntil { mac.commands.contains(.setLanguage(code: "de")) })
        session.close()
        #expect(session.reached == nil)
    }

    @Test func aConnectionThatSurvivedTheNetworkChangeIsKept() async throws {
        let mac = try RoutedMac(key: Self.key)
        let port = try await mac.start()
        let session = RemoteSession(pairing: Self.saved(), clientName: "Test phone") {
            [RemoteRoute(kind: .nearby, endpoint: .hostPort(host: "127.0.0.1", port: port))]
        }
        session.probeTimeout = .milliseconds(400)
        session.connect()
        #expect(await waitUntil { session.isConnected })
        session.networkChanged()
        #expect(await waitUntil { mac.commands.contains(.ping) })
        try await Task.sleep(for: .milliseconds(600))
        #expect(session.isConnected)
        #expect(mac.hellos == 1)
        session.close()
    }

    @Test func aConnectionThatDiedWithTheNetworkIsMadeAgainAtOnceOverAnotherRoute() async throws {
        // Wi-Fi gave way to cellular: the old connection is still "open" but nothing comes back on it. The other Mac
        // stands for the same Mac reached another way (its Tailscale address).
        let home = try RoutedMac(key: Self.key)
        let homePort = try await home.start()
        let away = try RoutedMac(key: Self.key)
        let awayPort = try await away.start()
        nonisolated(unsafe) var atHome = true
        let session = RemoteSession(pairing: Self.saved(), clientName: "Test phone") {
            atHome ? [RemoteRoute(kind: .nearby, endpoint: .hostPort(host: "127.0.0.1", port: homePort))]
                   : [RemoteRoute(kind: .advertised, endpoint: .hostPort(host: "127.0.0.1", port: awayPort), address: RemoteAddress(host: "100.101.102.103", port: awayPort.rawValue))]
        }
        session.probeTimeout = .milliseconds(300)
        session.quickReconnectAfter = .zero
        session.connect()
        #expect(await waitUntil { session.isConnected })
        #expect(session.route == .nearby)

        atHome = false
        home.answersPings = false
        let started = ContinuousClock.now
        session.networkChanged()
        #expect(await waitUntil { session.isConnected && session.route == .advertised })
        // Back within a couple of seconds, with no retry delay in between.
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(away.hellos == 1)
        #expect(await session.send(.next) == .ok)
        session.close()
    }

    @Test func aMacThatHangsUpStraightAwayIsNotHammered() async throws {
        // A connection that drops moments after signing in waits like any failed attempt before the next try.
        let mac = try RoutedMac(key: Self.key)
        let port = try await mac.start()
        let session = RemoteSession(pairing: Self.saved(), clientName: "Test phone") {
            [RemoteRoute(kind: .nearby, endpoint: .hostPort(host: "127.0.0.1", port: port))]
        }
        session.probeTimeout = .milliseconds(200)
        session.quickReconnectAfter = .seconds(60)
        session.connect()
        #expect(await waitUntil { session.isConnected })
        mac.listener.cancel()
        mac.answersPings = false
        session.networkChanged()
        // The dead link is still noticed and dropped (a probe that fails never waits), and the session keeps trying.
        #expect(await waitUntil { !session.isConnected })
        session.close()
    }
}
#endif

#if canImport(Network)
@Suite struct ReachTroubleTests {
    private func saved(_ addresses: [RemoteAddress]?, typed: RemoteAddress? = nil) -> SavedPairing {
        SavedPairing(serverID: "S", name: "Mac", device: "d", key: Data(), address: typed, advertised: addresses)
    }
    private let home = RemoteAddress(host: "192.168.1.24", port: 52718)
    private let tail = RemoteAddress(host: "100.101.102.103", port: 52718)

    @Test func theReasonNothingAnswersIsAsExactAsThePhoneCanTell() {
        #expect(saved([home, tail]).trouble(online: false, nearby: false, tailscaleOn: true) == .offline)
        // On the Mac's network and it doesn't answer: asleep, or Vespertine isn't open.
        #expect(saved([home]).trouble(online: true, nearby: true, tailscaleOn: false) == .notAnswering)
        // Away, and the Mac only ever told a home address.
        #expect(saved([home]).trouble(online: true, nearby: false, tailscaleOn: false) == .notOnThisNetwork)
        #expect(saved(nil).trouble(online: true, nearby: false, tailscaleOn: true) == .notOnThisNetwork)
        // The Mac is on Tailscale; this device isn't.
        #expect(saved([home, tail]).trouble(online: true, nearby: false, tailscaleOn: false) == .tailscaleOff)
        // Both are, and still nothing: the Mac is asleep or off.
        #expect(saved([home, tail]).trouble(online: true, nearby: false, tailscaleOn: true) == .notAnswering)
        // A typed public address doesn't need Tailscale.
        #expect(saved([home, tail], typed: RemoteAddress(host: "mac.example.org", port: 9)).trouble(online: true, nearby: false, tailscaleOn: false) == .notAnswering)
    }
}
#endif
