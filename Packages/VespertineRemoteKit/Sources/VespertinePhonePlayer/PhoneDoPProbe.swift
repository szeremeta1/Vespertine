//
// Vespertine: the DoP test on the phone. Plays the test sound (`DoPProbeClip`) to the DAC as DoP at 176.4 kHz and asks what
// you heard. A DAC can only play the chord if every frame reached it exactly as sent, so "music" is the proof that this
// phone, this cable and this DAC carry DoP; nothing is assumed from the DAC's name. Nothing is saved unless the sound
// really went out at the carrier rate, to the same DAC, with iOS's volume where it was, from start to end.
//
// The test asks nothing of the volume: on a DAC whose volume is set on the DAC, iOS's number may be anything and can't
// be moved. The chord heard with that number below the top shows the number changes nothing (kept with the result);
// hiss or noise heard that way shows nothing, since iOS scaling the samples sounds the same, and is not kept. Silence is
// its own answer and is never kept as a failure.
//
// A DAC that passed then hears the same chord at 192, 352.8 and 384 kHz, with the same question each time, and each
// rate's result is kept for it (`DoPDACs.results`): the rates at which frames were shown to reach it as sent.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if os(iOS)
import AVFAudio
import Foundation
import Observation
import os

@MainActor
@Observable
public final class DoPProbe {
    public enum Failure: Equatable, Sendable {
        /// The output isn't a DAC the test can run on.
        case notADAC
        /// The DAC wouldn't run at 176.4 kHz, or the sound couldn't be started there.
        case notAsDoP
        /// The output, its rate or the volume changed while the sound played.
        case changed
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Getting the DAC to the carrier rate and making the sound.
        case preparing
        case playing
        /// The sound has been heard: what was it?
        case asking
        case answered(DoPTestRun.Ending)
        case failed(Failure)
    }

    public private(set) var phase: Phase = .idle
    /// The carrier rate being played or asked about.
    public private(set) var carrier = DoPDACs.testCarrier
    private var plan: DoPTestRun?
    private let remote: PhoneRemote
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var task: Task<Void, Never>?

    public init(remote: PhoneRemote) { self.remote = remote }

    public var isBusy: Bool { phase == .preparing || phase == .playing }

    /// Stops the music (the test needs the output to itself) and plays the test sound.
    public func run() {
        guard !isBusy else { return }
        // Read now, not remembered: the volume shown may be from before the DAC was plugged in.
        let now = outputNow()
        guard DoPGate.canTest(now.route), let route = now.route, let uid = route.uid else { phase = .failed(.notADAC); return }
        remote.playback.stop()
        remote.playback.player.rest()
        plan = DoPTestRun(uid: uid, name: route.name, volume: now.volume)
        note("run on \(route.name) uid=\(uid) volume=\(now.volume.map { String($0) } ?? "unreported") moved=\(now.volumeMoved)")
        start()
    }

    /// Plays the chord at the rate the run has reached.
    private func start() {
        guard let next = plan?.carrier else { return }
        carrier = next
        phase = .preparing
        task = Task { [weak self] in await self?.play() }
    }

    /// What was heard at the rate just played. Music and (when nothing else can be to blame) hiss are kept for this DAC;
    /// "nothing" plays the rate once more and is never kept as a failure; "again" only plays it again.
    public func answer(_ heard: DoPTestRun.Heard) {
        guard phase == .asking, var run = plan else { return }
        var dacs = remote.dopDACs
        let step = run.heard(heard, into: &dacs)
        note("answer \(heard.rawValue) at \(carrier): \(step)")
        advance(run, dacs, step)
    }

    private func advance(_ run: DoPTestRun, _ dacs: DoPDACs, _ step: DoPTestRun.Step) {
        if dacs != remote.dopDACs { remote.dopDACs = dacs }
        plan = run
        switch step {
        case .replay, .next:
            start()
        case .ended(let ending):
            plan = nil
            phase = .answered(ending)
        }
    }

