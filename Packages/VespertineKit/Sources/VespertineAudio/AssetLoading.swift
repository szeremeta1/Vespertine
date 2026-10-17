//
// Vespertine — what an audio file's AVAsset says about its first audio track, loaded without the concurrency pool.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreMedia

/// The first audio track of an asset, with what playback needs to know about it.
struct LoadedAudioTrack: @unchecked Sendable {
    var track: AVAssetTrack
    var duration: CMTime
    /// Where the track sits in the asset (some containers don't start at zero).
    var timeRange: CMTimeRange
    var format: CMFormatDescription?

    /// Loads it with AVFoundation's completion handlers, which run on AVFoundation's own queues, and waits on the
    /// calling thread. The async `load` needs a thread of Swift's concurrency pool to finish, so a caller that blocks
    /// on it from a pool thread (any test, or anything called from a task) can wait forever once every pool thread is
    /// doing the same. Nil when the asset has no audio track.
    init?(_ asset: AVAsset) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var first: AVAssetTrack?
        asset.loadTracks(withMediaType: .audio) { tracks, _ in first = tracks?.first; done.signal() }
        done.wait()
        guard let track = first else { return nil }
        asset.loadValuesAsynchronously(forKeys: ["duration"]) { done.signal() }
        done.wait()
        track.loadValuesAsynchronously(forKeys: ["timeRange", "formatDescriptions"]) { done.signal() }
        done.wait()
        self.track = track
        duration = asset.duration
        timeRange = track.timeRange
        format = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
    }
}
