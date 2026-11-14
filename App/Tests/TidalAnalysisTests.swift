import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

/// Decision 206: a streamed TIDAL song's complete staged copy is analyzed before its lease goes; the result is stored under
/// `tidal://track/<id>` and the handed-over file is deleted.
@Suite("TIDAL analysis of staged streams") @MainActor
struct TidalAnalysisTests {
    @Test("A complete staged copy is analyzed, stored for the streamed row, and its file deleted")
    func analyzesStaged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidal-analysis-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        let source = try #require(try database.tidalSource(userId: 1).id)
        let ids = try database.upsertTidalTracks([TidalTrackInput(tidalId: 77, title: "Streamed")], sourceId: source)
        // The fake staged entry: one second of a 24-bit tone.
        let staged = root.appendingPathComponent("complete-1.wav")
        let file = try AVAudioFile(forWriting: staged, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                                                  AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for c in 0..<2 { for i in 0..<48_000 { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.05) * 0.5) } }
        try file.write(from: buffer)

        let saved = AnalysisQueue.analyzeStaged(file: staged, url: URL(string: "tidal://track/77")!, database: database)
        #expect(saved)
        #expect(!FileManager.default.fileExists(atPath: staged.path), "the staged copy's link is deleted")
        let row = try #require(try database.allTracks().first { $0.id == ids[77] })
        #expect(try database.storedAnalysis(for: row) != nil)
        // Not a TIDAL track: nothing stored, and the file is still deleted.
        let other = root.appendingPathComponent("other.wav")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Library.sqlite"), to: other)
        #expect(!AnalysisQueue.analyzeStaged(file: other, url: URL(string: "tidal://album/1")!, database: database))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
}
