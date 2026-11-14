// Layout decisions use the window, never the device model or the full screen.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import Foundation

nonisolated enum RemoteDestination: Hashable, Sendable {
    case nowPlaying, library, artists, songs, genres, recentlyAdded, favorites, playlists, queue, output
    /// What is kept on this device, playable without the Mac.
    case kept
    /// One of the Mac's sources (`SourceSummary.id`), listed in the sidebar as on the Mac.
    case source(Int64)

    /// Every destination but the sources, which the Mac lists.
    static let fixed: [RemoteDestination] = [.nowPlaying, .library, .artists, .songs, .genres, .recentlyAdded, .favorites, .playlists, .queue, .output]

    /// A name for the destination (accessibility identifiers, launch options).
    var id: String {
        switch self {
        case .nowPlaying: "nowPlaying"
        case .library: "library"
        case .artists: "artists"
        case .songs: "songs"
        case .genres: "genres"
        case .recentlyAdded: "recentlyAdded"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .queue: "queue"
        case .output: "output"
        case .kept: "kept"
        case .source(let id): "source-\(id)"
        }
    }

    var isLibrary: Bool {
        switch self {
        case .nowPlaying, .queue, .output: false
        default: true
        }
    }
    var compactTab: RemoteDestination { isLibrary ? .library : self }
    /// The Mac's sidebar symbols for the pages it has too.
    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .library: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .genres: "guitars"
        case .recentlyAdded: "clock"
        case .favorites: "heart"
        case .playlists: "music.note.list"
        case .queue: "list.bullet"
        case .output: "hifispeaker"
        case .kept: "arrow.down.circle"
        case .source: "folder"
        }
    }
    var title: String {
        switch self {
        case .nowPlaying: String(localized: "Now Playing")
        case .library: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .songs: String(localized: "Songs")
        case .genres: String(localized: "Genres")
        case .recentlyAdded: String(localized: "Recently Added")
        case .favorites: String(localized: "Favorites")
        case .playlists: String(localized: "Playlists")
        case .queue: String(localized: "Queue")
        case .output: String(localized: "Output")
        case .kept: String(localized: "On This Device")
        case .source: String(localized: "Source")
        }
    }
    static func starting(at screen: String?) -> Self {
        switch screen {
        case "library", "albums", "coverFlow", "album", "search": .library
        case "artists": .artists
        case "songs": .songs
        case "genres": .genres
        case "recentlyAdded": .recentlyAdded
        case "playlists": .playlists
        case "favorites": .favorites
        case "kept": .kept
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
