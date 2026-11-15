//
// Vespertine: Dolby Atmos (Dolby Digital Plus with Joint Object Coding).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// macOS decodes Dolby Digital Plus to its 5.1/7.1 channel bed for any app, but renders the Atmos
// objects only inside its own playback path (as Apple Music does). Vespertine recognizes Atmos streams
// so it can hand them to that renderer, or play the bed through its own engine.
//

import AudioToolbox
import Foundation

public enum DolbyAtmos {
    public static let codecName = "Dolby Atmos"
    /// Core Audio's format ID for Dolby Digital Plus carrying Atmos objects (JOC).
    static let jocFormatID: AudioFormatID = 0x6563_2B33   // 'ec+3'

    /// Whether this Dolby Digital Plus file carries Atmos objects: Core Audio then lists `ec+3`
    /// renderings (5.1.2 up to 9.1.6) among the file's formats.
    public static func hasObjects(_ url: URL) -> Bool {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return false }
        defer { AudioFileClose(file) }
        var size: UInt32 = 0
        guard AudioFileGetPropertyInfo(file, kAudioFilePropertyFormatList, &size, nil) == noErr, size > 0 else { return false }
        var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(size) / MemoryLayout<AudioFormatListItem>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyFormatList, &size, &items) == noErr else { return false }
        return items.contains { $0.mASBD.mFormatID == jocFormatID }
    }

    /// "9.1.6", "7.1.4", …
    public static func layoutName(_ tag: AudioChannelLayoutTag) -> String {
        switch tag {
        case kAudioChannelLayoutTag_Atmos_9_1_6: "9.1.6"
        case kAudioChannelLayoutTag_Atmos_7_1_4: "7.1.4"
        case kAudioChannelLayoutTag_Atmos_7_1_2: "7.1.2"
        case kAudioChannelLayoutTag_Atmos_5_1_4: "5.1.4"
        case kAudioChannelLayoutTag_Atmos_5_1_2: "5.1.2"
        default: ChannelLayouts.name(channels: Int(tag & 0xFFFF))
        }
    }

    /// The richest speaker layout Core Audio offers for the file's objects (e.g. 9.1.6), for display.
    public static func maximumLayout(_ url: URL) -> AudioChannelLayoutTag? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var size: UInt32 = 0
        guard AudioFileGetPropertyInfo(file, kAudioFilePropertyFormatList, &size, nil) == noErr, size > 0 else { return nil }
        var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(size) / MemoryLayout<AudioFormatListItem>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyFormatList, &size, &items) == noErr else { return nil }
        return items.filter { $0.mASBD.mFormatID == jocFormatID }.max { $0.mASBD.mChannelsPerFrame < $1.mASBD.mChannelsPerFrame }?.mChannelLayoutTag
    }
}

import AVFoundation
import CoreMedia

/// What macOS is rendering (shown instead of Vespertine's own signal path).
public struct SystemRendering: Sendable, Equatable {
    public var format: String          // "Dolby Atmos"
    public var objectLayout: String?   // "up to 9.1.6"
    public var spatial: Bool           // Spatial Audio allowed for the device
}

