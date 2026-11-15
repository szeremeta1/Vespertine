//
// Vespertine: left/right balance for a stereo output. The law (which channel is turned down, and by how much), the steps
// of the Controls menu, the words for a value, and the streams balance is never applied to.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Balance is one number per output: -1 (all left) ... 0 (centered) ... +1 (all right).
public enum BalanceLaw {
    /// One step of the Controls menu and of the slider's keys: 5 points of 100.
    public static let step = 0.05
    /// The slider settles on the center when it is let go this near it.
    public static let detent = 0.03

    /// A value in -1...1; anything that isn't a number is the center.
    public static func clamped(_ balance: Double) -> Double {
        guard balance.isFinite else { return 0 }
        return min(max(balance, -1), 1)
    }

    /// The level of each channel. Only the far side is turned down (a quarter cosine: -3 dB at half way, silence at the
    /// end), the near side stays at exactly 1, so the center is exactly (1, 1) and nothing is ever made louder.
    public static func gains(_ balance: Double) -> (left: Double, right: Double) {
        let b = clamped(balance)
        if b == 0 { return (1, 1) }
        let far = abs(b) == 1 ? 0 : cos(abs(b) * .pi / 2)
        return b > 0 ? (far, 1) : (1, far)
    }

    /// The value as whole points: -100...100.
    public static func points(_ balance: Double) -> Int { Int((clamped(balance) * 100).rounded()) }

    /// The center when within the detent of it, else the value.
    public static func snapped(_ balance: Double) -> Double {
        let b = clamped(balance)
        return abs(b) <= detent ? 0 : b
    }

    /// "Center", "20% left", "35% right": shown beside the control and spoken by VoiceOver.
    public static func caption(_ balance: Double) -> String {
        let points = points(balance)
        if points == 0 { return String(localized: "Center", comment: "Balance: the sound is centered between left and right.") }
        return points < 0
            ? String(localized: "\(-points)% left", comment: "Balance: how far the sound is moved to the left speaker, in percent.")
            : String(localized: "\(points)% right", comment: "Balance: how far the sound is moved to the right speaker, in percent.")
    }
}

/// Balance Left, Balance Right and Center Balance in the Controls menu.
public enum BalanceControls {
    public enum Action: Sendable { case left, right, center }

    /// Whole steps of 5 points, so twenty presses one way and twenty back end exactly on the center.
    public static func apply(_ action: Action, to balance: Double) -> Double {
        let steps = (BalanceLaw.clamped(balance) / BalanceLaw.step).rounded()
        let next: Double
        switch action {
        case .center: return 0
        case .left: next = steps - 1
        case .right: next = steps + 1
        }
        return min(max(next * 5, -100), 100) / 100
    }
}

/// Why a balance that is set for an output is not applied to the stream playing on it.
public enum BalanceBypass: String, Sendable, Hashable, CaseIterable {
    /// DoP and bitstream words can't be scaled without destroying them.
    case passthrough
    /// Spatial Audio places the channels itself, after the gain.
    case spatial
    /// A stream of one channel or of more than two, or a speaker group.
    case notStereo

    /// Whether a stream with this plan can be balanced on `device` at all; nil = it can.
    public static func reason(for device: OutputDevice?, plan: OutputPlan) -> BalanceBypass? {
        if plan.isPassthrough { return .passthrough }
        if plan.spatial != .off { return .spatial }
        if plan.channels != 2 { return .notStereo }
        return reason(for: device)
    }

    /// Whether `device` can be balanced at all, before anything plays; nil = it can.
    public static func reason(for device: OutputDevice?) -> BalanceBypass? {
        guard let device else { return nil }
        return GroupOutput.isGroupOutput(device) || device.capabilities.outputChannels < 2 ? .notStereo : nil
    }

    public var explanation: String {
        switch self {
        case .passthrough: String(localized: "Not available for DoP or bitstream output", comment: "Why the balance control is disabled.")
        case .spatial: String(localized: "Not available with Spatial Audio", comment: "Why the balance control is disabled.")
        case .notStereo: String(localized: "Stereo outputs only", comment: "Why the balance control is disabled: it works only for two-channel sound.")
        }
    }
}

extension EngineSettings {
    /// The balance chosen for `device`; nil = centered (or nothing usable stored).
    public func balance(for device: OutputDevice?) -> Double? {
        guard let uid = device?.uid, let stored = deviceBalances[uid] else { return nil }
        let balance = BalanceLaw.clamped(stored)
        return balance == 0 ? nil : balance
    }

    /// Whether a stream with this plan can be balanced on `device` at all; nil = it can.
    public func balanceBypass(for device: OutputDevice?, plan: OutputPlan) -> BalanceBypass? {
        BalanceBypass.reason(for: device, plan: plan)
    }

    /// The balance applied to a stream with this plan on `device`; nil = none (centered, or the stream can't take it).
    public func appliedBalance(for device: OutputDevice?, plan: OutputPlan) -> Double? {
        balanceBypass(for: device, plan: plan) == nil ? balance(for: device) : nil
    }
}
