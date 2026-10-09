//
// Vespertine — synthetic SACD images for tests: a Master TOC, area TOCs (track lists, text, ISRCs), and audio
// sectors of plain DSD or DST, the DST made by a small encoder below. All of it is generated; no disc audio.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum SACDFixture {
    public static let frameBytes = 4704          // DSD64: bytes per channel per 1/75 s frame
    public static let rate = 2_822_400.0

    /// Tones through a 2nd-order sigma-delta modulator, one per channel at its own frequency (so channels can't be
    /// mistaken for each other), as 1-bit streams per channel (MSB = earliest bit), `frames` SACD frames long.
    public static func modulate(channels: Int, frames: Int, seed: Double = 0) -> [[UInt8]] {
        let bits = frames * frameBytes * 8
        var out = [[UInt8]](repeating: [UInt8](repeating: 0, count: bits / 8), count: channels)
        for c in 0..<channels {
            var i1 = 0.0, i2 = 0.0
            let f = 300.0 * Double(c + 1) + seed
            for n in 0..<bits {
                let x = 0.4 * sin(2 * .pi * f * Double(n) / rate)
                let v = i2 >= 0 ? 1.0 : -1.0
                i1 += x - v
                i2 += i1 - 2 * v
                if v > 0 { out[c][n / 8] |= UInt8(0x80 >> (n % 8)) }
            }
        }
        return out
    }

    public struct TrackSpec: Sendable {
        public var title: String
        public var performer: String?
        public var composer: String?
        public var isrc: String?
        public var frames: Int
        /// Frames of the area after this track's duration that belong to no track (a pause before the next).
        public var pauseAfter: Int
        public init(title: String, performer: String? = nil, composer: String? = nil, isrc: String? = nil, frames: Int, pauseAfter: Int = 0) {
            self.title = title; self.performer = performer; self.composer = composer; self.isrc = isrc
            self.frames = frames; self.pauseAfter = pauseAfter
        }
    }

    public struct AreaSpec: Sendable {
        public var channels: Int
        public var dst: Bool
        /// One DSD plane per channel, covering the whole area (every track and pause), from time code `firstFrame`.
        public var planes: [[UInt8]]
        public var tracks: [TrackSpec]
        /// The time code of the area's first frame (the first track starts here).
        public var firstFrame: Int
        /// DST areas: store these frames uncompressed (DST's own "not compressed" frames).
        public var uncompressedFrames: Set<Int>
        public init(channels: Int, dst: Bool, planes: [[UInt8]], tracks: [TrackSpec], firstFrame: Int = 0, uncompressedFrames: Set<Int> = []) {
            self.channels = channels; self.dst = dst; self.planes = planes; self.tracks = tracks
            self.firstFrame = firstFrame; self.uncompressedFrames = uncompressedFrames
        }
    }

    public struct Disc: Sendable {
        public var albumTitle = "Night Studies"
        public var albumArtist = "The Vesper Quartet"
        public var publisher = "Fixture Records"
        public var copyright = "(P) 2003 Fixture Records"
        public var catalog = "FXR-1001"
        public var genre: UInt8 = 14                // Jazz
        public var year = 2003, month = 3, day = 1
        /// ISO 8859-1, so titles can carry accents.
        public var charset: UInt8 = 2
        public init() {}
    }

    /// Writes an SACD image: the stereo area first, then the multichannel one, if given.
    public static func write(to url: URL, disc: Disc = Disc(), stereo: AreaSpec, multichannel: AreaSpec? = nil) throws {
        var image = [UInt8](repeating: 0, count: 600 * 2048)
        func put(_ bytes: [UInt8], at sector: Int, offset: Int = 0) {
            let o = sector * 2048 + offset
            if image.count < o + bytes.count { image += [UInt8](repeating: 0, count: (o + bytes.count - image.count + 2047) / 2048 * 2048) }
            image.replaceSubrange(o..<o + bytes.count, with: bytes)
        }
        let tocSize = 6
        var areas: [(toc: Int, size: Int)] = []
        var next = 540
        for (index, spec) in [stereo, multichannel].compactMap({ $0 }).enumerated() {
            let toc = next
            let audioStart = toc + tocSize + 4
            let (sectors, trackSectors) = audioSectors(spec)
            for (i, s) in sectors.enumerated() { put(s, at: audioStart + i) }
            let audioEnd = audioStart + sectors.count - 1
            for (i, s) in areaTOC(spec, multichannel: index == 1, disc: disc, size: tocSize, audio: audioStart...audioEnd,
                                  trackSectors: trackSectors.map { (audioStart + $0.start, $0.length) }).enumerated() { put(s, at: toc + i) }
            areas.append((toc, tocSize))
            next = audioEnd + 20
        }
        put(masterTOC(disc, areas: areas), at: 510)
        put(masterText(disc), at: 511)
        try Data(image).write(to: url)
    }

    // MARK: TOC sectors

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func timecode(_ t: Int) -> [UInt8] { [UInt8(t / 4500), UInt8(t / 75 % 60), UInt8(t % 75)] }
    static func text(_ s: String, _ charset: UInt8) -> [UInt8] {
        Array(s.data(using: charset == 2 ? .isoLatin1 : .ascii, allowLossyConversion: true)!)
    }
    static func padded(_ s: String, _ n: Int) -> [UInt8] { Array((Array(s.utf8) + [UInt8](repeating: 0x20, count: n)).prefix(n)) }

    static func sector(_ fill: (inout [UInt8]) -> Void) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 2048)
        fill(&s)
        return s
    }

    static func masterTOC(_ disc: Disc, areas: [(toc: Int, size: Int)]) -> [UInt8] {
        sector { s in
            func at(_ o: Int, _ b: [UInt8]) { s.replaceSubrange(o..<o + b.count, with: b) }
            at(0, Array("SACDMTOC".utf8)); at(8, [1, 20])
            at(16, be16(1)); at(18, be16(1))
            at(24, padded(disc.catalog, 16))
            at(40, [1, 0, 0, disc.genre])
            if let a = areas.first { at(64, be32(a.toc)); at(68, be32(0)); at(84, be16(a.size)) }
            if areas.count > 1 { at(72, be32(areas[1].toc)); at(76, be32(0)); at(86, be16(areas[1].size)) }
            at(88, padded(disc.catalog, 16))
            at(104, [1, 0, 0, disc.genre])
            at(120, be16(disc.year)); at(122, [UInt8(disc.month), UInt8(disc.day)])
            at(128, [1])
            at(136, Array("en".utf8) + [disc.charset, 0])
        }
    }

    static func masterText(_ disc: Disc) -> [UInt8] {
        sector { s in
            func at(_ o: Int, _ b: [UInt8]) { s.replaceSubrange(o..<o + b.count, with: b) }
            at(0, Array("SACDText".utf8))
            var p = 48
            for (field, value) in [(0, disc.albumTitle), (1, disc.albumArtist), (2, disc.publisher), (3, disc.copyright),
                                   (8, disc.albumTitle), (9, disc.albumArtist)] {
                at(16 + 2 * field, be16(p))
                let bytes = text(value, disc.charset) + [0]
                at(p, bytes)
                p += (bytes.count + 3) / 4 * 4
            }
        }
    }

    static func areaTOC(_ spec: AreaSpec, multichannel: Bool, disc: Disc, size: Int, audio: ClosedRange<Int>,
                        trackSectors: [(start: Int, length: Int)]) -> [[UInt8]] {
        let count = spec.tracks.count
        var starts: [Int] = [], t = spec.firstFrame
        for track in spec.tracks { starts.append(t); t += track.frames + track.pauseAfter }
        let toc = sector { s in
            func at(_ o: Int, _ b: [UInt8]) { s.replaceSubrange(o..<o + b.count, with: b) }
            at(0, Array((multichannel ? "MULCHTOC" : "TWOCHTOC").utf8)); at(8, [1, 20]); at(10, be16(size))
            at(16, be32(spec.channels * 4704 * 75))
            at(20, [4, spec.dst ? 0 : 2])
            at(32, [UInt8(spec.channels), UInt8(spec.channels == 6 ? 4 << 3 : spec.channels == 5 ? 3 << 3 : 0), UInt8(spec.channels)])
            at(64, timecode(t - spec.firstFrame))
            at(69, [UInt8(count)])
            at(72, be32(audio.lowerBound)); at(76, be32(audio.upperBound))
            at(80, [1]); at(88, Array("en".utf8) + [disc.charset, 0])
            let copyright = text(disc.copyright, disc.charset) + [0]
            at(146, be16(152)); at(152, copyright)
        }
        let trl1 = sector { s in
            func at(_ o: Int, _ b: [UInt8]) { s.replaceSubrange(o..<o + b.count, with: b) }
            at(0, Array("SACDTRL1".utf8))
            for (i, ts) in trackSectors.enumerated() { at(8 + 4 * i, be32(ts.start)); at(8 + 1020 + 4 * i, be32(ts.length)) }
        }
        let trl2 = sector { s in
            func at(_ o: Int, _ b: [UInt8]) { s.replaceSubrange(o..<o + b.count, with: b) }
            at(0, Array("SACDTRL2".utf8))
            for (i, track) in spec.tracks.enumerated() { at(8 + 4 * i, timecode(starts[i]) + [0]); at(8 + 1020 + 4 * i, timecode(track.frames) + [0]) }
        }
        let ttxt = sector { s in
            func at(_ o: Int, _ b: [UInt8]) { s.replaceSubrange(o..<o + b.count, with: b) }
            at(0, Array("SACDTTxt".utf8))
            var p = (8 + 2 * count + 3) / 4 * 4
            for (i, track) in spec.tracks.enumerated() {
                at(8 + 2 * i, be16(p))
                let items = [(UInt8(1), track.title), (2, track.performer), (4, track.composer)].compactMap { k, v in v.map { (k, $0) } }
                at(p, [UInt8(items.count), 0, 0, 0]); p += 4
                for (kind, value) in items {
                    let bytes = [kind, 0x20] + text(value, disc.charset) + [0]
                    at(p, bytes)
                    p += (bytes.count + 3) / 4 * 4
                }
            }
        }
        var igl = [UInt8](repeating: 0, count: 4096)
        igl.replaceSubrange(0..<8, with: Array("SACD_IGL".utf8))
        for (i, track) in spec.tracks.enumerated() {
            if let isrc = track.isrc { igl.replaceSubrange(8 + 12 * i..<8 + 12 * i + 12, with: padded(isrc, 12)) }
            igl.replaceSubrange(8 + 3060 + 4 + 4 * i..<8 + 3060 + 8 + 4 * i, with: [1, 0, 0, i == 0 ? 23 : 0])   // the first track is Rock
        }
        return [toc, trl1, trl2, ttxt, Array(igl[0..<2048]), Array(igl[2048...])]
    }

    // MARK: Audio sectors

    /// The area's frames packed into audio sectors, with each track's first sector and sector count (SACDTRL1).
    static func audioSectors(_ spec: AreaSpec) -> (sectors: [[UInt8]], tracks: [(start: Int, length: Int)]) {
        let total = spec.planes[0].count / frameBytes
        let encoder = DSTEncoder(planes: spec.planes)
        let frames: [[UInt8]] = (0..<total).map { f in
            var inter = [UInt8](repeating: 0, count: frameBytes * spec.channels)
            for i in 0..<frameBytes { for c in 0..<spec.channels { inter[i * spec.channels + c] = spec.planes[c][f * frameBytes + i] } }
            guard spec.dst else { return inter }
            // As a real encoder does, a frame that wouldn't shrink is stored uncompressed.
            let coded = encoder.encode(inter, variant: f)
            return spec.uncompressedFrames.contains(f) || coded.count >= inter.count ? DSTEncoder.uncompressed(inter) : coded
        }
        struct Packet { var frame: Int; var start: Bool; var bytes: ArraySlice<UInt8>; var padding: Bool }
        var layout: [[Packet]] = []
        var f = 0, offset = 0
        var frameSector: [Int: Int] = [:]
        while f < frames.count {
            var packets: [Packet] = []
            var used = 1
            // Every third sector opens with a padding packet, which a reader must skip.
            if layout.count % 3 == 1 { packets.append(Packet(frame: -1, start: false, bytes: ArraySlice(repeating: 0xEE, count: 16), padding: true)); used += 18 }
            while f < frames.count, packets.count < 7 {
                let start = offset == 0
                let overhead = 2 + (start ? (spec.dst ? 4 : 3) : 0)
                let room = 2048 - used - overhead
                guard room > 0 else { break }
                let n = min(room, frames[f].count - offset, 2045)
                if start { frameSector[f] = layout.count }
                packets.append(Packet(frame: f, start: start, bytes: frames[f][offset..<offset + n], padding: false))
                used += overhead + n
                offset += n
                if offset == frames[f].count { f += 1; offset = 0 }
            }
            layout.append(packets)
        }
        var packetCount: [Int: Int] = [:]
        for packets in layout { for p in packets where !p.padding { packetCount[p.frame, default: 0] += 1 } }
        let channelBits: UInt8 = spec.channels == 6 ? 0b10 : spec.channels == 5 ? 0b01 : 0
        let sectors = layout.map { packets -> [UInt8] in
            let starts = packets.filter(\.start)
            var s: [UInt8] = [UInt8(packets.count << 5 | starts.count << 2 | (spec.dst ? 1 : 0))]
            for p in packets { s += [UInt8((p.start ? 0x80 : 0) | (p.padding ? 7 : 2) << 3 | p.bytes.count >> 8), UInt8(p.bytes.count & 0xFF)] }
            for p in starts {
                s += timecode(spec.firstFrame + p.frame)
                if spec.dst { s.append(UInt8(packetCount[p.frame]! << 2) | channelBits) }
            }
            for p in packets { s += p.bytes }
            return s + [UInt8](repeating: 0, count: 2048 - s.count)
        }
        var trackSectors: [(Int, Int)] = []
        var t = 0
        for track in spec.tracks {
            let first = frameSector[t] ?? 0
            let endFrame = t + track.frames + track.pauseAfter
            let last = endFrame < total ? (frameSector[endFrame] ?? layout.count) : layout.count
            trackSectors.append((first, max(1, last - first)))
            t = endFrame
        }
        return (sectors, trackSectors)
    }
}

