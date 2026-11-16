//
// Vespertine: the DoP test on the phone. Plays the test sound (`DoPProbeClip`) to the DAC as DoP at 176.4 kHz and asks what
// you heard. A DAC can only play the chord if every frame reached it exactly as sent, so "music" is the proof that this
// phone, this cable and this DAC carry DoP; nothing is assumed from the DAC's name. Nothing is saved unless the sound
// really went out at the carrier rate, to the same DAC, with the volume at its top, from start to end.
//
// A DAC that passed then hears the same chord at 192, 352.8 and 384 kHz, with the same question each time, and each
// rate's result is kept for it (`DoPDACs.results`): the rates at which frames were shown to reach it as sent.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if os(iOS)
import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
public final class DoPProbe {
    public enum Failure: Equatable, Sendable {
        /// The output isn't a DAC the test can run on.
        case notADAC
        /// The volume isn't at its top.
        case volume
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
        /// The sound has been heard: music or hiss?
        case asking
        case answered(DoPDACs.Answer)
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
        guard DoPGate.canTest(remote.route), let route = remote.route, let uid = route.uid else { phase = .failed(.notADAC); return }
        guard (remote.outputVolume ?? 0) >= DoPGate.fullVolume else { phase = .failed(.volume); return }
        remote.playback.stop()
        remote.playback.player.rest()
        plan = DoPTestRun(uid: uid, name: route.name)
        start()
    }

    /// Plays the chord at the rate the run has reached.
    private func start() {
        guard let next = plan?.carrier else { return }
        carrier = next
        phase = .preparing
        task = Task { [weak self] in await self?.play() }
    }

    /// The answer to "music or hiss?" for the rate just heard: kept for this DAC. After music at the first rate the
    /// chord is played at the next one.
    public func answer(_ answer: DoPDACs.Answer) {
        guard phase == .asking else { return }
        finish(answer == .music ? .passed : .hiss)
    }

    /// Keeps how the rate went and plays the next, or ends the run: with the first rate's answer when it wasn't music,
    /// with music once every rate has been played.
    private func finish(_ result: DoPDACs.CarrierResult) {
        guard var run = plan else { return }
        let first = run.isFirst
        var dacs = remote.dopDACs
        let more = run.finish(result, into: &dacs)
        remote.dopDACs = dacs
        plan = run
        if more {
            start()
        } else {
            plan = nil
            phase = .answered(first && result != .passed ? .hiss : .music)
        }
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

    /// The output is still the DAC under test, with two channels and the volume at its top.
    private func sameOutput() -> Bool {
        guard let plan, let now = PhoneAudioSession.currentRoute() else { return false }
        return now.uid == plan.uid && now.outputChannels == 2
            && Double(AVAudioSession.sharedInstance().outputVolume) >= DoPGate.fullVolume
    }

    /// The output is still the DAC under test, at the carrier rate, with the volume at its top.
    private func intact() -> Bool {
        guard sameOutput(), let now = PhoneAudioSession.currentRoute() else { return false }
        return abs(now.sampleRate - carrier) < 0.5
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
        node.play()
        await withCheckedContinuation { (heard: CheckedContinuation<Void, Never>) in
            // Called when the last of it has left the output, or when the node is stopped.
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in heard.resume() }
        }
        if Task.isCancelled { return }
        let held = intact()
        silence()
        phase = held ? .asking : .failed(.changed)
    }
}
#endif
