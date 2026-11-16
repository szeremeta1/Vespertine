//
// Vespertine: DSD on a DAC plugged into the phone. Which DACs are sent DoP (only ones that passed the listening test, only
// while the output can carry the frames exactly), the test sound itself, and what the phone's player does with a song that
// arrives as DoP frames: the output is brought to their rate before a note is played, and when it can't be, or stops
// being right, the song is asked for again as PCM.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func dac(rate: Double = 44_100, channels: Int = 2, uid: String? = "usb:fiio-k11") -> PhoneRoute {
    PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: rate, channels: channels, spatial: false, uid: uid)
}

@Suite struct WhichDACsGetDoP {
    @Test func aDacGetsDoPOnlyAfterItAnsweredMusic() {
        var dacs = DoPDACs()
        #expect(dacs.ceiling(for: "a") == nil && dacs.answer(for: "a") == nil)
        dacs.record(.hiss, uid: "a", name: "A")
        #expect(dacs.ceiling(for: "a") == nil && dacs.answer(for: "a") == .hiss)
        dacs.record(.music, uid: "a", name: "A")
        #expect(dacs.ceiling(for: "a") == DoPDACs.highestCarrier)
        // One DAC's answer says nothing about another, and none at all about an output iOS doesn't identify.
        #expect(dacs.ceiling(for: "b") == nil && dacs.ceiling(for: nil) == nil)
        dacs.forget(uid: "a")
        #expect(dacs.ceiling(for: "a") == nil)
    }

    @Test func aRateTheDacDeclinedIsNotAskedForAgain() {
        var dacs = DoPDACs()
        dacs.record(.music, uid: "a", name: "A")
        dacs.declined(705_600, uid: "a")
        #expect(dacs.ceiling(for: "a") == 352_800)
        dacs.declined(352_800, uid: "a")
        #expect(dacs.ceiling(for: "a") == 176_400)
        // A higher rate declined later never raises it again.
        dacs.declined(705_600, uid: "a")
        #expect(dacs.ceiling(for: "a") == 176_400)
        // Declining the rate the test itself ran at takes the answer back: it has to be tested again.
        dacs.declined(176_400, uid: "a")
        #expect(dacs.ceiling(for: "a") == nil && dacs.answer(for: "a") == nil)
        // Testing again starts afresh.
        dacs.record(.music, uid: "a", name: "A")
        #expect(dacs.ceiling(for: "a") == DoPDACs.highestCarrier)
    }

    @Test func aDacThatAnsweredHissIsNotChangedByADecline() {
        var dacs = DoPDACs()
        dacs.record(.hiss, uid: "a", name: "A")
        dacs.declined(352_800, uid: "a")
        #expect(dacs.answer(for: "a") == .hiss)
    }

    @Test func theAnswersAreKeptBetweenLaunches() throws {
        let suite = "dop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DoPDACs.load(from: defaults) == DoPDACs())
        var dacs = DoPDACs()
        dacs.record(.music, uid: "a", name: "FiiO K11")
        dacs.record(.hiss, uid: "b", name: "Dongle")
        dacs.declined(705_600, uid: "a")
        dacs.save(to: defaults)
        #expect(DoPDACs.load(from: defaults) == dacs)
    }

    @Test func onlyAStereoUsbDacThatIosIdentifiesCanBeTested() {
        #expect(DoPGate.canTest(dac()))
        #expect(!DoPGate.canTest(nil))
        #expect(!DoPGate.canTest(dac(uid: nil)) && !DoPGate.canTest(dac(uid: "")))
        #expect(!DoPGate.canTest(dac(channels: 6)), "an interface running with six outputs")
        for port in ["Speaker", "BluetoothA2DPOutput", "AirPlay", "Headphones", "HDMI", "CarAudio"] {
            #expect(!DoPGate.canTest(PhoneRoute(name: "x", portType: port, sampleRate: 48_000, channels: 2, spatial: false, uid: "u")), "\(port)")
        }
    }

