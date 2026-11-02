//
// Vespertine — Shortcuts actions for song transitions: turn them on or off, choose a style (for a party, from Vesper
// or a Focus).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppIntents
import VespertineAudio

/// The transition styles, as Shortcuts lists them.
enum TransitionStyleOption: String, AppEnum, CaseIterable {
    case crossfade, smartMix, liveSet

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transition Style"
    static let caseDisplayRepresentations: [TransitionStyleOption: DisplayRepresentation] = [
        .crossfade: "Crossfade",
        .smartMix: "Smart Mix",
        .liveSet: "Live Set",
    ]

    var style: TransitionStyle {
        switch self {
        case .crossfade: .crossfade
        case .smartMix: .smartMix
        case .liveSet: .liveSet
        }
    }
}

struct TransitionsIntentError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Vespertine’s library isn’t open." }
}

/// Turns transitions on or off, as Controls › Transitions does.
struct SetTransitionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Transitions On or Off"
    static let description = IntentDescription("Turns Vespertine’s song transitions on or off.")
    static let openAppWhenRun = true

    @Parameter(title: "On", default: true)
    var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = LibraryStartup.current?.model else { throw TransitionsIntentError() }
        model.setTransitions(on)
        return .result()
    }
}

/// Chooses how songs blend, and turns transitions on.
struct UseTransitionStyleIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose Transition Style"
    static let description = IntentDescription("Sets how Vespertine blends songs and turns transitions on.")
    static let openAppWhenRun = true

    @Parameter(title: "Style", default: .smartMix)
    var style: TransitionStyleOption

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = LibraryStartup.current?.model else { throw TransitionsIntentError() }
        model.settings.transitions.style = style.style
        model.setTransitions(true)
        return .result()
    }
}
