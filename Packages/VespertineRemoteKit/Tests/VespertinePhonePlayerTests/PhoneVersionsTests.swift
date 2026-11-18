//
// Vespertine: a song the library has in stereo and in surround plays on this phone as the version for the phone's own
// output, once, and follows the output when it changes.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

/// "Harbor" in stereo on the album (1) and in Dolby Atmos on the album's Atmos edition (101); "Lanterns" (2) only in
/// stereo; "Tide" in stereo (3) and in 5.1 (4) on the one album.
private func song(_ id: Int64, album: String = "evening", surround: Bool? = false, other: Int64? = nil, otherAlbum: String? = nil) -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "The Vesper Quartet", album: album, albumKey: album, duration: 200, trackNumber: Int(id % 100),
                 discNumber: 1, format: surround == true ? "Dolby Atmos · 768k · 5.1" : "ALAC · 24/96", artworkKey: "art-\(album)", favorite: false,
                 surround: surround,
                 otherLayout: other.map { TrackVersion(id: $0, album: otherAlbum ?? album, albumKey: otherAlbum ?? album, duration: 201,
                                                       format: surround == true ? "ALAC · 24/96" : "Dolby Atmos · 768k · 5.1",
                                                       artworkKey: "art-\(otherAlbum ?? album)") })
}

private let harbor = song(1, other: 101, otherAlbum: "evening atmos")
private let harborAtmos = song(101, album: "evening atmos", surround: true, other: 1, otherAlbum: "evening")
private let lanterns = song(2)
private let tide = song(3, other: 4)
private let tideSurround = song(4, surround: true, other: 3)
private let elsewhere = song(50, album: "other")

@Suite("A song's stereo and surround versions on the phone")
struct PhoneVersionsTests {
    @Test func theOtherVersionIsTheSameSongAndLeadsBack() throws {
        let atmos = try #require(harbor.asOtherLayout)
        #expect(atmos.id == 101 && atmos.albumKey == "evening atmos" && atmos.surround == true)
        #expect(atmos.format == "Dolby Atmos · 768k · 5.1" && atmos.duration == 201 && atmos.artworkKey == "art-evening atmos")
        #expect(atmos.title == harbor.title && atmos.artist == harbor.artist)
        let back = try #require(atmos.asOtherLayout)
        #expect(back.id == 1 && back.albumKey == "evening" && back.surround == false && back.format == "ALAC · 24/96" && back.duration == 200)
        #expect(lanterns.asOtherLayout == nil)
        // An older Mac says nothing of layouts: nothing is swapped.
        #expect(song(9, surround: nil).asOtherLayout == nil)
    }

    @Test func aSurroundOutputPlaysTheSurroundVersionAndAStereoOneTheStereoVersion() {
        let asked = [harbor, elsewhere, lanterns]
        #expect(PhoneVersions.resolve(asked, surround: true).tracks.map(\.id) == [101, 50, 2])
        #expect(PhoneVersions.resolve(asked, surround: false).tracks.map(\.id) == [1, 50, 2])
        #expect(PhoneVersions.resolve([harborAtmos, elsewhere], surround: false).tracks.map(\.id) == [1, 50], "hearted in Atmos, played on headphones")
        #expect(PhoneVersions.resolve([harborAtmos, elsewhere], surround: true).tracks.map(\.id) == [101, 50])
    }

    @Test func bothVersionsAskedForTogetherPlayOnce() {
        let both = [elsewhere, harbor, lanterns, harborAtmos, tideSurround, tide]
        #expect(PhoneVersions.resolve(both, surround: true).tracks.map(\.id) == [50, 101, 2, 4])
        #expect(PhoneVersions.resolve(both, surround: false).tracks.map(\.id) == [50, 1, 2, 3])
        // The same song put on a playlist twice is still there twice.
        #expect(PhoneVersions.resolve([harbor, elsewhere, harbor], surround: true).tracks.map(\.id) == [101, 50, 101])
    }

    @Test func theSongToStartWithKeepsItsPlace() {
        let both = [elsewhere, harbor, lanterns, harborAtmos, tide]
        #expect(PhoneVersions.resolve(both, surround: true, startAt: 2).startAt == 2)
        #expect(PhoneVersions.resolve(both, surround: true, startAt: 3).startAt == 1, "the version dropped starts as the one that plays")
        #expect(PhoneVersions.resolve(both, surround: true, startAt: 4).startAt == 3)
        #expect(PhoneVersions.resolve(both, surround: true).startAt == nil)
    }

