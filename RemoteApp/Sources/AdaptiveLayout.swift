// Layout decisions use the window, never the device model or the full screen.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import Foundation

nonisolated enum RemoteDestination: String, CaseIterable, Hashable, Sendable {
    case nowPlaying, library, artists, playlists, favorites, queue, output

    var isLibrary: Bool { [.library, .artists, .playlists, .favorites].contains(self) }
    var compactTab: RemoteDestination { isLibrary ? .library : self }
    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .library: "square.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .favorites: "heart"
        case .queue: "list.bullet"
        case .output: "hifispeaker"
        }
    }
    var title: String {
        switch self {
        case .nowPlaying: String(localized: "Now Playing")
        case .library: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .playlists: String(localized: "Playlists")
        case .favorites: String(localized: "Favorites")
        case .queue: String(localized: "Queue")
        case .output: String(localized: "Output")
        }
    }
    static func starting(at screen: String?) -> Self {
        switch screen {
        case "library", "albums", "coverFlow", "album", "search": .library
        case "artists": .artists
        case "playlists": .playlists
        case "favorites": .favorites
        case "queue": .queue
        case "output": .output
        default: .nowPlaying
        }
    }
}

nonisolated enum RemoteLayout {
    static func usesSidebar(regularWidth: Bool, width: CGFloat) -> Bool {
        regularWidth && width >= 600
    }
    static func playerColumns(width: CGFloat, height: CGFloat, accessibilityText: Bool) -> Bool {
        !accessibilityText && width >= 680 && height >= 260 && width > height * 1.05
    }
    /// Width of the player's text and controls column (the cover matches it when stacked).
    static func controlsWidth(width: CGFloat) -> CGFloat { max(0, min(560, width - 48)) }
    static func coverSide(width: CGFloat, height: CGFloat, columns: Bool) -> CGFloat {
        let available = max(0, width - 48)
        if columns { return max(0, min(520, (available - 32) * 0.48, height - 24)) }
        return max(0, min(controlsWidth(width: width), max(160, height - 440)))
    }
    static func albumColumns(width: CGFloat, accessibilityText: Bool) -> Int {
        let minimum: CGFloat = accessibilityText ? 240 : 160
        return max(1, Int((max(0, width - 32) + 16) / (minimum + 16)))
    }
}
