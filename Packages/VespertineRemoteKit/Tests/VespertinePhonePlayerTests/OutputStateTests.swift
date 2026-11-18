//
// Vespertine: the output's state is read from iOS in one go, on every occasion iOS may have changed it, and a rate that was
// asked for is not shown as settled before iOS has given or refused it. The session here is a script: it says what a test
// makes it say, and counts what it is asked.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// From TestFlight feedback on build 7 (FiiO K11): the app showed a volume of 30% with the phone at 100% until the volume was
// next changed, and 48 kHz for a song the DAC's own display showed at 44.1.
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

/// An audio session that says what the test tells it to.
@MainActor final class ScriptedSession: OutputSession {
    var route: PhoneRoute?
    var volume: Double?
    var rendering: SystemRenderingMode?
    private(set) var rateAsks: [Double] = []
    private(set) var channelAsks: [Int] = []
    private(set) var reads = 0
    /// Called at the start of each read, with how many there have been: where a test makes the output change by itself.
    var beforeRead: ((ScriptedSession, Int) -> Void)?
    /// Called for each rate asked for: where a test decides what the DAC does about it.
    var onRateAsk: ((ScriptedSession, Double) -> Void)?

    init(route: PhoneRoute?, volume: Double? = 1) {
        self.route = route
        self.volume = volume
    }

    func read() -> OutputReading {
        reads += 1
        beforeRead?(self, reads)
        return OutputReading(route: route, volume: route == nil ? nil : volume, rendering: rendering)
    }

    func ask(rate: Double) {
        rateAsks.append(rate)
        onRateAsk?(self, rate)
    }

    func ask(channels: Int) { channelAsks.append(channels) }
}

