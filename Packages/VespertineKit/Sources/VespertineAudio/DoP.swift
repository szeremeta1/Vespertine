//
// Vespertine — DSD over PCM (DoP 1.1, dsd-guide.com): 16 DSD bits per channel per PCM frame behind an 8-bit
// marker that alternates 0x05 / 0xFA, as a 24-bit sample.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// Why DSD can't be packed into DoP frames.
public enum DoPError: Error, Equatable, Sendable {
    /// No channels.
    case noChannels
    /// The channels hold different numbers of bytes.
    case unequalChannels
    /// An odd number of bytes per channel: a DoP frame carries exactly 16 DSD bits, so half a frame can't be sent.
    case oddByteCount(Int)
    /// A marker other than the base method's 0x05 / 0xFA.
    case marker(UInt8)
}

/// DoP packing.
public enum DoP {
    /// DSD silence (the idle pattern 0x69: as many ones as zeros). An odd last byte at the end of a track is padded
    /// with it to make a whole frame: DoP 1.1 doesn't say what to do with half a frame, and padding keeps every
    /// DSD bit of the track and adds at most eight bits of silence (2.8 µs at DSD64).
    public static let silence: UInt8 = 0x69

    /// One DoP sample as a 24-bit word: the marker (0 for 0x05, 1 for 0xFA), then 16 DSD bits, oldest in the MSB.
    @inline(__always) static func word(marker: Int, _ first: UInt8, _ second: UInt8) -> UInt32 {
        let m: UInt32 = marker & 1 == 0 ? 0x05 : 0xFA
        return m << 16 | UInt32(first) << 8 | UInt32(second)
    }

    /// Packs DSD (one plane per channel, MSB the oldest bit) into DoP frames, `frames[n][c]` the 24-bit word of
    /// channel c in frame n, the first frame carrying `firstMarker`. Refuses anything that isn't whole frames.
    public static func pack(_ planes: [[UInt8]], firstMarker: UInt8 = 0x05) throws(DoPError) -> [[UInt32]] {
        guard let count = planes.first?.count else { throw .noChannels }
        guard planes.allSatisfy({ $0.count == count }) else { throw .unequalChannels }
        guard count % 2 == 0 else { throw .oddByteCount(count) }
        guard firstMarker == 0x05 || firstMarker == 0xFA else { throw .marker(firstMarker) }
        let first = firstMarker == 0x05 ? 0 : 1
        return (0..<count / 2).map { i in planes.map { word(marker: first + i, $0[2 * i], $0[2 * i + 1]) } }
    }
}