/// A DST encoder (ISO/IEC 14496-3, subpart 10), the mirror image of Vespertine's decoder: prediction filters and
/// probability tables, sent both plain and Rice-coded, and the arithmetic coder. It aims at exercising every part
/// of the decoder, not at compressing well.
public struct DSTEncoder {
    let channels: Int
    /// Which filter (and probability table) each channel uses: its own, except the last two channels share one.
    let map: [Int]
    /// Per filter: prediction coefficients (9-bit), the one for the bit before first.
    let filters: [[Int]]
    let samples = SACDFixture.frameBytes * 8

    /// An encoder with filters trained on the start of each channel's stream.
    public init(planes: [[UInt8]]) {
        let count = planes.count
        let map = (0..<count).map { count > 2 && $0 == count - 1 ? $0 - 1 : $0 }
        channels = count
        self.map = map
        filters = (0...(map.max() ?? 0)).map { e in Self.train(planes[map.firstIndex(of: e)!], taps: 24) }
    }

    /// A prediction filter for a 1-bit stream: the least-squares fit of each bit (±1) to the `taps` before it, over
    /// the stream's first 16 384 bits, scaled to 9-bit coefficients.
    public static func train(_ plane: [UInt8], taps: Int) -> [Int] {
        let n = min(plane.count * 8, 16_384)
        let s = (0..<n).map { plane[$0 / 8] >> UInt8(7 - $0 % 8) & 1 == 1 ? 1.0 : -1.0 }
        var r = [[Double]](repeating: [Double](repeating: 0, count: taps + 1), count: taps)
        for i in taps..<n {
            for a in 0..<taps {
                let x = s[i - 1 - a]
                r[a][taps] += s[i] * x
                for b in a..<taps { r[a][b] += x * s[i - 1 - b] }
            }
        }
        for a in 0..<taps { r[a][a] += 1; for b in 0..<a { r[a][b] = r[b][a] } }
        // Gaussian elimination on the normal equations.
        for col in 0..<taps {
            let pivot = (col..<taps).max { abs(r[$0][col]) < abs(r[$1][col]) }!
            r.swapAt(col, pivot)
            for row in 0..<taps where row != col {
                let f = r[row][col] / r[col][col]
                for k in col...taps { r[row][k] -= f * r[col][k] }
            }
        }
        let w = (0..<taps).map { r[$0][taps] / r[$0][$0] }
        let scale = 255 / max(w.map(abs).max() ?? 1, 1e-9)
        return w.map { Int(($0 * scale).rounded()) }
    }

