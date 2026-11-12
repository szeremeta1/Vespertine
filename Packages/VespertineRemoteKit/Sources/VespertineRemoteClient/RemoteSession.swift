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

    /// How this phone introduces itself (shown in the Mac's list of paired phones).
    @ObservationIgnored public var clientName: String
    /// Makes a new connection to the Mac (nil while it can't be found: its address can change between connections).
    @ObservationIgnored private let makeChannel: @MainActor () -> (any RemoteChannel)?
    @ObservationIgnored private var link: (any RemoteChannel)?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0

    /// A session with a paired Mac; `resolve` finds the Mac's current address from its server ID.
    public init(pairing: SavedPairing, clientName: String, resolve: @escaping @MainActor (String) -> NWEndpoint?) {
        self.pairing = pairing
        self.clientName = clientName
        makeChannel = {
            resolve(pairing.serverID).map { RemoteLink(endpoint: $0, key: pairing.presharedKey) }
        }
    }

    /// A session over channels `makeChannel` makes (the demo Mac, tests).
    public init(pairing: SavedPairing, clientName: String, makeChannel: @escaping @MainActor () -> (any RemoteChannel)?) {
        self.pairing = pairing
        self.clientName = clientName
        self.makeChannel = makeChannel
    }

    /// Whether this is the built-in demo rather than a real Mac.
    public var isDemo: Bool { pairing.serverID == DemoMac.serverID }

    public var isConnected: Bool { phase == .connected }

    /// Connects now (again), if not connected.
    public func connect() {
        retry?.cancel()
        retry = nil
        guard link == nil, phase != .closed else { return }
        guard let link = makeChannel() else {
            phase = .unreachable("")
            scheduleRetry()
            return
        }
        phase = .connecting
        self.link = link
        link.onPush = { [weak self] message in self?.received(message) }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, self.link === link else { return }
            self.link = nil
            if self.phase == .connected || self.phase == .connecting {
                self.phase = .unreachable(reason ?? "")
                self.scheduleRetry()
            }
        }
        Task {
            do {
                try await link.open(timeout: .seconds(10))
                let reply = try await link.request(.hello(device: pairing.device, name: clientName, protocolVersion: RemoteProtocol.version), timeout: .seconds(15))
                guard self.link === link else { return }
                if case .welcome(let info) = reply {
                    server = info
                    attempts = 0
                    phase = .connected
                } else {
                    link.close()
                }
            } catch {
                // onClose (or the goodbye) has set the phase.
                if self.link === link { link.close() }
            }
        }
    }

    /// Disconnects for good (the app switched Mac or forgot this one).
    public func close() {
        phase = .closed
        retry?.cancel()
        retry = nil
        let link = self.link
        self.link = nil
        link?.close()
    }

    /// Drops the connection while the app is in the background; `connect()` resumes it.
    public func suspend() {
        retry?.cancel()
        retry = nil
        let link = self.link
        self.link = nil
        link?.close()
        if phase == .connected || phase == .connecting { phase = .unreachable("") }
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
        case .player(let state): player = state
        case .queue(let state): queue = state
        case .outputs(let state): outputs = state
        case .goodbye(let reason):
            switch reason {
            case .notPaired, .deviceRemoved: phase = .unpaired
            case .protocolMismatch: phase = .incompatible
            case .serverStopped: phase = .unreachable("")
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
            reply = try await link.request(.pair(name: clientName, protocolVersion: RemoteProtocol.version))
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
