//
// Vespertine — the Dolby Digital channel modes macOS's decoder gets wrong, read from the stream's first frame.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// macOS decodes Dolby Digital (Plus) under Dolby's licence and does it right for the usual modes: mono,
// stereo, 3/0, 3/1, 2/2, 3/2, with or without LFE. For 2/1 (L R S), 3/0 + LFE and 3/1 + LFE it
// returns channels in the wrong places, drops the LFE or repeats a channel (SpatialMatrixTests). Only
// those streams are decoded by FFmpeg instead; everything else stays with Apple.
//

import Foundation

public enum DolbyModes {
    /// Audio coding mode (front/rear channel counts) and LFE of a Dolby Digital (Plus) stream.
    public struct Mode: Equatable, Sendable {
        /// 0 = 1+1, 1 = 1/0, 2 = 2/0, 3 = 3/0, 4 = 2/1, 5 = 3/1, 6 = 2/2, 7 = 3/2.
        public var acmod: Int
        public var lfe: Bool
        public var enhanced: Bool
        /// E-AC-3 with dependent substreams (7.1 and up): left to macOS.
        public var extended: Bool
    }

    /// "2/1", "3/0+LFE", …
    public static func name(_ mode: Mode) -> String {
        let base = ["1+1", "1/0", "2/0", "3/0", "2/1", "3/1", "2/2", "3/2"][mode.acmod & 7]
        return mode.lfe ? base + "+LFE" : base
    }

    /// Whether macOS's decoder can't be trusted with this mode.
    public static func needsFFmpeg(_ mode: Mode) -> Bool {
        !mode.extended && (mode.acmod == 4 || (mode.lfe && (mode.acmod == 3 || mode.acmod == 5)))
    }

    /// The mode of the first frame of an elementary .ac3 / .ec3 file (read from its first 64 KB).
    public static func mode(of url: URL) -> Mode? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536) else { return nil }
        return mode(in: [UInt8](data))
    }

    static func mode(in bytes: [UInt8]) -> Mode? {
        var i = 0
        while i + 8 <= bytes.count {
            guard bytes[i] == 0x0B, bytes[i + 1] == 0x77 else { i += 1; continue }
            var bits = BitReader(bytes, byteOffset: i + 2)
            // bsid sits 40 bits after the sync word start in both: AC-3 up to 10, E-AC-3 11–16.
            var peek = BitReader(bytes, byteOffset: i)
            peek.skip(40)
            guard let bsid = peek.read(5), bsid <= 16 else { i += 1; continue }
            if bsid <= 10 {
                bits.skip(16 + 2 + 6)                                   // crc1, fscod, frmsizecod
                bits.skip(5 + 3)                                        // bsid, bsmod
                guard let acmod = bits.read(3) else { return nil }
                if acmod & 1 != 0, acmod != 1 { bits.skip(2) }          // cmixlev
                if acmod & 4 != 0 { bits.skip(2) }                      // surmixlev
                if acmod == 2 { bits.skip(2) }                          // dsurmod
                guard let lfe = bits.read(1) else { return nil }
                return Mode(acmod: acmod, lfe: lfe == 1, enhanced: false, extended: false)
            }
            guard let strmtyp = bits.read(2), strmtyp != 1 else { i += 1; continue }   // start at an independent frame
            bits.skip(3)                                                // substreamid
            guard let frmsiz = bits.read(11) else { return nil }
            bits.skip(2 + 2)                                            // fscod, fscod2 or numblkscod
            guard let acmod = bits.read(3), let lfe = bits.read(1) else { return nil }
            // A dependent substream right after this frame carries more channels (7.1 and up).
            let next = i + (frmsiz + 1) * 2
            var extended = false
            if next + 3 <= bytes.count, bytes[next] == 0x0B, bytes[next + 1] == 0x77 {
                extended = (bytes[next + 2] >> 6) == 1
            }
            return Mode(acmod: acmod, lfe: lfe == 1, enhanced: true, extended: extended)
        }
        return nil
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position: Int
        init(_ bytes: [UInt8], byteOffset: Int) { self.bytes = bytes; position = byteOffset * 8 }
        mutating func skip(_ n: Int) { position += n }
        mutating func read(_ n: Int) -> Int? {
            guard position + n <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<n {
                value = value << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
                position += 1
            }
            return value
        }
    }
}
