//
// Vespertine: who the Mac's remote listener lets knock. Reachable from a tailnet or a forwarded port, it shuts out a host
// that keeps failing the handshake (guessing keys or pairing codes) for a while, and keeps strangers from holding every
// connection open at once. Plain rules, no network: the server asks before it accepts.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct ConnectionThrottle: Sendable {
    /// Failed handshakes a host may have within `window` seconds before it is shut out for `lockout` seconds.
    public var allowedFailures: Int
    public var window: TimeInterval
    public var lockout: TimeInterval
    /// Connections that may be open without having signed in yet.
    public var maximumPending: Int

    /// A handshake that fails this soon after the same host signed in isn't counted: a phone tries every way to the Mac at
    /// once and hangs up on the slower ones, which looks like a failed handshake from here.
    public var grace: TimeInterval = 10

    private var failures: [String: [Date]] = [:]
    private var signedIn: [String: Date] = [:]
    private var shutOutUntil: [String: Date] = [:]

    public init(allowedFailures: Int = 10, window: TimeInterval = 60, lockout: TimeInterval = 300, maximumPending: Int = 16) {
        self.allowedFailures = allowedFailures
        self.window = window
        self.lockout = lockout
        self.maximumPending = maximumPending
    }

    /// Whether a new connection from `host` is taken, with `pending` connections not yet signed in.
    public mutating func admits(host: String, pending: Int, now: Date = Date()) -> Bool {
        forget(before: now)
        guard pending < maximumPending else { return false }
        if let until = shutOutUntil[host], until > now { return false }
        return true
    }

    public mutating func failed(host: String, now: Date = Date()) {
        if let last = signedIn[host], now.timeIntervalSince(last) < grace, now >= last { return }
        var recent = (failures[host] ?? []).filter { now.timeIntervalSince($0) < window }
        recent.append(now)
        if recent.count >= allowedFailures {
            shutOutUntil[host] = now.addingTimeInterval(lockout)
            failures[host] = nil
        } else {
            failures[host] = recent
        }
    }

    public mutating func succeeded(host: String, now: Date = Date()) {
        failures[host] = nil
        shutOutUntil[host] = nil
        signedIn[host] = now
    }

    /// Hosts being counted or shut out now.
    public var trackedHosts: Int { Set(failures.keys).union(shutOutUntil.keys).count }

    private mutating func forget(before now: Date) {
        shutOutUntil = shutOutUntil.filter { $0.value > now }
        signedIn = signedIn.filter { now.timeIntervalSince($0.value) < grace }
        failures = failures.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < window }
            return recent.isEmpty ? nil : recent
        }
    }

    /// The host of an endpoint's description ("192.168.1.20:51234", "fe80::1%en0.51234", "[fd7a::1]:47821"): no port, no
    /// interface scope, so one machine is one host.
    public static func host(of endpoint: String) -> String {
        var text = endpoint
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") { return String(text[text.index(after: text.startIndex)..<close]) }
        if let scope = text.firstIndex(of: "%") { return String(text[..<scope]) }
        // One colon: an IPv4 address or a name with its port. More: a bare IPv6 address.
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }
}
