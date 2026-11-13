//
// Vespertine: which navigations of the login sheet are TIDAL's redirect, and what they carry.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL login redirect")
struct TidalLoginRedirectTests {
    let redirect = "https://tidal.com/android/login/auth"

    @Test("A page on another host (or another path) is let through")
    func ignores() {
        #expect(TidalLoginRedirect.classify(URL(string: "https://login.tidal.com/authorize?x=1")!, redirectURI: redirect) == .ignore)
        #expect(TidalLoginRedirect.classify(URL(string: "https://tidal.com/browse")!, redirectURI: redirect) == .ignore)
        #expect(TidalLoginRedirect.classify(URL(string: "https://evil.example/android/login/auth?code=1")!, redirectURI: redirect) == .ignore)
    }

    @Test("The redirect with a code is the login's end")
    func code() {
        let url = URL(string: "https://tidal.com/android/login/auth?code=abc&state=1")!
        #expect(TidalLoginRedirect.classify(url, redirectURI: redirect) == .code(url))
    }

    @Test("The redirect with an error carries TIDAL's error")
    func error() {
        let url = URL(string: "https://tidal.com/android/login/auth?error=access_denied&error_description=No")!
        #expect(TidalLoginRedirect.classify(url, redirectURI: redirect) == .error("access_denied"))
        #expect(TidalLoginRedirect.classify(URL(string: "https://tidal.com/android/login/auth")!, redirectURI: redirect) == .error("no_code"))
        #expect(TidalLoginRedirect.redirectURI == redirect)
    }
}
