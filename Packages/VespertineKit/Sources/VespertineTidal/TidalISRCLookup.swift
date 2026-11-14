// Vespertine: finds the TIDAL version of a local song by its ISRC, for a drop on a TIDAL playlist (which takes TIDAL songs only).
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct TidalISRCLookup: Sendable {
    private let gate: TidalGate

    public init(gate: TidalGate) {
        self.gate = gate
    }

    /// The first track TIDAL lists for `isrc` that it can stream; nil when there is none, or when there is no ISRC to ask for (nothing is
    /// sent then). Asked at interactive priority: the user just dropped the song.
    public func track(forISRC isrc: String?) async throws -> TidalTrack? {
        let code = (isrc ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return nil }
        struct Answer: Decodable { var items: [TidalTrack] }
        let answer = try await gate.get("tracks", query: ["isrc": code], priority: .interactive, as: Answer.self)
        return answer.items.first { ($0.streamReady ?? true) && ($0.allowStreaming ?? true) }
    }

    /// The toast after a drop that was matched: "Added the TIDAL version of “Clocks”".
    public static func addedMessage(title: String) -> String {
        String(localized: "Added the TIDAL version of “\(title)”", comment: "Toast after a local song dropped on a TIDAL playlist was matched to TIDAL's version of it. The placeholder is the song's title.")
    }

    /// The refusal when there is no TIDAL version (or no ISRC to look it up by).
    public static var refusal: String {
        String(localized: "Not on TIDAL", comment: "Shown when a local song dropped on a TIDAL playlist has no TIDAL version.")
    }
}
