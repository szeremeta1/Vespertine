//
// Speaker probe — channel-identification signals written as CAF files.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation

/// One test file: each channel in turn plays a tone burst while the others are silent, in two rounds.
struct TestSignal: Identifiable, Hashable {
    let id: String
    let title: String
    let sampleRate: Double
    let bitDepth: Int
    let layoutTag: AudioChannelLayoutTag
    /// Speaker names in the layout's channel order.
    let channelNames: [String]

    static let burst = 1.5
    static let gap = 0.5
    static let rounds = 2
    static var slot: Double { burst + gap }

    static let all: [TestSignal] = [
        TestSignal(id: "2.0-44", title: "Stereo, 16-bit / 44.1 kHz", sampleRate: 44_100, bitDepth: 16,
                   layoutTag: kAudioChannelLayoutTag_Stereo, channelNames: ["Left", "Right"]),
        TestSignal(id: "2.0-48", title: "Stereo, 24-bit / 48 kHz", sampleRate: 48_000, bitDepth: 24,
                   layoutTag: kAudioChannelLayoutTag_Stereo, channelNames: ["Left", "Right"]),
        TestSignal(id: "2.0-96", title: "Stereo, 24-bit / 96 kHz", sampleRate: 96_000, bitDepth: 24,
                   layoutTag: kAudioChannelLayoutTag_Stereo, channelNames: ["Left", "Right"]),
        // L R C LFE Ls Rs
        TestSignal(id: "5.1-48", title: "5.1, 24-bit / 48 kHz", sampleRate: 48_000, bitDepth: 24,
                   layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A,
                   channelNames: ["Left", "Right", "Centre", "LFE", "Left surround", "Right surround"]),
        // L R C LFE Ls Rs Rls Rrs
        TestSignal(id: "7.1-48", title: "7.1, 24-bit / 48 kHz", sampleRate: 48_000, bitDepth: 24,
                   layoutTag: kAudioChannelLayoutTag_MPEG_7_1_C,
                   channelNames: ["Left", "Right", "Centre", "LFE", "Left side", "Right side", "Left rear", "Right rear"]),
    ]

    var channelCount: Int { channelNames.count }
    var duration: Double { Double(channelCount * Self.rounds) * Self.slot }

    /// The speaker that should be sounding at `time`, or nil in a gap.
    func channel(at time: Double) -> String? {
        guard time >= 0, time < duration else { return nil }
        let slotIndex = Int(time / Self.slot)
        guard time - Double(slotIndex) * Self.slot < Self.burst else { return nil }
        return channelNames[slotIndex % channelCount]
    }

    /// Writes the file to the temporary directory (once) and returns its URL.
    func fileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-probe-\(id).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else { throw ProbeError.layout }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let channels = buffer.floatChannelData else { throw ProbeError.buffer }
        buffer.frameLength = frames

        // About -20 dBFS, with 20 ms raised-cosine edges so the bursts don't click. The LFE gets 50 Hz, the rest 500 Hz.
        let amplitude: Float = 0.1
        let fade = 0.02
        for channel in 0..<channelCount {
            let samples = channels[channel]
            let frequency = channelNames[channel] == "LFE" ? 50.0 : 500.0
            for frame in 0..<Int(frames) {
                let time = Double(frame) / sampleRate
                let slotIndex = Int(time / Self.slot)
                let inSlot = time - Double(slotIndex) * Self.slot
                guard slotIndex % channelCount == channel, inSlot < Self.burst else { samples[frame] = 0; continue }
                let edge = min(inSlot, Self.burst - inSlot)
                let envelope = edge < fade ? 0.5 - 0.5 * cos(Double.pi * edge / fade) : 1
                samples[frame] = amplitude * Float(envelope * sin(2 * Double.pi * frequency * time))
            }
        }
        try file.write(from: buffer)
        return url
    }
}

enum ProbeError: LocalizedError {
    case layout, buffer

    var errorDescription: String? {
        switch self {
        case .layout: "The channel layout couldn't be made."
        case .buffer: "The sample buffer couldn't be made."
        }
    }
}
