//
// Vespertine: Mac Sound Output (beta): the helper's rules for living next to the Mac's own choices. The pure part: no device needed.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Found live (a group of a FiiO K11 and a Fosi ZD3, the group on): choosing either DAC on its own in the Sound menu spun forever.
// The helper held the DACs in hog mode (the app's Exclusive Mode, copied into the snapshot), and macOS never makes a device another
// process holds exclusively the Mac's output. So the helper never holds its members (the group is a pass-through of what other apps
// play: exclusive access buys nothing there), and it lets go of a member the moment the user or another app wants it.
//
// Also found: changing the group's layout put the group's volume back to 100% (macOS rebuilds the output when its channel count
// changes). The keeper remembers the level and puts it back.
//

import CoreAudio
import Foundation

public enum SystemOutputPolicy {
    /// The helper never takes exclusive access to a member, whatever Exclusive Mode says for Vespertine's own playback: a held DAC
    /// can't be chosen in the Sound menu (macOS spins forever), and the helper holds nothing while idle either.
    public static func holdsMembers(_ entry: SystemOutputEntry) -> Bool { false }

    /// Why the group must not play now.
    public enum MemberClaim: Equatable, Sendable {
        /// Nothing in the way.
        case none
        /// A member is the Mac's chosen output: the user asked for that DAC on its own.
        case isDefaultOutput(uid: String)
        /// Another process holds a member exclusively.
        case heldByOther(uid: String, pid: pid_t)
    }

    /// Whether a member of `group` is wanted by someone else. `defaultOutputUID`: the Mac's chosen output (nil when unknown);
    /// `hogOwners`: each member's hog owner by UID (-1: nobody; a missing one is unknown and counts as free). The user's choice
    /// (the default output) is named before another app's hold.
    public static func memberClaim(group: SpeakerGroup, defaultOutputUID: String?, hogOwners: [String: pid_t], me: pid_t) -> MemberClaim {
        if let defaultOutputUID, let member = group.members.first(where: { $0.deviceUID == defaultOutputUID }) {
            return .isDefaultOutput(uid: member.deviceUID)
        }
        for member in group.members {
            if let owner = hogOwners[member.deviceUID], owner != -1, owner != me { return .heldByOther(uid: member.deviceUID, pid: owner) }
        }
        return .none
    }
}

/// An output's volume and mute, as the keys and the Sound settings show them.
public struct SystemOutputLevel: Equatable, Sendable {
    public var volume: Float
    public var muted: Bool

    public init(volume: Float, muted: Bool = false) {
        self.volume = volume
        self.muted = muted
    }

    /// Equal for the purpose of "does it need putting back": within what a volume control stores.
    func matches(_ other: SystemOutputLevel) -> Bool { muted == other.muted && abs(volume - other.volume) < 0.002 }
}

/// Remembers each published output's level across a change of its layout. The helper reads the level just before it publishes a
/// layout that differs from the last one, and after the output has been rebuilt (its channel count is the new one) puts the level
/// back if it changed. It never writes a level when the layout didn't change: the volume belongs to the user.
public struct SystemOutputLevelKeeper: Sendable {
    /// What the helper reads from an output: its level (nil when unreadable) and its output channels now.
    public struct Reading: Sendable {
        public var level: SystemOutputLevel?
        public var channels: Int
        public init(level: SystemOutputLevel?, channels: Int) {
            self.level = level
            self.channels = channels
        }
    }

    /// A restore waits this long for the output to be rebuilt, then is given up.
    public static let patience: TimeInterval = 15
    /// After the output shows its new channel count it is watched this long more (the level may be reset a moment later).
    public static let settle: TimeInterval = 3

    private struct Pending {
        var level: SystemOutputLevel
        var channels: Int
        var since: Date
        var rebuiltAt: Date?
    }

    private var layouts: [String: [AudioChannelLabel]] = [:]
    private var levels: [String: SystemOutputLevel] = [:]
    private var pending: [String: Pending] = [:]

    public init() {}

    /// Called with every publish: the layouts about to be published, and each output's level read just before (nil: no such
    /// output yet, or unreadable). An output not listed is forgotten.
    public mutating func beforePublish(layouts now: [String: [AudioChannelLabel]], levels read: [String: SystemOutputLevel?], now date: Date) {
        for uid in layouts.keys where now[uid] == nil {
            layouts[uid] = nil
            levels[uid] = nil
            pending[uid] = nil
        }
        for (uid, layout) in now {
            let sampled = read[uid] ?? nil
            if let before = layouts[uid], before != layout {
                // A change: what was read just before is the level to keep (an earlier, unfinished change's level stands).
                if let keep = pending[uid]?.level ?? sampled ?? levels[uid] {
                    pending[uid] = Pending(level: keep, channels: layout.count, since: pending[uid]?.since ?? date, rebuiltAt: nil)
                }
            } else if pending[uid] == nil, let sampled {
                levels[uid] = sampled
            }
            layouts[uid] = layout
        }
    }

    /// The levels to write now, by output UID: outputs that were rebuilt for a new layout and show another level than before.
    public mutating func restores(devices: [String: Reading], now date: Date) -> [String: SystemOutputLevel] {
        var result: [String: SystemOutputLevel] = [:]
        for (uid, entry) in pending {
            var entry = entry
            if date.timeIntervalSince(entry.since) > Self.patience && entry.rebuiltAt == nil {
                pending[uid] = nil
                continue
            }
            guard let reading = devices[uid] else { continue }
            if entry.rebuiltAt == nil, reading.channels == entry.channels { entry.rebuiltAt = date }
            if let rebuilt = entry.rebuiltAt {
                if let level = reading.level, !level.matches(entry.level) { result[uid] = entry.level }
                if date.timeIntervalSince(rebuilt) >= Self.settle {
                    pending[uid] = nil
                    levels[uid] = entry.level
                    continue
                }
            }
            pending[uid] = entry
        }
        return result
    }

    /// An output is waiting for its level to be put back (the helper looks again soon).
    public var isWaiting: Bool { !pending.isEmpty }
}
