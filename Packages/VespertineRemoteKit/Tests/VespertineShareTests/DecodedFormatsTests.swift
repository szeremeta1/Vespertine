//
// Vespertine: files the app opens with a decoder library (APE, WavPack, Ogg Vorbis, Opus), with a made-up decoder in
// place of the libraries: what the scan lists, what a share gives the player, and that any range of it is the same bytes.
// (The libraries themselves are held to the Mac's decoding in VespertineKit's PhoneDecodersTests.)
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertineShare

/// A made-up kind of file: "TONE", the channels, the sample size (0: floats), the rate and the frames, then a title.
/// Its samples are a count: frame * 7 + channel.
enum ToneFile {
    static func make(channels: Int = 2, sampleBytes: Int = 2, rate: Int = 48_000, frames: Int = 5_000, title: String = "Tone") -> Data {
        var out = Data("TONE".utf8)
        out.append(contentsOf: [UInt8(channels), UInt8(sampleBytes)])
        for value in [rate, frames] { out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        out.append(Data(title.utf8))
        return out
    }

    /// The samples a file's decoder gives for `range`.
    static func samples(_ info: DecodedInfo, _ range: Range<Int64>) -> Data {
        var out = Data()
        for frame in range {
            for channel in 0..<info.channels {
                let value = Int32(truncatingIfNeeded: frame * 7 + Int64(channel))
                if info.sampleBytes == 0 {
                    let bits = (Float(value % 1_000) / 1_000).bitPattern
                    out.append(contentsOf: [UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)])
                } else {
                    for byte in stride(from: info.sampleBytes - 1, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: value >> Int32(byte * 8))) }
                }
            }
        }
        return out
    }
}

final class ToneDecoder: ShareDecoder {
    let info: DecodedInfo
    /// Frames the file turns out not to have, at its end.
    var missing: Int64 = 0
    private(set) var reads: [Range<Int64>] = []
    init(_ info: DecodedInfo) { self.info = info }

    func read(frame: Int64, count: Int) throws -> Data {
        let end = min(info.frames - missing, frame + Int64(count))
        reads.append(frame..<max(frame, end))
        return frame < end ? ToneFile.samples(info, frame..<end) : Data()
    }
}

struct ToneDecoders: ShareDecoders {
    var extensions: Set<String> = ["ape", "wv", "ogg", "opus"]

    func open(type: String, size: Int64, read: @escaping (Int64, Int) throws -> Data) throws -> DecoderOpening {
        let head = [UInt8](try read(0, Int(min(size, 256))))
        if head.starts(with: Array("DSDW".utf8)) { return .needsTheMac }
        guard head.count >= 14, head.starts(with: Array("TONE".utf8)) else { return .unreadable }
        func number(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(head[at + $1]) << ($1 * 8) } }
        let lossy = type == "ogg" || type == "opus"
        let info = DecodedInfo(codec: ["ape": "APE", "wv": "WavPack", "ogg": "Vorbis", "opus": "Opus"][type] ?? "?", sampleRate: Double(number(6)), channels: Int(head[4]),
                               bitDepth: lossy ? nil : max(1, Int(head[5])) * 8, sampleBytes: Int(head[5]), frames: Int64(number(10)),
                               text: ["title": String(decoding: head[14...], as: UTF8.self), "artist": "The Vesper Quartet", "album": "Night Rooms", "tracknumber": "2/9", "date": "2019-04-01"])
        return .opened(ToneDecoder(info))
    }
}

private func toneShare() -> FakeShare {
    let share = FakeShare()
    share.put("Night Rooms/01 Monkey.ape", ToneFile.make(sampleBytes: 2, rate: 44_100, title: "Monkey"))
    share.put("Night Rooms/02 Pack.wv", ToneFile.make(sampleBytes: 3, rate: 96_000, title: "Pack"))
    share.put("Night Rooms/03 Float.ogg", ToneFile.make(sampleBytes: 0, title: "Float"))
    share.put("Night Rooms/04 Surround.opus", ToneFile.make(channels: 6, sampleBytes: 0, title: "Surround"))
    share.put("Night Rooms/05 DSD.wv", Data("DSDW".utf8))
    share.put("Night Rooms/06 Broken.ape", Data("MAC ".utf8))
    share.put("Night Rooms/07 Other.tta", Data("TTA1".utf8))
    return share
}

