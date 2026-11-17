//
// Vespertine Remote: what Now Playing's cover and its record share: the picture they draw, and the tap that switches them.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

enum NowPlayingArt {
    /// Pixels asked of the Mac for the record's label and for the flat cover.
    static let recordSize = 600
    static let flatSize = 1000

    static func toggled(vinyl: Bool) -> Bool { vinyl }
    static func label(vinyl: Bool) -> String { "" }
    static func switchHint(vinyl: Bool) -> String { "" }
}
