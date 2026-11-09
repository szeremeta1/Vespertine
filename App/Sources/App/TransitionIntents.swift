//
// Vespertine: Shortcuts actions for song transitions: turn them on or off, choose a style (for a party, from Vesper
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
    var featureOff = false
    var localizedStringResource: LocalizedStringResource {
        featureOff ? "Transitions are off in Vespertine’s Settings." : "Vespertine’s library isn’t open."
    }
}

// None of these is offered in Shortcuts or Spotlight (`isDiscoverable`): the system lists App Intents from the built
// app, so they can't appear only while the Transitions feature is on, and off, the feature isn't in the app.

/// The model, only while the Transitions feature is on in Settings; off, these actions do nothing at all.
@MainActor
private func transitionsModel() throws -> AppModel {
    guard let model = LibraryStartup.current?.model else { throw TransitionsIntentError() }
    guard model.settings.transitionsFeature else { throw TransitionsIntentError(featureOff: true) }
    return model
}

/// Turns transitions on or off, as Controls › Transitions does.
struct SetTransitionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Transitions On or Off"
    static let description = IntentDescription("Turns Vespertine’s song transitions on or off.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "On", default: true)
    var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try transitionsModel()
        model.setTransitions(on)
        return .result()
    }
}

/// Chooses how songs blend, and turns transitions on.
struct UseTransitionStyleIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose Transition Style"
    static let description = IntentDescription("Sets how Vespertine blends songs and turns transitions on.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Style", default: .smartMix)
    var style: TransitionStyleOption

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try transitionsModel()
        model.settings.transitions.style = style.style
        model.setTransitions(true)
        return .result()
    }
}

/// Starts a Live Set: transitions on, in the Live Set style (one output rate, beat-matched blends, skips that blend).
struct StartLiveSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Live Set"
    static let description = IntentDescription("Turns on Vespertine’s transitions in Live Set: one output rate, beat-matched blends, skips that always blend.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try transitionsModel()
        model.settings.transitions.style = .liveSet
        model.setTransitions(true)
        return .result()
    }
}

/// Ends a Live Set: transitions off if they're in Live Set (otherwise nothing changes).
struct StopLiveSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Live Set"
    static let description = IntentDescription("Turns off Vespertine’s transitions if they’re in Live Set.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try transitionsModel()
        if model.settings.transitions.style == .liveSet { model.setTransitions(false) }
        return .result()
    }
}
