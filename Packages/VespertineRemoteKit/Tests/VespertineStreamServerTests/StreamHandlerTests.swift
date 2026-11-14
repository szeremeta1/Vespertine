//
// Vespertine: stream commands as the Mac's server answers them: who may stream, and what each command turns into.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineStreamServer

private struct NoConversion: StreamTranscoding {
    func transcode(_ request: TranscodeRequest, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> TranscodeResult {
        throw TranscodeFailure(message: "not in this test")
    }
}

private func makePreparer() throws -> (StreamPreparer, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-handler-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let song = dir.appendingPathComponent("a.flac")
    try Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) }).write(to: song)
    let facts = StreamSourceFacts(id: 7, url: song, fileExtension: "flac", codec: "FLAC", isDSD: false, isLossless: true, sampleRate: 44_100, bitDepth: 16,
                                  channels: 2, duration: 10, fileSize: 3000, modifiedAt: Date(timeIntervalSince1970: 1), isRegion: false,
                                  needsMacDecoder: false, replayGain: nil)
    let preparer = StreamPreparer(cache: try StreamCache(directory: dir.appendingPathComponent("c"), limitBytes: 1000), transcoder: NoConversion(),
                                  source: { $0 == 7 ? facts : nil })
    return (preparer, dir)
}

@Suite struct StreamCommands {
    @Test func onlyStreamCommandsAreTheirs() {
        #expect(StreamPreparer.isStreamCommand(.streamOpen(id: 1, maxSampleRate: nil)))
        #expect(StreamPreparer.isStreamCommand(.streamRead(stream: 1, offset: 0, length: 1)))
        #expect(StreamPreparer.isStreamCommand(.streamInfo(ids: [], maxSampleRate: nil)))
        #expect(StreamPreparer.isStreamCommand(.streamClose(stream: 1)))
        #expect(!StreamPreparer.isStreamCommand(.next))
        #expect(!StreamPreparer.isStreamCommand(.albums(offset: 0, limit: 10)))
    }

    @Test func aVersionOnePhoneIsToldToUpdate() async throws {
        let (preparer, dir) = try makePreparer(); defer { try? FileManager.default.removeItem(at: dir) }
        let answer = await preparer.handle(.streamOpen(id: 7, maxSampleRate: nil), id: 1, client: "a", protocolVersion: 1, allowed: true)
        guard case .reply(.failed(let reason))? = answer else { Issue.record("answered \(String(describing: answer))"); return }
        #expect(!reason.isEmpty)
    }

    @Test func streamingTurnedOffOnTheMacIsRefusedWithWords() async throws {
        let (preparer, dir) = try makePreparer(); defer { try? FileManager.default.removeItem(at: dir) }
        for command: RemoteCommand in [.streamInfo(ids: [7], maxSampleRate: nil), .streamOpen(id: 7, maxSampleRate: nil), .streamRead(stream: 1, offset: 0, length: 10)] {
            guard case .reply(.failed(let reason))? = await preparer.handle(command, id: 1, client: "a", protocolVersion: 2, allowed: false) else {
                Issue.record("\(command) was served while streaming is off"); continue
            }
            #expect(reason.contains("Settings"))
        }
    }

    @Test func infoOpenReadAndCloseWalkThroughASong() async throws {
        let (preparer, dir) = try makePreparer(); defer { try? FileManager.default.removeItem(at: dir) }
        guard case .reply(.streamInfo(let items))? = await preparer.handle(.streamInfo(ids: [7, 8], maxSampleRate: nil), id: 1, client: "a", protocolVersion: 2, allowed: true) else {
            Issue.record("no info"); return
        }
        #expect(items.map(\.id) == [7])
        guard case .reply(.streamOpened(let descriptor))? = await preparer.handle(.streamOpen(id: 7, maxSampleRate: nil), id: 2, client: "a", protocolVersion: 2, allowed: true) else {
            Issue.record("no descriptor"); return
        }
        guard case .frame(let frame)? = await preparer.handle(.streamRead(stream: descriptor.stream, offset: 10, length: 20), id: 3, client: "a", protocolVersion: 2, allowed: true) else {
            Issue.record("no frame"); return
        }
        #expect(frame.request == 3 && frame.offset == 10 && frame.payload.count == 20, "the frame answers the read's own id")
        #expect(await preparer.handle(.streamClose(stream: descriptor.stream), id: 4, client: "a", protocolVersion: 2, allowed: true) == .reply(.ok))
        guard case .reply(.failed)? = await preparer.handle(.streamRead(stream: descriptor.stream, offset: 0, length: 5), id: 5, client: "a", protocolVersion: 2, allowed: true) else {
            Issue.record("read after close"); return
        }
    }

    @Test func onlyAPhoneThatPlaysSongsItselfIsToldTheyStopped() {
        #expect(StreamNotice.tells(protocolVersion: RemoteProtocol.streamVersion))
        #expect(!StreamNotice.tells(protocolVersion: 1))
    }

    @Test func anUnknownSongFailsInWords() async throws {
        let (preparer, dir) = try makePreparer(); defer { try? FileManager.default.removeItem(at: dir) }
        guard case .reply(.failed(let reason))? = await preparer.handle(.streamOpen(id: 404, maxSampleRate: nil), id: 1, client: "a", protocolVersion: 2, allowed: true) else {
            Issue.record("opened"); return
        }
        #expect(reason.contains("library"))
    }

    @Test func otherCommandsAreNotHandledHere() async throws {
        let (preparer, dir) = try makePreparer(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await preparer.handle(.next, id: 1, client: "a", protocolVersion: 2, allowed: true) == nil)
    }
}
