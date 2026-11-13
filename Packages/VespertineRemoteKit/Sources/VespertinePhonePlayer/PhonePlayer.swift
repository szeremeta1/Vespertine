//
// Vespertine: the phone's player, stereo first. Plays the file a `StreamDownloader` made through AVAudioEngine: a player node
// into the main mixer at unity, no effects, no EQ, no sample-rate conversion of ours. What iOS then does with the signal
// (its own mixing, a fixed output rate, volume) is iOS's, and the app says so (see the plan's "bit-perfect" note).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// Skeleton: one file at a time, played whole once downloaded; queue, gapless, read-ahead while playing, interruptions, the lock
// screen and the 5.1 / Spatial Audio path (docs/plans/ios-spatial-multichannel.md) are the rest of M3.
//

import AVFAudio
import Foundation
import Observation
import VespertineRemoteProtocol

@MainActor
@Observable
public final class PhonePlayer {
    public enum State: Equatable, Sendable {
        case idle
        /// A file is loaded, at its start or at its end.
        case ready
        case playing
        case paused
    }

    public enum Failure: Error, Equatable {
        /// Not yet: more than two channels needs the Spatial Audio path.
        case multichannelNotYet(Int)
        case cannotOpen(String)
        case engine(String)
    }

    public private(set) var state: State = .idle
    public private(set) var format: StreamFormat?
    public private(set) var duration: Double = 0
    /// Where the song is, in seconds.
    public var position: Double {
        guard let file else { return 0 }
        return Double(currentFrame()) / file.processingFormat.sampleRate
    }
    /// The signal goes from the file to the output through a player node and a mixer at unity gain, with nothing else.
    public private(set) var isUntouchedPath = false

    @ObservationIgnored private let engine: AVAudioEngine
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    /// The file frame the scheduled segment starts at (the node's own clock counts from there).
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    /// Where a paused song is.
    @ObservationIgnored private var heldFrame: AVAudioFramePosition?
    /// Scheduled segments carry a generation, so a seek's old segment finishing doesn't end the new one.
    @ObservationIgnored private var generation = 0

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(node)
    }

    /// Opens `url` (the downloaded stream) for playing.
    public func load(_ url: URL, format: StreamFormat) throws {
        stop()
        guard format.channels <= 2 else { throw Failure.multichannelNotYet(format.channels) }
        let opened: AVAudioFile
        do { opened = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) } catch {
            throw Failure.cannotOpen(error.localizedDescription)
        }
        guard opened.length > 0 else { throw Failure.cannotOpen("The file has no audio.") }
        file = opened
        self.format = format
        duration = Double(opened.length) / opened.processingFormat.sampleRate
        startFrame = 0
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: opened.processingFormat)
        engine.mainMixerNode.outputVolume = 1
        node.volume = 1
        node.pan = 0
        isUntouchedPath = true
        schedule(from: 0)
        state = .ready
    }

    public func play() throws {
        guard file != nil else { return }
        heldFrame = nil
        #if os(iOS)
        do { try PhoneAudioSession.activate() } catch { throw Failure.engine(error.localizedDescription) }
        #endif
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { throw Failure.engine(error.localizedDescription) }
        }
        node.play()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        // A paused node keeps its scheduled audio and its clock: play() carries on from here.
        heldFrame = currentFrame()
        node.pause()
        state = .paused
    }

    public func stop() {
        node.stop()
        generation += 1
        startFrame = 0
        heldFrame = nil
        if file != nil {
            schedule(from: 0)
            state = .ready
        } else {
            state = .idle
        }
    }

    /// Moves to `seconds` and keeps playing if it was.
    public func seek(to seconds: Double) throws {
        guard let file else { return }
        let was = state == .playing
        node.stop()
        generation += 1
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * file.processingFormat.sampleRate)
        startFrame = min(frame, file.length)
        schedule(from: startFrame)
        let wasPaused = state == .paused
        heldFrame = wasPaused ? startFrame : nil
        state = was ? .playing : (wasPaused ? .paused : .ready)
        if was { try play() }
    }

    private func currentFrame() -> AVAudioFramePosition {
        if state == .paused, let heldFrame { return heldFrame }
        guard let file, state == .playing, let time = node.lastRenderTime, let player = node.playerTime(forNodeTime: time) else { return startFrame }
        return min(file.length, startFrame + max(0, player.sampleTime))
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file, frame < file.length else { return }
        let mine = generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == mine, self.state == .playing else { return }
                self.startFrame = 0
                self.heldFrame = nil
                self.state = .ready
                self.schedule(from: 0)
            }
        }
    }
}