@MainActor @Suite struct OutputStateTests {
    private func dac(_ rate: Double, name: String = "FiiO K11", uid: String? = "k11", channels: Int = 2, most: Int? = nil) -> PhoneRoute {
        PhoneRoute(name: name, portType: "USBAudio", sampleRate: rate, channels: channels, spatial: false, maximumChannels: most, uid: uid)
    }
    private let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false, uid: "speaker")

    // MARK: The volume (TestFlight AO0TzJgleq0jnLQ7g7ei9VA, AA0UDi09-2p4lRKsNesXlK8)

    @Test func aVolumeIOSChangedWithoutSayingSoIsReadWhenTheOutputChanges() {
        // The speaker at 30%. A DAC is plugged in, and on it iOS's volume is 100%: iOS says the route changed, and says
        // nothing about the volume.
        let session = ScriptedSession(route: speaker, volume: 0.3)
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        #expect(watch.state.volume == 0.3)
        session.route = dac(48_000)
        session.volume = 1
        watch.refresh(.routeChange)
        #expect(watch.state.route?.name == "FiiO K11")
        #expect(watch.state.volume == 1, "the volume is the DAC's, not the one from before it was plugged in")
    }

    @Test func everyOccasionReadsTheVolumeTheRateAndTheOutputTogether() {
        let session = ScriptedSession(route: dac(48_000), volume: 0.3)
        let watch = OutputWatch(session: session)
        let occasions: [OutputWatch.Occasion] = [.start, .routeChange, .outputChange, .rendering, .activation, .foreground, .song, .volume, .dopTest,
                                                 .settle, .heartbeat, .shown]
        for (index, occasion) in occasions.enumerated() {
            // Each time, all three have changed behind the app's back.
            let volume = Double(index + 1) / 20, rate = 44_100.0 + Double(index)
            session.volume = volume
            session.route = dac(rate, name: "DAC \(index)", uid: "dac-\(index)")
            let state = watch.refresh(occasion)
            #expect(state.volume == volume && state.route?.sampleRate == rate && state.route?.name == "DAC \(index)", "\(occasion)")
        }
        #expect(session.reads == occasions.count, "one read each: nothing is put together from older ones")
    }

    @Test func whoeverListensIsToldOnceForAReadingThatChangedAndNotForOneThatDidNot() {
        let session = ScriptedSession(route: dac(48_000), volume: 0.3)
        let watch = OutputWatch(session: session)
        var told: [OutputState] = []
        watch.onChange = { told.append($0) }
        watch.refresh(.start)
        watch.refresh(.heartbeat)
        watch.refresh(.heartbeat)
        #expect(told.count == 1)
        // The output and its volume changed together: they arrive together, in one state.
        session.route = dac(96_000)
        session.volume = 1
        watch.refresh(.routeChange)
        #expect(told.count == 2 && told.last?.volume == 1 && told.last?.route?.sampleRate == 96_000)
    }

    @Test func anOutputThatIsGoneHasNoVolume() {
        let session = ScriptedSession(route: dac(48_000), volume: 0.6)
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        session.route = nil
        watch.refresh(.routeChange)
        #expect(watch.state.route == nil && watch.state.volume == nil, "no number is made up for an output iOS doesn't name")
    }

    // MARK: The rate (TestFlight AF7O6K_qZH9VNVho4bluxWo, ADE_mjWBmVQ7T4Kp3R8zh6A)

    @Test func aDACThatSwitchesAMomentAfterItIsAskedIsNeverShownSettledAtItsOldRate() {
        // 48 kHz when the song starts; 44.1 from the fifth look on (400 ms after it was asked).
        let session = ScriptedSession(route: dac(48_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        var looksSinceAsked: Int?
        session.onRateAsk = { _, _ in looksSinceAsked = 0 }
        session.beforeRead = { session, _ in
            guard let looks = looksSinceAsked else { return }
            looksSinceAsked = looks + 1
            if looks + 1 >= 4 { session.route?.sampleRate = 44_100 }
        }
        watch.want(rate: 44_100, channels: 2)
        #expect(session.rateAsks == [44_100])
        #expect(watch.state.route?.sampleRate == 48_000 && watch.state.switchingTo == 44_100)
        for look in 1...3 {
            #expect(watch.tick(playing: true))
            #expect(watch.state.route?.sampleRate == 48_000 && watch.state.switchingTo == 44_100, "look \(look): still on its way, and said so")
        }
        watch.tick(playing: true)
        #expect(watch.state.route?.sampleRate == 44_100 && watch.state.switchingTo == nil && watch.state.pendingRate == nil)
        #expect(session.rateAsks == [44_100], "asked once")
        #expect(!watch.needsTicks)
    }

    @Test func aDACThatNeverSwitchesIsShownAtWhatIOSReportsOnceItHasHadLongEnough() {
        let session = ScriptedSession(route: dac(48_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 44_100, channels: 2)
        for _ in 1..<OutputWatch.patience {
            watch.tick(playing: true)
            #expect(watch.state.switchingTo == 44_100)
        }
        watch.tick(playing: true)
        // Nothing below 44.1 to ask for: 48 kHz is where it runs, and the song is resampled.
        #expect(watch.state.pendingRate == nil && watch.state.switchingTo == nil && watch.state.route?.sampleRate == 48_000)
        #expect(session.rateAsks == [44_100])
    }

    @Test func aDACThatSwitchesLateIsStillSeen() {
        // What build 7 missed: it looked once, 700 ms after asking, and never again.
        let session = ScriptedSession(route: dac(48_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 44_100, channels: 2)
        for _ in 0..<OutputWatch.patience { watch.tick(playing: true) }
        #expect(watch.state.route?.sampleRate == 48_000 && watch.needsTicks, "it goes on looking for a while")
        session.route?.sampleRate = 44_100
        watch.tick(playing: true)
        #expect(watch.state.route?.sampleRate == 44_100)
        // And the looking does end.
        var looks = 0
        while watch.tick(playing: true), looks < 1_000 { looks += 1 }
        #expect(looks <= OutputWatch.linger)
    }

    @Test func aRateIOSChangedWithoutSayingIsSeenAtTheNextLook() {
        let session = ScriptedSession(route: dac(96_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        session.route?.sampleRate = 48_000
        #expect(watch.refresh(.heartbeat).route?.sampleRate == 48_000)
    }

    @Test func aRateIsNotCalledDeclinedBeforeTheSongSounds() {
        // A preferred rate takes effect once the session is active: a paused or loading song proves nothing.
        let session = ScriptedSession(route: dac(48_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 192_000, channels: 2)
        for _ in 0..<(OutputWatch.patience * 3) { watch.tick(playing: false) }
        #expect(session.rateAsks == [192_000] && watch.state.switchingTo == 192_000)
        // Then it plays, and the DAC switches.
        session.route?.sampleRate = 192_000
        watch.tick(playing: true)
        #expect(watch.state.pendingRate == nil && watch.state.route?.sampleRate == 192_000)
    }

    @Test func aDeclinedRateIsFollowedByTheNextOneDownAndTheAskingEnds() {
        // A DAC that tops out at 96 kHz, asked for a 192 kHz song.
        let session = ScriptedSession(route: dac(48_000))
        session.onRateAsk = { session, rate in if rate <= 96_000 { session.route?.sampleRate = rate } }
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 192_000, channels: 2)
        var looks = 0
        while watch.state.pendingRate != nil, looks < 1_000 { watch.tick(playing: true); looks += 1 }
        #expect(session.rateAsks == [192_000, 96_000])
        #expect(watch.state.route?.sampleRate == 96_000 && watch.state.switchingTo == nil)
        #expect(looks <= OutputWatch.patience + 1)
    }

    @Test func aSongThatNeverPlaysStopsTheAsking() {
        let session = ScriptedSession(route: dac(48_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 96_000, channels: 2)
        var looks = 0
        while watch.tick(playing: false), looks < 10_000 { looks += 1 }
        #expect(looks < OutputWatch.waitForSong + 1 && watch.state.pendingRate == nil)
        // The same song again asks afresh.
        watch.want(rate: 96_000, channels: 2)
        #expect(session.rateAsks == [96_000, 96_000])
    }

    @Test func anotherOutputIsNotHeldToWhatTheOldOneWasAsked() {
        let session = ScriptedSession(route: dac(48_000))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 44_100, channels: 2)
        #expect(watch.state.pendingRate == 44_100)
        // Unplugged: the speaker is never asked for a rate, and nothing is pending on it.
        session.route = speaker
        watch.refresh(.routeChange)
        #expect(watch.state.pendingRate == nil && session.rateAsks == [44_100])
        // Another DAC: asked for the song's rate in its own right.
        session.route = dac(48_000, name: "Fosi Audio ZD3", uid: "zd3")
        watch.refresh(.routeChange)
        #expect(session.rateAsks == [44_100, 44_100] && watch.state.switchingTo == 44_100)
    }

    @Test func theSameSongIsNotAskedForTwiceAndTheNextSongIs() {
        let session = ScriptedSession(route: dac(48_000))
        session.onRateAsk = { session, rate in session.route?.sampleRate = rate }
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 96_000, channels: 2)
        watch.want(rate: 96_000, channels: 2)
        watch.tick(playing: true)
        #expect(session.rateAsks == [96_000] && watch.state.route?.sampleRate == 96_000)
        watch.want(rate: 44_100, channels: 2)
        #expect(session.rateAsks == [96_000, 44_100])
        watch.tick(playing: true)
        #expect(watch.state.route?.sampleRate == 44_100 && watch.state.pendingRate == nil)
    }

    @Test func aDoPCarrierRateIsShownAsOnItsWayUntilItIsThereOrGivenUp() {
        let session = ScriptedSession(route: dac(44_100))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.bring(to: 176_400)
        #expect(session.rateAsks == [176_400] && watch.state.switchingTo == 176_400)
        watch.giveUp()
        #expect(watch.state.pendingRate == nil && watch.state.route?.sampleRate == 44_100)
        // Already there: nothing to ask.
        session.route?.sampleRate = 176_400
        watch.refresh(.settle)
        watch.bring(to: 176_400)
        #expect(session.rateAsks == [176_400])
    }

    @Test func aSurroundSongAsksAnInterfaceForItsChannelsOnce() {
        let session = ScriptedSession(route: dac(48_000, name: "Interface", uid: "if", channels: 2, most: 6))
        let watch = OutputWatch(session: session)
        watch.refresh(.start)
        watch.want(rate: 48_000, channels: 6)
        watch.refresh(.heartbeat)
        #expect(session.channelAsks == [6] && session.rateAsks.isEmpty)
    }

    @Test func everyReadAndEveryAskIsLogged() {
        let session = ScriptedSession(route: dac(48_000), volume: 0.3)
        let watch = OutputWatch(session: session)
        var lines: [String] = []
        watch.log = { lines.append($0) }
        watch.refresh(.start)
        watch.want(rate: 44_100, channels: 2)
        watch.tick(playing: true)
        #expect(lines.count == 3)
        #expect(lines[0].contains("start") && lines[0].contains("FiiO K11") && lines[0].contains("rate=48000") && lines[0].contains("volume=0.300"))
        #expect(lines[1] == "ask: 44.1 kHz")
        #expect(lines[2].contains("settle") && lines[2].contains("asked=44100"))
    }

    // MARK: What is said about it

    private func flac(_ rate: Double, bits: Int = 24) -> StreamDescriptor {
        StreamDescriptor(stream: 1, kind: .original, byteSize: 10,
                         format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: rate, bitDepth: bits, channels: 2, channelLabels: nil, lossless: true),
                         frames: 10, tag: "t", chunkSize: 1)
    }

    @Test func aSongOnAnOutputThatIsStillSwitchingIsNeitherResampledNorUntouched() {
        let state = OutputState(route: dac(48_000), volume: 1, pendingRate: 44_100)
        let signal = PhoneSignal(stream: flac(44_100), output: state)
        #expect(signal.switchingTo == 44_100)
        #expect(!signal.resampled, "iOS hasn't answered yet: nothing is known to be resampled")
        #expect(!signal.untouched, "and nothing is known to be untouched either")
        // Settled where it was: resampled, and said.
        let stuck = PhoneSignal(stream: flac(44_100), output: OutputState(route: dac(48_000), volume: 1))
        #expect(stuck.switchingTo == nil && stuck.resampled && !stuck.untouched)
        // Settled at the song's rate.
        let there = PhoneSignal(stream: flac(44_100), output: OutputState(route: dac(44_100), volume: 1))
        #expect(there.switchingTo == nil && !there.resampled && there.untouched)
    }

    @Test func theK11At96WithTheVolumeDownIsTheSongsRateAndNotUntouched() {
        // Nick Drake, "One of These Things First", FLAC 24/96 on the K11 with the volume at 30%: the case that worked.
        let signal = PhoneSignal(stream: flac(96_000), output: OutputState(route: dac(96_000), volume: 0.3))
        #expect(signal.outputRate == 96_000 && !signal.resampled && signal.switchingTo == nil)
        #expect(signal.volume == 0.3 && signal.volumeReduced && signal.onDAC)
        #expect(!signal.untouched && !signal.verifiedOnDAC, "at 30% the DAC is not getting the song's own samples")
        // The same song with the volume at the top (the screenshot a minute later).
        let top = PhoneSignal(stream: flac(96_000), output: OutputState(route: dac(96_000), volume: 1))
        #expect(top.untouched && !top.volumeReduced)
    }

    @Test func anUnknownVolumeNeverCountsAsTheTop() {
        let signal = PhoneSignal(stream: flac(96_000), output: OutputState(route: dac(96_000), volume: nil))
        #expect(signal.volume == nil && !signal.volumeReduced && !signal.untouched)
    }
}

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import VespertineRemoteClient

/// A Mac that sends every song as a short made sound, and counts what it was asked for.
private final class CountingMac: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [Int: Data] = [:]
    private var next = 0
    private var _opens: [Int64] = []
    var opens: [Int64] { lock.withLock { _opens } }

    var client: PhoneStreamClient {
        PhoneStreamClient(open: { [self] song, _ in
            let data = DemoSound.wave(song: song, seconds: 4)
            return lock.withLock {
                _opens.append(song)
                next += 1
                streams[next] = data
                return .streamOpened(StreamDescriptor(stream: next, kind: .original, byteSize: Int64(data.count),
                                                      format: StreamFormat(codec: "WAV", container: "wav", sampleRate: Double(DemoSound.sampleRate), bitDepth: 16,
                                                                           channels: 2, channelLabels: nil, lossless: true),
                                                      frames: Int64((data.count - 44) / 4), tag: "\(song)", chunkSize: RemoteProtocol.defaultChunkSize))
            }
        }, read: { [self] stream, offset, length in
            guard let data = lock.withLock({ streams[stream] }), offset >= 0, offset <= Int64(data.count) else { throw RemoteLinkError.closed }
            let end = min(Int(offset) + max(0, length), data.count)
            return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: end >= data.count, payload: data.subdata(in: Int(offset)..<end))
        }, close: { [self] stream in lock.withLock { streams[stream] = nil } }, isConnected: { true })
    }
}

@Suite(.serialized) @MainActor struct OutputStateOnThePhoneTests {
    private let k11 = PhoneRoute(name: "FiiO K11", portType: "USBAudio", sampleRate: Double(DemoSound.sampleRate), channels: 2, spatial: false, uid: "k11")

    private func made(_ mac: CountingMac) throws -> PhoneRemote {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(DemoSound.sampleRate), channels: 2,
                                                                             interleaved: false)!, maximumFrameCount: 4096)
        let playback = PhonePlayback(client: mac.client, player: PhonePlayer(engine: engine),
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("output-state-\(UUID())"))
        return PhoneRemote(playback: playback, library: { _ in .failed(reason: "") })
    }

    /// Counted, not timed (see PhoneRemoteTests).
    private func until(_ condition: () -> Bool) async throws {
        var looks = 0
        while !condition(), looks < 500 { looks += 1; try await Task.sleep(for: .milliseconds(10)) }
    }

    private func song(_ id: Int64) -> TrackSummary {
        TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 4, trackNumber: Int(id), discNumber: 1,
                     format: "WAV · 16/44.1", artworkKey: nil, favorite: false)
    }

    @Test func theRouteTheVolumeAndTheRenderingAreOneStateOnThePhone() throws {
        let remote = try made(CountingMac())
        remote.output = OutputState(route: k11, volume: 0.3, rendering: .monoStereo)
        #expect(remote.route == k11 && remote.outputVolume == 0.3 && remote.systemRendering == .monoStereo)
        // The names the screens already read still write through to it.
        remote.outputVolume = 1
        #expect(remote.output.volume == 1 && remote.output.route == k11)
    }

    @Test func aVolumeChangeNeitherRestartsNorReopensNorPausesAPCMSong() async throws {
        // TestFlight AA0UDi09-2p4lRKsNesXlK8: "it was glitchy" while the volume moved, on the K11.
        let mac = CountingMac()
        let remote = try made(mac)
        remote.output = OutputState(route: k11, volume: 1)
        remote.playback.play([song(1)])
        try await until { remote.playback.player.state == .playing }
        let opensBefore = mac.opens, streamBefore = remote.playback.stream?.stream
        for level in [0.9, 0.5, 0.3, 0.0, 0.3, 0.6, 1.0, 0.95, 1.0] {
            remote.output = OutputState(route: k11, volume: level)
            #expect(remote.playback.player.state == .playing, "at \(level)")
            #expect(remote.playback.stream != nil, "at \(level)")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(mac.opens == opensBefore, "the song was not asked for again")
        #expect(remote.playback.stream?.stream == streamBefore, "and what plays is the stream that was playing")
        #expect(remote.playback.isPlaying && remote.playback.notice == nil)
        remote.playback.stop()
    }

    @Test func theSignalSaysTheVolumeAndTheRateOfTheSameReading() async throws {
        let mac = CountingMac()
        let remote = try made(mac)
        remote.output = OutputState(route: k11, volume: 0.3)
        remote.playback.play([song(1)])
        try await until { remote.signal != nil }
        #expect(remote.signal?.volume == 0.3 && remote.signal?.volumeReduced == true && remote.signal?.untouched == false)
        remote.output = OutputState(route: k11, volume: 1)
        #expect(remote.signal?.volume == 1 && remote.signal?.untouched == true)
        var other = k11
        other.sampleRate = 48_000
        remote.output = OutputState(route: other, volume: 1, pendingRate: Double(DemoSound.sampleRate))
        #expect(remote.signal?.switchingTo == Double(DemoSound.sampleRate) && remote.signal?.untouched == false && remote.signal?.resampled == false)
        #expect(remote.playerState.volume.level == 1)
        remote.playback.stop()
    }
}
#endif