/// Plays a Dolby Atmos file through macOS's own renderer, which turns its objects into what the device
/// can play: head-tracked Spatial Audio on AirPods, virtualized height on Mac speakers, the channels of a
/// multichannel device. The Dolby Digital Plus frames go to the renderer untouched.
final class SystemRendererSession: @unchecked Sendable, SystemRenderTap {
    let item: PlayableItem
    let url: URL
    let rendering: SystemRendering
    private(set) var duration: TimeInterval = 0
    /// Internal for tests (they post its route-change flush notice).
    let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    /// One reading of the track from some time on: its reader, the output it is read through, and the queue its feeding
    /// callback runs on. A seek or a flush starts a new one and retires the old one. Each has a queue of its own, so a read of
    /// an old one that is stuck (it can block for as long as the file's source does) holds nothing the new one needs.
    private final class Feeding: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let queue = DispatchQueue(label: "org.szeremeta.vespertine.system-renderer")
        /// The callback is inside `copyNextSampleBuffer`. Under the session's `state`.
        var reading = false
        /// Retired: it reads nothing more. Under the session's `state`.
        var retired = false
        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) { self.reader = reader; self.output = output }
    }
    /// Guards the small state below, and is never held across a read: asking how far the feeding has got (the engine does,
    /// every iteration; so do the tests) or stopping the session must not wait for a read that is stuck.
    private let state = NSLock()
    private let feeds = NSLock()
    private var asset: AVURLAsset
    private var track: AVAssetTrack?
    private var feeding: Feeding?      // under `state`
    private var inputDone = false      // under `state`
    private var enqueuedEnd = CMTime.zero      // under `state`
    /// The first frame's time in the file (some containers don't start at zero).
    private var origin = CMTime.zero
    private var generation = 0      // under `state`
    /// The visualizer's and the meters' view of the bed (see `SystemBedDecoder`); it decodes only while one of them is showing.
    private var meter: BedMeterSource?
    /// Tests: sees each compressed buffer as it goes to the renderer (never changes it).
    var enqueueObserver: (@Sendable (CMSampleBuffer) -> Void)?
    /// The route-change flush notice (`AVSampleBufferAudioRendererWasFlushedAutomatically`) for this session's renderer.
    private var flushObserver: NSObjectProtocol?
    /// `stop()` was called: a late flush notice doesn't start reading again. Under `state`.
    private var stopped = false

    init(item: PlayableItem, url: URL, deviceUID: String?, spatial: Bool, volume: Float) throws {
        self.item = item
        self.url = url
        asset = AVURLAsset(url: url)
        let layout = DolbyAtmos.maximumLayout(url).map(DolbyAtmos.layoutName)
        rendering = SystemRendering(format: DolbyAtmos.codecName, objectLayout: layout, spatial: spatial)
        renderer.audioOutputDeviceUniqueID = deviceUID
        renderer.allowedAudioSpatializationFormats = spatial ? .monoStereoAndMultichannel : []
        renderer.volume = volume
        synchronizer.addRenderer(renderer)
        guard let info = LoadedAudioTrack(asset) else { throw SourceOpenerError.unsupported(url) }
        let track = info.track, total = info.duration, start = info.timeRange.start
        self.track = track
        origin = start
        duration = max(0, CMTimeGetSeconds(total) - max(0, CMTimeGetSeconds(start)))
        meter = BedMeterSource(decoder: SystemBedDecoder(url: url), position: { [weak self] in self?.position ?? 0 })
        // When the output's configuration changes under it (AirPods Max moving between A2DP, call mode and the USB-C cable, a
        // headset reconnecting), macOS throws away what the renderer had queued and says from what time. It is fed again from
        // there; otherwise everything that was queued (about a second of the song) is skipped.
        flushObserver = NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                                               object: renderer, queue: nil) { [weak self] notice in
            let time = (notice.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self?.refillAfterAutomaticFlush(from: time)
        }
    }

    deinit {
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
        stop()
    }

    /// Positions at `seconds` (paused) and starts feeding the renderer.
    func prepare(at seconds: TimeInterval) throws {
        let target = CMTimeAdd(origin, CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 48_000))
        // The renderer is asked for data only after the timebase and the meter are set, as it always was.
        try feed(from: target, flushing: true) {
            self.synchronizer.setRate(0, time: target)
            self.meter?.start(at: seconds)
        }
    }

    /// macOS flushed the renderer on a route change: feed it again from `time` (where it flushed from), playing on. No time
    /// given: from where playback is.
    private func refillAfterAutomaticFlush(from time: CMTime?) {
        state.lock(); let stopped = stopped; state.unlock()
        guard !stopped else { return }
        let from = time.flatMap { $0.isValid && $0.isNumeric ? $0 : nil } ?? synchronizer.currentTime()
        let start = CMTimeMaximum(origin, from)
        log.notice("macOS flushed the Atmos renderer (the output changed); feeding it again from \(CMTimeGetSeconds(CMTimeSubtract(start, self.origin)), privacy: .public) s")
        do { try feed(from: start, flushing: false) } catch {
            log.error("Couldn't feed the Atmos renderer again after a flush: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts reading the track at `target` and handing it to the renderer, replacing any reading under way. `flushing`: the
    /// renderer's queue is emptied first (a seek); after macOS's own flush it already is, and flushing again would reset its time.
    /// `beforeFeeding` runs once the new reader is going, before the renderer is asked for data.
    private func feed(from target: CMTime, flushing: Bool, beforeFeeding: () -> Void = {}) throws {
        // One seek or flush at a time (the engine's thread and the flush notice's can both be here). Never held by a read.
        feeds.lock(); defer { feeds.unlock() }
        state.lock(); generation += 1; stopped = false; let gen = generation; let old = feeding; feeding = nil; state.unlock()
        renderer.stopRequestingMediaData()
        retire(old)
        // Nothing of the old reading is queued from here on (a buffer is queued under `state`, by the current reading only).
        if flushing { renderer.flush() }
        state.lock(); inputDone = false; enqueuedEnd = target; state.unlock()
        guard let track else { throw SourceOpenerError.unsupported(url) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: target, duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)   // compressed: the renderer decodes
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SourceOpenerError.unsupported(url) }
        let feeding = Feeding(reader: reader, output: output)
        state.lock()
        // A stop or another seek came meanwhile: this reading is not the one any more.
        guard gen == generation else { state.unlock(); reader.cancelReading(); return }
        self.feeding = feeding
        state.unlock()
        beforeFeeding()
        state.lock(); defer { state.unlock() }
        guard !feeding.retired else { return }
        renderer.requestMediaDataWhenReady(on: feeding.queue) { [weak self] in
            guard let self else { return }
            while self.renderer.isReadyForMoreMediaData {
                guard self.beginRead(feeding) else { return }
                let buffer = feeding.output.copyNextSampleBuffer()
                guard self.endRead(feeding) else { return }
                guard let buffer else {
                    // Under `state`, so a seek that starts the next reading meanwhile is not the one told to stop asking.
                    self.state.lock()
                    if !feeding.retired {
                        self.inputDone = true
                        self.renderer.stopRequestingMediaData()
                    }
                    self.state.unlock()
                    return
                }
                self.enqueueObserver?(buffer)
                // Queued under `state`, and only by the reading that is current: a seek's flush never has an old buffer after it.
                self.state.lock()
                guard !feeding.retired else { self.state.unlock(); return }
                self.renderer.enqueue(buffer)
                let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
                if end.isValid { self.enqueuedEnd = CMTimeMaximum(self.enqueuedEnd, end) }
                self.state.unlock()
            }
        }
    }

    /// The callback is about to read: false when its reading was retired meanwhile (it then reads nothing).
    private func beginRead(_ feeding: Feeding) -> Bool {
        state.lock(); defer { state.unlock() }
        guard !feeding.retired else { return false }
        feeding.reading = true
        return true
    }

    /// The read came back: false when its reading was retired while it read. The reader is cancelled here then, on the thread
    /// that was reading, now that it no longer is.
    private func endRead(_ feeding: Feeding) -> Bool {
        state.lock(); feeding.reading = false; let retired = feeding.retired; state.unlock()
        if retired { feeding.reader.cancelReading() }
        return !retired
    }

    /// Ends a reading. Its reader is never cancelled while its callback is inside `copyNextSampleBuffer`: the system's media
    /// framework frees what that read is waiting on, and the read then crashes (EXC_BAD_ACCESS under `FigSemaphoreWaitRelative`,
    /// seen with the tests run side by side). A reading that is mid-read is marked, and cancels itself when the read comes back.
    private func retire(_ feeding: Feeding?) {
        guard let feeding else { return }
        state.lock(); feeding.retired = true; let reading = feeding.reading; state.unlock()
        if !reading { feeding.reader.cancelReading() }
    }

    func play() { synchronizer.rate = 1 }
    func pause() { synchronizer.rate = 0 }
    func setVolume(_ volume: Float) { renderer.volume = volume }

    func stop() {
        state.lock(); generation += 1; stopped = true; let current = feeding; feeding = nil; state.unlock()
        meter?.stop()
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        renderer.flush()
        retire(current)
    }

    // MARK: Visualizer

    func setTapping(_ on: Bool) { meter?.setTapping(on) }
    func setMetering(_ on: Bool) { meter?.setMetering(on) }
    func takeChannelPeaks() -> [Float]? { meter?.takeChannelPeaks() }
    var channelLabels: [AudioChannelLabel]? { meter?.channelLabels }

    func copy(left: inout [Float], right: inout [Float]) -> PlaybackEngine.VisualizerTapRead? {
        meter?.copy(left: &left, right: &right)
    }

    var position: TimeInterval {
        let now = CMTimeGetSeconds(CMTimeSubtract(synchronizer.currentTime(), origin))
        return now.isFinite ? max(0, min(now, duration)) : 0
    }

    /// Everything was read and has been played out.
    var finished: Bool {
        state.lock(); defer { state.unlock() }
        return inputDone && CMTimeCompare(synchronizer.currentTime(), enqueuedEnd) >= 0
    }

    /// Whether every compressed frame has been handed to the renderer (tests).
    var inputExhausted: Bool { state.lock(); defer { state.unlock() }; return inputDone }

    var failure: Error? { renderer.status == .failed ? (renderer.error ?? SourceOpenerError.unsupported(url)) : nil }
}
