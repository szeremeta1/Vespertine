// Vespertine: the one rule for whether a song can play right now, and how a row names its source and its format.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether a song can play now, and if it can't, why. Every view that grays a row asks this, so the same song is grayed alike in
/// the songs table, an album, the queue and a playlist (decision 203).
public enum Playability: Equatable, Sendable {
    case playable
    case unavailable(reason: String)

    public var isPlayable: Bool { self == .playable }
    public var reason: String? { if case .unavailable(let reason) = self { reason } else { nil } }

    public static var offline: String { String(localized: "Offline", comment: "Why a song can't play: its source isn't reachable.") }
    public static var signInToTidal: String { String(localized: "Sign in to TIDAL", comment: "Why a TIDAL song can't play: no account is signed in.") }
    public static var notAvailableHere: String {
        String(localized: "Not available in your country", comment: "Why a TIDAL song can't play: TIDAL doesn't stream it here.")
    }
    public static var tidalAskedToWait: String {
        String(localized: "TIDAL asked us to wait", comment: "Why a TIDAL song can't play now: TIDAL's rate limit or abuse protection told the app to back off.")
    }

    /// A song plays now when:
    /// - it is a local or share song and its source is online;
    /// - it is a TIDAL song with a download whose file is there (whatever the network says); or
    /// - it is a TIDAL song to stream, and TIDAL is signed in, reachable and not asking Vespertine to wait, and the song is streamable.
    ///
    /// When several reasons hold the account's come first (the user can fix them, and `streamable` is as old as the last sync):
    /// signed out, then asked to wait, then offline, then not streamable.
    ///
    /// `fileExists` asks the file system; it is only asked about a TIDAL song's download.
    public static func playability(track: Track, source: LibrarySource?, tidal: TidalTrackRecord?, signedIn: Bool, reachable: Bool,
                                   backingOff: Bool, fileExists: (String) -> Bool) -> Playability {
        guard track.isTidalTrack || tidal != nil || source?.isTidal == true else {
            return source?.isOnline ?? true ? .playable : .unavailable(reason: offline)
        }
        if let path = tidal?.downloadPath ?? (track.filePath.isEmpty ? nil : track.filePath), fileExists(path) { return .playable }
        if !signedIn { return .unavailable(reason: signInToTidal) }
        if backingOff { return .unavailable(reason: tidalAskedToWait) }
        if !reachable { return .unavailable(reason: offline) }
        if tidal?.streamable == false { return .unavailable(reason: notAvailableHere) }
        return .playable
    }
}

/// Where a song comes from, as the Source column shows it.
public enum TrackSource: Equatable, Sendable {
    case local
    case share(name: String)
    case tidalStreaming
    case tidalDownloaded

    public var isTidal: Bool { self == .tidalStreaming || self == .tidalDownloaded }

    /// The Source column's tooltip.
    public var help: String {
        switch self {
        case .local: String(localized: "Local", comment: "Source column tooltip: a file on this Mac.")
        case .share(let name): name
        case .tidalStreaming: String(localized: "TIDAL · streaming", comment: "Source column tooltip.")
        case .tidalDownloaded: String(localized: "TIDAL · downloaded", comment: "Source column tooltip.")
        }
    }

    public static func of(track: Track, source: LibrarySource?, tidal: TidalTrackRecord?) -> TrackSource {
        if track.isTidalTrack || tidal != nil || source?.isTidal == true {
            return (tidal?.downloadPath ?? (track.filePath.isEmpty ? nil : track.filePath)) == nil ? .tidalStreaming : .tidalDownloaded
        }
        if let source, source.isNetwork { return .share(name: source.displayName) }
        return .local
    }
}

public extension Track {
    /// A song of the TIDAL account (streamed or downloaded): its location is "tidal://track/<id>", the download only changes its file path.
    var isTidalTrack: Bool { location.hasPrefix("tidal://") }

    /// What the Source column sorts by: sources of files (folders, drives, shares) one after another by source, TIDAL after them,
    /// streamed before downloaded.
    var sourceSortKey: Int64 {
        guard isTidalTrack else { return sourceId ?? 0 }
        return filePath.isEmpty ? Int64.max - 1 : Int64.max
    }

    /// The Format column's text and tooltip. A TIDAL song whose stream hasn't been read yet shows what TIDAL lists for it, marked "≈",
    /// so the app never claims a format it hasn't seen (decision 204). That covers catalog rows (a TIDAL song with no library row,
    /// so no `tidal` record): `probed` says their stream has been read this run.
    func formatLabel(tidal: TidalTrackRecord?, probed: Bool = false) -> (text: String, help: String?) {
        let listed = tidal.map { !$0.formatIsProbed } ?? (isTidalTrack && id == nil && !probed)
        guard listed else { return (formatSummary, nil) }
        return (formatSummary + " ≈", String(localized: "Listed by TIDAL; confirmed when played", comment: "Tooltip of a TIDAL song's format before it has been played."))
    }
}
