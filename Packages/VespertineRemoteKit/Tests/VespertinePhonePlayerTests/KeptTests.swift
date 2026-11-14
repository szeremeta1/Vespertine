//
// Vespertine: "Keep on This iPhone". An album or a playlist is fetched whole from the Mac and stays on the phone, listed and
// playable with the Mac off. What is kept survives the app closing, follows the list as it changes on the Mac, and never
// goes past the room it was given.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func song(_ id: Int64) -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 1, trackNumber: Int(id), discNumber: 1,
                 format: "WAV · 24/44.1", artworkKey: "art", favorite: false)
}

private func album(_ ids: [Int64], id: String = "album:a", smaller: Bool = false) -> KeptList {
    KeptList(id: id, kind: .album, reference: "a", title: "Album", subtitle: "Artist", artworkKey: "art", tracks: ids.map(song), smaller: smaller)
}

/// A Mac that sends each song's bytes, counting what it is asked, and can refuse a song or go away.
private final class KeepingMac: @unchecked Sendable {
    private let lock = NSLock()
    private var numbers: [Int: Int64] = [:]
    private var next = 0
    private var _opened: [Int64] = []
    private var _rates: [Double?] = []
    private var _closed = 0
    private var _connected = true
    private var _failAfter: Int?
    private var reads = 0
    var files: [Int64: Data] = [:]
    var refused: Set<Int64> = []

    var opened: [Int64] { lock.withLock { _opened } }
    var rates: [Double?] { lock.withLock { _rates } }
    var closed: Int { lock.withLock { _closed } }
    var connected: Bool {
        get { lock.withLock { _connected } }
        set { lock.withLock { _connected = newValue; if newValue { _failAfter = nil } } }
    }
    /// The connection drops after this many more reads.
    func drop(afterReads count: Int) { lock.withLock { _failAfter = reads + count } }

    static func format() -> StreamFormat {
        StreamFormat(codec: "WAV", container: "wav", sampleRate: 44_100, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true)
    }

    var client: PhoneStreamClient {
        PhoneStreamClient(open: { [self] id, rate in
            lock.withLock {
                guard _connected else { return .failed(reason: "") }
                if refused.contains(id) { return .failed(reason: "This song plays on the Mac only.") }
                guard let data = files[id] else { return .failed(reason: "That isn't in the library any more.") }
                next += 1
                numbers[next] = id
                _opened.append(id)
                _rates.append(rate)
                return .streamOpened(StreamDescriptor(stream: next, kind: .original, byteSize: Int64(data.count), format: Self.format(), frames: nil,
                                                      tag: "tag-\(id)", chunkSize: 1000))
            }
        }, read: { [self] stream, offset, length in
            let data: Data? = lock.withLock {
                reads += 1
                if let limit = _failAfter, reads > limit { _connected = false }
                guard _connected, let id = numbers[stream] else { return nil }
                return files[id]
            }
            guard let data else { throw RemoteLinkError.closed }
            let end = min(Int(offset) + length, data.count)
            return StreamFrame(request: 1, stream: stream, offset: offset, endOfStream: end >= data.count, payload: Data(data[Int(offset)..<end]))
        }, close: { [self] _ in lock.withLock { _closed += 1 } }, isConnected: { [self] in connected })
    }
}

@MainActor private func wait(_ seconds: Double = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { Issue.record("the condition never held"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func bytes(_ id: Int64, count: Int = 3500) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ Int(id)) }) }

