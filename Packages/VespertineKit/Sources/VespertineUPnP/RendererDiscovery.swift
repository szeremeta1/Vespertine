//
// Vespertine: the renderers on the network: found by SSDP, then their description, service descriptions and
// GetProtocolInfo read. Nothing is sent and nothing listens until the service is started, which the app does only
// while Settings › Playback › UPnP renderers (beta) is on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct RendererDevice: Sendable, Hashable, Identifiable {
    public static let uidPrefix = "upnp:"

    public var description: DeviceDescription
    public var kind: RendererKind
    public var capabilities: RendererCapabilities

    /// The output UID Vespertine stores for it: `upnp:` and its UDN.
    public var uid: String { Self.uidPrefix + description.udn }
    public var id: String { uid }
    public var name: String { description.friendlyName }
    public var host: String { description.location.host ?? "" }

    public static func isRendererUID(_ uid: String?) -> Bool { uid?.hasPrefix(uidPrefix) == true }

    public init(description: DeviceDescription, kind: RendererKind, capabilities: RendererCapabilities) {
        self.description = description
        self.kind = kind
        self.capabilities = capabilities
    }

    public enum LoadError: Error { case notARenderer }

    /// Reads the description at `location`, AVTransport's actions (for gapless) and ConnectionManager's sink formats.
    public static func load(location: URL, client: SOAPClient = SOAPClient()) async throws -> RendererDevice {
        let description = try DeviceDescription.parse(try await client.get(location), location: location)
        var avActions: Set<String>?
        if let av = description.service(.avTransport) { avActions = try? SCPD.actions(try await client.get(av.scpdURL)) }
        guard let kind = RendererKind.of(description, avActions: avActions) else { throw LoadError.notARenderer }
        var capabilities = RendererCapabilities()
        if let cm = description.service(.connectionManager), let sink = try? await client.call(cm, "GetProtocolInfo")["Sink"] {
            capabilities = RendererCapabilities.parse(sink: sink)
        }
        return RendererDevice(description: description, kind: kind, capabilities: capabilities)
    }

    public func makeTransport(client: SOAPClient = SOAPClient()) throws -> any RendererTransport {
        switch kind {
        case .openHome: try OpenHomeTransport(description: description, client: client)
        case .av(let gapless): try AVTransportControl(description: description, gapless: gapless, client: client)
        }
    }

    /// The services in its description that Vespertine knows, by name ("Product", "Playlist", "AVTransport"…).
    public var serviceNames: [String] {
        ServiceKind.allCases.filter { description.service($0) != nil }.map(\.displayName)
    }
}

public protocol SSDPSearching: Sendable {
    func search(targets: [String], mx: Int, wait: TimeInterval) async -> [SSDPResponse]
}

extension SSDPSearcher: SSDPSearching {}

/// Finds renderers and keeps the list current: a search when started, on `refresh()` (the output list opening) and every
/// five minutes. A renderer missing from three searches in a row, or whose description can't be read twice, is dropped.
public final class RendererDiscovery: @unchecked Sendable {
    public static let interval: TimeInterval = 300

    private let searcher: any SSDPSearching
    private let client: SOAPClient
    private let lock = NSLock()
    private var running = false
    private var loop: Task<Void, Never>?
    private var found: [String: (device: RendererDevice, missed: Int)] = [:]
    private var failures: [String: Int] = [:]
    private var _searches = 0
    private var _searching = false

    /// Called (on any thread) when the list changes.
    public var onChange: (@Sendable ([RendererDevice]) -> Void)?

    public init(searcher: any SSDPSearching = SSDPSearcher(), client: SOAPClient = SOAPClient()) {
        self.searcher = searcher
        self.client = client
    }

    public var isRunning: Bool { lock.withLock { running } }
    /// Searches sent since this was made.
    public var searches: Int { lock.withLock { _searches } }
    /// A search is under way (the first one, for "Searching…").
    public var isSearching: Bool { lock.withLock { _searching } }
    public var renderers: [RendererDevice] {
        lock.withLock { found.values.map(\.device).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }

    public func start() {
        let started = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard started else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.searchOnce()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
        lock.withLock { loop = task }
    }

    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            running = false
            found.removeAll()
            defer { loop = nil }
            return loop
        }
        task?.cancel()
        onChange?([])
    }

    /// Searches now (only while started).
    public func refresh() {
        guard isRunning else { return }
        Task { [weak self] in await self?.searchOnce() }
    }

    /// One search: new renderers are read, known ones kept, missing ones counted.
    public func searchOnce() async {
        let go = lock.withLock { () -> Bool in
            guard running, !_searching else { return false }
            _searches += 1
            _searching = true
            return true
        }
        guard go else { return }
        let replies = await searcher.search(targets: SSDP.rendererTargets, mx: 2, wait: 3)
        var locations: [String: URL] = [:]
        for reply in replies where locations[reply.udn] == nil { locations[reply.udn] = reply.location }
        var loaded: [String: RendererDevice] = [:]
        for (udn, location) in locations {
            let known = lock.withLock { found[udn]?.device }
            if let known, known.description.location == location { loaded[udn] = known; continue }
            if let device = try? await RendererDevice.load(location: location, client: client) {
                loaded[udn] = device
            } else {
                lock.withLock { failures[udn, default: 0] += 1 }
            }
        }
        let list = lock.withLock { () -> [RendererDevice]? in
            _searching = false
            guard running else { return nil }
            for (udn, device) in loaded { found[udn] = (device, 0); failures[udn] = nil }
            for udn in found.keys where loaded[udn] == nil {
                found[udn]?.missed += 1
                if (found[udn]?.missed ?? 0) >= 3 || (failures[udn] ?? 0) >= 2 { found[udn] = nil }
            }
            return found.values.map(\.device).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let list { onChange?(list) }
    }
}

/// Everything the UPnP output runs, behind its switch: discovery and the media server. Off, neither runs: no SSDP is sent and
/// no port is open.
public final class RendererService: @unchecked Sendable {
    public let discovery: RendererDiscovery
    public let media: MediaServer
    private let lock = NSLock()
    private var enabled = false

    public init(discovery: RendererDiscovery = RendererDiscovery(), media: MediaServer = MediaServer()) {
        self.discovery = discovery
        self.media = media
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    /// Starts (on) or stops (off) discovery and the media server.
    public func setEnabled(_ on: Bool) async throws {
        lock.withLock { enabled = on }
        if on {
            discovery.start()
            try await media.start()
        } else {
            discovery.stop()
            media.stop()
        }
    }

    /// Searches again, only while on.
    public func refresh() { if isEnabled { discovery.refresh() } }
}
