//
// Vespertine: the web remote's page. Its markup, style and script are the three RemoteWeb files in the app's resources,
// sent as one page; its words come from the String Catalog, so the page speaks the Mac's language like the rest of
// Vespertine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RemoteWebPage {
    /// The page's words, by key, in this Mac's language.
    static var strings: [String: String] {
        [
            "title": String(localized: "Vespertine Remote", comment: "Web remote: page title."),
            "pairTitle": String(localized: "Pair This Browser", comment: "Web remote: heading of the pairing screen."),
            "pairHelp": String(localized: "On the Mac, open Vespertine › Settings › Remote and choose Pair a Phone. Type the 6-digit code it shows.", comment: "Web remote: how to pair a browser."),
            "pair": String(localized: "Pair", comment: "Web remote: button that pairs the browser with the code typed."),
            "nowPlaying": String(localized: "Now Playing", comment: "Web remote: tab."),
            "library": String(localized: "Library", comment: "Web remote: tab."),
            "queue": String(localized: "Queue", comment: "Web remote: tab."),
            "output": String(localized: "Output", comment: "Web remote: tab (the Mac's audio outputs)."),
            "nothing": String(localized: "Nothing playing", comment: "Web remote: nothing is playing."),
            "albums": String(localized: "Albums", comment: "Web remote: library section."),
            "search": String(localized: "Search songs, artists, albums", comment: "Web remote: search field placeholder."),
            "more": String(localized: "More", comment: "Web remote: loads more albums."),
            "back": String(localized: "Back", comment: "Web remote: back from an album to the list."),
            "play": String(localized: "Play", comment: "Web remote: plays an album."),
            "shuffle": String(localized: "Shuffle", comment: "Web remote: shuffles an album, or the shuffle switch."),
            "repeat": String(localized: "Repeat", comment: "Web remote: the repeat button."),
            "playNext": String(localized: "Play Next", comment: "Web remote: puts a song next in the queue."),
            "addToQueue": String(localized: "Add to Queue", comment: "Web remote: adds a song at the end of the queue."),
            "remove": String(localized: "Remove", comment: "Web remote: removes a song from the queue."),
            "clear": String(localized: "Clear Upcoming", comment: "Web remote: clears the songs after the one playing."),
            "playingNext": String(localized: "Playing Next", comment: "Web remote: queue section."),
            // The same headings as the Mac's Up Next panel: "Up Next" alone, "Continue Playing" under "Playing Next".
            "upNext": String(localized: "Up Next"),
            "continuePlaying": String(localized: "Continue Playing"),
            "empty": String(localized: "The queue is empty."),
            "fixedVolume": String(localized: "Fixed volume: set the level on your amplifier or DAC", comment: "Web remote: the output's volume can't be changed from Vespertine."),
            "volume": String(localized: "Volume", comment: "Web remote: the volume slider."),
            "offline": String(localized: "Can’t reach the Mac. Trying again…", comment: "Web remote: the page lost the Mac."),
            "waiting": String(localized: "Waiting for \(placeholder) to connect", comment: "Web remote: playback waits for the chosen output; %@ is its name."),

            // The rest are the Mac window's own words for the same things, so the remote and the Mac always agree.
            "artists": String(localized: "Artists"),
            "songs": String(localized: "Songs"),
            "playlists": String(localized: "Playlists"),
            "favorites": String(localized: "Favorites"),
            "searchTab": String(localized: "Search"),
            "clearSearch": String(localized: "Clear search"),
            "noMatches": String(localized: "Nothing matches."),
            "noFavorites": String(localized: "No favorites yet"),
            "emptyLibrary": String(localized: "Your library is empty"),
            "nothingQueued": String(localized: "Nothing queued"),
            "pause": String(localized: "Pause"),
            "previous": String(localized: "Previous"),
            "next": String(localized: "Next"),
            "mute": String(localized: "Mute"),
            "unmute": String(localized: "Unmute"),
            "volumeUp": String(localized: "Volume Up"),
            "volumeDown": String(localized: "Volume Down"),
            "position": String(localized: "Position"),
            "off": String(localized: "Off"),
            "all": String(localized: "All"),
            "one": String(localized: "One"),
            "transitions": String(localized: "Transitions"),
            "favorite": String(localized: "Add to Favorites"),
            "unfavorite": String(localized: "Remove from Favorites"),
            "addToPlaylist": String(localized: "Add to Playlist"),
            "newPlaylist": String(localized: "New Playlist"),
            "name": String(localized: "Name"),
            "create": String(localized: "Create"),
            "cancel": String(localized: "Cancel"),
            "close": String(localized: "Close"),
            "options": String(localized: "Options"),
            "added": String(localized: "Added"),
            "goToAlbum": String(localized: "Go to Album"),
            "removeFromUpNext": String(localized: "Remove from Up Next"),
            "moveEarlier": String(localized: "Move \(placeholder) earlier"),
            "moveLater": String(localized: "Move \(placeholder) later"),
            "smart": String(localized: "SMART"),
            "smartPlaylist": String(localized: "Smart Playlist"),
            "hiRes": String(localized: "Hi-Res"),
            "multichannel": String(localized: "Multichannel"),
            "signalPath": String(localized: "Signal Path"),
            "tryAgain": String(localized: "Try again"),
            "reconnecting": String(localized: "Reconnecting…"),
        ]
    }

    /// Left in the words for the page to fill in (with the output's or the song's name).
    private static let placeholder = "%@"

    /// "3 songs" and "3 albums" for one number of each plural kind a language can have. The page picks the form its own
    /// plural rules name for a count and puts the count in, so "1 song", "2 utwory" and "5 utworów" all come out right.
    static let pluralSamples = [0, 1, 2, 3, 5, 11, 20, 100]

    static var plurals: [String: [String: String]] {
        var songs: [String: String] = [:], albums: [String: String] = [:]
        for n in pluralSamples {
            songs[String(n)] = String(localized: "\(n) songs")
            albums[String(n)] = String(localized: "\(n) albums")
        }
        return ["songs": songs, "albums": albums]
    }

    /// The language the page's words are in.
    static var language: String { Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en" }

    /// What the page may load and talk to: itself. Nothing from anywhere else runs or is fetched, and nothing frames it.
    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; "
        + "connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    static func html(serverName: String) -> String {
        var words: [String: Any] = strings
        words["mac"] = serverName
        words["plurals"] = plurals
        let language = language
        let rtl = Locale.Language(identifier: language).characterDirection == .rightToLeft
        // Arabic, Indic and Thai letters join or stack: spacing them apart breaks the words (as in the Mac's own labels).
        return template
            .replacingOccurrences(of: "__STRINGS__", with: scriptJSON(words))
            .replacingOccurrences(of: "__LANG__", with: language)
            .replacingOccurrences(of: "__DIR__", with: rtl ? "rtl" : "ltr")
            .replacingOccurrences(of: "__SPACED__", with: Locale.spacesLetters ? "spaced" : "unspaced")
    }

    /// JSON that can sit inside a <script> element: "<" must not end the element early.
    static func scriptJSON(_ value: Any) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// The web app manifest: what a phone needs to keep the remote on its home screen and open it without browser bars.
    static func manifest() -> Data {
        let manifest: [String: Any] = [
            "name": strings["title"] ?? "Vespertine Remote",
            "short_name": "Vespertine",
            "lang": language,
            "id": "/",
            "start_url": "/",
            "scope": "/",
            "display": "standalone",
            "orientation": "any",
            "background_color": "#09090A",
            "theme_color": "#09090A",
            "icons": [
                ["src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"],
                ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"],
                ["src": "/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The page with its style and script in it: one request, as the server answers one per connection.
    private static let template: String = {
        func resource(_ name: String, _ type: String) -> String? {
            let bundles = [Bundle.main, Bundle(for: RemoteWebServer.self)]
            for bundle in bundles {
                if let url = bundle.url(forResource: name, withExtension: type), let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            }
            return nil
        }
        guard let page = resource("RemoteWeb", "html"), let style = resource("RemoteWeb", "css"), let script = resource("RemoteWeb", "js") else {
            return "<!doctype html><html lang=\"__LANG__\" dir=\"__DIR__\"><meta charset=\"utf-8\"><title>Vespertine</title><p>Vespertine Remote</p></html>"
        }
        // The script goes in last and whole: its own text is never searched for the page's placeholders but the words'.
        return page.replacingOccurrences(of: "/*__STYLE__*/", with: style).replacingOccurrences(of: "/*__SCRIPT__*/", with: script)
    }()
}

/// The remote's icon for a phone's home screen: the brass crescent on obsidian, drawn here so no image file is needed.
enum RemoteWebIcon {
    /// The paths the icons are served at, and each one's size in pixels.
    static let sizes: [String: Int] = ["/icon-192.png": 192, "/icon-512.png": 512, "/icon-maskable-512.png": 512, "/apple-touch-icon.png": 180]

    /// The crescent of docs/brand/mark.svg, in its 512-unit square (y down).
    private static let crescent: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (441.48, 409.04, 403.76, 419.84, 363.52, 419.84), (241.93, 419.84, 143.36, 321.27, 143.36, 199.68),
        (143.36, 111.66, 195.01, 35.71, 269.78, 0.70), (265.28, 0.12, 260.65, 0, 256, 0), (114.62, 0, 0, 114.62, 0, 256),
        (0, 397.38, 114.62, 512, 256, 512), (348.18, 512, 428.99, 463.28, 473.82, 390.01),
    ]
    private static let crescentPath = "M473.82 390.01" + crescent.map { "C\($0.0) \($0.1) \($0.2) \($0.3) \($0.4) \($0.5)" }.joined() + "Z"

    static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><defs><linearGradient id="b" x1="0" y1="0" x2="1" y2="1">\
        <stop offset="0" stop-color="#F0DAAA"/><stop offset="0.55" stop-color="#C8A66A"/><stop offset="1" stop-color="#7C6541"/></linearGradient></defs>\
        <rect width="512" height="512" rx="112" fill="#09090A"/><g transform="translate(128 128) scale(0.5)"><path fill="url(#b)" d="\(crescentPath)"/></g></svg>
        """

    private static var cache: [String: Data] = [:]

    static func png(path: String) -> Data? {
        if let made = cache[path] { return made }
        guard let size = sizes[path], let data = png(size: size, maskable: path.contains("maskable") || path.contains("apple")) else { return nil }
        cache[path] = data
        return data
    }

    /// A square PNG: obsidian from edge to edge (a phone cuts its own corners), the crescent in the middle. A maskable
    /// icon keeps the crescent inside the circle every launcher shows.
    nonisolated static func png(size: Int, maskable: Bool) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard size > 0, size <= 1024,
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = CGFloat(size)
        context.setFillColor(CGColor(srgbRed: 0x09 / 255.0, green: 0x09 / 255.0, blue: 0x0A / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // A faint lift behind the mark, as on the app's icon.
        if let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1),
                                                             CGColor(srgbRed: 0x09 / 255.0, green: 0x09 / 255.0, blue: 0x0A / 255.0, alpha: 1)] as CFArray, locations: [0, 1]) {
            context.drawRadialGradient(glow, startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: 0,
                                       endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: side * 0.62, options: [])
        }
        let scale = side * (maskable ? 0.46 : 0.54) / 512
        let inset = (side - 512 * scale) / 2
        // The mark's coordinates have y down; a bitmap context has y up.
        context.translateBy(x: inset, y: side - inset)
        context.scaleBy(x: scale, y: -scale)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 473.82, y: 390.01))
        for c in crescent { path.addCurve(to: CGPoint(x: c.4, y: c.5), control1: CGPoint(x: c.0, y: c.1), control2: CGPoint(x: c.2, y: c.3)) }
        path.closeSubpath()
        context.addPath(path)
        context.clip()
        let colors = [CGColor(srgbRed: 0xF0 / 255.0, green: 0xDA / 255.0, blue: 0xAA / 255.0, alpha: 1),
                      CGColor(srgbRed: 0xC8 / 255.0, green: 0xA6 / 255.0, blue: 0x6A / 255.0, alpha: 1),
                      CGColor(srgbRed: 0x7C / 255.0, green: 0x65 / 255.0, blue: 0x41 / 255.0, alpha: 1)] as CFArray
        if let brass = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(brass, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 512, y: 512), options: [])
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
