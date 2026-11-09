//
// Vespertine — Volume Up, Volume Down and Mute in the Controls menu: which volume they move for the current output, and the steps.
// They act on the output Vespertine plays to and nothing else: not the media keys, not the Mac's own sound output.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum VolumeControls {
    public enum Action: Sendable { case up, down, mute }

    /// What a volume command moves.
    public enum Route: Equatable, Sendable {
        /// The device's own volume, which Core Audio exposes and can read.
        case hardware
        /// Vespertine's digital volume for this output.
        case software
        /// An output with no volume to move: the bar's "FIXED" note says where to set one.
        case fixed
    }

    /// The same choice the volume control in the transport bar makes: a readable hardware volume first, then Vespertine's own
    /// when this output uses it, else nothing to move.
    public static func route(for device: OutputDevice?, usesAppVolume: Bool, hardwareLevelKnown: Bool) -> Route {
        guard let device else { return .fixed }
        if device.hasHardwareVolume && hardwareLevelKnown { return .hardware }
        return usesAppVolume ? .software : .fixed
    }

    /// A volume and, while muted, the level to come back to.
    public struct State: Equatable, Sendable {
        public var level: Double
        public var restoreLevel: Double?
        public init(level: Double, restoreLevel: Double? = nil) {
            self.level = level
            self.restoreLevel = restoreLevel
        }
    }

    /// One step is a sixteenth of the range, the way the Mac's own volume moves.
    public static let stepsPerRange = 16.0
    /// Where Mute goes from silence when nothing was remembered.
    public static let unmuteFallback = 0.5

    public static func apply(_ action: Action, to state: State) -> State {
        let level = state.level.isFinite ? min(max(state.level, 0), 1) : 0
        let muted = level == 0 && state.restoreLevel != nil
        switch action {
        case .mute:
            if muted { return State(level: state.restoreLevel ?? unmuteFallback) }
            if level == 0 { return State(level: unmuteFallback) }
            return State(level: 0, restoreLevel: level)
        case .up:
            if muted { return State(level: state.restoreLevel ?? unmuteFallback) }
            let next = (level * stepsPerRange + 1e-9).rounded(.down) + 1
            return State(level: min(next / stepsPerRange, 1))
        case .down:
            if muted { return state }
            let next = (level * stepsPerRange - 1e-9).rounded(.up) - 1
            return State(level: max(next / stepsPerRange, 0))
        }
    }
}
