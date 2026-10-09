//
// Vespertine verification: loads verification/fixtures/dst/.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts
import Foundation

public enum DSTFixtures {
    private struct Entry: Decodable {
        var name: String
        var channels: Int
        var coding: String
    }

    /// The fixture directory: $VERIFICATION_FIXTURES/dst when set, else verification/fixtures/dst next to this
    /// package.
    public static var directory: URL {
        if let root = ProcessInfo.processInfo.environment["VERIFICATION_FIXTURES"] {
            return URL(fileURLWithPath: root).appendingPathComponent("dst")
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/dst")
    }

    /// Every fixture, in fixtures.json order. Empty when the directory can't be read (checks then fail on it).
    public static let all: [DSTFixture] = {
        let dir = directory
        guard let index = try? Data(contentsOf: dir.appendingPathComponent("fixtures.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: index) else { return [] }
        return entries.compactMap { e in
            guard let frame = try? Data(contentsOf: dir.appendingPathComponent(e.name + ".dst")),
                  let dsd = try? Data(contentsOf: dir.appendingPathComponent(e.name + ".dsd")) else { return nil }
            return DSTFixture(name: e.name, channels: e.channels, coding: e.coding, frame: [UInt8](frame), expected: [UInt8](dsd))
        }
    }()
}