@Suite struct DecodedFormatsOnAShareTests {
    @Test func withDecodersAScanListsTheirFiles() throws {
        let library = try ShareScanner.scan(toneShare(), decoders: ToneDecoders())
        #expect(library.songs.map(\.fileName) == ["01 Monkey.ape", "02 Pack.wv", "03 Float.ogg"])
        #expect(library.needTheMac == 3, "5.1 Opus, DSD in WavPack, and TTA")
        #expect(library.unreadable == 1)
        let ape = try #require(library.songs.first).tags
        #expect(ape.codec == "APE" && ape.sampleRate == 44_100 && ape.bitDepth == 16 && ape.channels == 2 && ape.frames == 5_000 && ape.lossless && ape.bitRate == nil)
        #expect(ape.title == "Monkey" && ape.artist == "The Vesper Quartet" && ape.album == "Night Rooms" && ape.track == 2 && ape.year == 2019)
        #expect(abs(ape.duration - 5_000.0 / 44_100) < 1e-9)
        let vorbis = library.songs[2].tags
        #expect(vorbis.codec == "Vorbis" && vorbis.bitDepth == nil && !vorbis.lossless && vorbis.bitRate != nil)
        let catalog = ShareCatalog(library)
        #expect(catalog.allTracks.map(\.title) == ["Monkey", "Pack", "Float"])
    }

    @Test func withoutDecodersTheyAllNeedTheMac() throws {
        let library = try ShareScanner.scan(toneShare())
        #expect(library.songs.isEmpty && library.needTheMac == 7 && library.unreadable == 0)
    }

    @Test func aFileAlreadyIndexedIsNotOpenedAgain() throws {
        let share = toneShare()
        let first = try ShareScanner.scan(share, decoders: ToneDecoders())
        share.forgetCounts()
        let again = try ShareScanner.scan(share, previous: first, decoders: ToneDecoders())
        #expect(again.songs == first.songs)
        #expect(!share.readPaths.contains("Night Rooms/01 Monkey.ape"))
    }
}

@Suite struct DecodedRenderingTests {
    private func info(sampleBytes: Int, channels: Int = 2, frames: Int64 = 3_000) -> DecodedInfo {
        DecodedInfo(codec: "APE", sampleRate: 44_100, channels: channels, bitDepth: sampleBytes == 0 ? nil : sampleBytes * 8, sampleBytes: sampleBytes, frames: frames)
    }

    @Test func theHeaderSaysWhatTheSamplesAre() {
        let whole = DecodedRendering(info(sampleBytes: 2))
        #expect(whole.header.count == CAFHeader.size && whole.byteSize == 68 + 3_000 * 4 && !whole.float && whole.sampleBytes == 2)
        #expect(Array(whole.header[0..<4]) == Array("caff".utf8) && Array(whole.header[28..<32]) == Array("lpcm".utf8))
        #expect(Array(whole.header[32..<36]) == [0, 0, 0, 0] && Array(whole.header[48..<52]) == [0, 0, 0, 16], "whole numbers, 16 bits")
        let float = DecodedRendering(info(sampleBytes: 0, channels: 1))
        #expect(float.float && float.sampleBytes == 4 && float.byteSize == 68 + 3_000 * 4)
        #expect(Array(float.header[32..<36]) == [0, 0, 0, 1] && Array(float.header[48..<52]) == [0, 0, 0, 32], "floats, 32 bits")
        // The same header a DSD file's PCM has, for the same samples.
        let dsd = DSDRendering(layout: DSDLayout(kind: .dff, dsdRate: 2_822_400, channels: 2, dataOffset: 0, bytesPerChannel: 8, blockSize: 1, lsbFirst: false),
                               form: .pcm, sampleRate: 44_100, frames: 3_000)
        #expect(dsd.header == DecodedRendering(info(sampleBytes: 3)).header)
    }

    @Test(arguments: [1, 2, 3, 4, 0])
    func anyRangeIsTheSameBytesHoweverItIsCutUp(_ sampleBytes: Int) throws {
        let info = info(sampleBytes: sampleBytes)
        let rendering = DecodedRendering(info)
        let decoder = ToneDecoder(info)
        let whole = try rendering.read(offset: 0, length: Int(rendering.byteSize), decoder: decoder)
        #expect(whole == Data(rendering.header) + ToneFile.samples(info, 0..<3_000))
        // Ranges that start and end inside a frame, inside the header and past the end.
        for (offset, length) in [(0, 10), (60, 20), (68, 1), (69, 7), (1_001, 3_333), (Int(rendering.byteSize) - 5, 100)] {
            let piece = try rendering.read(offset: Int64(offset), length: length, decoder: decoder)
            #expect(piece == whole.subdata(in: offset..<min(whole.count, offset + length)), "\(length) bytes from \(offset)")
        }
        #expect(try rendering.read(offset: rendering.byteSize, length: 10, decoder: decoder).isEmpty)
    }