    @Test func doPNeedsATestedDacAndTheVolumeAtItsTop() {
        var dacs = DoPDACs()
        dacs.record(.music, uid: "usb:fiio-k11", name: "K11")
        #expect(DoPGate.ceiling(route: dac(), volume: 1, dacs: dacs) == DoPDACs.highestCarrier)
        #expect(DoPGate.ceiling(route: dac(), volume: 0.9, dacs: dacs) == nil, "below the top, iOS may be scaling the samples")
        #expect(DoPGate.ceiling(route: dac(), volume: nil, dacs: dacs) == nil, "an unknown volume is not assumed to be full")
        #expect(DoPGate.ceiling(route: dac(uid: "usb:other"), volume: 1, dacs: dacs) == nil, "another DAC")
        #expect(DoPGate.ceiling(route: dac(channels: 6), volume: 1, dacs: dacs) == nil)
        #expect(DoPGate.ceiling(route: nil, volume: 1, dacs: dacs) == nil)
        #expect(DoPGate.ceiling(route: dac(), volume: 1, dacs: DoPDACs()) == nil, "never tested")
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false, uid: "usb:fiio-k11")
        #expect(DoPGate.ceiling(route: speaker, volume: 1, dacs: dacs) == nil)
    }

    @Test func aSongOpenedAheadGetsDoPOnlyAtTheRateTheOutputAlreadyRunsAt() {
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 176_400) == 176_400)
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 352_800) == 352_800)
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 44_100) == 44_100, "below every carrier rate: the Mac sends no DSD as DoP for it")
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 0) == nil)
        #expect(DoPGate.aheadCeiling(ceiling: 176_400, outputRate: 352_800) == nil)
        #expect(DoPGate.aheadCeiling(ceiling: nil, outputRate: 176_400) == nil)
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: nil) == nil)
    }

    @Test func dsdRatesAreNamedAsEverywhereElse() {
        #expect(DoPGate.name(dsdRate: 2_822_400) == "DSD64" && DoPGate.name(dsdRate: 5_644_800) == "DSD128")
        #expect(DoPGate.name(dsdRate: 11_289_600) == "DSD256" && DoPGate.name(dsdRate: 3_072_000) == "DSD64")
    }
}

@Suite struct TheDoPTestSound {
    private static let frames = DoPProbeClip.frames()

    @Test func itIsFiveSecondsOfDoPFramesWithTheMarkerAlternatingThroughout() {
        let frames = Self.frames
        #expect(frames.count == 882_000 && frames.count % 2 == 0)
        var wrong = 0
        for (index, word) in frames.enumerated() where word >> 16 != (index % 2 == 0 ? 0x05 : 0xFA) { wrong += 1 }
        #expect(wrong == 0)
        #expect(frames.allSatisfy { $0 <= 0xFF_FFFF })
    }

    /// The DSD the frames carry, decoded as a DAC would: the mean of each 16 bits is one sample at 176.4 kHz, averaged
    /// again over 16 of those to take the modulator's noise out (11 kHz wide: plenty for a chord under 1 kHz).
    private static func decoded() -> [Double] {
        let raw = frames.map { word -> Double in
            let ones = (word & 0xFFFF).nonzeroBitCount
            return Double(2 * ones - 16) / 16
        }
        return stride(from: 0, to: raw.count - 15, by: 16).map { start in raw[start..<start + 16].reduce(0, +) / 16 }
    }

    @Test func aDacThatDecodesItPlaysASoftChordThatRisesFromSilenceAndEndsInIt() {
        let audio = Self.decoded()
        let rate = 176_400.0 / 16
        func peak(_ from: Double, _ to: Double) -> Double { audio[Int(from * rate)..<Int(to * rate)].map(abs).max() ?? 0 }
        // Nothing at the very start or the very end: no click when it begins or stops.
        #expect(peak(0, 0.05) < 0.02 && peak(4.95, 5.0) < 0.02)
        // It rises: quieter in the first half second than once it is up.
        #expect(peak(0.1, 0.5) < peak(2.5, 4.0))
        // The chord is there, and never above -20 dB of full scale (with a little room for what's left of the noise).
        #expect(peak(2.5, 4.0) > 0.04 && peak(0, 5.0) < DoPProbeClip.amplitude * 1.3)
        // The first note is C5: its level over a second of the held chord, by Goertzel.
        let held = Array(audio[Int(3.0 * rate)..<Int(4.0 * rate)])
        func level(_ hz: Double) -> Double {
            let w = 2 * Double.pi * hz / rate
            var re = 0.0, im = 0.0
            for (n, x) in held.enumerated() { re += x * cos(w * Double(n)); im += x * sin(w * Double(n)) }
            return 2 * (re * re + im * im).squareRoot() / Double(held.count)
        }
        #expect(level(523.25) > 0.02 && level(659.25) > 0.02 && level(783.99) > 0.02)
        #expect(level(2_000) < 0.005, "and nothing where no note is")
    }