@Suite(.serialized) @MainActor struct KeptTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kept-\(UUID())", isDirectory: true) }

    private func made(_ ids: [Int64], in directory: URL? = nil) throws -> (Keeper, KeepingMac, URL) {
        let directory = directory ?? folder()
        let mac = KeepingMac()
        for id in ids { mac.files[id] = bytes(id) }
        let keeper = Keeper(store: try KeptStore(directory: directory))
        keeper.pollInterval = .milliseconds(10)
        keeper.client = mac.client
        return (keeper, mac, directory)
    }

    @Test func anAlbumIsFetchedWholeAndIsStillThereWhenTheAppOpensAgain() async throws {
        let (keeper, mac, directory) = try made([1, 2, 3])
        keeper.keep(album([1, 2, 3]))
        #expect(keeper.progress(of: "album:a") == KeptProgress(done: 0, total: 3))
        try await wait { keeper.isIdle }
        #expect(keeper.progress(of: "album:a") == KeptProgress(done: 3, total: 3))
        #expect(mac.opened == [1, 2, 3])
        #expect(mac.closed == 3)
        #expect(keeper.store.bytes == 10_500)

        let again = try KeptStore(directory: directory)
        #expect(again.lists.map(\.id) == ["album:a"])
        #expect(again.lists[0].tracks.map(\.id) == [1, 2, 3])
        let kept = try #require(again.kept(2))
        #expect(try Data(contentsOf: kept.file) == bytes(2))
        #expect(kept.descriptor.tag == "tag-2" && kept.descriptor.format == KeepingMac.format())
        // Nothing half-made is left beside the songs.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.filter { $0.hasSuffix(".part") }.isEmpty)
    }

    @Test func aSongInTwoListsIsFetchedOnceAndStaysUntilBothAreGone() async throws {
        let (keeper, mac, _) = try made([1, 2, 3])
        keeper.keep(album([1, 2]))
        keeper.keep(KeptList(id: "playlist:7", kind: .playlist, reference: "7", title: "Evening", subtitle: "", artworkKey: nil, tracks: [song(2), song(3)], smaller: false))
        try await wait { keeper.isIdle }
        #expect(mac.opened == [1, 2, 3])
        let two = try #require(keeper.store.kept(2)).file
        keeper.remove("album:a")
        #expect(keeper.store.kept(1) == nil)
        #expect(FileManager.default.fileExists(atPath: two.path))
        keeper.remove("playlist:7")
        #expect(!FileManager.default.fileExists(atPath: two.path))
        #expect(keeper.store.bytes == 0 && keeper.store.lists.isEmpty)
    }

    @Test func aSongTheMacWillNotSendIsPassedOverAndSaidSo() async throws {
        let (keeper, mac, _) = try made([1, 2, 3])
        mac.refused = [2]
        keeper.keep(album([1, 2, 3]))
        try await wait { keeper.isIdle }
        #expect(keeper.progress(of: "album:a") == KeptProgress(done: 2, total: 3))
        #expect(keeper.unavailable == [2])
        #expect(keeper.store.kept(1) != nil && keeper.store.kept(3) != nil)
    }

    @Test func nothingIsFetchedPastTheRoomGiven() async throws {
        let (keeper, _, _) = try made([1, 2, 3])
        keeper.limitBytes = 8000
        keeper.keep(album([1, 2, 3]))
        try await wait { keeper.isIdle }
        #expect(keeper.progress(of: "album:a").done == 2)
        #expect(keeper.isFull)
        // More room: it carries on.
        keeper.limitBytes = 20_000
        keeper.resume()
        try await wait { keeper.isIdle }
        #expect(keeper.progress(of: "album:a").done == 3 && !keeper.isFull)
    }

    @Test func aMacThatGoesAwayMidSongLeavesNoBrokenFileAndTheRestComesLater() async throws {
        let (keeper, mac, directory) = try made([1, 2, 3])
        mac.drop(afterReads: 5)
        keeper.keep(album([1, 2, 3]))
        try await wait { keeper.isIdle }
        #expect(keeper.progress(of: "album:a").done == 1)
        #expect(keeper.unavailable.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.filter { $0.hasSuffix(".part") }.isEmpty)
        mac.connected = true
        keeper.resume()
        try await wait { keeper.isIdle }
        #expect(keeper.progress(of: "album:a").done == 3)
        #expect(try Data(contentsOf: #require(keeper.store.kept(2)).file) == bytes(2))
    }

    @Test func aKeptPlaylistFollowsWhatItHoldsOnTheMac() async throws {
        let (keeper, mac, _) = try made([1, 2, 3, 4])
        keeper.keep(album([1, 2, 3]))
        try await wait { keeper.isIdle }
        let one = try #require(keeper.store.kept(1)).file
        // On the Mac, song 1 left the list and song 4 joined it.
        keeper.update("album:a", tracks: [song(2), song(3), song(4)])
        try await wait { keeper.isIdle }
        #expect(mac.opened == [1, 2, 3, 4])
        #expect(keeper.store.lists[0].tracks.map(\.id) == [2, 3, 4])
        #expect(!FileManager.default.fileExists(atPath: one.path))
        #expect(keeper.progress(of: "album:a") == KeptProgress(done: 3, total: 3))
    }

    @Test func smallerForThePhoneAsksTheMacToKeepTo48Kilohertz() async throws {
        let (keeper, mac, _) = try made([1, 2])
        keeper.keep(album([1], smaller: true))
        keeper.keep(album([2], id: "album:b"))
        try await wait { keeper.isIdle }
        #expect(mac.rates == [48_000, nil])
    }

    @Test func fetchingWaitsWhileThePhoneHoldsBack() async throws {
        let (keeper, mac, _) = try made([1])
        var reason: String? = "Playing over cellular data is off."
        keeper.holdReason = { reason }
        keeper.keep(album([1]))
        try await wait { keeper.isIdle }
        #expect(mac.opened.isEmpty && keeper.notice == "Playing over cellular data is off.")
        reason = nil
        keeper.resume()
        try await wait { keeper.isIdle }
        #expect(keeper.store.kept(1) != nil && keeper.notice == nil)
    }

    @Test func aKeptSongPlaysWithTheMacOffAndWithoutAskingIt() async throws {
        // A real file this time: the player has to open it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kept-\(UUID()).wav")
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 22_050)!
            buffer.frameLength = 22_050
            for c in 0..<2 { for i in 0..<22_050 { buffer.floatChannelData![c][i] = Float(0.3 * sin(Double(i) / 20)) } }
            try file.write(from: buffer)
        }
        let (keeper, mac, _) = try made([])
        mac.files[1] = try Data(contentsOf: url)
        keeper.keep(album([1, 2]))
        try await wait { keeper.isIdle }
        #expect(mac.opened == [1])
        mac.connected = false

        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let playback = PhonePlayback(client: mac.client, player: PhonePlayer(engine: engine), cacheDirectory: folder())
        playback.kept = { [store = keeper.store] id in store.kept(id).map { ($0.file, $0.descriptor) } }
        playback.play([song(1), song(2)])
        try await wait { playback.player.state == .playing }
        #expect(playback.stream?.tag == "tag-1")
        #expect(mac.opened == [1])
        #expect(playback.bytesReceived == 0)
        // The song that isn't kept can't follow with the Mac off: the first still plays.
        #expect(playback.nowPlaying?.track.id == 1 && playback.notice == nil)
        playback.stop()
    }
}
#endif
