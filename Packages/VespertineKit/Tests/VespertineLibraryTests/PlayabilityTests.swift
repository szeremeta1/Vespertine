//
// Vespertine: the one playability rule, the Source column's kinds and the "≈" of a format TIDAL only lists.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

private func track(location: String = "/Music/a.flac", filePath: String? = nil, sourceId: Int64? = 1) -> Track {
    Track(id: 1, sourceId: sourceId, location: location, filePath: filePath ?? location, fileSize: 1, modifiedAt: .now, addedAt: .now,
          codec: "FLAC", isLossless: true, isDSD: false, sampleRate: 96_000, bitDepth: 24, channels: 2, duration: 100, bitrate: nil,
          cueStartFrame: nil, cueFrameLength: nil, title: "T", artist: nil, album: nil, albumArtist: nil, composer: nil, genre: nil,
          releaseDate: nil, year: nil, trackNumber: nil, trackTotal: nil, discNumber: nil, discTotal: nil, compilation: false, grouping: nil,
          comment: nil, lyrics: nil, bpm: nil, rating: nil, isrc: nil, label: nil, musicBrainzReleaseID: nil, musicBrainzRecordingID: nil,
          titleSort: nil, artistSort: nil, albumSort: nil, albumArtistSort: nil, extraTags: [:], rgTrackGain: nil, rgTrackPeak: nil,
          rgAlbumGain: nil, rgAlbumPeak: nil, artworkKey: nil, playCount: 0, lastPlayedAt: nil, isMissing: false, effectiveBitDepth: nil,
          bandwidthHz: nil, analysisVerdict: nil)
}

private func record(streamable: Bool = true, download: String? = nil, probed: Bool = false) -> TidalTrackRecord {
    TidalTrackRecord(trackId: 1, tidalId: 5, albumId: nil, artistIds: [], listedQuality: "HI_RES_LOSSLESS", mediaTags: [], explicit: false,
                     copyright: nil, popularity: nil, streamable: streamable, unavailableReason: nil, downloadPath: download,
                     formatIsProbed: probed, lastSyncedAt: nil)
}

private let folder = LibrarySource(id: 1, path: "/Music", mode: .reference, isOnline: true)
private let offlineFolder = LibrarySource(id: 1, path: "/Music", mode: .reference, isOnline: false)
private let share = LibrarySource(id: 2, path: "/Volumes/NAS", mode: .reference, isOnline: true, remoteURL: "smb://nas/music", name: "NAS")
private let offlineShare = LibrarySource(id: 2, path: "/Volumes/NAS", mode: .reference, isOnline: false, remoteURL: "smb://nas/music", name: "NAS")
private let tidalSource = LibrarySource(id: 3, path: "tidal://", mode: .reference, isOnline: true, remoteURL: "tidal://user/1", name: "TIDAL")

private func rule(_ t: Track, _ source: LibrarySource?, _ tidal: TidalTrackRecord? = nil, signedIn: Bool = true, reachable: Bool = true,
                  backingOff: Bool = false, present: Set<String> = []) -> Playability {
    Playability.playability(track: t, source: source, tidal: tidal, signedIn: signedIn, reachable: reachable, backingOff: backingOff,
                            fileExists: present.contains)
}

@Suite("Playability")
struct PlayabilityTests {
    private static let streaming = track(location: "tidal://track/5", filePath: "", sourceId: 3)
    private static let downloadPath = "/Music/TIDAL/a.flac"
    private static let downloaded = track(location: "tidal://track/5", filePath: downloadPath, sourceId: 3)

