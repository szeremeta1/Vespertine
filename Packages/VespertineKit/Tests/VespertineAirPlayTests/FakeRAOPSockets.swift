//
// Vespertine: socket ownership for the fake receiver. A worker closes its own descriptors; stopping the receiver
// shuts them down to wake the workers. Registration, shutdown and close share a lock because a closed descriptor
// can immediately be reused by another test in this process.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

final class FakeRAOPSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: Set<Int32> = []
    private var stopped = false

    /// Takes ownership, or closes the socket if the receiver has already stopped.
    func insert(_ fd: Int32) -> Bool {
        lock.withLock {
            guard !stopped else { Darwin.close(fd); return false }
            descriptors.insert(fd)
            return true
        }
    }

    func close(_ fd: Int32) {
        lock.withLock {
            guard descriptors.remove(fd) != nil else { return }
            Darwin.close(fd)
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            for fd in descriptors { shutdown(fd, SHUT_RDWR) }
        }
    }
}