    @Test func severalSongsOfOneAlbumKeepToThatAlbum() {
        // The stereo album played from its own page is the stereo album; its own 5.1 tracks still follow the output.
        #expect(PhoneVersions.album(of: [harbor, lanterns, tide]) == "evening")
        #expect(PhoneVersions.resolve([harbor, lanterns, tide], surround: true).tracks.map(\.id) == [1, 2, 4])
        // One song asked for by itself is a song, not an album.
        #expect(PhoneVersions.album(of: [harbor]) == nil)
        #expect(PhoneVersions.resolve([harbor], surround: true).tracks.map(\.id) == [101])
        #expect(PhoneVersions.album(of: [harbor, elsewhere]) == nil)
    }

    @Test func aQueuedSongChangesOnlyWhenTheOutputWantsItsOtherVersion() {
        #expect(PhoneVersions.changed(harbor, surround: true)?.id == 101)
        #expect(PhoneVersions.changed(harbor, surround: false) == nil)
        #expect(PhoneVersions.changed(harborAtmos, surround: false)?.id == 1)
        #expect(PhoneVersions.changed(lanterns, surround: true) == nil)
        #expect(PhoneVersions.changed(harbor, surround: true, oneAlbum: "evening") == nil)
        #expect(PhoneVersions.changed(tide, surround: true, oneAlbum: "evening")?.id == 4)
    }

    @Test func theQueueGivesUpcomingSongsTheirOtherVersionAndLeavesThePlayingOneAlone() {
        var queue = PhoneQueue()
        queue.play([harbor, tide, lanterns, harbor], startAt: 0)
        let before = queue.entries.map(\.id)
        let revision = queue.revision
        let toSurround = queue.retrackUpcoming { PhoneVersions.changed($0.track, surround: true) }
        #expect(toSurround)
        #expect(queue.entries.compactMap(\.track.id) == [1, 4, 2, 101], "the song playing stays the version it is")
        #expect(queue.current?.id == before[0] && queue.revision > revision)
        // A changed entry is a new entry (what was opened for the old one is another file); the rest keep theirs.
        #expect(queue.entries[1].id != before[1] && queue.entries[2].id == before[2] && queue.entries[3].id != before[3])
        // Shuffle off puts the songs back in their order, as the versions they are now.
        queue.setShuffle(true)
        queue.setShuffle(false)
        #expect(queue.entries.compactMap(\.track.id) == [1, 4, 2, 101])
        // And back, when the output is a stereo one again.
        let toStereo = queue.retrackUpcoming { PhoneVersions.changed($0.track, surround: false) }
        #expect(toStereo)
        #expect(queue.entries.compactMap(\.track.id) == [1, 3, 2, 1])
        let again = queue.retrackUpcoming { PhoneVersions.changed($0.track, surround: false) }
        var empty = PhoneQueue()
        let nothing = empty.retrackUpcoming { _ in lanterns }
        #expect(!again && !nothing)
    }

    @Test func whichOutputsGetASongsSurroundVersion() {
        let interface = PhoneRoute(name: "Interface", portType: "USBAudio", sampleRate: 48_000, channels: 2, spatial: false, maximumChannels: 6)
        #expect(interface.wantsSurround(wanted: .off), "a 5.1 interface, though it runs with two channels while a stereo song plays")
        #expect(PhoneRoute(name: "Receiver", portType: "HDMI", sampleRate: 48_000, channels: 8, spatial: false).wantsSurround(wanted: .off))
        let dac = PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: 48_000, channels: 2, spatial: false)
        #expect(!dac.wantsSurround(wanted: .off))
        #expect(dac.wantsSurround(wanted: .fixed), "surround rendered for headphones is surround")
        let airPods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        #expect(!airPods.wantsSurround(wanted: .off) && airPods.wantsSurround(wanted: .headTracked))
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false)
        #expect(!speaker.wantsSurround(wanted: .headTracked), "the speaker folds surround to stereo: it gets the stereo version")
    }

    @Test func aSummaryFromAnOlderMacReadsAsBefore() throws {
        let old = #"{"id":7,"title":"T","artist":"A","album":"B","albumKey":"k","duration":1,"format":"FLAC","favorite":false}"#
        let read = try JSONDecoder().decode(TrackSummary.self, from: Data(old.utf8))
        #expect(read.surround == nil && read.otherLayout == nil)
        let sent = try JSONDecoder().decode(TrackSummary.self, from: JSONEncoder().encode(harbor))
        #expect(sent == harbor)
    }
}

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import VespertineRemoteClient

