//
// Vespertine: tells the login sheet's navigations apart: TIDAL's pages (let through), and the redirect that ends the login with a
// code or an error (caught, never loaded).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum TidalLoginRedirect: Equatable, Sendable {
    case ignore
    case code(URL)
    case error(String)

    /// Where TIDAL sends the browser after the login page.
    public static var redirectURI: String { TidalAuth.redirectURI }

    public static func classify(_ url: URL, redirectURI: String = TidalLoginRedirect.redirectURI) -> TidalLoginRedirect {
        guard let target = URLComponents(string: redirectURI), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == target.scheme?.lowercased(), components.host?.lowercased() == target.host?.lowercased(),
              components.path == target.path
        else { return .ignore }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty { return .error(error) }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty { return .code(url) }
        return .error("no_code")
    }
}
