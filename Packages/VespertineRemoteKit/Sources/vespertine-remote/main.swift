//
// vespertine-remote: a command-line remote for testing a Mac's remote server.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
//   vespertine-remote list                       Macs advertising the remote on this network
//   vespertine-remote pair <code> [mac name]     pairs with the code Settings › Remote shows (saves the key)
//   vespertine-remote send '<command JSON>'      e.g. '{"playPause":{}}' or '{"albums":{"offset":0,"limit":5}}'
//   vespertine-remote watch [seconds]            prints everything the Mac pushes
//
// The key is saved in ~/.vespertine-remote.json (or $VESPERTINE_REMOTE_CONFIG). Replies are printed as JSON.
//

#if canImport(Network)
import Foundation
import Network
import VespertineRemoteProtocol

struct SavedPairing: Codable {
    var serverID: String
    var name: String
    var device: String
    var key: Data
}

let configURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VESPERTINE_REMOTE_CONFIG"]
                    ?? (NSHomeDirectory() + "/.vespertine-remote.json"))
let queue = DispatchQueue(label: "vespertine-remote")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

struct Found {
    var name: String
    var serverID: String
    var endpoint: NWEndpoint
}

/// The Macs advertising the remote, found within `seconds`.
func browse(seconds: Double = 3) -> [Found] {
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: NWParameters())
    let results = Box<[Found]>([])
    browser.browseResultsChangedHandler = { all, _ in
        results.value = all.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            var id = ""
            if case .bonjour(let txt) = result.metadata { id = txt[RemoteProtocol.TXTKey.serverID] ?? "" }
            return Found(name: name, serverID: id, endpoint: result.endpoint)
        }
    }
    browser.start(queue: queue)
    Thread.sleep(forTimeInterval: seconds)
    browser.cancel()
    return queue.sync { results.value }
}

/// One connection: send messages, wait for replies, print pushes.
final class Link: @unchecked Sendable {
    let connection: NWConnection
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var replies: [Int: RemoteReply] = [:]
    private let arrived = DispatchSemaphore(value: 0)
    var printPushes = false
    private(set) var failed: String?

    init(endpoint: NWEndpoint, key: RemoteTransport.PresharedKey) {
        connection = NWConnection(to: endpoint, using: RemoteTransport.parameters(keys: [key]))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.ready.signal()
            case .failed(let error), .waiting(let error): self?.failed = "\(error)"; self?.ready.signal(); self?.arrived.signal()
            case .cancelled: self?.arrived.signal()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func open() {
        let wrongCode = "Couldn't connect. Check the 6-digit code, or choose Pair a Phone on the Mac for a new one."
        if ready.wait(timeout: .now() + 10) == .timedOut { fail(wrongCode) }
        if let failed { fail("\(wrongCode) (\(failed))") }
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if error != nil || (content == nil && isComplete) { self.arrived.signal(); return }
            if let content, let message = try? RemoteProtocol.decoder().decode(ServerMessage.self, from: content) {
                switch message {
                case .reply(let id, let result):
                    self.lock.lock(); self.replies[id] = result; self.lock.unlock()
                    self.arrived.signal()
                case .goodbye(let reason):
                    print("goodbye: \(reason.rawValue)")
                    self.arrived.signal()
                default:
                    if self.printPushes { print(String(decoding: content, as: UTF8.self)) }
                }
            }
            self.receive()
        }
    }

    private var nextID = 0

    /// Sends `command` and waits for its reply.
    func call(_ command: RemoteCommand, timeout: Double = 10) -> RemoteReply {
        nextID += 1
        let id = nextID
        let data = try! RemoteProtocol.encoder().encode(ClientMessage(id: id, command: command))
        connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .idempotent)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let reply = replies.removeValue(forKey: id); lock.unlock()
            if let reply { return reply }
            _ = arrived.wait(timeout: .now() + 0.2)
        }
        fail("No reply from the Mac.")
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = RemoteProtocol.encoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

func signIn(printingPushes: Bool = false) -> Link {
    guard let data = try? Data(contentsOf: configURL), let saved = try? JSONDecoder().decode(SavedPairing.self, from: data) else {
        fail("Not paired yet: run `vespertine-remote pair <code>` first.")
    }
    guard let mac = browse().first(where: { $0.serverID == saved.serverID }) else { fail("“\(saved.name)” isn't advertising the remote on this network.") }
    let link = Link(endpoint: mac.endpoint, key: .init(identity: saved.device, key: saved.key))
    link.printPushes = printingPushes
    link.open()
    let welcome = link.call(.hello(device: saved.device, name: "vespertine-remote on \(ProcessInfo.processInfo.hostName)", protocolVersion: RemoteProtocol.version))
    guard case .welcome = welcome else { printJSON(welcome); fail("The Mac didn't let this remote in.") }
    return link
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list":
    for mac in browse() { print("\(mac.name)\t\(mac.serverID)") }
case "pair":
    guard arguments.count >= 2 else { fail("Usage: vespertine-remote pair <code> [mac name]") }
    let code = PairingSecret.normalizedCode(arguments[1])
    let macs = browse()
    guard let mac = arguments.count >= 3 ? macs.first(where: { $0.name == arguments[2] }) : macs.first else { fail("No Mac is advertising the remote.") }
    let key = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: code, serverID: mac.serverID))
    let link = Link(endpoint: mac.endpoint, key: key)
    link.open()
    let reply = link.call(.pair(name: "vespertine-remote on \(ProcessInfo.processInfo.hostName)", protocolVersion: RemoteProtocol.version))
    guard case .paired(let device, let deviceKey, let server) = reply else { printJSON(reply); fail("Pairing didn't work.") }
    let saved = SavedPairing(serverID: server.serverID, name: server.name, device: device, key: deviceKey)
    try JSONEncoder().encode(saved).write(to: configURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    print("Paired with \(server.name) as \(device).")
case "send":
    guard arguments.count >= 2, let command = try? RemoteProtocol.decoder().decode(RemoteCommand.self, from: Data(arguments[1].utf8)) else {
        fail("Usage: vespertine-remote send '{\"playPause\":{}}'")
    }
    printJSON(signIn().call(command))
case "watch":
    // Keep the link alive while watching: its callbacks hold it weakly.
    let link = signIn(printingPushes: true)
    withExtendedLifetime(link) {
        Thread.sleep(forTimeInterval: arguments.count >= 2 ? Double(arguments[1]) ?? 10 : 10)
    }
default:
    fail("Usage: vespertine-remote list | pair <code> [mac name] | send '<command JSON>' | watch [seconds]")
}
#else
print("vespertine-remote needs Apple's Network framework (macOS).")
#endif
