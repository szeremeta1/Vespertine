//
// Vespertine Remote: what Now Playing's cover and its record share: the picture they draw, and the tap that switches them.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import SwiftUI

enum NowPlayingArt {
    /// Pixels asked of the Mac for the record's label and for the flat cover: one size, so one picture. It is a size the
    /// Mac keeps pre-rendered; a larger one is answered with the original, which a hi-res cover can make too big to send.
    static let recordSize = 600
    static let flatSize = recordSize

    /// What a tap on the record or the cover makes of the choice.
    static func toggled(vinyl: Bool) -> Bool { !vinyl }

    /// What VoiceOver calls what is showing.
    static func label(vinyl: Bool) -> LocalizedStringResource { vinyl ? "Record" : "Cover" }

    /// What a tap would do, in the words the old button used.
    static func switchHint(vinyl: Bool) -> LocalizedStringResource { vinyl ? "Show the Cover" : "Show a Record" }
}