    /// "Not compressed": a zero bit, seven more, then the DSD as it is.
    public static func uncompressed(_ dsd: [UInt8]) -> [UInt8] { [0] + dsd }

    struct BitWriter {
        var bytes: [UInt8] = []
        var count = 0
        mutating func bit(_ b: Int) {
            if count % 8 == 0 { bytes.append(0) }
            if b & 1 != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(count % 8) }
            count += 1
        }
        mutating func put(_ v: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bit(v >> i & 1) } }
    }

    /// The arithmetic coder the decoder's `ac_get` undoes, with carries propagated into the bits already written.
    struct ArithmeticEncoder {
        var a = 4095
        var low = 0
        var bits: [UInt8] = []
        mutating func encode(_ e: Int, probability p: Int) {
            let k = (a >> 8) | ((a >> 7) & 1)
            let q = k * p
            if e == 1 { a -= q } else { low += a - q; a = q }
            if low >= 4096 {
                var i = bits.count - 1
                while bits[i] == 1 { bits[i] = 0; i -= 1 }
                bits[i] = 1
                low -= 4096
            }
            while a < 2048 { a <<= 1; bits.append(UInt8(low >> 11 & 1)); low = (low << 1) & 4095 }
        }
        mutating func finish() { for _ in 0..<12 { bits.append(UInt8(low >> 11 & 1)); low = (low << 1) & 4095 } }
    }

    static let fsetsPrediction: [[Int]] = [[-8], [-16, 8], [-9, -5, 6]]
    static let probsPrediction: [[Int]] = [[-8], [-16, 8], [-24, 24, -8]]

    /// A table entry Rice-coded with prediction `method` (0, 1, 2): the first method + 1 values plain, the rest
    /// as the difference from their prediction.
    static func writeCoded(_ w: inout BitWriter, _ values: [Int], method: Int, bits: Int, signed: Bool, offset: Int, prediction: [[Int]]) {
        w.bit(1)
        w.put(method, 2)
        for v in values.prefix(method + 1) { w.put((v - offset) & ((1 << bits) - 1), bits) }
        let k = 2
        w.put(k, 3)
        for j in (method + 1)..<values.count {
            var x = 0
            for i in 0...method { x += prediction[method][i] * values[j - i - 1] }
            let g = values[j] + (x >= 0 ? (x + 4) / 8 : -((-x + 3) / 8))
            let a = abs(g)
            for _ in 0..<(a >> k) { w.bit(0) }
            w.bit(1)
            w.put(a & ((1 << k) - 1), k)
            if a != 0 { w.bit(g < 0 ? 1 : 0) }
        }
    }

    /// Encodes one frame of DSD (interleaved by channel). `variant` varies the filters, tables and their coding.
    public func encode(_ dsd: [UInt8], variant: Int) -> [UInt8] {
        let elements = filters.count
        let filters = self.filters.map { Array($0.prefix($0.count - variant % 4)) }
        let probabilities: [[Int]] = (0..<elements).map { e in
            (0..<(24 + e)).map { j in max(1, min(128, 120 - j * (4 + e) + variant % 7)) }
        }
        let halfProbability = (0..<channels).map { ($0 + variant) % 3 == 0 }

        var w = BitWriter()
        w.bit(1)                                    // DST coded
        w.put(0b111, 3)                             // one segment, the same for every channel
        w.bit(1)                                    // the same map for filters and probabilities
        if elements == 1 { w.bit(1) } else {
            w.bit(0)
            var seen = 1
            for ch in 1..<channels {
                let bits = (Int.bitWidth - 1 - seen.leadingZeroBitCount) + 1
                w.put(map[ch], bits)
                if map[ch] == seen { seen += 1 }
            }
        }
        for h in halfProbability { w.bit(h ? 1 : 0) }
        for (e, f) in filters.enumerated() {
            w.put(f.count - 1, 7)
            if (e + variant) % 2 == 0 { w.bit(0); for c in f { w.put(c & 0x1FF, 9) } }
            else { Self.writeCoded(&w, f, method: (e + variant) % 3, bits: 9, signed: true, offset: 0, prediction: Self.fsetsPrediction) }
        }
        for (e, p) in probabilities.enumerated() {
            w.put(p.count - 1, 6)
            if (e + variant) % 2 == 1 { w.bit(0); for c in p { w.put(c - 1, 7) } }
            else { Self.writeCoded(&w, p, method: (e + variant + 1) % 3, bits: 7, signed: false, offset: 1, prediction: Self.probsPrediction) }
        }
        w.bit(0)

        // Prediction tables, as the decoder builds them (only the bytes of history a filter reaches are summed: the
        // rest of its table is zeros). Flat, so the loop below stays quick in debug builds.
        let used = filters.map { ($0.count + 7) / 8 }
        var table = [Int](repeating: 0, count: filters.count * 16 * 256)
        for (e, f) in filters.enumerated() {
            for j in 0..<used[e] {
                let total = min(8, f.count - j * 8)
                for k in 0..<256 { table[(e * 16 + j) * 256 + k] = (0..<total).reduce(0) { $0 + ((k >> $1) & 1 == 1 ? 1 : -1) * f[j * 8 + $1] } }
            }
        }
        var ac = ArithmeticEncoder()
        let first = filters[0][0] & 127
        var reversed = 0
        for i in 0..<8 where first & (1 << i) != 0 { reversed |= 0x80 >> i }
        ac.encode(0, probability: (reversed >> 1) + 1)
        var status = [UInt64](repeating: 0xAAAA_AAAA_AAAA_AAAA, count: channels * 2)
        table.withUnsafeBufferPointer { table in
            for i in 0..<samples {
                for ch in 0..<channels {
                    let e = map[ch]
                    var sum = 0
                    for j in 0..<used[e] { sum += table[(e * 16 + j) * 256 + Int(status[2 * ch + j / 8] >> UInt64(8 * (j % 8)) & 0xFF)] }
                    let predict = Int(Int16(truncatingIfNeeded: sum))
                    let p = !halfProbability[ch] || i >= filters[e].count
                        ? probabilities[e][min(abs(predict) >> 3, probabilities[e].count - 1)] : 128
                    let v = Int(dsd[(i >> 3) * channels + ch] >> UInt8(7 - i & 7)) & 1
                    ac.encode(v ^ ((predict >> 15) & 1), probability: p)
                    status[2 * ch + 1] = status[2 * ch + 1] << 1 | status[2 * ch] >> 63
                    status[2 * ch] = status[2 * ch] << 1 | UInt64(v)
                }
            }
        }
        ac.finish()
        for b in ac.bits { w.bit(Int(b)) }
        return w.bytes
    }
}

