//
// Vespertine: what can go wrong talking to TIDAL, as one error type the player and library can switch on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum TidalError: Error, Equatable {
    /// No session (never signed in, signed out, or the refresh token was refused).
    case notSignedIn
    /// `tidal-client.json` is missing.
    case missingCredentials
    /// TIDAL asked us to slow down; nothing is sent until the backoff ends.
    case backingOff(remaining: TimeInterval, reason: String)
    /// A 403 that reads as abuse detection or a suspended account.
    case abuse(retryAfter: TimeInterval)
    case http(status: Int, body: String)
    /// The stream is DRM-protected (`encryptionType` other than NONE, or `ContentProtection` in the manifest).
    case encrypted
    /// A manifest or fMP4 segment that doesn't have the shape we expect.
    case malformedStream(String)
    /// TIDAL says the track can't be streamed (not ready, region, subscription).
    case notStreamable(String)
    case unavailable
    /// TIDAL answered a playlist's GET without the `ETag` a write needs; nothing was written.
    case missingETag(playlist: String)
}
