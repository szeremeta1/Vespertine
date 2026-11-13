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
    public var endpoint: NWEndpoint

    public init(name: String, serverID: String, protocolVersion: Int? = nil, appVersion: String? = nil, endpoint: NWEndpoint) {
        self.name = name
        self.serverID = serverID
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.endpoint = endpoint
    }
}

/// Browses for Macs while started. Everything happens on the main actor.
@MainActor
@Observable
public final class RemoteDiscovery {
    public private(set) var macs: [DiscoveredMac] = []
    /// Why browsing doesn't work (most often: Local Network access was turned off for the app).
    public private(set) var problem: String?

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
            MainActor.assumeIsolated { self?.macs = found }
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
        var serverID = "", version: Int?, app: String?
        if case .bonjour(let txt) = result.metadata {
            serverID = txt[RemoteProtocol.TXTKey.serverID] ?? ""
            version = txt[RemoteProtocol.TXTKey.protocolVersion].flatMap { Int($0) }
            app = txt[RemoteProtocol.TXTKey.appVersion]
        }
        return DiscoveredMac(name: name, serverID: serverID, protocolVersion: version, appVersion: app, endpoint: result.endpoint)
    }
}
#endif
