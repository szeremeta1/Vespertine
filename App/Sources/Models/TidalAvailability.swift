//
// Vespertine: what the app knows about TIDAL right now, for the one playability rule.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineLibrary

/// Whether TIDAL can be streamed from at this moment: signed in, the network up, no backoff. The TIDAL model keeps it current (the
/// same three facts set the TIDAL source's online state); until it does, TIDAL is not signed in, so nothing is streamable.
@MainActor @Observable
final class TidalAvailability {
    var signedIn = false
    var reachable = true
    var backingOff = false

    /// Why the account can't stream now, nil when it can: what the offline banner says before "Sign In…" or "Retry".
    var accountReason: String? {
        if !signedIn { return Playability.signInToTidal }
        if backingOff { return Playability.tidalAskedToWait }
        if !reachable { return Playability.offline }
        return nil
    }
}
