//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

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

    @Test("Every bed Vespertine may choose is one Apple's spatial mixer takes")
    func bedsAccepted() throws {
        for bed in ChannelLayouts.spatialBeds {
            let layout = try #require(AVAudioChannelLayout(layoutTag: bed.tag))
            #expect(throws: Never.self, "0x\(String(bed.tag, radix: 16)) \(layout.shortNames)") {
                _ = try SpatialRenderer(inputLayout: layout, channels: bed.labels.count, sampleRate: 48_000, maxFrames: 4096, mode: .fixed)
            }
        }
    }

    /// The bed chosen for these speakers, and where each source channel lands on it.
    func placement(_ source: [AudioChannelLabel]) throws -> (bed: [String], routes: [String]) {
        let bed = try #require(ChannelLayouts.spatialBed(for: source))
        let labels = try #require(AVAudioChannelLayout(layoutTag: bed.tag)).channelLabels
        let router = try #require(BedRouter(source: source, bed: labels))
        return (labels.map(ChannelLayouts.shortName), router.routes.map { $0.map { ChannelLayouts.shortName(labels[$0.bed]) }.joined(separator: "+") })
    }

    @Test("Each channel keeps its own speaker: 3.1 keeps its LFE, LCRS its centres, 7.1.4 its heights")
    func beds() throws {
        let threeOne = try placement([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen])
        #expect(threeOne.routes == ["L", "R", "C", "LFE"], "\(threeOne)")
        let lcrs = try placement([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_CenterSurround])
        #expect(lcrs.routes == ["L", "R", "C", "Cs"], "\(lcrs)")
        let atmos = try placement(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)!.channelLabels)
        #expect(atmos.bed.count == 12 && atmos.routes == atmos.bed, "\(atmos)")
        // WAVE speaker masks: back pair Ls/Rs, side pair Lsd/Rsd. The sides must stay beside, the backs behind.
        let wave71 = try placement([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                    kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect])
        #expect(wave71.routes == ["L", "R", "C", "LFE", "Lrs", "Rrs", "Ls", "Rs"], "\(wave71)")
    }

    @Test("The plan carries the bed; tracks on different beds are never joined gaplessly")
    func planBed() {
        let airPods = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
        let threeOne = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 4,
                                    channelLabels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen])
        let quad = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 4)
        let a = FormatPlanner.plan(source: threeOne, device: airPods, spatial: .headTracked)
        let b = FormatPlanner.plan(source: quad, device: airPods, spatial: .headTracked)
        #expect(a.spatialBed != nil && a.channels == 4 && a.reason.hasPrefix("3.1 rendered"), "\(a.reason)")
        #expect(b.reason.hasPrefix("Quad rendered"), "\(b.reason)")
        #expect(!a.isDeviceCompatible(with: b))
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

