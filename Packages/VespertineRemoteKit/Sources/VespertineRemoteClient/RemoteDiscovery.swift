//
// Vespertine Remote: the Macs on this network that have the remote switched on (Bonjour, `_vespertine._tcp`).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Observation
import VespertineRemoteProtocol

/// A Mac advertising the remote.
public struct DiscoveredMac: Identifiable, Hashable, Sendable {
    /// The Mac's server ID (stable across restarts and renames), or its Bonjour name if it didn't say.
    public var id: String { serverID.isEmpty ? name : serverID }
    public var name: String
    public var serverID: String
    public var protocolVersion: Int?
    public var appVersion: String?
    /// The port the Mac says it listens on (nil from a Mac that doesn't say).
    public var port: UInt16?
    public var endpoint: NWEndpoint
    /// The Mac says it is a notebook (nil: it doesn't say).
    public var portable: Bool?

    public init(name: String, serverID: String, protocolVersion: Int? = nil, appVersion: String? = nil, port: UInt16? = nil, endpoint: NWEndpoint) {
        self.name = name
        self.serverID = serverID
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.port = port
        self.endpoint = endpoint
    }

    /// A Mac as its Bonjour service record describes it.
    public init(name: String, txt: NWTXTRecord, endpoint: NWEndpoint) {
        self.init(name: name,
                  serverID: txt[RemoteProtocol.TXTKey.serverID] ?? "",
                  protocolVersion: txt[RemoteProtocol.TXTKey.protocolVersion].flatMap { Int($0) },
                  appVersion: txt[RemoteProtocol.TXTKey.appVersion],
                  port: RemotePort.advertised(txt: txt[RemoteProtocol.TXTKey.port].map { [RemoteProtocol.TXTKey.port: $0] } ?? [:]),
                  endpoint: endpoint)
        if txt[RemoteProtocol.TXTKey.portable] == "1" { portable = true }
    }
}

/// Browses for Macs while started. Everything happens on the main actor.
@MainActor
@Observable
public final class RemoteDiscovery {
    public private(set) var macs: [DiscoveredMac] = []
    /// Why browsing doesn't work (most often: Local Network access was turned off for the app).
    public private(set) var problem: String?

    /// Called when the list of Macs changed (the app keeps the ports the Macs announce).
    @ObservationIgnored public var onChange: (@MainActor ([DiscoveredMac]) -> Void)?
    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public var isBrowsing: Bool { browser != nil }

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.mac(from:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            MainActor.assumeIsolated {
                self?.macs = found
                self?.onChange?(found)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let problem: String?
            switch state {
            case .failed(let error), .waiting(let error): problem = "\(error)"
            default: problem = nil
            }
            MainActor.assumeIsolated { self?.problem = problem }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The Mac with `serverID`, if it's advertising now.
    public func mac(serverID: String) -> DiscoveredMac? {
        macs.first { $0.serverID == serverID }
    }

    nonisolated static func mac(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        if case .bonjour(let txt) = result.metadata {
            return DiscoveredMac(name: name, txt: txt, endpoint: result.endpoint)
        }
        return DiscoveredMac(name: name, serverID: "", endpoint: result.endpoint)
    }
}
#endif
