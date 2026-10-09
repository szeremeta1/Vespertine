//
// Vespertine — a value behind an unfair lock.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The same `withLock` shape as Synchronization's `Mutex`, which needs macOS 15. This one runs on macOS 14,
// the oldest system Vespertine supports.
//

import os

public final class Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ value: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: value)
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLockUnchecked(body)
    }
}
