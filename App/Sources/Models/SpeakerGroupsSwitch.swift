//
// Vespertine — the Settings › Playback switch that brings Speaker Groups (beta) into the app, like Transitions'. Its words, what
// Settings shows under it, and what turning it on or off does to the groups model, kept apart from the views so they can be tested.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

@MainActor
enum SpeakerGroupsSwitch {
    static var title: String {
        String(localized: "Speaker Groups (beta)", comment: "Settings › Playback: the title of the switch that brings speaker groups (several DACs played as one multichannel system) into the app, and of its section. “beta” stays as it is in your language.")
    }

    static var explanation: String {
        String(localized: "Plays through two or more USB DACs as one multichannel speaker system. Off, none of it is in the app and every song plays as before.", comment: "Settings › Playback: the caption under the Speaker Groups (beta) switch.")
    }

    /// What Settings shows in the section, top to bottom.
    enum Row: Hashable { case toggle, explanation, groups }

    /// The switch and its line always; the groups list only while the feature is on.
    static func rows(featureOn: Bool) -> [Row] {
        featureOn ? [.toggle, .explanation, .groups] : [.toggle, .explanation]
    }

    /// Turns the feature on or off in `settings` and answers the groups model that should exist now: the one in `current` (or a
    /// new one over the saved groups, whose changes call `onChange`) while on, nil while off. The saved groups stay in their file.
    static func apply(_ on: Bool, to settings: AppSettings, current: SpeakerGroupsModel?, onChange: @escaping () -> Void) -> SpeakerGroupsModel? {
        settings.speakerGroupsFeature = on
        guard on else { return nil }
        if let current { return current }
        let groups = SpeakerGroupsModel(directory: settings.dataDirectory)
        groups.onChange = onChange
        return groups
    }

    /// Whether the chosen output survives the switch going to `on`: a speaker group chosen as the output doesn't, once groups are off.
    static func keepsOutput(_ uid: String?, turningOnTo on: Bool, groups: [SpeakerGroup]) -> Bool {
        on || uid == nil || !groups.contains { $0.outputUID == uid }
    }
}
