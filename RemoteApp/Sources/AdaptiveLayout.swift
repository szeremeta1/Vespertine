// Layout decisions use the window, never the device model or the full screen.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import Foundation

/// Where pieces of given sizes go when they are set left to right and wrap onto another line when the width runs out
/// (the signal badges: never clipped, never scrolled).
nonisolated enum FlowRows {
    struct Result: Equatable {
        var origins: [CGPoint]
        var size: CGSize
    }

    /// A piece wider than `width` gets a line of its own (and is offered only `width`).
    /// `centered`: each line sits in the middle of the widest one.
    static func place(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat, centered: Bool = false) -> Result {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for size in sizes {
            let wide = min(size.width, width)
            if x > 0, x + wide > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += wide + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        if centered {
            // The right edge of each line, by its y.
            var ends: [CGFloat: CGFloat] = [:]
            for (origin, size) in zip(origins, sizes) { ends[origin.y] = max(ends[origin.y] ?? 0, origin.x + min(size.width, width)) }
            origins = origins.map { CGPoint(x: $0.x + (widest - (ends[$0.y] ?? widest)) / 2, y: $0.y) }
        }
        return Result(origins: origins, size: CGSize(width: widest, height: sizes.isEmpty ? 0 : y + lineHeight))
    }
}

nonisolated enum RemoteDestination: Hashable, Sendable {
    case nowPlaying, library, artists, songs, genres, recentlyAdded, favorites, playlists, queue, output
    /// What is kept on this device, playable without the Mac.
    case kept
    /// One of the Mac's sources (`SourceSummary.id`), listed in the sidebar as on the Mac.
    case source(Int64)

    /// Every destination but the sources, which the Mac lists.
    static let fixed: [RemoteDestination] = [.nowPlaying, .library, .artists, .songs, .genres, .recentlyAdded, .favorites, .playlists, .kept, .queue, .output]

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
