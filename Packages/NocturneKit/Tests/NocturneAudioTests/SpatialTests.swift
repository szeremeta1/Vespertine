//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import NocturneAudio

@Suite("Spatial Audio")
struct SpatialTests {
    /// 5.1 bed (L R C LFE Ls Rs) with a tone in one channel, rendered binaurally.
    func render(channel: Int, mode: SpatialMode = .fixed) throws -> (left: Double, right: Double) {
        let rate = 48_000.0, frames = 48_000
        let layout = try #require(ChannelLayouts.layout(channels: 6))
        let renderer = try SpatialRenderer(inputLayout: layout, channels: 6, sampleRate: rate, maxFrames: 4096, mode: mode)
        var input = [Float](repeating: 0, count: frames * 6)
        for f in 0..<frames { input[f * 6 + channel] = 0.3 * sin(2 * .pi * 1_000 * Float(f) / Float(rate)) }
        let out = renderer.render(interleaved: input, frames: frames)
        // Skip the first 100 ms (filter warm-up).
        var l = 0.0, r = 0.0
        for f in 4_800..<frames { l += Double(out[f * 2] * out[f * 2]); r += Double(out[f * 2 + 1] * out[f * 2 + 1]) }
        return (sqrt(l / Double(frames - 4_800)), sqrt(r / Double(frames - 4_800)))
    }

    @Test("A left-surround sound is heard on the left, a center sound in the middle")
    func placement() throws {
        let surroundLeft = try render(channel: 4)
        #expect(surroundLeft.left > 0.001, "silent output")
        #expect(surroundLeft.left > surroundLeft.right * 1.3, "Ls: L \(surroundLeft.left) R \(surroundLeft.right)")
        let surroundRight = try render(channel: 5)
        #expect(surroundRight.right > surroundRight.left * 1.3, "Rs: L \(surroundRight.left) R \(surroundRight.right)")
        let center = try render(channel: 2)
        #expect(center.left > 0.001 && abs(20 * log10(center.left / center.right)) < 1.5, "C: L \(center.left) R \(center.right)")
    }

    @Test("Head-tracked mode renders too (without a headset it behaves as fixed)")
    func headTracked() throws {
        let c = try render(channel: 0, mode: .headTracked)
        #expect(c.left > c.right, "L: L \(c.left) R \(c.right)")
    }

    @Test("Standard layouts for common channel counts")
    func layouts() {
        #expect(ChannelLayouts.name(channels: 6) == "5.1")
        #expect(ChannelLayouts.name(channels: 8) == "7.1")
        for n in 1...8 { #expect(ChannelLayouts.layout(channels: n)?.channelCount == AVAudioChannelCount(n)) }
        #expect(ChannelLayouts.layout(channels: 12)?.channelCount == 12)
    }
}

@Suite("Multichannel routing")
struct MultichannelPlanTests {
    let surround = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 88_200, bitDepth: 24, channels: 6)
    let stereoDAC = DeviceCapabilities(sampleRates: [44_100, 48_000, 88_200, 96_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
    let airPods = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
    let interface = DeviceCapabilities(sampleRates: [44_100, 48_000, 88_200, 96_000], physicalFormats: [], outputChannels: 8, supportsDoP: false)

    @Test("5.1 on AirPods: all six channels rendered with Spatial Audio to two")
    func spatialOnHeadphones() {
        let plan = FormatPlanner.plan(source: surround, device: airPods, spatial: .headTracked)
        #expect(plan.channels == 6 && plan.deviceChannels == 2 && plan.spatial == .headTracked)
        #expect(plan.deviceSampleRate == 48_000)
        #expect(plan.reason.contains("Spatial Audio"))
    }

    @Test("5.1 on a stereo DAC with Spatial Audio off: downmixed")
    func downmix() {
        let plan = FormatPlanner.plan(source: surround, device: stereoDAC)
        #expect(plan.channels == 2 && plan.deviceChannels == 2 && plan.spatial == .off)
        #expect(plan.deviceSampleRate == 88_200)
        #expect(plan.reason.contains("downmixed"))
    }

    @Test("5.1 on an 8-channel interface: every channel, no downmix")
    func discrete() {
        let plan = FormatPlanner.plan(source: surround, device: interface)
        #expect(plan.channels == 6 && plan.deviceChannels == 6 && plan.spatial == .off)
    }

    @Test("Stereo is untouched by Spatial Audio settings")
    func stereoUnchanged() {
        let stereo = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2)
        let plan = FormatPlanner.plan(source: stereo, device: airPods, spatial: .headTracked)
        #expect(plan.channels == 2 && plan.spatial == .off)
    }

    @Test("Spatial and downmixed plans are never joined gaplessly with plain stereo")
    func compatibility() {
        let spatial = FormatPlanner.plan(source: surround, device: airPods, spatial: .fixed)
        let stereo = FormatPlanner.plan(source: SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2), device: airPods)
        #expect(!spatial.isDeviceCompatible(with: stereo))
        #expect(spatial.isDeviceCompatible(with: FormatPlanner.plan(source: surround, device: airPods, spatial: .fixed)))
    }
}

@Suite("Multichannel export")
struct MultichannelExportTests {
    @Test("5.1 exports to binaural stereo ALAC and to 6-channel ALAC", arguments: MultichannelExport.Kind.allCases)
    func export(kind: MultichannelExport.Kind) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 5.1 WAV with a tone only in the left surround.
        let source = dir.appendingPathComponent("surround.wav")
        do {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                                                      AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                                                                      AVChannelLayoutKey: Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
            buffer.frameLength = 96_000
            for c in 0..<6 { for i in 0..<96_000 { buffer.floatChannelData![c][i] = c == 4 ? 0.3 * sin(2 * .pi * 1_000 * Float(i) / 48_000) : 0 } }
            try file.write(from: buffer)
        }
        let dest = dir.appendingPathComponent("out.m4a")
        let written = try MultichannelExport.export(PlayableItem(url: source), kind: kind, to: dest)
        let out = try AVAudioFile(forReading: dest)
        #expect(out.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatAppleLossless)
        #expect(Int(out.processingFormat.channelCount) == written)
        #expect(abs(Double(out.length) - 96_000) < 4_800)
        let buf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(out.length))!
        try out.read(into: buf)
        func rms(_ c: Int) -> Double {
            let p = buf.floatChannelData![c]; var s = 0.0
            for i in 4_800..<Int(buf.frameLength) { s += Double(p[i] * p[i]) }
            return sqrt(s / Double(Int(buf.frameLength) - 4_800))
        }
        if kind == .spatialStereo {
            #expect(written == 2)
            #expect(rms(0) > rms(1) * 1.3, "left-surround should be heard on the left: L \(rms(0)) R \(rms(1))")
        } else {
            #expect(written == 6)
            #expect(rms(4) > 0.1 && rms(0) < 0.001, "the surround stays in its own channel")
        }
    }
}
