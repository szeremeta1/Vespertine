import Foundation
import Testing
import VespertineTidal
@testable import Vespertine

@Suite("TIDAL sidebar") @MainActor
struct TidalSidebarTests {
    @Test("Switching TIDAL off leaves a TIDAL page for Albums")
    func offLeavesTidalPages() {
        for item in [SidebarItem.tidalSearch, .tidalMixes, .tidalNewReleases, .tidalDownloads] {
            let (sidebar, path) = AppModel.navigation(afterTidalOff: item, path: [], sourceIDs: [], playlistIDs: [],
                                                      albumExists: { _ in true }, artistExists: { _ in true })
            #expect(sidebar == .albums && path.isEmpty)
        }
        #expect(!SidebarItem.albums.isTidal && SidebarItem.tidalDownloads.isTidal)
    }

    private func item(_ id: Int, _ state: TidalDownloader.State) -> TidalDownloader.Item {
        TidalDownloader.Item(kind: .track(TidalTrack(id: id, title: "T\(id)", duration: 1, trackNumber: 1, explicit: false,
                                                     audioQuality: "LOSSLESS", artists: [], album: TidalAlbumRef(id: 1, title: "A"))),
                             album: nil, state: state)
    }

    @Test("The Downloads ring: songs left, the run's share done, the backoff's reason")
    func progress() {
        let progress = TidalDownloadProgress(items: [item(1, .done(URL(fileURLWithPath: "/a"))), item(2, .downloading(0.5)), item(3, .queued),
                                                     item(4, .failed("x"))])
        #expect(progress.remaining == 2)
        #expect(progress.fraction == 0.5)
        #expect(progress.pausedReason == nil)
        let paused = TidalDownloadProgress(items: [item(1, .paused("TIDAL asked us to wait 2 min"))])
        #expect(paused.pausedReason == "TIDAL asked us to wait 2 min" && paused.remaining == 1)
        #expect(TidalDownloadProgress(items: []).remaining == 0)
    }
}
