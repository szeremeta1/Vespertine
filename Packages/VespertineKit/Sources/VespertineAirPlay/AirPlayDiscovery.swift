//
// Vespertine: the AirPlay receivers on the network, from Bonjour (`_raop._tcp` and `_airplay._tcp`, merged by device id).
// Nothing is browsed and no socket is opened until the service is enabled, which the app does only while Settings ›
// Playback › AirPlay Players (beta) is on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import SystemConfiguration

/// One Bonjour service seen, with its TXT record.
public struct BonjourResult: Sendable, Hashable {
    public var service: BonjourService
    public var txt: [String: String]

    public init(service: BonjourService, txt: [String: String]) {
        self.service = service
        self.txt = txt
    }
}

public protocol BonjourBrowsing: AnyObject, Sendable {
    /// Starts browsing; `onChange` gets every service currently seen, whenever that changes.
    func start(onChange: @escaping @Sendable ([BonjourResult]) -> Void)
    func stop()
}

public enum AirPlayServiceType {
    public static let raop = "_raop._tcp"
    public static let airplay = "_airplay._tcp"
}

/// Browses with `NWBrowser`, one per service type.
public final class NWBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let types: [String]
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.airplay.browse")
    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var results: [String: [BonjourResult]] = [:]

    public init(types: [String] = [AirPlayServiceType.raop, AirPlayServiceType.airplay]) {
        self.types = types
    }

    public func start(onChange: @escaping @Sendable ([BonjourResult]) -> Void) {
        stop()
        let made = types.map { type -> NWBrowser in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
            browser.browseResultsChangedHandler = { [weak self] found, _ in
                guard let self else { return }
                let list = found.compactMap { result -> BonjourResult? in
                    guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                    var txt: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                    return BonjourResult(service: BonjourService(name: name, type: type, domain: domain), txt: txt)
                }
                let all = self.lock.withLock { () -> [BonjourResult] in
                    self.results[type] = list
                    return self.results.values.flatMap { $0 }
                }
                onChange(all)
            }
            return browser
        }
        lock.withLock { browsers = made }
        made.forEach { $0.start(queue: queue) }
    }

    public func stop() {
        let old = lock.withLock { () -> [NWBrowser] in
            defer { browsers = []; results = [:] }
            return browsers
        }
        old.forEach { $0.cancel() }
    }
}

/// The receivers seen, kept current while running.
public final class AirPlayDiscovery: @unchecked Sendable {
    private let browser: any BonjourBrowsing
    /// This Mac's own AirPlay receiver (macOS 12 and later) is left out: its name is the computer's.
    private let excludedName: String?
    private let lock = NSLock()
    private var running = false
    private var found: [AirPlayDevice] = []
    private var _seen = false

    /// Called (on any thread) when the list changes.
    public var onChange: (@Sendable ([AirPlayDevice]) -> Void)?

    public init(browser: any BonjourBrowsing = NWBonjourBrowser(), excludedName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?) {
        self.browser = browser
        self.excludedName = excludedName
    }

    public var isRunning: Bool { lock.withLock { running } }
    /// The browser has answered at least once since it started.
    public var hasAnswered: Bool { lock.withLock { _seen } }
    public var devices: [AirPlayDevice] { lock.withLock { found } }

    public func start() {
        let go = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            _seen = false
            return true
        }
        guard go else { return }
        browser.start { [weak self] results in self?.update(results) }
    }

    public func stop() {
        let was = lock.withLock { () -> Bool in
            defer { running = false; found = []; _seen = false }
            return running
        }
        if was { browser.stop() }
        onChange?([])
    }

    func update(_ results: [BonjourResult]) {
        let list = Self.merge(results, excluding: excludedName)
        let changed = lock.withLock { () -> Bool? in
            guard running else { return nil }
            _seen = true
            defer { found = list }
            return found != list
        }
        if changed != nil { onChange?(list) }
    }

    /// `_raop._tcp` and `_airplay._tcp` records of the same device become one, sorted by name.
    public static func merge(_ results: [BonjourResult], excluding excluded: String?) -> [AirPlayDevice] {
        var byID: [String: AirPlayDevice] = [:]
        for r in results where r.service.type.hasPrefix(AirPlayServiceType.raop) {
            guard let record = RAOPRecord.parse(serviceName: r.service.name, txt: r.txt) else { continue }
            byID[record.deviceID] = AirPlayDevice(deviceID: record.deviceID, name: record.name, raop: record, service: r.service)
        }
        for r in results where r.service.type.hasPrefix(AirPlayServiceType.airplay) {
            guard let record = AirPlayRecord.parse(serviceName: r.service.name, txt: r.txt) else { continue }
            if byID[record.deviceID] != nil { byID[record.deviceID]?.airplay = record } else {
                byID[record.deviceID] = AirPlayDevice(deviceID: record.deviceID, name: record.name, raop: nil, airplay: record)
            }
        }
        return byID.values.filter { $0.name != excluded }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Everything the AirPlay output runs, behind its switch. Off, nothing is browsed and no socket is open (sessions are
/// opened only by a playback, which exists only while a receiver is the chosen output).
public final class AirPlayService: @unchecked Sendable {
    public let discovery: AirPlayDiscovery
    private let lock = NSLock()
    private var enabled = false
    private var chain: Task<Void, Never>?

    public init(discovery: AirPlayDiscovery = AirPlayDiscovery()) {
        self.discovery = discovery
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    /// Turns it on or off; changes apply in order, each looking at what is wanted once the one before is done.
    public func want(_ on: Bool) {
        lock.withLock {
            enabled = on
            let previous = chain
            chain = Task { [weak self] in
                await previous?.value
                self?.apply()
            }
        }
    }

    /// Waits until every change asked for has been applied.
    public func settled() async {
        while true {
            let current = lock.withLock { chain }
            await current?.value
            if lock.withLock({ chain }) == current { return }
        }
    }

    public func setEnabled(_ on: Bool) async {
        want(on)
        await settled()
    }

    private func apply() {
        if isEnabled { discovery.start() } else { discovery.stop() }
    }
}