public enum DSDIFFFixture {
    private static func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

    /// A DSDIFF file of any channel count (SACD order: L R C LFE Ls Rs).
    public static func write(_ planes: [[UInt8]], rate: Double = SACDFixture.rate, to url: URL) throws {
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be(UInt64(body.count)) + body + (body.count % 2 == 1 ? [0] : []) }
        var inter = [UInt8](repeating: 0, count: planes[0].count * planes.count)
        for i in 0..<planes[0].count { for c in 0..<planes.count { inter[i * planes.count + c] = planes[c][i] } }
        let ids = planes.count == 2 ? ["SLFT", "SRGT"] : Array(["MLFT", "MRGT", "C   ", "LFE ", "LS  ", "RS  "].prefix(planes.count))
        let name = Array("not compressed".utf8)
        let prop = Array("SND ".utf8) + chunk("FS  ", be(UInt32(rate))) + chunk("CHNL", be(UInt16(planes.count)) + ids.flatMap { Array($0.utf8) })
            + chunk("CMPR", Array("DSD ".utf8) + [UInt8(name.count)] + name + [0])
        let body = Array("DSD ".utf8) + chunk("FVER", be(UInt32(0x0105_0000))) + chunk("PROP", prop) + chunk("DSD ", inter)
        try Data(Array("FRM8".utf8) + be(UInt64(body.count)) + body).write(to: url)
    }
}
