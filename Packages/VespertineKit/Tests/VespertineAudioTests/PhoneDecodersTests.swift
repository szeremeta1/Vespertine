//
// Vespertine: the iPhone's decoders for APE, WavPack, Ogg Vorbis and Opus (VespertineDecoders), held to what the Mac's
// decoder makes of the same files: the same frames, the same samples.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
import VespertineDecoders
import VespertineShare

@Suite struct PhoneDecodersTests {
    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Formats")!
    }

    /// A file's samples, each as 32 bits: a whole number moved up to fill them, or a float's own bits.
    struct Samples: Equatable {
        var sampleRate: Double
        var channels: Int
        var float: Bool
        var words: [UInt32]
    }

    /// What the Mac's decoder (SFBAudioEngine, as VespertineAudio uses it) makes of a file.
    static func onTheMac(_ url: URL) throws -> Samples {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }
        let format = decoder.processingFormat
        let description = format.streamDescription.pointee
        let channels = Int(description.mChannelsPerFrame)
        let float = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let apart = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let size = Int(description.mBytesPerFrame) / (apart ? 1 : channels)
        var words: [UInt32] = []
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        while true {
            try decoder.decode(into: buffer, length: 4096)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let base = list[apart ? channel : 0].mData!.assumingMemoryBound(to: UInt8.self) + frame * Int(description.mBytesPerFrame) + (apart ? 0 : channel * size)
                    // Native (little-endian) bytes, moved to the top of 32 bits.
                    var word: UInt32 = 0
                    for byte in 0..<size { word |= UInt32(base[byte]) << UInt32(8 * byte) }
                    words.append(word << UInt32(32 - 8 * size))
                }
            }
        }
        return Samples(sampleRate: format.sampleRate, channels: channels, float: float, words: words)
    }

    /// A decoder over a file's bytes, counting how the file was read.
    static func open(_ name: String) throws -> (decoder: any ShareDecoder, data: Data) {
        let data = try Data(contentsOf: fixture(name))
        let type = (name as NSString).pathExtension
        guard case .opened(let decoder) = try PhoneDecoders().open(type: type, size: Int64(data.count), read: { offset, length in
            data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
        }) else { throw DecodingFailed() }
        return (decoder, data)
    }

    static func words(_ data: Data, _ info: DecodedInfo) -> [UInt32] {
        let size = info.sampleBytes == 0 ? 4 : info.sampleBytes
        var out: [UInt32] = []
        out.reserveCapacity(data.count / size)
        let bytes = [UInt8](data)
        for at in stride(from: 0, to: bytes.count - size + 1, by: size) {
            var word: UInt32 = 0
            for byte in 0..<size { word = word << 8 | UInt32(bytes[at + byte]) }
            out.append(word << UInt32(32 - 8 * size))
        }
        return out
    }

    @Test(arguments: ["ape-stereo16.ape", "ape-stereo24.ape", "pcm-stereo24.wv", "vorbis-stereo.ogg", "gapless.opus"])
    func decodesToTheSamplesTheMacDecodes(_ name: String) throws {
        let mac = try Self.onTheMac(Self.fixture(name))
        let (decoder, _) = try Self.open(name)
        let info = decoder.info
        #expect(info.sampleRate == mac.sampleRate)
        #expect(info.channels == mac.channels)
        #expect((info.sampleBytes == 0) == mac.float)
        #expect(Int(info.frames) * info.channels == mac.words.count)
        // Read in pieces of an odd size, in order.
        var data = Data()
        var frame: Int64 = 0
        while frame < info.frames {
            let piece = try decoder.read(frame: frame, count: 1_777)
            if piece.isEmpty { break }
            data.append(piece)
            frame += 1_777
        }
        #expect(Self.words(data, info) == mac.words)
    }

    @Test(arguments: ["ape-stereo16.ape", "ape-stereo24.ape", "pcm-stereo24.wv", "vorbis-stereo.ogg"])
    func aReadFromAnyFrameIsTheSameSamples(_ name: String) throws {
        let (decoder, _) = try Self.open(name)
        let info = decoder.info
        let size = info.channels * (info.sampleBytes == 0 ? 4 : info.sampleBytes)
        let whole = try decoder.read(frame: 0, count: Int(info.frames))
        #expect(whole.count == Int(info.frames) * size)
        // Backwards, forwards and across the end.
        for (frame, count) in [(30_000, 500), (7, 3), (12_345, 4_097), (0, 10), (Int(info.frames) - 100, 500), (20_000, 1)] {
            let piece = try decoder.read(frame: Int64(frame), count: count)
            let end = min(Int(info.frames), frame + count)
            #expect(piece == whole.subdata(in: (frame * size)..<(end * size)), "frames \(frame)..<\(end) of \(name)")
        }
        #expect(try decoder.read(frame: info.frames, count: 10).isEmpty)
    }

    /// Opus decoded from a new place is the same sound as reading in order, not always the same bits (the decoder starts a
    /// second early and lets itself settle): within a hair of the samples read in order.
    @Test func opusFromAnyFrameIsTheSameSound() throws {
        let (decoder, _) = try Self.open("gapless.opus")
        let info = decoder.info
        let whole = Self.words(try decoder.read(frame: 0, count: Int(info.frames)), info).map { Float(bitPattern: $0) }
        for frame in [48_000, 9_600, 70_000, 100] {
            let piece = Self.words(try decoder.read(frame: Int64(frame), count: 2_000), info).map { Float(bitPattern: $0) }
            #expect(piece.count == 2_000 * info.channels)
            let worst = zip(piece, whole[(frame * info.channels)...]).map { abs($0 - $1) }.max() ?? 1
            #expect(worst < 1e-5, "from frame \(frame): off by \(worst)")
        }
    }

    @Test func saysWhatAFileIs() throws {
        let ape = try Self.open("ape-stereo24.ape").decoder.info
        #expect(ape.codec == "APE" && ape.sampleRate == 48_000 && ape.channels == 2 && ape.bitDepth == 24 && ape.sampleBytes == 3 && ape.frames == 48_000)
        #expect(ape.text["title"] == "Monkey Tone" && ape.text["artist"] == "The Vesper Quartet" && ape.text["album"] == "Formats" && ape.text["track"] == "3")
        let wavpack = try Self.open("pcm-stereo24.wv").decoder.info
        #expect(wavpack.codec == "WavPack" && wavpack.bitDepth == 24 && wavpack.sampleBytes == 3 && wavpack.channels == 2 && wavpack.playsHere)
        let vorbis = try Self.open("vorbis-stereo.ogg").decoder.info
        #expect(vorbis.codec == "Vorbis" && vorbis.bitDepth == nil && vorbis.sampleBytes == 0 && vorbis.sampleRate == 48_000 && vorbis.frames == 48_000)
        #expect(vorbis.text["title"] == "Vorbis Tone" && vorbis.text["artist"] == "The Vesper Quartet" && vorbis.text["tracknumber"] == "4")
        let opus = try Self.open("gapless.opus").decoder.info
        #expect(opus.codec == "Opus" && opus.bitDepth == nil && opus.sampleRate == 48_000 && opus.frames == 96_000)
    }

    @Test func leavesToTheMacWhatOnlyTheMacPlays() throws {
        func opening(_ name: String, as type: String? = nil) throws -> DecoderOpening {
            let data = try Data(contentsOf: Self.fixture(name))
            return try PhoneDecoders().open(type: type ?? (name as NSString).pathExtension, size: Int64(data.count)) { offset, length in
                data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
            }
        }
        // WavPack holding DSD.
        guard case .needsTheMac = try opening("dsd64-stereo-from-dsf.wv") else { Issue.record("a DSD WavPack file was not left to the Mac"); return }
        // Opus in 5.1 opens, and says it is not for this device.
        guard case .opened(let surround) = try opening("opus-51.opus") else { Issue.record("5.1 Opus did not open"); return }
        #expect(surround.info.channels == 6 && !surround.info.playsHere)
        // A FLAC with the wrong name, and an Ogg file that is not Ogg.
        guard case .unreadable = try opening("stereo24.flac", as: "ape") else { Issue.record("a FLAC opened as APE"); return }
        guard case .unreadable = try opening("stereo24.flac", as: "ogg") else { Issue.record("a FLAC opened as Ogg"); return }
        guard case .unreadable = try opening("stereo24.flac", as: "wv") else { Issue.record("a FLAC opened as WavPack"); return }
    }

    @Test func aShareThatStopsAnsweringIsSaidAsThat() throws {
        struct Gone: Error {}
        let data = try Data(contentsOf: Self.fixture("ape-stereo16.ape"))
        nonisolated(unsafe) var answering = true
        guard case .opened(let decoder) = try PhoneDecoders().open(type: "ape", size: Int64(data.count), read: { offset, length in
            guard answering else { throw Gone() }
            // A little at a time, so that decoding has to come back for more.
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + min(length, 2_048)))
        }) else { Issue.record("did not open"); return }
        _ = try decoder.read(frame: 0, count: 100)
        answering = false
        #expect(throws: Gone.self) { _ = try decoder.read(frame: 40_000, count: 4_000) }
        // And is read again once it answers.
        answering = true
        #expect(try decoder.read(frame: 40_000, count: 4_000).count == 4_000 * 4)
        #expect(throws: Gone.self) {
            _ = try PhoneDecoders().open(type: "ape", size: Int64(data.count)) { _, _ in throw Gone() }
        }
    }
}
