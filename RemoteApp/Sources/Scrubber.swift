//
// Vespertine Remote: the position slider on Now Playing, as what it does rather than how it is drawn. The finger puts the
// knob somewhere; letting go seeks there; the knob stays there until the player says it is there (or a moment passes),
// so neither the clock nor an older report pulls it back.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Observation
import SwiftUI

@MainActor
@Observable
final class Scrubber {
    /// Where the finger put the song, in seconds, while that is what the knob shows.
    private(set) var held: Double?
    /// Seeks: called once for each place the finger lets go of (or rests at).
    @ObservationIgnored var commit: ((Double) -> Void)?
    /// How long the slider may be still, with no word that the finger lifted, before the place it was left at is sought.
    /// A SwiftUI slider tells of a lifted finger through `onEditingChanged`; a tap on its track and a VoiceOver swipe set
    /// its value and say nothing more, and a drag that ends while the view is being redrawn may do the same.
    @ObservationIgnored var quiet: Duration = .milliseconds(350)
    /// How long the knob stays where it was put when the player never reports being there.
    @ObservationIgnored var settle: Duration = .seconds(2)
    /// How near the player's position has to be to count as the place asked for, in seconds.
    @ObservationIgnored var tolerance = 1.5
    @ObservationIgnored private var dragging = false
    /// The place last sought, so the same place isn't sought twice.
    @ObservationIgnored private var sent: Double?
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// What the knob and the time labels show when the player is at `position`.
    func shown(position: Double) -> Double { held ?? position }

    /// The slider moved to `seconds` (called for every movement of a drag, and once for a tap or a VoiceOver swipe).
    func drag(to seconds: Double) {
        // A new drag: the place the last one sought may be sought again.
        if !dragging { sent = nil }
        dragging = true
        held = seconds.isFinite ? max(0, seconds) : 0
        after(quiet) { $0.stillness() }
    }

    /// The slider has been still for `quiet` and nobody said the finger lifted: the place it rests at is sought.
    func stillness() {
        guard dragging else { return }
        send()
        // The finger may still be down, so reports don't let go of the knob; time does.
        after(settle) { $0.expire() }
    }

    /// The finger lifted: seek, and keep the knob there until the player reports it.
    func end() {
        guard dragging else { return }
        dragging = false
        send()
        after(settle) { $0.expire() }
    }

    /// The player says where the song is. During a drag that is older than the finger.
    func reported(position: Double) {
        guard !dragging, let held, sent == held, abs(position - held) <= tolerance else { return }
        expire()
    }

    /// The knob goes back to following the player.
    func expire() {
        timer?.cancel()
        timer = nil
        dragging = false
        held = nil
        sent = nil
    }

    private func send() {
        guard let held, sent != held else { return }
        sent = held
        commit?(held)
    }

    private func after(_ wait: Duration, _ then: @escaping @MainActor (Scrubber) -> Void) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            then(self)
        }
    }
}
