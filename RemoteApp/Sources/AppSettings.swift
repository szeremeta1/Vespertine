//
// Vespertine Remote: the app's own few choices (how Now Playing and the albums look), kept on this device.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Observation

@Observable
final class AppSettings {
    enum AlbumsLayout: String { case grid, coverFlow }

    /// Now Playing shows the cover as the label of a turning record.
    var vinyl: Bool { didSet { defaults.set(vinyl, forKey: Keys.vinyl) } }
    /// Cover Flow shifts its perspective as the device tilts (never with Reduce Motion on).
    var tiltParallax: Bool { didSet { defaults.set(tiltParallax, forKey: Keys.tilt) } }
    /// Songs may be fetched from the Mac over cellular data when music plays on this device. On unless turned off.
    var cellularPlayback: Bool { didSet { defaults.set(cellularPlayback, forKey: Keys.cellular) } }
    var albumsLayout: AlbumsLayout { didSet { defaults.set(albumsLayout.rawValue, forKey: Keys.albums) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let vinyl = "nowPlayingVinyl"
        static let tilt = "coverFlowTilt"
        static let albums = "albumsLayout"
        static let cellular = "cellularPlayback"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.vinyl: false, Keys.tilt: true, Keys.albums: AlbumsLayout.grid.rawValue, Keys.cellular: true])
        vinyl = defaults.bool(forKey: Keys.vinyl)
        tiltParallax = defaults.bool(forKey: Keys.tilt)
        cellularPlayback = defaults.bool(forKey: Keys.cellular)
        albumsLayout = AlbumsLayout(rawValue: defaults.string(forKey: Keys.albums) ?? "") ?? .grid
    }
}