    @Test func aFileThatEndsEarlyIsSilenceToItsSaidLength() throws {
        let info = info(sampleBytes: 2)
        let rendering = DecodedRendering(info)
        let decoder = ToneDecoder(info)
        decoder.missing = 100
        let whole = try rendering.read(offset: 0, length: Int(rendering.byteSize), decoder: decoder)
        #expect(whole.count == Int(rendering.byteSize))
        #expect(whole.suffix(400) == Data(count: 400))
        #expect(whole.prefix(whole.count - 400) == Data(rendering.header) + ToneFile.samples(info, 0..<2_900))
    }
}

@MainActor
@Suite struct DecodedFormatsFromAShareTests {
    private func opened() async throws -> (mac: ShareMac, songs: [String: Int64]) {
        let share = toneShare()
        let store = ShareStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("share-tone-\(UUID().uuidString)", isDirectory: true))
        let mac = ShareMac(id: "share-test", name: "Studio NAS", files: share, playback: share, store: store, decoders: ToneDecoders(), now: { FakeShare.day })
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { !mac.isScanning })
        guard case .songs(let items, _) = try await mac.request(.songs(offset: 0, limit: 10), timeout: .seconds(1)) else { throw RemoteLinkError.closed }
        return (mac, Dictionary(uniqueKeysWithValues: items.compactMap { item in item.id.map { (item.title, $0) } }))
    }

    private func whole(_ mac: ShareMac, _ descriptor: StreamDescriptor) async throws -> Data {
        var out = Data()
        while Int64(out.count) < descriptor.byteSize {
            let frame = try await mac.read(stream: descriptor.stream, offset: Int64(out.count), length: 7_001, timeout: .seconds(1))
            guard !frame.payload.isEmpty else { break }
            out += frame.payload
        }
        return out
    }

    @Test func aDecodedSongOpensAsItsOwnSamples() async throws {
        let (mac, songs) = try await opened()
        guard case .streamOpened(let descriptor) = try await mac.request(.streamOpen(id: try #require(songs["Monkey"]), maxSampleRate: 48_000, smaller: nil, dop: nil), timeout: .seconds(1)) else {
            Issue.record("did not open"); return
        }
        #expect(descriptor.kind == .decoded && descriptor.dsdRate == nil && descriptor.frames == 5_000)
        #expect(descriptor.format == StreamFormat(codec: "PCM", container: "caf", sampleRate: 44_100, bitDepth: 16, channels: 2, channelLabels: nil, lossless: true))
        #expect(descriptor.tag.hasPrefix("pcm44100-"))
        let info = DecodedInfo(codec: "APE", sampleRate: 44_100, channels: 2, bitDepth: 16, sampleBytes: 2, frames: 5_000)
        #expect(descriptor.byteSize == DecodedRendering(info).byteSize)
        #expect(try await whole(mac, descriptor) == Data(DecodedRendering(info).header) + ToneFile.samples(info, 0..<5_000))
        // A seek: any range, the same bytes.
        let piece = try await mac.read(stream: descriptor.stream, offset: 9_001, length: 500, timeout: .seconds(1))
        #expect(piece.payload == (Data(DecodedRendering(info).header) + ToneFile.samples(info, 0..<5_000)).subdata(in: 9_001..<9_501))
        // It is the song's own file to the player, as a FLAC is: not a conversion.
        let signal = PhoneSignal(stream: descriptor, route: nil)
        #expect(!signal.converted && !signal.convertedHere && !signal.cut && signal.lossless && signal.bitDepth == 16)
    }

    @Test func aLossySongIsGivenAsFloats() async throws {
        let (mac, songs) = try await opened()
        guard case .streamOpened(let descriptor) = try await mac.request(.streamOpen(id: try #require(songs["Float"]), maxSampleRate: nil, smaller: nil, dop: nil), timeout: .seconds(1)) else {
            Issue.record("did not open"); return
        }
        #expect(descriptor.kind == .decoded && descriptor.format.bitDepth == nil && !descriptor.format.lossless && descriptor.format.sampleRate == 48_000)
        #expect(descriptor.byteSize == 68 + 5_000 * 8)
        guard case .streamInfo(let items) = try await mac.request(.streamInfo(ids: [try #require(songs["Float"])], maxSampleRate: nil), timeout: .seconds(1)) else { throw RemoteLinkError.closed }
        let info = try #require(items.first)
        #expect(info.streamable && info.kind == .decoded && info.source.codec == "Vorbis" && info.source.container == "ogg" && info.delivered?.container == "caf")
    }

    @Test func aFileThatIsNoLongerWhatWasIndexedIsSaid() async throws {
        let share = toneShare()
        let store = ShareStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("share-tone-\(UUID().uuidString)", isDirectory: true))
        let mac = ShareMac(id: "share-test", name: "Studio NAS", files: share, playback: share, store: store, decoders: ToneDecoders(), now: { FakeShare.day })
        try await mac.open(timeout: .seconds(1))
        #expect(await eventually { !mac.isScanning })
        guard case .songs(let items, _) = try await mac.request(.songs(offset: 0, limit: 10), timeout: .seconds(1)) else { throw RemoteLinkError.closed }
        let song = try #require(items.first { $0.title == "Monkey" }?.id)
        // The same size, another rate.
        share.put("Night Rooms/01 Monkey.ape", ToneFile.make(sampleBytes: 2, rate: 48_000, title: "Monkey"))
        guard case .failed(let reason) = try await mac.request(.streamOpen(id: song, maxSampleRate: nil, smaller: nil, dop: nil), timeout: .seconds(1)) else {
            Issue.record("opened a changed file"); return
        }
        #expect(reason == ShareSayings.english.changed)
    }
}

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AVFAudio

private final class MemoryBytes: ByteSource, @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    var byteSize: Int64 { Int64(data.count) }
    var isComplete: Bool { true }
    func read(at offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, offset < byteSize, length > 0 else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
    }
    func interruptReads() {}
}

@Suite struct DecodedFormatsThroughThePlayersDecoderTests {
    /// The decoder the player uses must read each kind of sample back as it was written.
    @Test(arguments: [2, 3, 4, 0])
    func thePlayersDecoderReadsTheSamplesBack(_ sampleBytes: Int) throws {
        let info = DecodedInfo(codec: "APE", sampleRate: 48_000, channels: 2, bitDepth: sampleBytes == 0 ? nil : sampleBytes * 8, sampleBytes: sampleBytes, frames: 6_000)
        let rendering = DecodedRendering(info)
        let samples = ToneFile.samples(info, 0..<6_000)
        let format = StreamFormat(codec: "PCM", container: "caf", sampleRate: 48_000, bitDepth: info.bitDepth, channels: 2, channelLabels: nil, lossless: sampleBytes != 0)
        let decoder = try StreamDecoder(source: MemoryBytes(Data(rendering.header) + samples), format: format)
        #expect(decoder.length == 6_000 && decoder.processingFormat.sampleRate == 48_000)
        #expect(decoder.fileFormat.mBitsPerChannel == UInt32(rendering.sampleBytes * 8) && decoder.fileFormat.mChannelsPerFrame == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8_192))
        var out: [Float] = []
        while true {
            let read = try decoder.read(into: buffer)
            if read == 0 { break }
            let planes = try #require(buffer.floatChannelData)
            for frame in 0..<read { for channel in 0..<2 { out.append(planes[channel][frame]) } }
        }
        #expect(out.count == 12_000)
        let size = rendering.sampleBytes
        let bytes = [UInt8](samples)
        let expected: [Float] = stride(from: 0, to: bytes.count, by: size).map { at in
            var word: UInt32 = 0
            for byte in 0..<size { word = word << 8 | UInt32(bytes[at + byte]) }
            if sampleBytes == 0 { return Float(bitPattern: word) }
            // Sign-extended, then as the fraction of full scale it is.
            let value = Int32(bitPattern: word << UInt32(32 - 8 * size)) >> Int32(32 - 8 * size)
            return Float(Double(value) / Double(Int64(1) << (8 * size - 1)))
        }
        #expect(out == expected)
    }
}
#endif
