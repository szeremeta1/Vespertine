//
// Vespertine — DVD-Video LPCM playback: one LPCM run (a VOB's audio) as a PCM decoder. Library tracks are sample
// ranges of a run, played through the same region path as CUE tracks, so tracks that share a run join gaplessly.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine

/// A run's LPCM as Float32 (every 16-, 20- and 24-bit sample is exact in Float32), seekable to any sample.
final class DVDLPCMDecoder: NSObject, PCMDecoding {
    let url: URL
    let run: DVDLPCMRun
    private let reader: DVDLPCMReader
    private let format: AVAudioFormat
    private var scratch: [Int32] = []
    private(set) var isOpen = true

    /// Opens the run `ref` names on the disc at `url` (a .iso, or a VIDEO_TS folder's VIDEO_TS.IFO).
    convenience init(url: URL, ref: DVDStreamRef) throws {
        let volume = try DVDVideoVolume.open(url)
        let sectors = DVDSectorReader(extents: volume.titleVOBs(titleSet: ref.titleSet))
        guard ref.lastSector < sectors.sectorCount else {
            throw DVDVideoError.damaged(String(localized: "the VOBs are shorter than the library expects", comment: "Part of “This DVD-Video is damaged (…).”"))
        }
        guard let run = try DVDLPCMRun.analyze(sectors, titleSet: ref.titleSet, stream: ref.stream,
                                               sectors: ref.firstSector...ref.lastSector) else {
            throw DVDVideoError.unsupportedAudio(String(localized: "no LPCM audio", comment: "Why DVD audio can't be played."))
        }
        try self.init(url: url, run: run, sectors: sectors)
    }

    init(url: URL, run: DVDLPCMRun, sectors: DVDSectorReader) throws {
        self.url = url
        self.run = run
        reader = DVDLPCMReader(reader: sectors, run: run)
        let rate = Double(run.format.sampleRate), channels = run.format.channels
        // DVD-Video LPCM carries no speaker assignment: more than two channels get the usual layout for the count.
        let layout = channels > 2 ? ChannelLayouts.layout(channels: channels) : nil
        let f: AVAudioFormat? = if let layout { AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout) }
                                else { AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) }
        guard let f else { throw DVDVideoError.unsupportedAudio(run.format.description) }
        format = f
        super.init()
    }

    var inputSource: InputSource { (try? InputSource(for: url)) ?? InputSource(data: Data()) }
    var sourceFormat: AVAudioFormat { format }
    var processingFormat: AVAudioFormat { format }
    var decodingIsLossless: Bool { true }
    var properties: [AudioDecodingPropertiesKey: Any] { [:] }
    var supportsSeeking: Bool { true }
    var position: AVAudioFramePosition { reader.position }
    var length: AVAudioFramePosition { run.frameCount }
    func open() throws {}
    func close() throws { isOpen = false }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard let out = buffer.floatChannelData else { throw DVDVideoError.damaged("LPCM") }
        let channels = run.format.channels, want = Int(min(length, buffer.frameCapacity))
        if scratch.count < want * channels { scratch = [Int32](repeating: 0, count: want * channels) }
        let got = try scratch.withUnsafeMutableBufferPointer { try reader.read(into: $0.baseAddress!, frames: want) }
        scratch.withUnsafeBufferPointer { s in
            for c in 0..<channels {
                let plane = out[c]
                for i in 0..<got { plane[i] = Float(s[i * channels + c]) / 2_147_483_648 }
            }
        }
        buffer.frameLength = AVAudioFrameCount(got)
    }

    /// Interleaved left-justified integers, for verification (hashes of the exact samples).
    func readIntegers(into out: UnsafeMutablePointer<Int32>, frames: Int) throws -> Int {
        try reader.read(into: out, frames: frames)
    }

    func seek(to frame: AVAudioFramePosition) throws { try reader.seek(to: frame) }
}