@Suite("Receivers and speaker setups")
struct ReceiverPlanTests {
    let surround = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 6)
    let surround71 = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 8)
    let hiResSurround = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 6)

    /// An HDMI receiver: 2-channel LPCM up to 192 kHz, 8-channel LPCM up to 96 kHz.
    func receiver(outputChannels: Int, speakers: Int? = nil) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: [32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
                           physicalFormats: [
                               PhysicalFormat(minRate: 32_000, maxRate: 192_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2),
                               PhysicalFormat(minRate: 32_000, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 8),
                           ],
                           outputChannels: outputChannels, supportsDoP: false, speakerLayoutChannels: speakers)
    }

    @Test("A receiver left in 2-channel mode still counts as 8 channels")
    func capacity() {
        #expect(DeviceQuery.channelCapacity(streams: [(widest: 8, current: 2)], configured: 2) == 8)
        #expect(DeviceQuery.channelCapacity(streams: [(widest: 2, current: 2), (widest: 2, current: 2), (widest: 2, current: 2)], configured: 2) == 6)
        #expect(DeviceQuery.channelCapacity(streams: [], configured: 2) == 2)
    }

    @Test("5.1 to an unconfigured 8-channel receiver: six channels in standard order, no downmix")
    func unconfigured() {
        let plan = FormatPlanner.plan(source: surround, device: receiver(outputChannels: 8))
        #expect(plan.channels == 6 && plan.deviceChannels == 6 && plan.spatial == .off)
        #expect(plan.deviceSampleRate == 48_000)
        #expect(plan.reason.contains("standard order"))
    }

    @Test("192 kHz 5.1 on HDMI that carries 8 channels only up to 96 kHz: every channel at 96 kHz")
    func rateLimitedByChannels() {
        let plan = FormatPlanner.plan(source: hiResSurround, device: receiver(outputChannels: 8))
        #expect(plan.channels == 6)
        #expect(plan.deviceSampleRate == 96_000)
    }

    @Test("5.1 into a configured 7.1 room: placed by speaker position (back speakers stay silent)")
    func intoLargerRoom() {
        let plan = FormatPlanner.plan(source: surround, device: receiver(outputChannels: 8, speakers: 8))
        #expect(plan.channels == 8 && plan.deviceChannels == 8)
        #expect(plan.reason.contains("placed on the 7.1"))
    }

    @Test("7.1 into a configured 5.1 room: folded by speaker position")
    func intoSmallerRoom() {
        let plan = FormatPlanner.plan(source: surround71, device: receiver(outputChannels: 8, speakers: 6))
        #expect(plan.channels == 6)
        #expect(plan.reason.contains("placed on the 5.1"))
    }

    @Test("Matching speaker setup: straight through")
    func matching() {
        let plan = FormatPlanner.plan(source: surround, device: receiver(outputChannels: 8, speakers: 6))
        #expect(plan.channels == 6 && plan.reason.contains("5.1 to 5.1 speakers"))
    }

    @Test("A stereo speaker setup doesn't count as a surround room: 8-channel capacity is still used")
    func stereoSetupIgnored() {
        let plan = FormatPlanner.plan(source: surround, device: receiver(outputChannels: 8, speakers: 2))
        #expect(plan.channels == 6 && !plan.reason.contains("placed"))
    }

    @Test("Spatial Audio settings never apply to a receiver's discrete output")
    func spatialOnlyWhenAsked() {
        let plan = FormatPlanner.plan(source: surround, device: receiver(outputChannels: 8), spatial: .off)
        #expect(plan.spatial == .off && plan.deviceChannels == 6)
    }
}

