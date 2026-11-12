//
// Vespertine: the limits that keep the DoP test quiet, and the checks that stop it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum DoPTestSafety {
    /// The cap actually used for a requested one: never above the absolute ceiling, never below zero.
    public static func effectiveCap(requested: Float) -> Float {
        min(max(requested, 0), DoPTestConstants.absoluteVolumeCeiling)
    }

    /// The hardware volume to set for the test: the cap, when the DAC's volume is above it. nil when there is nothing to
    /// do (the DAC has no volume control, or is already at or under the cap): the test never raises a volume.
    public static func volumeToSet(current: Float?, cap: Float) -> Float? {
        guard let current else { return nil }
        let limit = effectiveCap(requested: cap)
        return current > limit ? limit : nil
    }
}

/// While the test plays, nothing about the audio devices may change.
public enum DoPTestGuard {
    public struct Snapshot: Equatable, Sendable {
        public var outputUIDs: Set<String>
        public var defaultOutput: String?
        /// The UID being tested.
        public var target: String
        public init(outputUIDs: Set<String>, defaultOutput: String?, target: String) {
            self.outputUIDs = outputUIDs; self.defaultOutput = defaultOutput; self.target = target
        }
    }

    /// Any difference at all, an output arriving or leaving or the default output moving, ends the test.
    public static func shouldAbort(start: Snapshot, now: Snapshot) -> Bool { start != now }

    /// An answer is only taken for a clip the engine played as DoP, start to finish.
    public static func mayAnswer(playedAsDoP: Bool, aborted: Bool) -> Bool { playedAsDoP && !aborted }
}