@Suite(.serialized) @MainActor struct PhoneRemoteVersionsTests {
    private static let library: [Int64: TrackSummary] = Dictionary(uniqueKeysWithValues: [harbor, harborAtmos, lanterns, tide, tideSurround, elsewhere].map { ($0.id!, $0) })

    private func made() throws -> PhoneRemote {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let client = PhoneStreamClient(open: { _, _ in .streamPreparing(progress: 0.25) }, read: { _, _, _ in throw RemoteLinkError.closed },
                                       close: { _ in }, isConnected: { true })
        let playback = PhonePlayback(client: client, player: PhonePlayer(engine: engine),
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("phone-versions-\(UUID())"))
        playback.pollInterval = .milliseconds(10)
        return PhoneRemote(playback: playback, library: { command in
            switch command {
            case .tracks(let ids): .tracks(items: ids.compactMap { Self.library[$0] })
            case .albumTracks: .tracks(items: [harbor, lanterns, tide])
            default: .failed(reason: "unexpected")
            }
        })
    }

    private let interface = PhoneRoute(name: "Interface", portType: "USBAudio", sampleRate: 48_000, channels: 6, spatial: false, maximumChannels: 6)
    private let dac = PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: 48_000, channels: 2, spatial: false)

    private func queued(_ remote: PhoneRemote) -> [Int64] { remote.playback.queue.entries.compactMap(\.track.id) }

    @Test func thePhonesOwnOutputPicksTheVersionAndTheQueueFollowsIt() async throws {
        let remote = try made()
        defer { remote.playback.stop() }
        remote.route = interface
        // Favorites, as the Mac listed them for its own output: the stereo Harbor, both Tides.
        #expect(await remote.run(.playTracks(ids: [1, 2, 3, 4, 50], startAt: 3, shuffled: nil)) == .ok)
        #expect(queued(remote) == [101, 2, 4, 50], "each song once, as its surround version")
        #expect(remote.queueState.current?.track.id == 4, "the song tapped is the one that starts")
        // A stereo DAC is plugged in: the songs still to come are the stereo versions; the one playing plays on.
        remote.route = dac
        #expect(queued(remote) == [101, 2, 4, 50])
        _ = await remote.run(.playTracks(ids: [1, 2, 3, 4, 50], startAt: 0, shuffled: nil))
        #expect(queued(remote) == [1, 2, 3, 50])
        remote.route = interface
        #expect(queued(remote) == [1, 2, 4, 50], "upcoming songs follow the output; the song playing stays")
        // Surround rendered for headphones counts as a surround output.
        remote.route = dac
        #expect(queued(remote) == [1, 2, 3, 50])
        remote.surroundChoice = .fixed
        #expect(queued(remote) == [1, 2, 4, 50])
    }

    @Test func aCopyPickedByHandAndAnAlbumFromItsPageStayAsTheyAre() async throws {
        let remote = try made()
        defer { remote.playback.stop() }
        remote.route = interface
        _ = await remote.run(.playCopy(ids: [2, 1], startAt: 0))
        #expect(queued(remote) == [2, 1], "the copy asked for by name")
        remote.route = dac
        remote.route = interface
        #expect(queued(remote) == [2, 1])
        // Added after it, a song follows the output as any other.
        _ = await remote.run(.addToQueue(ids: [3]))
        #expect(queued(remote) == [2, 4, 1])

        // The stereo album from its own page: its Atmos edition stays out, its own 5.1 track plays.
        _ = await remote.run(.playAlbum(key: "evening", startAt: 0, shuffled: nil))
        #expect(queued(remote) == [1, 2, 4])
        remote.route = dac
        #expect(queued(remote) == [1, 2, 3])
        remote.route = interface
        #expect(queued(remote) == [1, 2, 4])
        // One song put next by itself follows the output, to the other edition too.
        _ = await remote.run(.playNext(ids: [1]))
        #expect(queued(remote) == [1, 101, 2, 4])
    }

    @Test func switchedOffEverySongPlaysAsAskedFor() async throws {
        let remote = try made()
        defer { remote.playback.stop() }
        remote.combinesVersions = false
        remote.route = interface
        _ = await remote.run(.playTracks(ids: [1, 101, 3, 4], startAt: 0, shuffled: nil))
        #expect(queued(remote) == [1, 101, 3, 4])
        remote.route = dac
        #expect(queued(remote) == [1, 101, 3, 4])
    }
}
#endif
