//
// Vespertine: the processed stream for a renderer: the song rendered by Vespertine's own chain (NetworkRender), encoded as
// 24-bit FLAC at the source rate into a file the media server sends as it grows. Encoding runs on a thread of its own,
// faster than real time; FLAC's header is completed when the song is done (a renderer reading earlier sees a stream header,
// which FLAC allows).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import os
import SFBAudioEngine
import VespertineAudio

public enum FLACStreamWriter {
    /// The format the FLAC encoder takes for 24-bit samples: Int32 words, interleaved, the sample in the top 24 bits.
    static func format(rate: Double, channels: Int) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 24, mReserved: 0)
        let layout: AVAudioChannelLayout? = channels > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) : nil
        if let layout { return AVAudioFormat(streamDescription: &asbd, channelLayout: layout) }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Encodes everything `render` gives into a FLAC file at `url`; throws what went wrong.
    static func encode(_ render: NetworkRender, to url: URL, isCancelled: () -> Bool) throws {
        let rate = render.format.sampleRate, channels = render.format.channels
        guard let format = format(rate: rate, channels: channels) else { throw RendererPlaybackError.unplayable("FLAC format") }
        let encoder = try AudioEncoder(url: url, encoderName: .FLAC)
        encoder.settings = [.flacCompressionLevel: 5]
        try encoder.setSourceFormat(format)
        try encoder.openReturningError()
        defer { try? encoder.close() }
        let frames: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let words = buffer.int32ChannelData?[0] else {
            throw RendererPlaybackError.unplayable("FLAC buffer")
        }
        while !isCancelled() {
            let samples = render.next(maxFrames: Int(frames))
            if samples.isEmpty { break }
            for i in samples.indices { words[i] = samples[i] << 8 }
            buffer.frameLength = AVAudioFrameCount(samples.count / channels)
            try encoder.encode(from: buffer)
        }
        try encoder.finish()
        if let error = render.error { throw error }
    }
}

/// Makes processed streams in the caches folder; one encoding thread per stream.
public final class ProcessedStreamMaker: ProcessedStreamMaking, @unchecked Sendable {
    let directory: URL
    private let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "renderer")

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vespertine UPnP", isDirectory: true)
        // Streams of an earlier run aren't anyone's any more.
        if directory == nil { try? FileManager.default.removeItem(at: self.directory) }
    }

    public func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat) {
        let render = try NetworkRender(item: item, url: url, equalizer: settings.activeEqualizer, roomCorrection: settings.activeRoomCorrection,
                                       digitalVolumeDB: settings.activeVolumeDB, startSeconds: startSeconds)
        let file = try GrowingFile(url: directory.appendingPathComponent(UUID().uuidString + ".flac"))
        let log = self.log
        let thread = Thread {
            do {
                // Stops early once the media server lets go of the stream (it is no longer current or next).
                try FLACStreamWriter.encode(render, to: file.url, isCancelled: { file.isAbandoned })
                file.finish()
            } catch {
                log.error("Processed stream failed: \(String(describing: error), privacy: .public)")
                file.fail()
            }
        }
        thread.name = "Vespertine renderer stream"
        thread.qualityOfService = .userInitiated
        thread.start()
        return (file, render.format)
    }
}
