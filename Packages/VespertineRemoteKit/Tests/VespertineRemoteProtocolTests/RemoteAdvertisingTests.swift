//
// Vespertine: how a phone finds its Mac on the same network. The Mac's listener carries a Bonjour service
// (`_vespertine._tcp`) with the Mac's ID in its text record; the phone browses for that type. The first test checks what the
// listener is given. The second really announces and really browses, and so needs Bonjour and a process macOS allows on the
// local network: it runs only when VESPERTINE_BONJOUR=1, which the suite's machine does not set.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Testing
import VespertineRemoteClient
@testable import VespertineRemoteProtocol

private let bonjourAllowed = ProcessInfo.processInfo.environment["VESPERTINE_BONJOUR"] == "1"

private func keys() -> [RemoteTransport.PresharedKey] {
    [.init(identity: "advertising-test", key: Data((0..<32).map { UInt8($0) }))]
}

private func record(serverID: String) -> NWTXTRecord {
    NWTXTRecord([RemoteProtocol.TXTKey.serverID: serverID, RemoteProtocol.TXTKey.protocolVersion: String(RemoteProtocol.version)])
}

/// Resumes once, with whichever comes first.
private final class First<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}

@Suite struct RemoteAdvertisingTests {
    @Test func theMacsListenerCarriesTheServiceAPhoneBrowsesFor() throws {
        let listener = try RemoteTransport.listener(keys: keys(), port: nil, txtRecord: record(serverID: "S-ADVERTISED"))
        defer { listener.cancel() }
        let service = try #require(listener.service, "a listener without a service is never announced")
        #expect(service.type == RemoteProtocol.serviceType)
        #expect(service.type == "_vespertine._tcp")
        // The computer's name, which Bonjour fills in: a fixed name would collide between two Macs.
        #expect(service.name == nil)
        let text = try #require(service.txtRecordObject)
        #expect(text[RemoteProtocol.TXTKey.serverID] == "S-ADVERTISED")
        #expect(text[RemoteProtocol.TXTKey.protocolVersion] == String(RemoteProtocol.version))
    }

    @Test(.enabled(if: bonjourAllowed), .timeLimit(.minutes(1)))
    func aStartedListenerIsAnnouncedAndFoundByABrowserOfThePhonesKind() async throws {
        let serverID = "S-" + UUID().uuidString
        let listener = try RemoteTransport.listener(keys: keys(), port: nil, txtRecord: record(serverID: serverID))
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "remote-advertising-test")
        // A listener with nobody to hand connections to refuses to start at all (EINVAL).
        listener.newConnectionHandler = { $0.cancel() }

        // Bonjour says it took the service (this is what the Mac app waits for before it stops warning).
        let announced: String = await withCheckedContinuation { continuation in
            let first = First(continuation)
            listener.serviceRegistrationUpdateHandler = { change in
                if case .add = change { first.resume("added") }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error): first.resume("the listener failed: \(error)")
                case .waiting(let error): first.resume("the listener is waiting: \(error)")
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 20) { first.resume("nothing from Bonjour in 20 s: is this process allowed on the local network?") }
            listener.start(queue: queue)
        }
        #expect(announced == "added")

        // And a browser made the way the phone app makes its own sees it, text record and all.
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: parameters)
        defer { browser.cancel() }
        let found: String = await withCheckedContinuation { continuation in
            let first = First(continuation)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .bonjour(let text) = result.metadata, text[RemoteProtocol.TXTKey.serverID] == serverID { first.resume("found") }
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error): first.resume("the browser failed: \(error)")
                case .waiting(let error): first.resume("the browser is waiting: \(error)")
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 20) { first.resume("the browser did not see the service in 20 s") }
            browser.start(queue: queue)
        }
        #expect(found == "found")
    }
}
#endif
