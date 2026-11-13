//
// Vespertine: the remote server. Off until Settings › Remote turns it on; then it advertises this Mac on Bonjour, lets a
// phone pair while the pairing window is open, and serves paired phones over TLS (a pre-shared key per phone) with length-framed JSON messages.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything here runs on the main queue: the listener, every connection and the push loop. The traffic is small (a few
// JSON messages a second at most); covers are read off the main thread.
//

import Foundation
import Network
import Observation
import SystemConfiguration
import VespertineRemoteProtocol

@Observable
final class RemoteServer {
    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    /// The window in which a phone can pair: the QR link and the code to type, both good until `expires`.
    struct PairingWindow: Equatable {
        var link: PairingLink
        var code: String
        var expires: Date
    }

    private(set) var status: Status = .off
    private(set) var pairing: PairingWindow?
    /// The paired phones connected right now (their device IDs).
    private(set) var connected: Set<String> = []
    /// The phone that paired last, while the pairing sheet thanks it (cleared when a new window opens).
    private(set) var justPaired: String?

    let store: RemoteStore
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var listener: NWListener?
    /// Which port the next listener binds: set when the server starts, and walked on when a port is taken.
    private enum PortPlan {
        /// This port is ours now: a restart (new keys) binds it again, a few times over if the last listener hasn't let go.
        case held(UInt16, retries: Int)
        /// Ports still to try, the first next. The first (the saved one) is tried again a few times before it counts
        /// as taken: the listener that had it a moment ago (before a restart of the server) may not have let go yet.
        case trying([UInt16], retriesLeft: Int)
        /// Every candidate was taken: let the system choose.
        case system
    }
    @ObservationIgnored private var portPlan: PortPlan?
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private let preferredPort: UInt16
    @ObservationIgnored private var clients: [ObjectIdentifier: RemoteClient] = [:]
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored private var failedPairingHandshakes = 0
    @ObservationIgnored private let keepAwake = RemoteKeepAwake()
    @ObservationIgnored let web = RemoteWebServer()
    /// The web remote's port while it's on (Settings shows the address).
    private(set) var webPort: UInt16?
    @ObservationIgnored private var queueSignature: RemoteBridge.QueueSignature?
    @ObservationIgnored private var queueRevision = 0
    @ObservationIgnored private var lastQueue: QueueState?
    @ObservationIgnored private var lastOutputs: OutputsState?

    /// How long a pairing window stays open.
    static let pairingDuration: Duration = .seconds(120)
    /// Failed handshakes while pairing (wrong codes) after which the window closes, so a code can't be guessed.
    static let pairingAttempts = 10

    /// How often a port we held (or saved) is tried again before it counts as taken, and how long it waits between.
    static let restartTries = 6
    static let restartDelay: Duration = .milliseconds(150)

    init(store: RemoteStore, preferredPort: UInt16 = RemotePort.preferred) {
        self.store = store
        self.preferredPort = preferredPort
        web.server = self
        web.onPortChange = { [weak self] port in self?.webPort = port }
    }

    var isRunning: Bool { if case .running = status { true } else { false } }

