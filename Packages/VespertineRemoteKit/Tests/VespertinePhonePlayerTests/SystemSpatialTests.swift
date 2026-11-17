//
// Vespertine: surround reaching iOS's own Spatial Audio (TestFlight feedback tf-1c99555e54, tf-4e0452d141, tf-a5b2a6dbdc).
// Build 7 rendered a 5.1 song to two binaural channels inside the app and handed iOS stereo: Control Center on AirPods Max
// said "Stereo", the Output screen read "Output's channels 2", the Surround on Headphones setting changed nothing iOS could
// see, and the badge still said "SPATIAL AUDIO · HEAD TRACKED". These hold the fix to: where iOS says it spatializes, the
// song's channels and their layout reach iOS as they are; the badge says spatial only when iOS says so.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio) && canImport(AVFoundation)
import AudioToolbox
import AVFAudio
import AVFoundation
import CoreMedia
import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private let rate = 48_000.0
private let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center, LFE = kAudioChannelLabel_LFEScreen
private let Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround
private let fivePointOne = [L, R, C, LFE, Ls, Rs]

private let pods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
private let podsSpatialOff = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: false)
private let wired = PhoneRoute(name: "Headphones", portType: "Headphones", sampleRate: 48_000, channels: 2, spatial: false)
private let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false)
private let interface = PhoneRoute(name: "UMC1820", portType: "USBAudio", sampleRate: 48_000, channels: 8, spatial: false)

/// A WAV of `channels` channels with a different tone on each.
private func surroundFile(channels: Int, seconds: Double = 0.6) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-spatial-\(UUID()).wav")
    let frames = Int(seconds * rate)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<channels {
        for i in 0..<frames { buffer.floatChannelData![c][i] = Float(0.4 * sin(2 * Double.pi * (300 + 100 * Double(c)) * Double(i) / rate)) }
    }
    try file.write(from: buffer)
    return url
}

private func streamFormat(_ labels: [AudioChannelLabel]) -> StreamFormat {
    StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: labels.count, channelLabels: labels, lossless: true)
}

/// Stands in for iOS's sample buffer renderer: keeps what it is given and runs a clock the test moves.
final class FakeSink: PlayerSink, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = PlayedLedger()
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private(set) var playing = false
    private var clock: Int64?

    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        lock.withLock {
            buffers.append(buffer)
            _ = ledger.add(frames: Int64(buffer.frameLength), now: clock, lead: 0, played: played)
        }
    }
    func play() { lock.withLock { playing = true; if clock == nil { clock = 0 } } }
    func pause() { lock.withLock { playing = false } }
    func stop() { lock.withLock { playing = false; clock = nil; ledger.clear() } }
    func rendered() -> Int64? { lock.withLock { clock } }

    /// Moves the clock on by `frames` and says what was heard.
    func advance(_ frames: Int64) {
        let calls: [@Sendable () -> Void] = lock.withLock {
            guard playing, let now = clock else { return [] }
            clock = now + frames
            return ledger.heard(by: now + frames)
        }
        calls.forEach { $0() }
    }
}

@MainActor private func offline() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!,
                                         maximumFrameCount: 4096)
    return engine
}

@Suite struct SurroundPathPolicy {
    @Test func whereIOSSpatializesSurroundIsHandedToIOS() {
        // AirPods with Spatial Audio on: iOS renders it, as for Apple Music; Fixed or Head Tracked is Control Center's.
        #expect(pods.surroundPath(wanted: .fixed) == .system)
        #expect(pods.surroundPath(wanted: .headTracked) == .system)
        #expect(pods.surroundPath(wanted: .headTracked, canTrackHead: false) == .system)
        // Off is Off: the song is folded to stereo here, and iOS gets two channels.
        #expect(pods.surroundPath(wanted: .off) == .fold)
    }