    @Test("Local and share songs play when their source is online, whatever TIDAL is doing")
    func filesFollowTheirSource() {
        for signedIn in [true, false] {
            for reachable in [true, false] {
                for backingOff in [true, false] {
                    #expect(rule(track(), folder, signedIn: signedIn, reachable: reachable, backingOff: backingOff) == .playable)
                    #expect(rule(track(), offlineFolder, signedIn: signedIn, reachable: reachable, backingOff: backingOff) == .unavailable(reason: "Offline"))
                    #expect(rule(track(), share, signedIn: signedIn, reachable: reachable, backingOff: backingOff) == .playable)
                    #expect(rule(track(), offlineShare, signedIn: signedIn, reachable: reachable, backingOff: backingOff) == .unavailable(reason: "Offline"))
                }
            }
        }
        #expect(rule(track(sourceId: nil), nil) == .playable, "a song with no source row has nothing to be offline")
    }

    /// Every combination for a TIDAL song: what the rule must answer, written out by hand (account state first).
    @Test("TIDAL songs, every combination", arguments: [
        // signedIn, reachable, backingOff, download (nil / present / missing), streamable, expected
        (true,  true,  false, "none",    true,  Playability.playable),
        (true,  true,  false, "none",    false, .unavailable(reason: "Not available in your country")),
        (true,  true,  false, "present", true,  .playable),
        (true,  true,  false, "present", false, .playable),
        (true,  true,  false, "missing", true,  .playable),
        (true,  true,  false, "missing", false, .unavailable(reason: "Not available in your country")),
        (true,  false, false, "none",    true,  .unavailable(reason: "Offline")),
        (true,  false, false, "none",    false, .unavailable(reason: "Offline")),
        (true,  false, false, "present", true,  .playable),
        (true,  false, false, "present", false, .playable),
        (true,  false, false, "missing", true,  .unavailable(reason: "Offline")),
        (true,  true,  true,  "none",    true,  .unavailable(reason: "TIDAL asked us to wait")),
        (true,  true,  true,  "present", true,  .playable),
        (true,  true,  true,  "missing", true,  .unavailable(reason: "TIDAL asked us to wait")),
        (true,  false, true,  "none",    true,  .unavailable(reason: "TIDAL asked us to wait")),
        (false, true,  false, "none",    true,  .unavailable(reason: "Sign in to TIDAL")),
        (false, true,  false, "present", true,  .playable),
        (false, true,  false, "missing", true,  .unavailable(reason: "Sign in to TIDAL")),
        (false, false, false, "none",    true,  .unavailable(reason: "Sign in to TIDAL")),
        (false, false, false, "present", true,  .playable),
        (false, false, true,  "none",    false, .unavailable(reason: "Sign in to TIDAL")),
        (false, false, true,  "present", false, .playable),
    ])
    func tidalTable(signedIn: Bool, reachable: Bool, backingOff: Bool, download: String, streamable: Bool, expected: Playability) {
        let path = download == "none" ? nil : Self.downloadPath
        let t = path == nil ? Self.streaming : Self.downloaded
        let present: Set<String> = download == "present" ? [Self.downloadPath] : []
        #expect(rule(t, tidalSource, record(streamable: streamable, download: path), signedIn: signedIn, reachable: reachable,
                     backingOff: backingOff, present: present) == expected)
    }

    @Test("A TIDAL song's TIDAL source being marked offline in the database does not matter: the rule reads the live state")
    func ignoresTheSourceFlag() {
        let flagged = LibrarySource(id: 3, path: "tidal://", mode: .reference, isOnline: false, remoteURL: "tidal://user/1", name: "TIDAL")
        #expect(rule(Self.streaming, flagged, record()) == .playable)
    }

    @Test("A row with no TIDAL record but the TIDAL source or location is still a TIDAL song; its download is its file path")
    func recordless() {
        #expect(rule(Self.streaming, tidalSource, nil, signedIn: false) == .unavailable(reason: "Sign in to TIDAL"))
        #expect(rule(Self.downloaded, tidalSource, nil, signedIn: false, present: [Self.downloadPath]) == .playable)
        #expect(rule(Self.downloaded, tidalSource, nil, signedIn: false, present: []) == .unavailable(reason: "Sign in to TIDAL"))
    }

    @Test("The file is only looked for when the song is downloaded")
    func fileCheckIsLazy() {
        var asked: [String] = []
        _ = Playability.playability(track: track(), source: folder, tidal: nil, signedIn: true, reachable: true, backingOff: false) { asked.append($0); return true }
        _ = Playability.playability(track: Self.streaming, source: tidalSource, tidal: record(), signedIn: true, reachable: true, backingOff: false) { asked.append($0); return true }
        #expect(asked.isEmpty)
        _ = Playability.playability(track: Self.downloaded, source: tidalSource, tidal: record(download: Self.downloadPath), signedIn: true, reachable: true,
                                    backingOff: false) { asked.append($0); return true }
        #expect(asked == [Self.downloadPath])
    }

    @Test("Source kinds: local, share by name, TIDAL streaming and downloaded, with their tooltips")
    func sources() {
        #expect(TrackSource.of(track: track(), source: folder, tidal: nil) == .local)
        #expect(TrackSource.of(track: track(), source: share, tidal: nil) == .share(name: "NAS"))
        #expect(TrackSource.of(track: Self.streaming, source: tidalSource, tidal: record()) == .tidalStreaming)
        #expect(TrackSource.of(track: Self.downloaded, source: tidalSource, tidal: record(download: Self.downloadPath)) == .tidalDownloaded)
        #expect(TrackSource.tidalStreaming.help == "TIDAL · streaming" && TrackSource.tidalDownloaded.help == "TIDAL · downloaded")
        #expect(TrackSource.local.help == "Local" && TrackSource.share(name: "NAS").help == "NAS")
        #expect(TrackSource.tidalStreaming.isTidal && !TrackSource.local.isTidal)
    }

    @Test("Sorting by source groups folders and shares by source, then TIDAL streamed, then TIDAL downloaded")
    func sourceSort() {
        let keys = [track(sourceId: 1), track(sourceId: 2), Self.streaming, Self.downloaded].map(\.sourceSortKey)
        #expect(keys == keys.sorted() && Set(keys).count == 4)
    }

    @Test("A TIDAL song not yet played shows its listed format with ≈ and a tooltip; a probed one, and every other song, shows its own")
    func approximateFormat() {
        let streamed = Self.streaming
        let unprobed = streamed.formatLabel(tidal: record(probed: false))
        #expect(unprobed.text == streamed.formatSummary + " ≈" && unprobed.help == "Listed by TIDAL; confirmed when played")
        let probed = streamed.formatLabel(tidal: record(probed: true))
        #expect(probed.text == streamed.formatSummary && probed.help == nil)
        let local = track().formatLabel(tidal: nil)
        #expect(local.text == track().formatSummary && local.help == nil)
    }

    @Test("A catalog row (a TIDAL song with no library row) shows ≈ too, until its stream has been read")
    func approximateCatalogFormat() {
        var catalog = Self.streaming
        catalog.id = nil
        let listed = catalog.formatLabel(tidal: nil)
        #expect(listed.text == catalog.formatSummary + " ≈" && listed.help != nil)
        let probed = catalog.formatLabel(tidal: nil, probed: true)
        #expect(probed.text == catalog.formatSummary && probed.help == nil)
    }

    @Test("A probed format applied to a track replaces codec, rate, depth and channels; a lossless one drops the bitrate")
    func applyProbedFormat() {
        var t = Self.streaming
        t.codec = "AAC"; t.isLossless = false; t.bitrate = 96; t.bitDepth = nil; t.sampleRate = 44_100
        t.applyProbedFormat(codec: "flac", sampleRate: 96_000, bitDepth: 24, channels: 2)
        #expect(t.codec == "FLAC" && t.isLossless && t.sampleRate == 96_000 && t.bitDepth == 24 && t.bitrate == nil && t.channels == 2)
    }
}