    var serverInfo: ServerInfo {
        ServerInfo(name: Self.computerName, serverID: store.serverID,
                   appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    /// This Mac's Bonjour host name ("Living-Room-Mac.local"), for the web remote's address.
    static var localHostName: String {
        ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost") + ".local"
    }

    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    // MARK: On and off

    /// Brings the server and the keep-awake hold in line with the switches.
    func apply() {
        if store.enabled {
            if listener == nil { startListener() }
            if store.webEnabled { web.start() } else { web.stop() }
        } else {
            stop()
        }
        keepAwake.hold(store.enabled && store.keepAwake)
    }

    private func stop() {
        endPairing()
        for client in clients.values { client.close(saying: .serverStopped) }
        clients.removeAll()
        connected.removeAll()
        restart?.cancel()
        restart = nil
        listener?.cancel()
        listener = nil
        portPlan = nil
        web.stop()
        pushTask?.cancel()
        pushTask = nil
        status = .off
    }

    /// The keys the listener accepts: every paired phone's, and the pairing keys while a window is open.
    var acceptedKeys: [RemoteTransport.PresharedKey] {
        var keys = store.devices.filter { !$0.isWeb }.map { RemoteTransport.PresharedKey(identity: $0.id, key: $0.key) }
        if let pairing {
            keys.append(.init(identity: RemoteProtocol.pairingLinkIdentity, key: PairingKey.derive(secret: pairing.link.secret, serverID: store.serverID)))
            keys.append(.init(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: pairing.code, serverID: store.serverID)))
        }
        return keys
    }

    /// (Re)starts the listener with the current keys. Connections already open stay open; the port stays the same
    /// (it is the one the phones know), and Bonjour says where it is either way.
    private func startListener() {
        restart?.cancel()
        restart = nil
        listener?.cancel()
        listener = nil
        let keys = acceptedKeys
        guard !keys.isEmpty else {
            // Nothing could connect yet: no paired phone and no pairing window. Advertise anyway, so the phone app can
            // list this Mac and say how to pair, but with a key nobody has.
            return startListener(keys: [.init(identity: "vespertine-nobody", key: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))])
        }
        startListener(keys: keys)
    }

    /// The text record Bonjour carries for this Mac, with the port it listens on (nil before the system has chosen one).
    static func txtRecord(info: ServerInfo, port: UInt16?) -> NWTXTRecord {
        var record = NWTXTRecord([
            RemoteProtocol.TXTKey.serverID: info.serverID,
            RemoteProtocol.TXTKey.protocolVersion: String(RemoteProtocol.version),
            RemoteProtocol.TXTKey.appVersion: info.appVersion,
        ])
        if let port { record[RemoteProtocol.TXTKey.port] = String(port) }
        return record
    }