    @Test func headphonesIOSWontSpatializeGetVespertinesOwnFixedRendering() {
        #expect(wired.surroundPath(wanted: .fixed) == .binaural)
        #expect(wired.surroundPath(wanted: .headTracked) == .binaural)
        #expect(podsSpatialOff.surroundPath(wanted: .headTracked) == .binaural)
        #expect(wired.surroundPath(wanted: .off) == .fold)
    }

    @Test func speakersFoldAndInterfacesGetAChannelEach() {
        #expect(speaker.surroundPath(wanted: .fixed) == .fold)
        #expect(interface.surroundPath(wanted: .fixed) == .discrete)
        #expect(interface.surroundPath(wanted: .off) == .discrete)
        // The iPhone's speaker says it spatializes (measured on an iPhone 15 Pro Max): it still gets the fold the setting promises.
        let spatialSpeaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: true)
        #expect(spatialSpeaker.surroundPath(wanted: .fixed) == .fold)
    }
}

@Suite struct SpatialBadgeHonesty {
    private func signal(route: PhoneRoute, sent: Int?, rendering: SystemRenderingMode?) -> PhoneSignal {
        let stream = StreamDescriptor(stream: 1, kind: .original, byteSize: 1, format: streamFormat(fivePointOne), frames: 1, tag: "t", chunkSize: 1)
        var signal = PhoneSignal(stream: stream, route: route)
        signal.systemChannels = sent
        signal.systemRendering = rendering
        return signal
    }

    @Test func spatialIsSaidOnlyWhenIOSSaysIt() {
        #expect(signal(route: pods, sent: 6, rendering: .spatialAudio).systemSurround == .spatial)
        #expect(signal(route: pods, sent: 6, rendering: .dolbyAtmos).systemSurround == .spatial)
        // Handed over, iOS hasn't resolved it yet: not called spatial.
        #expect(signal(route: pods, sent: 6, rendering: .notApplicable).systemSurround == .pending)
        #expect(signal(route: pods, sent: 6, rendering: nil).systemSurround == .pending)
        // iOS says stereo: the badge says so.
        #expect(signal(route: pods, sent: 6, rendering: .monoStereo).systemSurround == .stereo)
        #expect(signal(route: pods, sent: 6, rendering: .surround).systemSurround == .surround)
        // The route stopped spatializing (Spatial Audio off in Control Center): whatever the mode says, not spatial.
        #expect(signal(route: podsSpatialOff, sent: 6, rendering: .spatialAudio).systemSurround == .surround)
        // Nothing multichannel handed to iOS (build 7's two binaural channels): never spatial.
        #expect(signal(route: pods, sent: 2, rendering: .spatialAudio).systemSurround == nil)
        #expect(signal(route: pods, sent: nil, rendering: .spatialAudio).systemSurround == nil)
    }
}

@Suite struct PlayedLedgerTests {
    @Test func buffersAreHeardInOrderAndAStarveStartsAhead() {
        var ledger = PlayedLedger()
        let heard = Heard()
        #expect(ledger.add(frames: 100, now: nil, lead: 10, played: { heard.add(1) }) == 0)
        #expect(ledger.add(frames: 100, now: 50, lead: 10, played: { heard.add(2) }) == 100)
        ledger.heard(by: 99).forEach { $0() }
        #expect(heard.all.isEmpty)
        ledger.heard(by: 150).forEach { $0() }
        #expect(heard.all == [1])
        // The clock ran past the end: the next buffer starts `lead` after now, not in the past.
        #expect(ledger.add(frames: 100, now: 400, lead: 10, played: { heard.add(3) }) == 410)
        ledger.heard(by: 510).forEach { $0() }
        #expect(heard.all == [1, 2, 3] && ledger.isEmpty)
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }
}