    @Test func aDacThatDoesNotDecodeItPlaysOnlyAQuietHiss() {
        // Played as 24-bit PCM, the marker alternates every frame: a tone at 88.2 kHz, far above hearing. What can be
        // heard is what the 16 DSD bits under it add up to: averaged over two frames the marker is gone.
        let samples = Self.frames.map { Double(Int32(bitPattern: $0 << 8) >> 8) / 8_388_608 }
        var sum = 0.0
        var count = 0
        for index in stride(from: 0, to: samples.count - 1, by: 2) {
            let audible = (samples[index] + samples[index + 1]) / 2
            sum += audible * audible
            count += 1
        }
        let decibels = 20 * log10((sum / Double(count)).squareRoot())
        #expect(decibels < -42, "got \(decibels) dBFS")
    }

    @Test func aFrameSurvivesTheFloatSampleItIsSentAs() {
        // What an output makes of the float: scaled back to 24 bits, the same word.
        var wrong = 0
        for word in Self.frames.prefix(50_000) + Self.frames.suffix(50_000) {
            let back = UInt32(bitPattern: Int32((DoPProbeClip.sample(word) * 8_388_608).rounded())) & 0xFF_FFFF
            if back != word { wrong += 1 }
        }
        #expect(wrong == 0)
    }
}

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import VespertineRemoteClient

/// A Mac that sends every song as a short made sound, and says it is DoP frames when asked for DoP at or above `carrier`
/// (the sound's own rate stands in for the carrier rate). It keeps what it was asked.
private final class DoPMac: @unchecked Sendable {
    struct Ask: Equatable { var song: Int64; var dop: Double? }
    private let lock = NSLock()
    private var open: [Int: Data] = [:]
    private var next = 0
    private var _asks: [Ask] = []
    private var _closed: [Int] = []
    let carrier = Double(DemoSound.sampleRate)
    let seconds: Double
    /// Songs that are PCM whatever is asked.
    var pcmSongs: Set<Int64> = []
    /// The ReplayGain values the Mac has for every song.
    var replayGain: ReplayGain?

    init(seconds: Double = 3) { self.seconds = seconds }

    var asks: [Ask] { lock.withLock { _asks } }
    var closed: [Int] { lock.withLock { _closed } }

    func answer(_ song: Int64, dop: Double?) -> RemoteReply {
        let data = DemoSound.wave(song: song, seconds: seconds)
        let asDoP = !pcmSongs.contains(song) && (dop.map { $0 >= carrier - 0.5 } ?? false)
        return lock.withLock {
            _asks.append(Ask(song: song, dop: dop))
            next += 1
            open[next] = data
            return .streamOpened(StreamDescriptor(stream: next, kind: asDoP ? .flac : .original, byteSize: Int64(data.count),
                                                  format: StreamFormat(codec: "WAV", container: "wav", sampleRate: carrier, bitDepth: 16, channels: 2,
                                                                       channelLabels: nil, lossless: true),
                                                  frames: Int64((data.count - 44) / 4), tag: "\(song)-\(asDoP ? "dop" : "pcm")",
                                                  chunkSize: RemoteProtocol.defaultChunkSize, dsdRate: asDoP ? 2_822_400 : nil))
        }
    }

    var client: PhoneStreamClient {
        var client = PhoneStreamClient(open: { [self] song, _ in answer(song, dop: nil) },
                                       read: { [self] stream, offset, length in
                                           guard let data = lock.withLock({ open[stream] }), offset >= 0, offset <= Int64(data.count) else { throw RemoteLinkError.closed }
                                           let end = min(Int(offset) + max(0, length), data.count)
                                           return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: end >= data.count,
                                                              payload: data.subdata(in: Int(offset)..<end))
                                       },
                                       close: { [self] stream in lock.withLock { open[stream] = nil; _closed.append(stream) } },
                                       isConnected: { true })
        client.openDoP = { [self] song, _, dop in answer(song, dop: dop) }
        client.info = { [self] song in
            let format = StreamFormat(codec: "DSD", container: "dsf", sampleRate: 2_822_400, bitDepth: 1, channels: 2, channelLabels: nil, lossless: true)
            return StreamInfo(id: song, streamable: true, kind: .flac, source: format, delivered: nil, macOnlyReason: nil, byteSize: nil, totalFrames: nil,
                              replayGain: replayGain, encoderDelay: nil, endPadding: nil)
        }
        return client
    }
}

