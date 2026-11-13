//
// Vespertine: names a paired web browser from its User-Agent ("Chrome on Mac"), so Settings › Remote and the pair sheet
// say which browser it is. (navigator.platform gave "MacIntel" for every Mac browser.)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated enum RemoteBrowserName {
    /// "Chrome on Mac", "Safari on iPhone"; just the browser when the system isn't recognised; nil when the browser isn't.
    /// Browser and system names are brand names and stay as they are; only the joining word follows the Mac's language.
    /// `maxTouchPoints` is the page's `navigator.maxTouchPoints`: iPad Safari in its default desktop mode sends a "Macintosh"
    /// user agent, and a touch screen is the only thing that tells it from a Mac (no Mac reports more than one touch point).
    static func name(userAgent: String, maxTouchPoints: Int? = nil) -> String? {
        // The order matters: Edge, Opera and Chrome on iOS all say "Safari" too, and Edge and Opera say "Chrome".
        let browsers: [(marker: String, name: String)] = [
            ("Edg/", "Edge"), ("EdgA/", "Edge"), ("EdgiOS/", "Edge"), ("OPR/", "Opera"), ("OPiOS/", "Opera"),
            ("Firefox/", "Firefox"), ("FxiOS/", "Firefox"), ("CriOS/", "Chrome"), ("Chrome/", "Chrome"), ("Safari/", "Safari"),
        ]
        // iPhone and iPad before Mac: their user agents say "like Mac OS X".
        let systems: [(marker: String, name: String)] = [
            ("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Windows", "Windows"),
            ("Macintosh", "Mac"), ("Linux", "Linux"), ("X11", "Linux"),
        ]
        guard let browser = browsers.first(where: { userAgent.contains($0.marker) })?.name else { return nil }
        let isIPadInDesktopMode = userAgent.contains("Macintosh") && (maxTouchPoints ?? 0) > 1
        guard let system = isIPadInDesktopMode ? "iPad" : systems.first(where: { userAgent.contains($0.marker) })?.name else { return browser }
        return String(localized: "\(browser) on \(system)", comment: "Settings › Remote: name of a paired web browser; first %@ is the browser (Chrome, Safari), second the device (Mac, iPhone).")
    }
}
