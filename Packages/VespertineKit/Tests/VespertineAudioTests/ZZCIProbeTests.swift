// TEMPORARY CI probe: which AVAssetReader configurations hand out a first buffer on the CI machine, and how fast.
import AVFoundation
import Foundation
import Testing
@testable import VespertineAudio

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = "pending"
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return text }
        set { lock.lock(); text = newValue; lock.unlock() }
    }
}

@Suite("ZZ CI probe")
struct ZZCIProbeTests {
    private static func probe(_ name: String, settings: [String: Any]?) -> String {
        let url = Bundle.module.url(forResource: "dolby-digital-plus-tones.m4a", withExtension: nil, subdirectory: "Fixtures")!
        let done = DispatchSemaphore(value: 0)
        let result = ProbeBox()
        let began = Date()
        let thread = Thread {
            do {
                let asset = AVURLAsset(url: url)
                guard let info = LoadedAudioTrack(asset) else { result.value = "no track"; done.signal(); return }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: info.track, outputSettings: settings)
                reader.add(output)
                let started = reader.startReading()
                let t1 = Date().timeIntervalSince(began)
                let buffer = output.copyNextSampleBuffer()
                let frames = buffer.map { CMSampleBufferGetNumSamples($0) } ?? -1
                result.value = String(format: "started=%@ (%.2fs) first buffer frames=%d status=%d error=%@ after %.2fs",
                                      "\(started)", t1, frames, reader.status.rawValue, "\(String(describing: reader.error))",
                                      Date().timeIntervalSince(began))
                reader.cancelReading()
            } catch { result.value = "threw \(error)" }
            done.signal()
        }
        thread.start()
        let finished = done.wait(timeout: .now() + 25) == .success
        return "\(name): \(finished ? result.value : "HUNG >25 s (\(result.value))")"
    }

    private static func pcm(channels: Int, layout: UInt32?) -> [String: Any] {
        var s: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if let layout {
            var l = AudioChannelLayout(); l.mChannelLayoutTag = layout
            s[AVChannelLayoutKey] = Data(bytes: &l, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return s
    }

    @Test("probe")
    func probeReaders() {
        var lines = ["cores=\(ProcessInfo.processInfo.activeProcessorCount) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"]
        lines.append(Self.probe("compressed(nil)", settings: nil))
        lines.append(Self.probe("pcm stereo+layout", settings: Self.pcm(channels: 2, layout: kAudioChannelLayoutTag_Stereo)))
        lines.append(Self.probe("pcm stereo no layout", settings: Self.pcm(channels: 2, layout: nil)))
        lines.append(Self.probe("pcm 5.1 layout", settings: Self.pcm(channels: 6, layout: kAudioChannelLayoutTag_MPEG_5_1_A)))
        lines.append(Self.probe("pcm stereo+layout again", settings: Self.pcm(channels: 2, layout: kAudioChannelLayoutTag_Stereo)))
        Issue.record(Comment(rawValue: "CIPROBE " + lines.joined(separator: " | ")))
    }
}
