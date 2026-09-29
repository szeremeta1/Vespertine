//
// Vespertine — Dolby Atmos (Dolby Digital Plus with Joint Object Coding).
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
final class SystemRendererSession: @unchecked Sendable {
    let item: PlayableItem
    let url: URL
    let rendering: SystemRendering
    private(set) var duration: TimeInterval = 0
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.system-renderer")
    private let lock = NSLock()
    private var asset: AVURLAsset
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var inputDone = false
    private var enqueuedEnd = CMTime.zero
    /// The first frame's time in the file (some containers don't start at zero).
    private var origin = CMTime.zero
    private var generation = 0

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
        let loaded = Self.wait { [asset] in
            let track = try await asset.loadTracks(withMediaType: .audio).first
            let duration = try await asset.load(.duration)
            let range = try await track?.load(.timeRange)
            return Loaded(track: track, duration: duration, start: range?.start ?? .zero)
        }
        let info = try loaded.get()
        guard let track = info.track else { throw SourceOpenerError.unsupported(url) }
        let total = info.duration, start = info.start
        self.track = track
        origin = start
        duration = max(0, CMTimeGetSeconds(total) - max(0, CMTimeGetSeconds(start)))
    }

    deinit { stop() }

    /// Positions at `seconds` (paused) and starts feeding the renderer.
    func prepare(at seconds: TimeInterval) throws {
        lock.lock()
        generation += 1
        let gen = generation
        renderer.stopRequestingMediaData()
        renderer.flush()
        reader?.cancelReading()
        inputDone = false
        let target = CMTimeAdd(origin, CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 48_000))
        guard let track else { lock.unlock(); throw SourceOpenerError.unsupported(url) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: target, duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)   // compressed: the renderer decodes
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { lock.unlock(); throw reader.error ?? SourceOpenerError.unsupported(url) }
        self.reader = reader
        enqueuedEnd = target
        lock.unlock()
        synchronizer.setRate(0, time: target)
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard gen == self.generation else { return }
            while self.renderer.isReadyForMoreMediaData {
                guard let buffer = output.copyNextSampleBuffer() else {
                    self.inputDone = true
                    self.renderer.stopRequestingMediaData()
                    return
                }
                self.renderer.enqueue(buffer)
                let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
                if end.isValid { self.enqueuedEnd = CMTimeMaximum(self.enqueuedEnd, end) }
            }
        }
    }

    func play() { synchronizer.rate = 1 }
    func pause() { synchronizer.rate = 0 }
    func setVolume(_ volume: Float) { renderer.volume = volume }

    func stop() {
        lock.lock(); generation += 1; lock.unlock()
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        renderer.flush()
        reader?.cancelReading()
    }

    var position: TimeInterval {
        let now = CMTimeGetSeconds(CMTimeSubtract(synchronizer.currentTime(), origin))
        return now.isFinite ? max(0, min(now, duration)) : 0
    }

    /// Everything was read and has been played out.
    var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return inputDone && CMTimeCompare(synchronizer.currentTime(), enqueuedEnd) >= 0
    }

    var failure: Error? { renderer.status == .failed ? (renderer.error ?? SourceOpenerError.unsupported(url)) : nil }

    private struct Loaded: @unchecked Sendable { var track: AVAssetTrack?; var duration: CMTime; var start: CMTime }

    /// Runs async AVFoundation loading from a plain thread (the engine thread isn't in the concurrency pool).
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error> = .failure(CancellationError())
        Task.detached { result = await Result { try await work() }; done.signal() }
        done.wait()
        return result
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
