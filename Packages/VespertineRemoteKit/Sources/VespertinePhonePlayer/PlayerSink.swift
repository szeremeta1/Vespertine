//
// Vespertine: where the player's decoded audio goes. Two kinds:
//
// - `NodeSink`: an AVAudioPlayerNode in the app's AVAudioEngine (stereo, mono, surround folded to stereo, and surround to an
//   interface with an output per channel). On AirPods and other Bluetooth headphones iOS runs the engine's output with two
//   channels, so whatever the engine plays reaches the system as stereo.
// - `RendererSink`: an AVSampleBufferAudioRenderer. Surround handed to it keeps all its channels and its channel layout all
//   the way into iOS, which is what lets iOS's own Spatial Audio render it on AirPods and Beats (Control Center then shows
//   Spatial Audio, with its own Fixed and Head Tracked choice) as it does for Apple Music. WWDC21 "Immerse your app in
//   Spatial Audio": a sample buffer renderer playing audio only spatializes multichannel content by default.
//
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio) && canImport(AVFoundation)
import AVFAudio
import AVFoundation
import CoreMedia
import Foundation

/// What the pump hands its audio to. Every buffer is played after the one before it, on one clock that starts at zero
/// with `play()` after a `stop()`.
protocol PlayerSink: AnyObject, Sendable {
    /// Queues `buffer` after everything queued before; `played` is called once it has been heard (or right away, never,
    /// after a `stop()`: callers tell stale calls apart themselves).
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void)
    func play()
    func pause()
    /// Drops everything queued; the clock starts again from zero at the next `play()`.
    func stop()
    /// Frames sounded since the clock last started, or nil while it hasn't.
    func rendered() -> Int64?
}

/// The engine's player node.
final class NodeSink: PlayerSink, @unchecked Sendable {
    let node: AVAudioPlayerNode
    private let completion: AVAudioPlayerNodeCompletionCallbackType

    init(node: AVAudioPlayerNode, completion: AVAudioPlayerNodeCompletionCallbackType) {
        self.node = node
        self.completion = completion
    }

    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        node.scheduleBuffer(buffer, completionCallbackType: completion) { _ in played() }
    }

    func play() { node.play() }
    func pause() { node.pause() }
    func stop() { node.stop() }

    func rendered() -> Int64? {
        guard let time = node.lastRenderTime, time.isSampleTimeValid, let player = node.playerTime(forNodeTime: time) else { return nil }
        return max(0, player.sampleTime)
    }
}

/// The audio that has been queued and not yet heard, by where it ends on the clock: what tells the pump to decode more.
struct PlayedLedger: Sendable {
    private var waiting: [(end: Int64, played: @Sendable () -> Void)] = []
    /// Where the next buffer starts on the clock.
    private(set) var end: Int64 = 0

    /// Queues `frames` frames; returns the frame the run starts at. A clock already past the end (the listener heard
    /// silence while this was on its way) starts it `lead` frames after where the clock is now, as a player node would
    /// start it at once.
    mutating func add(frames: Int64, now: Int64?, lead: Int64, played: @escaping @Sendable () -> Void) -> Int64 {
        if let now, now + lead > end { end = now + lead }
        let start = end
        end += frames
        waiting.append((end, played))
        return start
    }

    /// The calls for everything heard by `now`, in order; they are forgotten here.
    mutating func heard(by now: Int64) -> [@Sendable () -> Void] {
        var done: [@Sendable () -> Void] = []
        while let first = waiting.first, first.end <= now {
            done.append(first.played)
            waiting.removeFirst()
        }
        return done
    }

    var isEmpty: Bool { waiting.isEmpty }

    mutating func clear() {
        waiting = []
        end = 0
    }
}

