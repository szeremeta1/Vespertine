//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineLibrary

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-stuck-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func audio(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100))
    buffer.frameLength = 44100
    for c in 0..<2 { for i in 0..<44100 { buffer.floatChannelData![c][i] = 0 } }
    try file.write(from: buffer)
}

/// A share that stops answering when one folder is listed: the listing blocks (as `contentsOfDirectory` does on a
/// hung SMB mount) until the test lets it go. `after`: the folder is read first and the call blocks afterwards, so
/// the listing a scan works from was taken before anything the test adds.
private final class StallingShare: @unchecked Sendable {
    private let condition = NSCondition()
    private let folder: String
    private let after: Bool
    private var stalling = true
    private var released = false
    private(set) var entered = 0

    init(stallingOn folder: String, after: Bool = false) { self.folder = folder; self.after = after }

    /// Calls from now on answer at once; one already stalled stays stalled until `release`.
    func recover() { condition.lock(); stalling = false; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    var hasStalled: Bool { condition.lock(); defer { condition.unlock() }; return entered > 0 }

    var reader: LibraryScanner.FolderReader {
        { [self] dir, keys in
            let read = { try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) }
            let items = after ? try read() : []
            condition.lock()
            if dir.lastPathComponent == folder, stalling {
                entered += 1
                while !released { condition.wait() }
            }
            condition.unlock()
            return after ? items : try read()
        }
    }
}

private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 10) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < end else { Issue.record("timed out waiting"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("A scan of a share that stops answering")
struct StuckScanTests {
    @Test("Listing a folder that never answers gives up after the deadline instead of waiting forever")
    func listingTimesOut() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try audio(root.appendingPathComponent("Ultimate Sinatra/Disc 4/16 - The World We Knew.wav"))
        let share = StallingShare(stallingOn: "Disc 4"); defer { share.release() }
        let start = Date()
        await #expect(throws: LibraryScanner.ScanError.self) {
            _ = try await LibraryScanner.list(root, network: true, gate: ShareIOGate(healthyGrace: 0), timeout: 0.3, readFolder: share.reader)
        }
        #expect(share.hasStalled)
        #expect(Date().timeIntervalSince(start) < 5, "the listing waited on the stalled folder")
    }

    @Test("A scan that times out stops with an error and marks nothing missing")
    func scanTimesOutWithoutMarkingMissing() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try audio(root.appendingPathComponent("Frank Sinatra/My Way/01 - My Way.wav"))
        try audio(root.appendingPathComponent("Ultimate Sinatra/Disc 4/16 - The World We Knew.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: root.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: root.path, mode: .reference))
        try await scanner.scan(source)
        #expect(try db.allTracks().count == 2)
        let scannedAt = try #require(try db.sources().first?.lastScannedAt)

        let share = StallingShare(stallingOn: "Disc 4"); defer { share.release() }
        await scanner.setFolderReader(share.reader)
        await scanner.setTimeouts(response: 0.3, stall: 60)
        let start = Date()
        await #expect(throws: LibraryScanner.ScanError.self) { try await scanner.scan(source) }
        #expect(Date().timeIntervalSince(start) < 5, "the scan waited on the stalled folder")
        #expect(try db.allTracks().count == 2, "a folder that didn't answer was taken for deleted files")  // missing ones are left out
        #expect(try db.sources().first?.lastScannedAt == scannedAt, "a scan that didn't finish counted as finished")
    }

    @Test("Rescan replaces a scan that has stopped moving, instead of waiting behind it")
    func rescanReplacesStalledScan() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try audio(root.appendingPathComponent("Ultimate Sinatra/Disc 4/16 - The World We Knew.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: root.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let share = StallingShare(stallingOn: "Disc 4"); defer { share.release() }
        await scanner.setFolderReader(share.reader)
        await scanner.setTimeouts(response: 600, stall: 0.2)
        let source = try db.addSource(LibrarySource(path: root.path, mode: .reference))

        let stuck = Task { try await scanner.scan(source) }
        try await waitUntil { share.hasStalled }
        try await Task.sleep(for: .milliseconds(400))
        // A scan asked for by the app (not by the user) still joins the one running.
        // The user presses Rescan: the share answers again by now, but the old listing is still hung.
        share.recover()
        let start = Date()
        let summary = try await scanner.scan(source, restart: true)
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(summary.added == 1)
        #expect(try db.allTracks().map(\.title) == ["16 - The World We Knew"])

        // The replaced scan ends as cancelled once its read returns, and writes nothing.
        share.release()
        await #expect(throws: CancellationError.self) { try await stuck.value }
        #expect(try db.allTracks().count == 1)
    }

    @Test("Rescan during a scan that is still moving runs again after it, so files added meanwhile are found")
    func rescanAfterHealthyScan() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try audio(root.appendingPathComponent("Ultimate Sinatra/Disc 4/01 - Old.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: root.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        // The folder is listed, then the answer is held: the running scan has its listing before the new file lands.
        let share = StallingShare(stallingOn: "Disc 4", after: true); defer { share.release() }
        await scanner.setFolderReader(share.reader)
        await scanner.setTimeouts(response: 600, stall: 600)
        let source = try db.addSource(LibrarySource(path: root.path, mode: .reference))

        let first = Task { try await scanner.scan(source) }
        try await waitUntil { share.hasStalled }
        try audio(root.appendingPathComponent("Ultimate Sinatra/Disc 4/16 - The World We Knew.wav"))
        share.recover()
        let second = Task { try await scanner.scan(source, restart: true) }
        try await Task.sleep(for: .milliseconds(200))
        share.release()
        #expect(try await first.value.added == 1)
        #expect(try await second.value.added == 1)
        #expect(Set(try db.allTracks().map(\.title)) == ["01 - Old", "16 - The World We Knew"])
    }
}
