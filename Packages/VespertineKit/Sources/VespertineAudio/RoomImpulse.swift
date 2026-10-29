//
// Vespertine — room correction filters as impulse responses: one speaker's measured filter (from REW, rePhase,
// Dirac-style tools …), kept as a file of its own and convolved on the I/O thread (`nrt_context_set_fir`).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A filter is stored once, at the rate it was made for, as 32-bit float samples in Application Support (or another
// folder, for tests). At play time it's resampled to the device's rate (and scaled so its gain stays the same), so one
// file works at every rate.
//

import AVFAudio
import CVespertineRT
import Foundation

public enum RoomImpulseError: LocalizedError, Equatable {
    case unreadable
    case empty
    case tooLong(seconds: Double)
    case notFinite
    case tooManyChannels(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The file isn't an audio file Vespertine can read (WAV, AIFF, CAF or FLAC).")
        case .empty: String(localized: "The file has no samples.")
        case .tooLong(let seconds):
            String(localized: "The filter is \(seconds.formatted(.number.precision(.fractionLength(1)))) seconds long; room correction filters can be at most \(RoomImpulse.maxSeconds.formatted(.number.precision(.fractionLength(1)))) seconds.")
        case .notFinite: String(localized: "The filter has samples that aren't numbers.")
        case .tooManyChannels(let n):
            String(localized: "The files hold \(n) filters; room correction takes one per speaker, up to six (5.1).")
        }
    }
}

/// One speaker's correction filter.
public struct RoomImpulse: Codable, Hashable, Sendable {
    /// The stored file's name in the filter folder (`defaultDirectory`).
    public var file: String
    /// What it was imported from, for the summary.
    public var name: String
    public var sampleRate: Double
    public var frames: Int

    /// Longest filter accepted at import: one that fits the I/O thread whole at up to 96 kHz (and at 192 kHz up to half
    /// as long).
    public static let maxSeconds = Double(NRT_FIR_MAX_TAPS) / 96_000

    public init(file: String, name: String, sampleRate: Double, frames: Int) {
        self.file = file
        self.name = name
        self.sampleRate = sampleRate
        self.frames = frames
    }

    /// Where filters are kept: Application Support/Vespertine/Room Filters.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vespertine", isDirectory: true)
            .appendingPathComponent("Room Filters", isDirectory: true)
    }

    func url(in directory: URL) -> URL { directory.appendingPathComponent(file) }

    /// Reads an impulse response (WAV, AIFF, CAF, FLAC) and stores each of its channels as a filter of its own.
    public static func importFile(_ source: URL, into directory: URL = defaultDirectory) throws -> [RoomImpulse] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw RoomImpulseError.unreadable }
        let rate = file.processingFormat.sampleRate
        let frames = Int(file.length)
        guard rate > 0, frames > 0 else { throw RoomImpulseError.empty }
        guard Double(frames) / rate <= maxSeconds + 0.001 else { throw RoomImpulseError.tooLong(seconds: Double(frames) / rate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw RoomImpulseError.unreadable
        }
        do { try file.read(into: buffer) } catch { throw RoomImpulseError.unreadable }
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { throw RoomImpulseError.empty }
        let length = Int(buffer.frameLength)
        let channels = Int(file.processingFormat.channelCount)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent
        return try (0..<channels).map { c in
            var samples = Array(UnsafeBufferPointer(start: data[c], count: length))
            guard samples.allSatisfy(\.isFinite) else { throw RoomImpulseError.notFinite }
            // Trailing silence (below −120 dB) costs time on the I/O thread and does nothing.
            let quiet = (samples.lazy.map { abs($0) }.max() ?? 0) * 1e-6
            guard let last = samples.lastIndex(where: { abs($0) > quiet }) else { throw RoomImpulseError.empty }
            samples.removeSubrange((last + 1)...)
            let impulse = RoomImpulse(file: UUID().uuidString + ".f32",
                                      name: channels == 1 ? name : "\(name) \(c + 1)", sampleRate: rate, frames: samples.count)
            try samples.withUnsafeBytes { try Data($0).write(to: impulse.url(in: directory), options: .atomic) }
            return impulse
        }
    }

    /// The stored samples, at the rate the filter was made for.
    func samples(in directory: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url(in: directory)), data.count == frames * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Whether the filter, resampled to `rate`, fits the I/O thread whole. One that doesn't is left out at that rate
    /// (cut short, it would no longer correct anything).
    public func fits(at rate: Double) -> Bool {
        sampleRate > 0 && rate > 0 && Double(frames) * rate / sampleRate + Self.resamplerSpread <= Double(NRT_FIR_MAX_TAPS)
    }

    /// Taps a resampled filter may grow by: the sample rate converter's own impulse response.
    static let resamplerSpread = 256.0

    /// Silence added after a filter before resampling it (input frames): more than the converter's reach.
    static let resamplerPadding = 1024

    /// The filter at `rate`, with the same gain, or nil if it can't be read or doesn't fit (`fits(at:)`).
    func taps(at rate: Double, in directory: URL = defaultDirectory) -> [Float]? {
        guard fits(at: rate), let samples = samples(in: directory), let taps = Self.resample(samples, from: sampleRate, to: rate) else { return nil }
        let quiet = (taps.lazy.map { abs($0) }.max() ?? 0) * 1e-6
        guard let last = taps.lastIndex(where: { abs($0) > quiet }) else { return nil }
        return Array(taps[...min(last, Int(NRT_FIR_MAX_TAPS) - 1)])
    }

    /// The filter's magnitude in dB at each of `frequencies` (at the rate it was made for), or nil if it can't be read.
    public func responseDB(at frequencies: [Double], in directory: URL = defaultDirectory) -> [Double]? {
        guard let taps = samples(in: directory), sampleRate > 0 else { return nil }
        return frequencies.map { hz in
            let w = 2 * Double.pi * hz / sampleRate
            var re = 0.0, im = 0.0
            for (n, tap) in taps.enumerated() where tap != 0 {
                let phase = w * Double(n)
                re += Double(tap) * cos(phase)
                im -= Double(tap) * sin(phase)
            }
            return 20 * log10(max(hypot(re, im), 1e-12))
        }
    }

    public func delete(in directory: URL = defaultDirectory) { try? FileManager.default.removeItem(at: url(in: directory)) }

    /// Resamples an impulse response. Sampling it more often adds samples, so it's scaled by `from / to` to keep its gain.
    /// Silence is added after the filter first, so the converter's own ringing after the filter's last sample comes
    /// out whole instead of being cut off at the end of the input.
    static func resample(_ samples: [Float], from: Double, to: Double) -> [Float]? {
        guard from != to else { return samples }
        guard from > 0, to > 0, !samples.isEmpty,
              let inFormat = AudioFormats.float32(sampleRate: from, channels: 1, interleaved: false),
              let outFormat = AudioFormats.float32(sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count + Self.resamplerPadding)),
              let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_384),
              let inData = input.floatChannelData else { return nil }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(samples.count + Self.resamplerPadding)
        samples.withUnsafeBufferPointer { inData[0].update(from: $0.baseAddress!, count: samples.count) }
        (inData[0] + samples.count).update(repeating: 0, count: Self.resamplerPadding)
        var given = false
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) * to / from) + 16_384)
        while true {
            chunk.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                if given { inputStatus.pointee = .endOfStream; return nil }
                given = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error || error != nil { return nil }
            if let data = chunk.floatChannelData, chunk.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(chunk.frameLength)))
            }
            if status != .haveData || chunk.frameLength == 0 { break }
        }
        let scale = Float(from / to)
        return out.map { $0 * scale }
    }
}