@Suite("Multichannel export")
struct MultichannelExportTests {
    @Test("5.1 exports to binaural stereo ALAC and to 6-channel ALAC", arguments: MultichannelExport.Kind.allCases)
    func export(kind: MultichannelExport.Kind) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 5.1 WAV with a tone only in the left surround.
        let source = dir.appendingPathComponent("surround.wav")
        do {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                                                      AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                                                                      AVChannelLayoutKey: Data(bytes: layout.layout, count: layout.byteSize)],
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

@Suite("Speaker mapping")
struct SpeakerMappingTests {
    /// Converts one frame per source channel (a unique value on each) the way the engine does and
    /// returns, for each output channel, which source channel it carries (-1 = silent / mixed).
    func route(from source: AVAudioChannelLayout, to device: AVAudioChannelLayout) throws -> [Int] {
        let n = Int(source.channelCount), m = Int(device.channelCount)
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: source)
        let outFormat = try #require(AudioFormats.float32(sampleRate: 48_000, channels: m, interleaved: true, layout: device))
        let converter = try #require(AVAudioConverter(from: inFormat, to: outFormat))
        converter.downmix = true
        converter.dither = false
        let frames: AVAudioFrameCount = 4096
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames))
        input.frameLength = frames
        for c in 0..<n { for i in 0..<Int(frames) { input.floatChannelData![c][i] = Float(c + 1) * 0.1 } }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames))
        var fed = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        let data = output.floatChannelData![0]
        let mid = Int(output.frameLength) / 2
        return (0..<m).map { o in
            let v = data[mid * m + o]
            guard abs(v) > 0.01 else { return -1 }
            let src = Int((v / 0.1).rounded()) - 1
            return abs(v - Float(src + 1) * 0.1) < 0.005 ? src : -2
        }
    }

    func layout(_ labels: [AudioChannelLabel]) -> AVAudioChannelLayout {
        let size = MemoryLayout<AudioChannelLayout>.size + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        let l = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        l.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        l.pointee.mChannelBitmap = []
        l.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        withUnsafeMutablePointer(to: &l.pointee.mChannelDescriptions) { p in
            let d = UnsafeMutableRawPointer(p).assumingMemoryBound(to: AudioChannelDescription.self)
            for (i, label) in labels.enumerated() { d[i] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0)) }
        }
        return AVAudioChannelLayout(layout: l)
    }

    @Test("5.1 on 7.1 speakers in HDMI order: centre to centre, LFE to the subwoofer, rears silent")
    func hdmi() throws {
        // CEA-861 HDMI order: L R LFE C Ls Rs Lrs Rrs.
        let device = layout([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_Center,
                             kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                             kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight])
        #expect(device.hasSpeakerPositions && device.shortNames == ["L", "R", "LFE", "C", "Ls", "Rs", "Lrs", "Rrs"])
        let source = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)! // L R C LFE Ls Rs
        let r = try route(from: source, to: device)
        #expect(Array(r.prefix(6)) == [0, 1, 3, 2, 4, 5], "\(r)")
    }

    @Test("7.1 in WAVE order reaches the matching 7.1 speakers")
    func wave71() throws {
        let source = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_WAVE_7_1)!
        let device = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_7_1_C)!
        let r = try route(from: source, to: device)
        #expect(!r.contains(-1) && !r.contains(-2) && Set(r).count == 8, "\(r) · source \(source.shortNames) device \(device.shortNames)")
        for (o, s) in r.enumerated() { #expect(device.shortNames[o] == source.shortNames[s], "\(device.shortNames[o]) ← \(source.shortNames[s])") }
    }

    /// For each source channel alone, the output channels it reaches.
    func reach(from source: AVAudioChannelLayout, to device: AVAudioChannelLayout) throws -> [[String]] {
        let n = Int(source.channelCount), m = Int(device.channelCount)
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: source)
        let outFormat = try #require(AudioFormats.float32(sampleRate: 48_000, channels: m, interleaved: true, layout: device))
        return try (0..<n).map { s in
            let converter = try #require(AVAudioConverter(from: inFormat, to: outFormat))
            converter.downmix = true
            let frames: AVAudioFrameCount = 4096
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames))
            input.frameLength = frames
            for c in 0..<n { for i in 0..<Int(frames) { input.floatChannelData![c][i] = c == s ? 0.5 : 0 } }
            let output = try #require(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames))
            var fed = false
            _ = converter.convert(to: output, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return input
            }
            let mid = Int(output.frameLength) / 2
            return (0..<m).filter { abs(output.floatChannelData![0][mid * m + $0]) > 0.01 }.map { device.shortNames[$0] }
        }
    }

    @Test("7.1 folds into a 5.1 room: every channel is heard, rears join the surrounds")
    func fold() throws {
        let source = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_7_1_C)! // L R C LFE Ls Rs Lrs Rrs
        let device = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)! // L R C LFE Ls Rs
        let r = try reach(from: source, to: device)
        #expect(r[0] == ["L"] && r[1] == ["R"] && r[2] == ["C"] && r[3] == ["LFE"], "\(zip(source.shortNames, r).map { "\($0)→\($1)" })")
        #expect(r[6].contains("Ls") && r[7].contains("Rs"), "rear surrounds must fold into the surrounds: \(r)")
    }
}
