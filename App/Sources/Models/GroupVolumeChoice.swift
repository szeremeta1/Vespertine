//
// Vespertine — a speaker group's volume: the DACs' own knobs, or Vespertine's volume for all of them. The choice is the per-output
// "Volume control in Vespertine" setting the transport bar uses, kept for the group's UID.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

enum GroupVolumeChoice: Hashable, CaseIterable {
    case hardware, software

    /// What the group has now: software only when that was chosen for it (a group without a choice keeps the DACs' own knobs).
    @MainActor static func current(in settings: AppSettings, for group: SpeakerGroup) -> GroupVolumeChoice {
        settings.usesAppVolume(group.outputUID) ? .software : .hardware
    }

    @MainActor func apply(to settings: AppSettings, for group: SpeakerGroup) {
        settings.setUsesAppVolume(self == .software, for: group.outputUID)
    }
}
