//
// Vespertine: when a song on a network share starts playing: after a small prefix is on disk, or only once the whole file is.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// How much of a song on a share must be local before the output starts.
///
/// The cache used to copy the entire file first, so a 24-bit/96 kHz FLAC or a WAV from a NAS waited for its whole size at the
/// link's speed before the first note (the "Buffering from the network… 59%" of a slow start). A song that a decoder can read
/// through the cache's guarded input source (`NetworkPlaybackCache.Entry.inputSource`) starts instead on a prefix, and the copy
/// carries on ahead of the playhead; the output's buffer and its rebuffering cover a link that turns out too slow.
enum NetworkStart {
    /// Containers whose header and first audio are at the front of the file, so a prefix is all the decoder asks for at first.
    /// Others (MP4/ALAC keep their index at the end, MP3 and APE may scan the whole file) still copy whole.
    static let earlyExtensions: Set<String> = ["flac", "wav", "aif", "aiff"]

    /// Smaller files copy whole: the wait is short and nothing is gained by streaming them.
    static let smallestEarlyFile: Int64 = 12 << 20

    /// What is waited for before the decoder is opened: the headers (metadata blocks, seek tables) and the first seconds.
    static let prefix: Int64 = 4 << 20

    /// The fewest bytes kept on disk ahead of the playhead when the output starts.
    static let smallestLead: Int64 = 2 << 20

    /// The copy's measured speed is trusted to this fraction: a link that does 10 MB/s is planned on as doing 7.7.
    static let trust = 1 / 1.3

    /// Whether `size` bytes of a `fileExtension` file are played from a prefix rather than copied whole first.
    /// A CUE track (a region of a bigger file) always copies whole: its share of the file is not its length.
    static func startsEarly(fileExtension: String, size: Int64, isRegion: Bool) -> Bool {
        !isRegion && size >= smallestEarlyFile && earlyExtensions.contains(fileExtension.lowercased())
    }

    /// The bytes that must be on disk beyond `position` before the output starts, so the rest of the file arrives before the
    /// playhead reaches it: `smallestLead` when the copy is faster than the song plays, more the slower it is, all of it when it has all but stopped.
    /// - `duration`: the song's length in seconds. `copied`/`elapsed`: what the copy has done so far, and how long it took.
    static func lead(fileSize: Int64, position: Int64, duration: TimeInterval, copied: Int64, elapsed: TimeInterval) -> Int64 {
        let remaining = max(0, fileSize - position)
        guard duration > 0, elapsed > 0, copied > 0 else { return remaining }
        let rate = Double(copied) / elapsed * trust
        // Local before the start: the file less what the copy can fetch while the song plays.
        let needed = Double(fileSize) - rate * duration
        let lead = Int64(max(0, needed)) - position
        return min(remaining, max(smallestLead, lead))
    }
}
