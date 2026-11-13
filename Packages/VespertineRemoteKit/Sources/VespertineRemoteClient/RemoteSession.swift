//
// Vespertine Remote: a paired phone's session with one Mac: signs in, keeps the Mac's pushed state (playback, queue,
// outputs), sends commands, and reconnects when the network drops.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Observation
import VespertineRemoteProtocol

@MainActor
@Observable
public final class RemoteSession {
    public enum Phase: Equatable, Sendable {
        /// Connecting or signing in.
        case connecting
        case connected
        /// Lost the Mac (asleep, off the network, remote switched off); retrying on its own.
        case unreachable(String)
        /// The Mac doesn't know this phone any more (removed in Settings › Remote): pair again.
        case unpaired
        /// The Mac's Vespertine speaks another protocol version: one of the two needs updating.
        case incompatible
        /// Closed by the app.
        case closed
    }

    public let pairing: SavedPairing
    public private(set) var phase: Phase = .connecting
    public private(set) var server: ServerInfo?
    public private(set) var player: PlayerState?
    public private(set) var queue: QueueState?
    public private(set) var outputs: OutputsState?

    /// The volume as a slider moves it: sent while it's dragged, and shown where the finger put it.
    @ObservationIgnored public private(set) lazy var volume = LiveLevel { [weak self] level in
        await self?.send(.setVolume(level: level))
    }

    /// How the Mac was reached, while connected (nil for the demo).
    public private(set) var route: RemoteRoute.Kind?
    /// When the phase last changed (for "trying again since…").
    public private(set) var phaseSince = Date()

    /// How this phone introduces itself (shown in the Mac's list of paired phones).
    @ObservationIgnored public var clientName: String
    /// Called once signed in, with the address the Mac answered at (to remember for next time).
    @ObservationIgnored public var onConnected: (@MainActor (RemoteRoute.Kind?, RemoteAddress?) -> Void)?
    /// How long a second way of reaching the Mac waits for the first before starting too.
    @ObservationIgnored public var stagger: Duration = .milliseconds(1200)

    private struct Candidate {
        var kind: RemoteRoute.Kind?
        var channel: any RemoteChannel
    }

    /// Makes new connections to the Mac, one per way of reaching it, best first (none while it can't be found: its
    /// address can change between connections).
    @ObservationIgnored private let makeChannels: @MainActor () -> [Candidate]
    @ObservationIgnored private var link: (any RemoteChannel)?
    /// The connections being tried now.
    @ObservationIgnored private var racing: [any RemoteChannel] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0

    /// A session with a paired Mac; `routes` lists the ways to reach it now, best first. They're tried together,
    /// each a little after the one before, and the first to answer wins.
    public init(pairing: SavedPairing, clientName: String, routes: @escaping @MainActor () -> [RemoteRoute]) {
        self.pairing = pairing
        self.clientName = clientName
        makeChannels = {
            routes().map { Candidate(kind: $0.kind, channel: RemoteLink(endpoint: $0.endpoint, key: pairing.presharedKey)) }
        }
    }

    /// A session with a paired Mac; `resolve` finds the Mac's current address from its server ID.
    public convenience init(pairing: SavedPairing, clientName: String, resolve: @escaping @MainActor (String) -> NWEndpoint?) {
        self.init(pairing: pairing, clientName: clientName, routes: {
            resolve(pairing.serverID).map { [RemoteRoute(kind: .nearby, endpoint: $0)] } ?? []
        })
    }

    /// A session over channels `makeChannel` makes (the demo Mac, tests).
    public init(pairing: SavedPairing, clientName: String, makeChannel: @escaping @MainActor () -> (any RemoteChannel)?) {
        self.pairing = pairing
        self.clientName = clientName
        makeChannels = { makeChannel().map { [Candidate(kind: nil, channel: $0)] } ?? [] }
    }

    /// Whether this is the built-in demo rather than a real Mac.
    public var isDemo: Bool { pairing.serverID == DemoMac.serverID }

    public var isConnected: Bool { phase == .connected }
    /// Whether the Mac speaks protocol 2: it can stream songs to this phone (an older Mac only takes commands).
    public var canStream: Bool { (server?.protocolVersion ?? 1) >= RemoteProtocol.streamVersion }

    private func setPhase(_ new: Phase) {
        guard phase != new else { return }
        phase = new
        phaseSince = Date()
        if new != .connected { volume.reset() }
        if new != .connected { route = nil }
    }

    /// Connects now (again), if not connected.
    public func connect() {
        retry?.cancel()
        retry = nil
        guard link == nil, racing.isEmpty, phase != .closed else { return }
        let candidates = makeChannels()
        guard !candidates.isEmpty else {
            setPhase(.unreachable(""))
            scheduleRetry()
            return
        }
        setPhase(.connecting)
        generation += 1
        let generation = generation
        racing = candidates.map(\.channel)
        Task {
            let winner = await firstToOpen(candidates)
            guard generation == self.generation, phase != .closed else {
                winner?.channel.close()
                return
            }
            racing = []
            guard let winner else {
                setPhase(.unreachable(""))
                scheduleRetry()
                return
            }
            await signIn(winner)
        }
    }

