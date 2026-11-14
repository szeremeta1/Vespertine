//
// Vespertine: whether phones can find this Mac by themselves. The listener can be up and answering while Bonjour never
// announces it (macOS keeps an app off the local network until it is allowed in System Settings), and then a phone on the
// same Wi-Fi says "Not on this network" with nothing on the Mac to explain it. This keeps count of what Bonjour said.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct AdvertisingWatch: Sendable, Equatable {
    /// How long after the listener is up Bonjour may take before it counts as not announcing.
    public var patience: TimeInterval

    private var listeningSince: Date?
    private var announced = 0

    public init(patience: TimeInterval = 8) {
        self.patience = patience
    }

    /// The listener is up and taking connections.
    public mutating func listening(at now: Date = Date()) {
        if listeningSince == nil { listeningSince = now }
    }

    /// The listener stopped (or is starting again): nothing is known until it is up.
    public mutating func stopped() {
        listeningSince = nil
        announced = 0
    }

    /// Bonjour took the service on one more network, or dropped it from one.
    public mutating func announced(added: Bool) {
        announced = max(0, announced + (added ? 1 : -1))
    }

    /// Up for long enough, and Bonjour still announces it nowhere.
    public func isSilent(at now: Date = Date()) -> Bool {
        guard let listeningSince, announced == 0 else { return false }
        return now.timeIntervalSince(listeningSince) >= patience
    }
}