    /// The rate being played went a way nobody has to be asked about (the DAC declined it).
    private func finish(_ result: DoPDACs.CarrierResult) {
        guard var run = plan else { return }
        var dacs = remote.dopDACs
        let more = run.finish(result, into: &dacs)
        advance(run, dacs, more ? .next : .ended(.on))
    }

    /// Stops the sound. What was answered for the rates already heard stays.
    public func cancel() {
        task?.cancel()
        task = nil
        plan = nil
        silence()
        phase = .idle
    }

    private func silence() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }

    /// The output as iOS reports it this instant: read the one way everything else reads it (`OutputWatch`), so the
    /// screens show what the test saw.
    private func outputNow() -> OutputState { remote.readOutput?(.dopTest) ?? remote.output }

    /// The output is still the DAC under test, with two channels and iOS's volume where it was when the run began.
    private func sameOutput(_ now: OutputState) -> Bool { plan?.holds(on: now) ?? false }

    private func sameOutput() -> Bool { sameOutput(outputNow()) }

    /// The output is still the DAC under test, at the carrier rate, with the volume where it was.
    private func intact() -> Bool {
        let now = outputNow()
        guard sameOutput(now), let route = now.route else { return false }
        return abs(route.sampleRate - carrier) < 0.5
    }

    /// The chord couldn't be sent at this rate. At the first rate that ends the test with nothing saved. At a later one
    /// it is that rate's result (the DAC declined it) as long as the DAC and the volume are as they were, and the next
    /// rate follows.
    private func declined() {
        guard let plan, !plan.isFirst else { phase = .failed(.notAsDoP); return }
        guard sameOutput() else { phase = .failed(.changed); return }
        finish(.declined)
    }

    private func play() async {
        let carrier = carrier
        let session = AVAudioSession.sharedInstance()
        try? PhoneAudioSession.activate()
        try? session.setPreferredSampleRate(carrier)
        var waited = 0
        while !intact(), waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            waited += 1
        }
        guard intact() else { declined(); return }
        let words = await Task.detached(priority: .userInitiated) { DoPProbeClip.frames(carrier: carrier) }.value
        if Task.isCancelled { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: carrier, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(words.count)),
              let planes = buffer.floatChannelData else { phase = .failed(.notAsDoP); return }
        for (index, word) in words.enumerated() {
            let sample = DoPProbeClip.sample(word)
            planes[0][index] = sample
            planes[1][index] = sample
        }
        buffer.frameLength = AVAudioFrameCount(words.count)
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        node.volume = 1
        do { try engine.start() } catch { declined(); return }
        // The engine must be feeding the DAC at the carrier rate itself, or iOS is converting on the way.
        guard intact(), abs(engine.outputNode.outputFormat(forBus: 0).sampleRate - carrier) < 0.5 else {
            engine.stop()
            declined()
            return
        }
        self.engine = engine
        self.node = node
        phase = .playing
        let began = ContinuousClock.now
        node.play()
        await withCheckedContinuation { (heard: CheckedContinuation<Void, Never>) in
            // Called when the last of it has left the output, or when the node is stopped.
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in heard.resume() }
        }
        if Task.isCancelled { return }
        let held = intact()
        note("played \(words.count) frames at \(carrier) (lead-in \(DoPProbeClip.leadFrames(carrier: carrier))) in \(ContinuousClock.now - began), intact=\(held)")
        silence()
        phase = held ? .asking : .failed(.changed)
        // The engine has stopped: what the output does now is read once more.
        _ = outputNow()
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "org.szeremeta.VespertineRemote", category: "dop-test")
    #endif

    /// Debug builds write each step of the test to the system log, to compare with what the DAC's display showed.
    private func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        let text = line()
        Self.logger.debug("\(text, privacy: .public)")
        #endif
    }
}
#endif
