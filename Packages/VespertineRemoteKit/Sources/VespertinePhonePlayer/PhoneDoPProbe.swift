//
// Vespertine: the DoP test on the phone. Plays the test sound (`DoPProbeClip`) to the DAC as DoP at 176.4 kHz and asks what
// you heard. A DAC can only play the chord if every frame reached it exactly as sent, so "music" is the proof that this
// phone, this cable and this DAC carry DoP; nothing is assumed from the DAC's name. Nothing is saved unless the sound
// really went out at the carrier rate, to the same DAC, with the volume at its top, from start to end.
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
        /// The DAC wouldn't run at 176.4 kHz, or the sound couldn't be started.
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
    private let remote: PhoneRemote
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var task: Task<Void, Never>?
    private var tested: (uid: String, name: String)?

    public init(remote: PhoneRemote) { self.remote = remote }

    public var isBusy: Bool { phase == .preparing || phase == .playing }

    /// Stops the music (the test needs the output to itself) and plays the test sound.
    public func run() {
        guard !isBusy else { return }
        guard DoPGate.canTest(remote.route), let route = remote.route, let uid = route.uid else { phase = .failed(.notADAC); return }
        guard (remote.outputVolume ?? 0) >= DoPGate.fullVolume else { phase = .failed(.volume); return }
        remote.playback.stop()
        remote.playback.player.rest()
        tested = (uid, route.name)
        phase = .preparing
        task = Task { [weak self] in await self?.play() }
    }

    /// The answer to "music or hiss?": kept for this DAC.
    public func answer(_ answer: DoPDACs.Answer) {
        guard phase == .asking, let tested else { return }
        remote.dopDACs.record(answer, uid: tested.uid, name: tested.name)
        phase = .answered(answer)
    }

    /// Stops the sound and saves nothing.
    public func cancel() {
        task?.cancel()
        task = nil
        silence()
        phase = .idle
    }

    private func silence() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }

    /// The output is still the DAC under test, at the carrier rate, with the volume at its top.
    private func intact() -> Bool {
        guard let tested, let now = PhoneAudioSession.currentRoute() else { return false }
        return now.uid == tested.uid && now.outputChannels == 2 && abs(now.sampleRate - DoPProbeClip.carrierRate) < 0.5
            && Double(AVAudioSession.sharedInstance().outputVolume) >= DoPGate.fullVolume
    }

    private func play() async {
        let session = AVAudioSession.sharedInstance()
        try? PhoneAudioSession.activate()
        try? session.setPreferredSampleRate(DoPProbeClip.carrierRate)
        var waited = 0
        while !intact(), waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            waited += 1
        }
        guard intact() else { phase = .failed(.notAsDoP); return }
        let words = await Task.detached(priority: .userInitiated) { DoPProbeClip.frames() }.value
        if Task.isCancelled { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: DoPProbeClip.carrierRate, channels: 2),
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
        do { try engine.start() } catch { phase = .failed(.notAsDoP); return }
        // The engine must be feeding the DAC at the carrier rate itself, or iOS is converting on the way.
        guard intact(), abs(engine.outputNode.outputFormat(forBus: 0).sampleRate - DoPProbeClip.carrierRate) < 0.5 else {
            engine.stop()
            phase = .failed(.notAsDoP)
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