@Suite struct SampleBufferMaking {
    @Test func fivePointOneKeepsItsChannelsLayoutAndSamples() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        for c in 0..<6 { for i in 0..<64 { buffer.floatChannelData![c][i] = Float(c * 1000 + i) } }
        let sample = try #require(SampleBuffers.make(buffer, start: 4_800))
        #expect(CMSampleBufferGetNumSamples(sample) == 64)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 4_800, timescale: 48_000))
        let description = try #require(CMSampleBufferGetFormatDescription(sample))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        #expect(asbd.mChannelsPerFrame == 6 && asbd.mSampleRate == rate && asbd.mFormatID == kAudioFormatLinearPCM)
        var size = 0
        let carried = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(carried.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_MPEG_5_1_A, "iOS is told which speaker each channel is")
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var pointer: UnsafeMutablePointer<CChar>?
        #expect(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr)
        let floats = UnsafeRawPointer(try #require(pointer)).bindMemory(to: Float.self, capacity: 64 * 6)
        for i in [0, 1, 63] { for c in 0..<6 { #expect(floats[i * 6 + c] == Float(c * 1000 + i), "frame \(i) channel \(c)") } }
    }
}

@Suite(.serialized) @MainActor struct SystemSpatialPlayer {
    @Test func aSurroundSongReachesIOSWithAllItsChannels() throws {
        let url = try surroundFile(channels: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offline()
        let sink = FakeSink()
        let player = PhonePlayer(engine: engine)
        player.makeSystemSink = { sink }
        player.systemSpatial = true
        player.spatialMode = .fixed
        try player.load(url, format: streamFormat(fivePointOne))
        try player.play()
        #expect(player.rendering == .system(channels: 6))
        #expect(!player.isUntouchedPath)
        let first = try #require(sink.buffers.first)
        #expect(first.format.channelCount == 6, "build 7 handed iOS 2 binaural channels")
        #expect(first.format.channelLayout?.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(sink.playing && engine.isRunning == false, "the engine isn't playing beside it")
        // The clock is iOS's: the place follows it, and the pump decodes more as it is heard.
        sink.advance(Int64(0.25 * rate))
        #expect(abs(player.position - 0.25) < 0.01)
        player.pause()
        #expect(!sink.playing && player.state == .paused)
        player.halt()
    }

    @Test func offFoldsInTheEngineAndHandsIOSNothing() throws {
        let url = try surroundFile(channels: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = FakeSink()
        let player = PhonePlayer(engine: try offline())
        player.makeSystemSink = { sink }
        player.systemSpatial = false
        player.spatialMode = .off
        try player.load(url, format: streamFormat(fivePointOne))
        try player.play()
        #expect(player.rendering == .downmix)
        #expect(sink.buffers.isEmpty)
        player.halt()
    }

    @Test func turningSpatialOnWhilePlayingMovesTheSongToIOSFromTheSamePlace() throws {
        let url = try surroundFile(channels: 6, seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offline()
        let sink = FakeSink()
        let player = PhonePlayer(engine: engine)
        player.makeSystemSink = { sink }
        try player.load(url, format: streamFormat(fivePointOne))
        try player.play()
        #expect(player.rendering == .downmix)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        for _ in 0..<6 { _ = try engine.renderOffline(4000, to: buffer) }
        player.systemSpatial = true
        #expect(player.rendering == .system(channels: 6) && player.state == .playing)
        #expect(abs(player.position - 0.5) < 0.1)
        #expect(sink.buffers.first?.format.channelCount == 6)
        player.systemSpatial = false
        #expect(player.rendering == .downmix && player.state == .playing && !sink.playing)
        player.halt()
    }

    @Test func stereoNeverGoesToTheRenderer() throws {
        let url = try surroundFile(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = FakeSink()
        let player = PhonePlayer(engine: try offline())
        player.makeSystemSink = { sink }
        player.systemSpatial = true
        try player.load(url, format: StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true))
        try player.play()
        #expect(player.rendering == .untouched && player.isUntouchedPath)
        #expect(sink.buffers.isEmpty)
        player.halt()
    }
}
#endif
