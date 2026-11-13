import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
@testable import Vespertine

/// What a TIDAL row plays from: its download when the file is there, else the stream through the playback cache.
@Suite("TIDAL playable items") @MainActor
struct TidalItemTests {
    /// A real TIDAL row (and its record) from a library on disk.
    private static let fixture: (Track, TidalTrackRecord) = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidal-items-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try! LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        let source = try! database.tidalSource(userId: 1).id!
        let ids = try! database.upsertTidalTracks([TidalTrackInput(tidalId: 77, title: "T")], sourceId: source)
        let id = ids[77]!
        return (try! database.allTracks().first { $0.id == id }!, try! database.tidalRecord(trackId: id)!)
    }()

    private func track(location: String, filePath: String) -> Track {
        var t = Self.fixture.0
        t.location = location
        t.filePath = filePath
        return t
    }

    private func record(download: String?) -> TidalTrackRecord {
        var r = Self.fixture.1
        r.downloadPath = download
        return r
    }

    @Test("A local row is left alone")
    func local() {
        #expect(PlayerController.tidalAddress(of: track(location: "/a.flac", filePath: "/a.flac"), record: nil, fileExists: { _ in true }) == nil)
    }

    @Test("A streamed row plays tidal://track/<id> through the cache key tidal:<id>")
    func streaming() {
        let address = PlayerController.tidalAddress(of: track(location: "tidal://track/77", filePath: ""), record: record(download: nil),
                                                    fileExists: { _ in true })
        #expect(address?.url.absoluteString == "tidal://track/77" && address?.cacheKey == "tidal:77")
    }

    @Test("A downloaded row whose file is there plays the file, with no cache key")
    func downloaded() {
        let address = PlayerController.tidalAddress(of: track(location: "tidal://track/77", filePath: "/m/a.flac"),
                                                    record: record(download: "/m/a.flac"), fileExists: { $0 == "/m/a.flac" })
        #expect(address?.url == URL(fileURLWithPath: "/m/a.flac") && address?.cacheKey == nil)
    }

    @Test("A downloaded row whose file was deleted streams again")
    func downloadGone() {
        let address = PlayerController.tidalAddress(of: track(location: "tidal://track/77", filePath: "/m/a.flac"),
                                                    record: record(download: "/m/a.flac"), fileExists: { _ in false })
        #expect(address?.url.absoluteString == "tidal://track/77" && address?.cacheKey == "tidal:77")
    }

    @Test("The probed format is recorded once per track, only for streamed TIDAL items not probed before")
    func probedOnce() {
        var recorded: [Int64] = []
        let recorder = ProbedFormatRecorder { id, _ in recorded.append(id) }
        let format = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2)
        let tidal = URL(string: "tidal://track/77")!
        recorder.observe(url: tidal, trackID: 5, source: format, alreadyProbed: false)
        recorder.observe(url: tidal, trackID: 5, source: format, alreadyProbed: false)
        recorder.observe(url: tidal, trackID: 6, source: format, alreadyProbed: true)
        recorder.observe(url: URL(fileURLWithPath: "/a.flac"), trackID: 7, source: format, alreadyProbed: false)
        recorder.observe(url: tidal, trackID: 8, source: nil, alreadyProbed: false)
        #expect(recorded == [5])
    }
}