    /// Opens the candidates (the first now, each next one `stagger` later or as soon as those before it have failed)
    /// and returns the first that opens; the rest are closed. nil when none opens.
    private func firstToOpen(_ candidates: [Candidate]) async -> Candidate? {
        let stagger = stagger
        let race = Race()
        let winner = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            for (index, candidate) in candidates.enumerated() {
                Task { @MainActor in
                    let start = ContinuousClock.now
                    while index > 0, !race.won, race.failed < index, ContinuousClock.now - start < stagger * index {
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    var opened = false
                    if !race.won {
                        opened = (try? await candidate.channel.open(timeout: .seconds(10))) != nil
                    }
                    if opened, !race.won {
                        race.won = true
                        continuation.resume(returning: index)
                        return
                    }
                    candidate.channel.close()
                    race.failed += 1
                    if race.failed == candidates.count, !race.won {
                        race.won = true
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return winner.map { candidates[$0] }
    }

    @MainActor private final class Race {
        var won = false
        var failed = 0
    }

    private func signIn(_ candidate: Candidate) async {
        let link = candidate.channel
        self.link = link
        link.onPush = { [weak self] message in self?.received(message) }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link else { return }
            self.lost(link, reason: reason)
        }
        do {
            let reply = try await link.request(.hello(device: pairing.device, name: clientName, protocolVersion: RemoteProtocol.minimumVersion, highestProtocolVersion: RemoteProtocol.version), timeout: .seconds(15))
            guard self.link === link else { return }
            if case .welcome(let info) = reply {
                server = info
                attempts = 0
                setPhase(.connected)
                route = candidate.kind
                onConnected?(candidate.kind, link.remoteAddress)
            } else {
                link.close()
                lost(link, reason: nil)
            }
        } catch {
            // Closed before or while signing in (a goodbye has set its own phase).
            link.close()
            lost(link, reason: nil)
        }
    }

    /// The connection in use ended.
    private func lost(_ link: any RemoteChannel, reason: String?) {
        guard self.link === link else { return }
        self.link = nil
        if phase == .connected || phase == .connecting {
            setPhase(.unreachable(reason ?? ""))
            scheduleRetry()
        }
    }

    /// The network changed (Wi-Fi came back, a VPN connected): try now rather than at the next retry.
    public func networkChanged() {
        guard phase != .closed, phase != .unpaired, phase != .incompatible, !isConnected, link == nil, racing.isEmpty else { return }
        attempts = 0
        connect()
    }

    private func abandonAttempt() {
        generation += 1
        let trying = racing
        racing = []
        for channel in trying { channel.close() }
    }

    /// Disconnects for good (the app switched Mac or forgot this one).
    public func close() {
        setPhase(.closed)
        retry?.cancel()
        retry = nil
        abandonAttempt()
        let link = self.link
        self.link = nil
        link?.close()
    }

    /// Drops the connection while the app is in the background; `connect()` resumes it.
    public func suspend() {
        retry?.cancel()
        retry = nil
        abandonAttempt()
        let link = self.link
        self.link = nil
        link?.close()
        if phase == .connected || phase == .connecting { setPhase(.unreachable("")) }
    }

    private func scheduleRetry() {
        guard retry == nil, phase != .closed, phase != .unpaired, phase != .incompatible else { return }
        attempts += 1
        let delay = min(Double(1 << min(attempts, 4)), 15)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.connect()
        }
    }

    private func received(_ message: ServerMessage) {
        switch message {
        case .player(let state):
            // Another output has its own level: nothing held from the one before applies to it.
            if let old = player, old.output != state.output || old.volume.route != state.volume.route { volume.reset() }
            player = state
            volume.reported(state.volume.level)
        case .queue(let state): queue = state
        case .outputs(let state): outputs = state
        case .goodbye(let reason):
            switch reason {
            case .notPaired, .deviceRemoved: setPhase(.unpaired)
            case .protocolMismatch: setPhase(.incompatible)
            case .serverStopped: setPhase(.unreachable(""))
            }
            let link = self.link
            self.link = nil
            link?.close()
            scheduleRetry()
        case .reply:
            break
        }
    }

    /// Sends a command and returns the Mac's reply (`.failed` with a reason when it couldn't be sent).
    @discardableResult
    public func send(_ command: RemoteCommand) async -> RemoteReply {
        guard let link, phase == .connected else {
            return .failed(reason: "")
        }
        do {
            return try await link.request(command, timeout: .seconds(15))
        } catch {
            return .failed(reason: "")
        }
    }

    // MARK: Pairing

    public enum PairingError: Error, Equatable, Sendable {
        /// The code or QR link was wrong or had expired (the Mac refused the key).
        case refused
        /// The Mac said no, with its reason.
        case failed(String)
        case unreachable
    }

    /// Pairs with the Mac at `endpoint` using the secret from its QR code (`viaLink`) or the 6-digit code it shows.
    public static func pair(endpoint: NWEndpoint, serverID: String, secret: String, viaLink: Bool, clientName: String) async throws(PairingError) -> SavedPairing {
        let identity = viaLink ? RemoteProtocol.pairingLinkIdentity : RemoteProtocol.pairingCodeIdentity
        let key = RemoteTransport.PresharedKey(identity: identity, key: PairingKey.derive(secret: secret, serverID: serverID))
        let link = RemoteLink(endpoint: endpoint, key: key)
        defer { link.close() }
        do {
            try await link.open()
        } catch {
            throw .refused
        }
        let reply: RemoteReply
        do {
            reply = try await link.request(.pair(name: clientName, protocolVersion: RemoteProtocol.minimumVersion, highestProtocolVersion: RemoteProtocol.version))
        } catch {
            throw .unreachable
        }
        switch reply {
        case .paired(let device, let key, let server):
            return SavedPairing(serverID: server.serverID, name: server.name, device: device, key: key)
        case .failed(let reason):
            throw .failed(reason)
        default:
            throw .failed("")
        }
    }
}
#endif
