import Foundation
import Testing
import VespertineLibrary
import VespertineTidal
@testable import Vespertine

@Suite("TIDAL routing") @MainActor
struct TidalRoutingTests {
    @Test("Hearts: TIDAL songs go to TIDAL (by their TIDAL id) while TIDAL is on; local songs, and everything while off, stay local")
    func favorites() {
        let tracks: [(Int64, Int?)] = [(1, nil), (2, 77), (3, 78)]
        #expect(TidalRouting.favoriteTargets(tracks, tidalOn: true) == [77, 78])
        #expect(TidalRouting.favoriteTargets(tracks, tidalOn: false) == [])
    }

    @Test("A playlist goes to TIDAL only when it is linked (or being created there) and TIDAL is on")
    func playlistTarget() {
        #expect(TidalRouting.target(linked: true, tidalOn: true) == .tidal)
        #expect(TidalRouting.target(linked: false, tidalOn: true) == .local)
        #expect(TidalRouting.target(linked: true, tidalOn: false) == .local)
    }

    @Test("Songs added to a TIDAL playlist: TIDAL songs by id; local songs need their TIDAL version found by ISRC")
    func adds() {
        let plan = TidalRouting.additions([(10, 70), (11, nil), (12, 72)])
        #expect(plan.tidal == [70, 72] && plan.needsLookup == [11])
    }

    @Test("A removal from a TIDAL playlist becomes removes by song and place (highest place first)")
    func removals() {
        #expect(TidalRouting.edits(from: [1, 2, 3, 2], to: [1, 3]) == [.remove(trackId: 2, index: 3), .remove(trackId: 2, index: 1)])
    }

    @Test("A reorder becomes moves that turn the old order into the new")
    func moves() {
        let old = [1, 2, 3, 4], new = [3, 1, 2, 4]
        let edits = TidalRouting.edits(from: old, to: new)
        #expect(edits == [.move(from: 2, to: 0)])
        #expect(TidalRouting.apply(TidalRouting.edits(from: [5, 6, 7, 8], to: [8, 7, 6, 5]), to: [5, 6, 7, 8]) == [8, 7, 6, 5])
        #expect(TidalRouting.apply(TidalRouting.edits(from: [1, 2, 3, 2, 4], to: [4, 2, 1]), to: [1, 2, 3, 2, 4]) == [4, 2, 1])
    }

    @Test("Un-hearting a downloaded TIDAL song: TIDAL is told, the heart goes at once, and the next pull keeps the row (not in favorites)")
    func unfavoriteDownloaded() async throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        let source = try #require(try rig.library.database.tidalSource(userId: 42).id)
        let ids = try rig.library.database.upsertTidalTracks([TidalTrackInput(tidalId: 9, title: "Kept")], sourceId: source)
        try rig.library.database.setTidalDownload(tidalId: 9, path: rig.root.appendingPathComponent("kept.flac").path)
        try rig.library.database.setFavorite(true, trackIDs: [ids[9]!])
        let model = rig.model()
        rig.library.tidalFavoritesChanged = { model.favoritesChanged($0, favorite: $1) }
        model.start()
        rig.library.setFavorite(false, trackIDs: [ids[9]!])
        #expect(try rig.library.database.favoriteTracks().isEmpty, "the heart goes at once")
        #expect(await eventually { model.pendingFavorites.contains(9) || rig.transport.requests.withLock { $0.contains { $0.httpMethod == "DELETE" } } })
        try rig.library.database.removeTidalTracks(notIn: [], sourceId: source)
        let record = try #require(try rig.library.database.tidalRecord(trackId: ids[9]!))
        #expect(record.unavailableReason == TidalTrackRecord.notInFavorites)
    }
}