enum SampleBuffers {
    /// A buffer's audio as one Core Media sample buffer: 32-bit float, the channels interleaved in the buffer's own order,
    /// with its channel layout (what tells iOS which speaker each channel is), at frame `start` of a clock at the buffer's rate.
    static func make(_ buffer: AVAudioPCMBuffer, start: Int64) -> CMSampleBuffer? {
        let format = buffer.format
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0, format.commonFormat == .pcmFormatFloat32, let planes = buffer.floatChannelData else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let layout = format.channelLayout
        let made: OSStatus = if let layout {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                                           layoutSize: Self.layoutSize(layout.layout), layout: layout.layout,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        } else {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        }
        guard made == noErr, let formatDescription else { return nil }

        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let out = UnsafeMutableRawPointer(pointer).bindMemory(to: Float.self, capacity: frames * channels)
        if format.isInterleaved {
            out.update(from: planes[0], count: frames * channels)
        } else {
            for channel in 0..<channels {
                let plane = planes[channel]
                var index = channel
                for frame in 0..<frames {
                    out[index] = plane[frame]
                    index += channels
                }
            }
        }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(format.sampleRate.rounded())), packetDescriptions: nil,
            sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    /// The size of a layout with its channel descriptions.
    static func layoutSize(_ layout: UnsafePointer<AudioChannelLayout>) -> Int {
        let descriptions = Int(layout.pointee.mNumberChannelDescriptions)
        return MemoryLayout<AudioChannelLayout>.size + max(0, descriptions - 1) * MemoryLayout<AudioChannelDescription>.size
    }
}

/// iOS's sample buffer renderer, with a synchronizer for its clock. Audio queued here is presented, channels and layout as
/// they are, to the system, which spatializes multichannel content on headphones that have Spatial Audio on.
final class RendererSink: PlayerSink, @unchecked Sendable {
    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    /// iOS emptied the renderer by itself (the output changed under it): the player queues again from where it is.
    var onFlushed: (@Sendable () -> Void)?
    /// The renderer failed (iOS couldn't play what it was given).
    var onFailed: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var ledger = PlayedLedger()
    private var rate: Double = 0
    private var started = false
    private var running = false
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.phone-renderer", qos: .userInitiated)

    /// `muted`: nothing is heard (the package's tests on a Mac must never make a sound).
    init(muted: Bool = false) {
        renderer.isMuted = muted
        if #available(iOS 15.0, macOS 12.0, *) {
            // Audio-only sample buffer renderers spatialize multichannel by default; said here so nobody wonders.
            renderer.allowedAudioSpatializationFormats = .multichannel
        }
        synchronizer.addRenderer(renderer)
        observers.append(NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
                                                                queue: nil) { [weak self] _ in self?.onFlushed?() })
        observers.append(NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
                                                                object: renderer, queue: nil) { _ in })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.cancel()
        synchronizer.rate = 0
        renderer.flush()
    }

    /// How far ahead of the clock audio that arrives after a starve is placed, in seconds: enough for it to be presented.
    static let lead = 0.1

    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        let now = rendered()
        let start: Int64 = lock.withLock {
            rate = buffer.format.sampleRate
            return ledger.add(frames: Int64(buffer.frameLength), now: started ? now : nil, lead: Int64(Self.lead * rate), played: played)
        }
        guard let sample = SampleBuffers.make(buffer, start: start) else { return }
        renderer.enqueue(sample)
        if renderer.status == .failed, let error = renderer.error { onFailed?(error) }
    }

    func play() {
        let first: Bool = lock.withLock {
            defer { started = true; running = true }
            return !started
        }
        if first {
            synchronizer.setRate(1, time: .zero)
        } else {
            synchronizer.rate = 1
        }
        startTimer()
    }

    func pause() {
        lock.withLock { running = false }
        synchronizer.rate = 0
    }

    func stop() {
        synchronizer.rate = 0
        renderer.flush()
        lock.withLock {
            ledger.clear()
            started = false
            running = false
        }
    }

    func rendered() -> Int64? {
        let (began, rate) = lock.withLock { (started, self.rate) }
        guard began, rate > 0 else { return nil }
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        guard seconds.isFinite else { return nil }
        return max(0, Int64(seconds * rate))
    }

    /// What iOS's renderer reports, for the readback.
    var status: AVQueuedSampleBufferRenderingStatus { renderer.status }
    var error: Error? { renderer.error }

    private func startTimer() {
        lock.withLock {
            guard timer == nil else { return }
            let made = DispatchSource.makeTimerSource(queue: queue)
            made.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            made.setEventHandler { [weak self] in self?.check() }
            timer = made
            made.resume()
        }
    }

    /// Tells the pump about every buffer heard by now.
    private func check() {
        guard let now = rendered() else { return }
        let done = lock.withLock { ledger.heard(by: now) }
        for call in done { call() }
        if renderer.status == .failed, let error = renderer.error { onFailed?(error) }
    }
}
#endif
