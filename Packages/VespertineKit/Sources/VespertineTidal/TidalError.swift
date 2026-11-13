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

extension TidalError: LocalizedError {
    /// What the player shows (the spec's error table where it words a case).
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "Sign in to TIDAL", comment: "A TIDAL track can't play: no TIDAL session.")
        case .missingCredentials:
            String(localized: "TIDAL client credentials are missing. Add them in Settings › TIDAL.")
        case .backingOff(let remaining, _):
            Self.waitMessage(remaining)
        case .abuse(let retryAfter):
            Self.waitMessage(retryAfter)
        case .http(let status, _):
            String(localized: "TIDAL answered with an error (HTTP \(status)).")
        case .encrypted:
            String(localized: "This track's stream is encrypted", comment: "A TIDAL track whose stream is DRM-protected.")
        case .malformedStream:
            String(localized: "TIDAL sent a stream Vespertine can't read.")
        case .notStreamable(let reason):
            reason
        case .unavailable:
            String(localized: "This track isn't available on TIDAL.")
        }
    }

    /// What a TIDAL song says when the CDN (or the stream's resolution) sends nothing for the playback cache's silence limit.
    public static var notAnsweringMessage: String {
        String(localized: "TIDAL isn't answering", comment: "A TIDAL track's stream sent nothing for two minutes.")
    }

    /// "TIDAL asked us to wait N min", N rounded up, at least 1.
    private static func waitMessage(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return String(localized: "TIDAL asked us to wait \(minutes) min", comment: "A TIDAL backoff is in force.")
    }
}