/// The output as the tests set it.
@MainActor private final class FakeOutput {
    var ceiling: Double?
    var rate: Double = 48_000
    /// What `bring` does: true moves the output to the rate asked for.
    var grants = true
    var brought: [Double] = []
    var declined: [Double] = []
    /// Called inside `bring`, before it answers.
    var whileBringing: (() -> Void)?

    func install(on playback: PhonePlayback) {
        // Weak, not unowned: a test that gives up leaves its player running a moment longer than this output, and asking a
        // dead output must not take every other test down with it.
        playback.dop.ceiling = { [weak self] in self?.ceiling }
        playback.dop.rate = { [weak self] in self?.rate }
        playback.dop.bring = { [weak self] carrier in
            guard let self else { return false }
            brought.append(carrier)
            whileBringing?()
            if grants { rate = carrier }
            return grants
        }
        playback.dop.declined = { [weak self] carrier in self?.declined.append(carrier) }
    }
}

@Suite(.serialized) @MainActor struct ASongThatArrivesAsDoP {
    private func track(_ id: Int64) -> TrackSummary {
        TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 3, trackNumber: Int(id), discNumber: 1,
                     format: "DSD64", artworkKey: nil, favorite: false)
    }

    private func make(_ mac: DoPMac) throws -> (PhonePlayback, FakeOutput) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let playback = PhonePlayback(client: mac.client, player: PhonePlayer(engine: engine),
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("phone-dop-\(UUID())"))
        let output = FakeOutput()
        output.install(on: playback)
        return (playback, output)
    }

    /// Waits for something the phone must get round to. The 500 looks end a run where it never does; they decide nothing. They are counted, not timed: a busy machine that holds every test still for seconds uses up a clock but not a count.
    private func until(_ condition: () -> Bool) async throws {
        var looks = 0
        while !condition(), looks < 500 { looks += 1; try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func withoutATestedDacNothingIsEverAskedForAsDoP() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        playback.play([track(1), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        #expect(mac.asks == [.init(song: 1, dop: nil), .init(song: 2, dop: nil)])
        #expect(playback.stream?.dsdRate == nil && output.brought.isEmpty)
        playback.stop()
    }

    @Test func theOutputIsBroughtToTheCarrierRateBeforeTheSongStarts() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        var stateWhileBringing: PhonePlayer.State?
        output.whileBringing = { stateWhileBringing = playback.player.state }
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        #expect(mac.asks == [.init(song: 1, dop: 768_000)])
        #expect(output.brought == [mac.carrier] && output.declined.isEmpty)
        #expect(stateWhileBringing == .idle, "nothing of the song is played while the output changes rate")
        #expect(playback.stream?.dsdRate == 2_822_400)
        playback.stop()
    }

    @Test func aDacThatWillNotRunAtTheCarrierRateGetsTheSongAsPCMAndIsNotAskedAgain() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        output.grants = false
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        #expect(mac.asks == [.init(song: 1, dop: 768_000), .init(song: 1, dop: nil)])
        #expect(output.declined == [mac.carrier])
        #expect(playback.stream?.dsdRate == nil, "what plays is the PCM")
        try await until { mac.closed == [1] }   // and the DoP stream was given back to the Mac
        playback.stop()
    }

    @Test func theSongAfterItComesAsDoPOnlyWhileTheOutputRunsAtItsRate() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        // The first song brought the output to the carrier rate, so the one after it is asked for at exactly that rate.
        #expect(mac.asks == [.init(song: 1, dop: 768_000), .init(song: 2, dop: mac.carrier)], "\(mac.asks)")
        #expect(output.brought == [mac.carrier], "the output is not touched for a song opened ahead")
        playback.stop()
    }

    @Test func aDsdSongAfterAPcmSongAtAnotherRateIsNotAskedForAsDoP() async throws {
        // Nothing may change under the song being heard, so the DSD song lined up behind it comes as PCM.
        let mac = DoPMac()
        mac.pcmSongs = [10]
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        output.rate = 40_000
        playback.play([track(10), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        // Asked for only up to the rate the output runs at, which is below the song's carrier: it comes as PCM.
        #expect(mac.asks == [.init(song: 10, dop: 768_000), .init(song: 2, dop: 40_000)])
        #expect(output.brought.isEmpty && playback.stream?.dsdRate == nil)
        try await until { playback.player.state == .playing }
        playback.next()
        try await until { playback.nowPlaying?.track.id == 2 && playback.player.state == .playing }
        #expect(playback.stream?.dsdRate == nil && output.brought.isEmpty)
        playback.stop()
    }

    @Test func turningTheVolumeDownMidSongBringsTheSongBackAsPCMWhereItWas() async throws {
        let mac = DoPMac(seconds: 6)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1)])
        try await until { playback.player.state == .playing && playback.stream?.dsdRate != nil }
        playback.seek(to: 2)
        try await until { abs(playback.livePosition - 2) < 0.2 }
        // The volume leaves its top: the output takes no DoP any more.
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing }
        #expect(mac.asks.last == .init(song: 1, dop: nil))
        #expect(abs(playback.livePosition - 2) < 0.3, "it carries on from where it was, at \(playback.livePosition)")
        #expect(playback.nowPlaying?.track.id == 1 && playback.notice == nil)
        playback.stop()
    }

    @Test func aPausedSongStaysPausedWhenItIsBroughtBackAsPCM() async throws {
        let mac = DoPMac(seconds: 6)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        playback.pause()
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state != .loading && playback.player.state != .idle }
        #expect(!playback.isPlaying)
        playback.stop()
    }

    @Test func aPcmSongIsLeftAloneWhenTheOutputChanges() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        output.rate = 96_000
        playback.outputChanged()
        output.ceiling = 768_000
        playback.outputChanged()
        #expect(mac.asks == [.init(song: 1, dop: nil)] && playback.player.state == .playing)
        playback.stop()
    }

    @Test func aSongLinedUpAsDoPIsLinedUpAgainAsPCMWhenTheOutputStopsTakingDoP() async throws {
        let mac = DoPMac(seconds: 8)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        // The first song goes on as it is only if it isn't DoP itself: here it is, so both come back as PCM.
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing && mac.asks.count >= 4 }
        #expect(mac.asks.suffix(2).allSatisfy { $0.dop == nil })
        #expect(Set(mac.asks.suffix(2).map(\.song)) == [1, 2])
        playback.stop()
    }

    @Test func replayGainNeverTouchesDoPFramesButLevelsTheSameSongSentAsPCM() async throws {
        let mac = DoPMac()
        mac.replayGain = ReplayGain(trackGain: -6, trackPeak: 0.5, albumGain: nil, albumPeak: nil)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.replayGain = .track
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        // The frames are DSD bits: multiplying them would be noise. Nothing is done, and the phone says nothing is.
        #expect(playback.stream?.dsdRate == 2_822_400)
        #expect(playback.appliedGain == nil && playback.player.gain == 1 && !playback.player.isProcessing)
        #expect(playback.replayGainHasNothing)
        // The DAC stops taking DoP: the song comes back as PCM, and now it is levelled.
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing }
        #expect(playback.appliedGain?.decibels == -6 && playback.player.isProcessing)
        #expect(abs(playback.player.gain - Float(pow(10, -6.0 / 20))) < 1e-6)
        playback.stop()
    }
}

@Suite @MainActor struct WhatThePhoneSaysAboutDoP {
    private func descriptor(dsd: Double?) -> StreamDescriptor {
        StreamDescriptor(stream: 1, kind: .flac, byteSize: 10,
                         format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: 176_400, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true),
                         frames: 10, tag: "t", chunkSize: 1, dsdRate: dsd)
    }

    @Test func theSignalSaysDsdOnlyForAStreamTheMacSentAsDoP() {
        var signal = PhoneSignal(stream: descriptor(dsd: 2_822_400), route: dac(rate: 176_400))
        signal.volume = 1
        #expect(signal.dsdRate == 2_822_400 && !signal.dopBroken)
        #expect(PhoneSignal(stream: descriptor(dsd: nil), route: dac(rate: 176_400)).dsdRate == nil)
        // At another rate, or with the volume down, the DAC is not getting DSD, and the signal says so.
        #expect(PhoneSignal(stream: descriptor(dsd: 2_822_400), route: dac(rate: 96_000)).dopBroken)
        signal.volume = 0.5
        #expect(signal.dopBroken)
    }
}
#endif