    private func startListener(keys: [RemoteTransport.PresharedKey]) {
        let plan = portPlan ?? .trying(RemotePort.candidates(saved: store.port, preferred: preferredPort), retriesLeft: Self.restartTries)
        portPlan = plan
        let wanted: UInt16?
        switch plan {
        case .held(let port, _): wanted = port
        case .trying(let ports, _): wanted = ports.first
        case .system: wanted = nil
        }
        let parameters = RemoteTransport.parameters(keys: keys)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            if let wanted, let port = NWEndpoint.Port(rawValue: wanted) {
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            return portUnavailable(error)
        }
        let info = serverInfo
        listener.service = NWListener.Service(type: RemoteProtocol.serviceType, txtRecord: Self.txtRecord(info: info, port: wanted))
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state, listener) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        if case .held = plan {} else { status = .starting }
        listener.start(queue: .main)
        if pushTask == nil {
            pushTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.push()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State, _ listener: NWListener) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            let port = listener.port?.rawValue ?? 0
            portPlan = .held(port, retries: 0)
            if port != 0 { store.setPort(port) }
            status = .running(port: port)
        case .failed(let error):
            self.listener = nil
            listener.cancel()
            portUnavailable(error)
        case .waiting(let error):
            // A port another program holds can show up as waiting rather than failed: either way, try the next.
            if case .posix(.EADDRINUSE) = error {
                self.listener = nil
                listener.cancel()
                portUnavailable(error)
            } else {
                status = .failed(error.localizedDescription)
            }
        default:
            break
        }
    }

    /// The port the listener tried couldn't be bound. A port we held a moment ago is tried again shortly (the last
    /// listener may not have let go yet); a candidate that's taken gives way to the next; after the last, the system chooses.
    private func portUnavailable(_ error: any Error) {
        func again(_ next: PortPlan) {
            portPlan = next
            restart = Task { [weak self] in
                try? await Task.sleep(for: Self.restartDelay)
                guard !Task.isCancelled, let self, self.store.enabled, self.listener == nil else { return }
                self.startListener()
            }
        }
        switch portPlan {
        case .held(let port, let retries):
            if retries < Self.restartTries {
                again(.held(port, retries: retries + 1))
            } else {
                // Taken since: the rest of the candidates, without this one.
                portPlan = .trying(RemotePort.candidates(saved: nil, preferred: preferredPort).filter { $0 != port }, retriesLeft: 0)
                startListener()
            }
        case .trying(let ports, let retriesLeft):
            if retriesLeft > 0 {
                again(.trying(ports, retriesLeft: retriesLeft - 1))
                return
            }
            let rest = Array(ports.dropFirst())
            portPlan = rest.isEmpty ? .system : .trying(rest, retriesLeft: 0)
            startListener()
        case .system, nil:
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Pairing

    /// Opens a pairing window (a new QR link and code) for `pairingDuration`, or until a phone pairs.
    func beginPairing() {
        guard store.enabled else { return }
        pairing = PairingWindow(link: PairingLink(serverID: store.serverID, name: Self.computerName, secret: PairingSecret.makeLinkSecret()),
                                code: PairingSecret.makeTypedCode(), expires: .now.addingTimeInterval(120))
        justPaired = nil
        failedPairingHandshakes = 0
        startListener()
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.pairingDuration)
            guard !Task.isCancelled else { return }
            self?.endPairing()
        }
    }

    func endPairing() {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        guard pairing != nil else { return }
        pairing = nil
        if store.enabled, listener != nil { startListener() }
    }

    /// A phone asked to pair over a pairing key: it gets its own key and device ID.
    fileprivate func pair(name: String) -> RemoteReply {
        guard pairing != nil else {
            return .failed(reason: String(localized: "Pairing has ended on the Mac. Open Settings › Remote there and choose Pair a Phone again.", comment: "Remote control: a phone tried to pair after the pairing window closed."))
        }
        let credential = DeviceCredential.make()
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let displayName = cleanName.isEmpty ? String(localized: "Phone", comment: "Remote control: name of a paired phone that didn't say its name.") : cleanName
        store.add(PairedRemote(id: credential.device, name: displayName, key: credential.key, pairedAt: .now, lastSeen: nil))
        justPaired = displayName
        // One phone per window; the listener restarts with the new key and without the pairing keys.
        endPairing()
        return .paired(device: credential.device, key: credential.key, server: serverInfo)
    }

    /// Unpairs a phone: its key goes, and its connection (if any) is closed.
    func remove(_ id: String) {
        store.remove(id)
        for client in clients.values where client.device == id { client.close(saying: .deviceRemoved) }
        web.disconnect(device: id)
        connected.remove(id)
        if listener != nil { startListener() }
    }

    enum BrowserPairingFailure: Error {
        case notPairing, wrongCode

        var message: String {
            switch self {
            case .notPairing: String(localized: "Pairing has ended on the Mac. Open Settings › Remote there and choose Pair a Phone again.", comment: "Remote control: a phone tried to pair after the pairing window closed.")
            case .wrongCode: String(localized: "That code didn’t work. Check the code on the Mac, or choose Pair a Phone there again for a new one.", comment: "Web remote: the code typed in the browser is wrong.")
            }
        }
    }

    /// A browser typed the pairing code: it gets a token for its cookie (stored here only as a hash).
    func pairBrowser(code: String, name: String?, userAgent: String? = nil, maxTouchPoints: Int? = nil) -> Result<String, BrowserPairingFailure> {
        guard let pairing else { return .failure(.notPairing) }
        let typed = PairingSecret.normalizedCode(code)
        guard RemoteWebServer.constantTimeEqual(Data(typed.utf8), Data(pairing.code.utf8)) else {
            failedPairingHandshakes += 1
            if failedPairingHandshakes >= Self.pairingAttempts { endPairing() }
            return .failure(.wrongCode)
        }
        let token = PairingSecret.makeLinkSecret() + PairingSecret.makeLinkSecret()
        // Named from its user agent ("Chrome on Mac"); a name the page sent is the fallback.
        let cleanName = userAgent.flatMap({ RemoteBrowserName.name(userAgent: $0, maxTouchPoints: maxTouchPoints) })
            ?? String((name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let displayName = cleanName.isEmpty ? String(localized: "Web browser", comment: "Settings › Remote: name of a paired web browser.") : cleanName
        let id = "web-" + UUID().uuidString.lowercased()
        store.add(PairedRemote(id: id, name: displayName, key: RemoteWebServer.hash(token), pairedAt: .now, lastSeen: .now, web: true))
        justPaired = displayName
        endPairing()
        return .success(token)
    }

    /// A browser's event stream opened or closed.
    func webDevicesChanged() {
        let webDevices = web.connectedDevices
        for device in webDevices { store.touch(device, name: store.device(device)?.name ?? "") }
        let appDevices = Set(clients.values.compactMap { $0.isSignedIn ? $0.device : nil })
        connected = appDevices.union(webDevices)
    }

    /// Pushes right away (after a web command), rather than at the next tick.
    func pushSoon() {
        Task { [weak self] in self?.push() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard let model else { connection.cancel(); return }
        let client = RemoteClient(connection: connection, server: self, bridge: RemoteBridge(model: model))
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    fileprivate func ended(_ client: RemoteClient, handshakeFailed: Bool) {
        clients[ObjectIdentifier(client)] = nil
        if let device = client.device, !clients.values.contains(where: { $0.device == device }), !web.connectedDevices.contains(device) {
            connected.remove(device)
        }
        if handshakeFailed, pairing != nil {
            failedPairingHandshakes += 1
            if failedPairingHandshakes >= Self.pairingAttempts { endPairing() }
        }
    }

    fileprivate func authenticated(_ client: RemoteClient, device: String, name: String) -> Bool {
        guard let paired = store.device(device), !paired.isWeb else { return false }
        store.touch(device, name: name)
        connected.insert(device)
        return true
    }

    // MARK: Pushing state

    /// Sends each signed-in phone what changed since it last heard: playback, the queue, the outputs.
    private func push() {
        let signedIn = clients.values.filter(\.isSignedIn)
        guard !signedIn.isEmpty || web.hasListeners, let model else { return }
        let bridge = RemoteBridge(model: model)
        let player = bridge.playerState()
        let signature = bridge.queueSignature
        if signature != queueSignature || lastQueue == nil {
            queueSignature = signature
            queueRevision += 1
            lastQueue = bridge.queueState(revision: queueRevision)
        }
        let outputs = bridge.outputsState()
        lastOutputs = outputs
        for client in signedIn { client.update(player: player, queue: lastQueue, outputs: outputs) }
        web.push(player: player, queue: lastQueue, outputs: outputs)
    }

    /// Everything, for a phone that just signed in.
    func snapshot(_ bridge: RemoteBridge) -> (PlayerState, QueueState, OutputsState) {
        let signature = bridge.queueSignature
        if signature != queueSignature || lastQueue == nil {
            queueSignature = signature
            queueRevision += 1
            lastQueue = bridge.queueState(revision: queueRevision)
        }
        return (bridge.playerState(), lastQueue ?? bridge.queueState(revision: queueRevision), bridge.outputsState())
    }
}

/// One phone's connection.
@MainActor
final class RemoteClient {
    let connection: NWConnection
    private weak var server: RemoteServer?
    private let bridge: RemoteBridge
    /// Its device ID once it said hello with a paired key.
    private(set) var device: String?
    private(set) var isSignedIn = false
    private var becameReady = false
    private var closed = false
    private var sentPlayer: PlayerState?
    private var sentQueueRevision: Int?
    private var sentOutputs: OutputsState?
    private var helloTimeout: Task<Void, Never>?

    init(connection: NWConnection, server: RemoteServer, bridge: RemoteBridge) {
        self.connection = connection
        self.server = server
        self.bridge = bridge
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        connection.start(queue: .main)
        // A phone has 15 seconds to say who it is.
        helloTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, !self.isSignedIn else { return }
            self.connection.cancel()
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            becameReady = true
            receive()
        case .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        helloTimeout?.cancel()
        connection.cancel()
        // A connection that never got through TLS used a wrong key: while pairing, that's a wrong code.
        server?.ended(self, handshakeFailed: !becameReady)
    }

    func close(saying reason: GoodbyeReason) {
        guard !closed else { return }
        send(.goodbye(reason: reason)) { [weak self] in self?.connection.cancel() }
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            // No content on a complete receive: the phone closed the connection.
            let ended = error != nil || (content == nil && isComplete)
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if ended { self.finish(); return }
                if let content { self.handle(content) }
                self.receive()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? RemoteProtocol.decoder().decode(ClientMessage.self, from: data) else {
            // A command this Mac doesn't know (a newer phone app): say so, but only when the ID can be read.
            if let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int {
                reply(id, .failed(reason: String(localized: "This Mac’s Vespertine doesn’t know that command. Update Vespertine on the Mac.", comment: "Remote control: the phone app is newer than Vespertine on the Mac.")))
            }
            return
        }
        switch message.command {
        case .hello(let device, let name, let version):
            guard version == RemoteProtocol.version else { return close(saying: .protocolMismatch) }
            guard let server, server.authenticated(self, device: device, name: name) else { return close(saying: .notPaired) }
            self.device = device
            isSignedIn = true
            helloTimeout?.cancel()
            reply(message.id, .welcome(server.serverInfo))
            let (player, queue, outputs) = server.snapshot(bridge)
            update(player: player, queue: queue, outputs: outputs)
        case .pair(let name, let version):
            guard version == RemoteProtocol.version else { return close(saying: .protocolMismatch) }
            guard let server else { return }
            let result = server.pair(name: name)
            // The phone connects again with its own key.
            send(.reply(id: message.id, result: result)) { [weak self] in self?.connection.cancel() }
        case _ where !isSignedIn:
            close(saying: .notPaired)
        case .artwork(let key, let size):
            let store = ArtworkCache.shared.store
            Task { [weak self] in
                let found = await RemoteBridge.artwork(key: key, size: size, store: store)
                guard let self else { return }
                if let found {
                    self.reply(message.id, .artwork(key: key, size: size, mimeType: found.mimeType, data: found.data))
                } else {
                    self.reply(message.id, .failed(reason: String(localized: "There’s no cover for this.", comment: "Remote control: the phone asked for a cover the Mac doesn't have.")))
                }
            }
        default:
            reply(message.id, bridge.perform(message.command))
            // A command usually changes what's playing: tell the phone at once rather than at the next tick.
            if let server {
                let (player, queue, outputs) = server.snapshot(bridge)
                update(player: player, queue: queue, outputs: outputs)
            }
        }
    }

    /// Sends what changed since this phone last heard.
    func update(player: PlayerState, queue: QueueState?, outputs: OutputsState) {
        guard isSignedIn, !closed else { return }
        if sentPlayer.map({ $0.differs(from: player) }) ?? true {
            sentPlayer = player
            send(.player(player))
        }
        if let queue, queue.revision != sentQueueRevision {
            sentQueueRevision = queue.revision
            send(.queue(queue))
        }
        if outputs != sentOutputs {
            sentOutputs = outputs
            send(.outputs(outputs))
        }
    }

    private func reply(_ id: Int, _ result: RemoteReply) {
        send(.reply(id: id, result: result))
    }

    private func send(_ message: ServerMessage, then done: (@MainActor () -> Void)? = nil) {
        guard !closed, let data = try? RemoteProtocol.encoder().encode(message) else { return }
        connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { [weak self] error in
            let failed = error != nil
            MainActor.assumeIsolated {
                if failed { self?.finish() }
                done?()
            }
        })
    }
}
