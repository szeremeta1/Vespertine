//
// Vespertine: a song the library has in stereo and in surround, played on this phone. The library says which songs those
// are (`TrackSummary.otherLayout`); the phone's own output says which of the two plays.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

/// The rule is the Mac's (`PlayerController.entries`): a song plays as its surround version on an output that wants
/// surround and as its stereo version on any other, and is queued once however many of its versions were asked for.
/// Several songs that all come from one album keep to that album (an album played from its own page is that edition).
public enum PhoneVersions {
    /// `tracks` as they play on an output that wants surround or doesn't, and `index` (the song to start with) as its
    /// place among them.
    public static func resolve(_ tracks: [TrackSummary], surround: Bool, startAt index: Int? = nil) -> (tracks: [TrackSummary], startAt: Int?) {
        let oneAlbum = album(of: tracks) != nil
        var resolved: [TrackSummary] = []
        // For each song with two versions: the layouts it was asked for in, and where it went.
        var songs: [[Int64]: (asked: Set<Bool>, at: Int)] = [:]
        var start = index
        for (i, track) in tracks.enumerated() {
            guard let id = track.id, let layout = track.surround, let other = track.otherLayout, !oneAlbum || other.albumKey == track.albumKey else {
                if i == index { start = resolved.count }
                resolved.append(track)
                continue
            }
            let key = [id, other.id].sorted()
            // The song's other version was asked for too (a playlist that holds both): it plays once.
            if let song = songs[key], song.asked.contains(!layout) {
                if i == index { start = song.at }
                continue
            }
            if i == index { start = resolved.count }
            songs[key] = ((songs[key]?.asked ?? []).union([layout]), songs[key]?.at ?? resolved.count)
            resolved.append(layout == surround ? track : track.asOtherLayout ?? track)
        }
        return (resolved, start)
    }

    /// The album `tracks` keep to: theirs, when they are several songs of one album.
    public static func album(of tracks: [TrackSummary]) -> String? {
        guard tracks.count > 1, let first = tracks.first?.albumKey, tracks.allSatisfy({ $0.albumKey == first }) else { return nil }
        return first
    }

    /// A queued song as it plays on an output that wants surround or doesn't: its other version when that is the one
    /// for the output, else nil (it stays as it is). `oneAlbum`: the album the queue keeps to, if it was started as one album.
    public static func changed(_ track: TrackSummary, surround: Bool, oneAlbum: String? = nil) -> TrackSummary? {
        guard let layout = track.surround, layout != surround, let other = track.otherLayout else { return nil }
        if let oneAlbum, other.albumKey != oneAlbum { return nil }
        return track.asOtherLayout
    }
}
