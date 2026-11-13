//
// Vespertine: the badges of a song sent to a network renderer. Vespertine can say what it sent, not what the renderer's DAC
// received, so a renderer path is never BIT-PERFECT in the DAC-level sense and its badge always says "SENT" or "PROCESSED".
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Renderer signal path")
struct RendererSignalPathTests {
    static func path(_ source: SourceFormat, processing: [SignalPath.RendererStage.Processing] = [], sentDepth: Int? = nil,
                     volume: SignalPath.VolumeStage = .fixed, equalizer: String? = nil) -> SignalPath {
        let stage = SignalPath.RendererStage(name: "moOde UPNP", protocolName: "OpenHome", processing: processing,
                                             sentCodec: processing.isEmpty ? source.codec : "FLAC", sentSampleRate: source.sampleRate,
                                             sentBitDepth: sentDepth ?? source.bitDepth, sentChannels: source.channels, gapless: true)
        return SignalPath.renderer(stage, source: source, decoderName: source.codec, volume: volume, equalizer: equalizer)
    }

    static let hiRes = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 2)

    @Test("Pass-through says what was sent, and never claims the DAC-level badge")
    func passThrough() {
        let p = Self.path(Self.hiRes)
        #expect(p.statusLine == "BIT-PERFECT · 24/192 SENT")
        #expect(!p.isBitPerfect)
        #expect(p.isUntouched)
        #expect(p.statusLine != "BIT-PERFECT")
        #expect(p.deviceFormatShort == "24/192")
        #expect(p.deviceProfile.kind == .networkRenderer)
        #expect(!p.deviceProfile.canBeBitPerfect)
    }

    @Test("Processing names the badge, the strongest reason first")
    func processed() {
        #expect(Self.path(Self.hiRes, processing: [.equalizer], equalizer: "Warm").statusLine == "PROCESSED · EQ")
        #expect(Self.path(Self.hiRes, processing: [.equalizer, .roomCorrection]).statusLine == "PROCESSED · ROOM CORRECTION")
        #expect(Self.path(Self.hiRes, processing: [.volume], volume: .digital(dB: -6)).statusLine == "PROCESSED · VOLUME")
        #expect(Self.path(Self.hiRes, processing: [.replayGain]).statusLine == "PROCESSED · REPLAYGAIN")
        #expect(Self.path(Self.hiRes, processing: [.format]).statusLine == "PROCESSED · FLAC")
        let p = Self.path(Self.hiRes, processing: [.equalizer])
        #expect(!p.isUntouched)
        #expect(!p.isBitPerfect)
    }

    @Test("A lossy or DSD file sent as it is says so")
    func otherSources() {
        let mp3 = SourceFormat(encoding: .lossy, codec: "MP3", sampleRate: 44_100, bitDepth: nil, channels: 2)
        #expect(Self.path(mp3).statusLine == "LOSSY SOURCE · SENT AS IS")
        #expect(!Self.path(mp3).isUntouched)
        let dsd = SourceFormat(encoding: .dsd, codec: "DSD", sampleRate: 2_822_400, bitDepth: nil, channels: 2)
        #expect(Self.path(dsd).statusLine == "NATIVE DSD · DSD64 SENT")
        #expect(Self.path(dsd).isUntouched)
    }

    @Test("A local device's path is unchanged: isUntouched is isBitPerfect")
    func localUnchanged() {
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 96_000, decodedSampleRate: 96_000, physicalBitDepth: 24, channels: 2, dsdConvertedToPCM: false, reason: "")
        let applied = AppliedFormat(sampleRate: 96_000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2, exclusive: true, bufferFrames: 512)
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2)
        let path = SignalPath(source: source, decoderName: "FLAC", plan: plan, applied: applied, deviceName: "DAC", deviceUID: "dac",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .hardware, replayGainDB: nil)
        #expect(path.isBitPerfect)
        #expect(path.isUntouched)
        #expect(path.statusLine == "BIT-PERFECT")
        #expect(path.renderer == nil)
    }

    @Test("An engine snapshot can be made outside the engine")
    func snapshot() {
        var s = EngineSnapshot()
        s.position = 3
        #expect(s.state == .stopped)
        #expect(s.position == 3)
    }
}
