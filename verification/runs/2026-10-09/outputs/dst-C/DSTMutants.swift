//
// Mutants of the DST frame decoding contract (contracts/dst-decode.md), role C.
//
// Each mutant decorates a correct DSTDecoderMaker: it lets the correct decoder decode every frame it is given and then
// gets the result wrong in one deliberate way. Rules only ever look at what the contract exposes (the channel count,
// the frame bytes, the correct result and the calls made on the same decoder); none of them assume anything about the
// DST frame format. Every rule is total: it never traps or loops, whatever the frame or the result.
//

import Contracts
import SpecKit

// MARK: - Plumbing

/// What a mutant decoder remembers between calls (the state its bug lives in).
struct MutantState {
    /// The channel count the decoder was made for.
    let channels: Int
    /// 0 on the first decode on this decoder, 1 on the second, and so on.
    var call: Int = 0
    /// Results of earlier decodes on this decoder, keyed by frame (kept small).
    var cache: [[UInt8]: [UInt8]] = [:]

    init(channels: Int) { self.channels = channels }
}

/// Turns the correct result of decoding `frame` into the mutant's result.
typealias MutantRule = @Sendable (_ state: inout MutantState, _ frame: [UInt8], _ correct: [UInt8]?) -> [UInt8]?

struct MutantMaker: DSTDecoderMaker {
    let base: any DSTDecoderMaker
    let rule: MutantRule

    func makeDecoder(channels: Int) -> any DSTFrameDecoder {
        MutantDecoder(inner: base.makeDecoder(channels: channels), channels: channels, rule: rule)
    }
}

final class MutantDecoder: DSTFrameDecoder {
    private let inner: any DSTFrameDecoder
    private let rule: MutantRule
    private var state: MutantState

    init(inner: any DSTFrameDecoder, channels: Int, rule: @escaping MutantRule) {
        self.inner = inner
        self.rule = rule
        self.state = MutantState(channels: channels)
    }

    func decode(frame: [UInt8]) -> [UInt8]? {
        let correct = inner.decode(frame: frame)
        let result = rule(&state, frame, correct)
        state.call &+= 1
        return result
    }
}

private func mutant(_ id: String, _ targets: [String], _ summary: String,
                    _ rule: @escaping MutantRule) -> Mutant<any DSTDecoderMaker> {
    Mutant(id, targets: targets, summary: summary) { base in MutantMaker(base: base, rule: rule) }
}

/// A rule that only rewrites successful results.
private func onSuccess(_ f: @escaping @Sendable (_ channels: Int, _ frame: [UInt8], _ out: [UInt8]) -> [UInt8]?)
    -> MutantRule {
    { state, frame, correct in
        guard let out = correct else { return nil }
        return f(state.channels, frame, out)
    }
}

/// A rule that rewrites successful results from the `from`-th decode on a decoder onwards (0-based).
private func fromCall(_ from: Int, _ f: @escaping @Sendable (_ channels: Int, _ out: [UInt8]) -> [UInt8]?)
    -> MutantRule {
    { state, _, correct in
        guard let out = correct, state.call >= from else { return correct }
        return f(state.channels, out)
    }
}

// MARK: - Byte and channel helpers (all bounds-checked)

/// The byte with its bit order reversed (bit 7 becomes bit 0).
private func reversedBits(_ byte: UInt8) -> UInt8 {
    var x = byte
    var r: UInt8 = 0
    for _ in 0..<8 {
        r = (r << 1) | (x & 1)
        x >>= 1
    }
    return r
}

/// Interleaved channel bytes split into one array per channel; nil when they don't split evenly.
private func planes(_ out: [UInt8], _ channels: Int) -> [[UInt8]]? {
    guard channels > 0, out.count % channels == 0 else { return nil }
    var result = Array(repeating: [UInt8](), count: channels)
    for c in 0..<channels { result[c].reserveCapacity(out.count / channels) }
    for (i, byte) in out.enumerated() { result[i % channels].append(byte) }
    return result
}

/// One array per channel interleaved byte by byte (up to the shortest channel).
private func interleaved(_ planes: [[UInt8]]) -> [UInt8] {
    let n = planes.map(\.count).min() ?? 0
    var out: [UInt8] = []
    out.reserveCapacity(n * planes.count)
    for i in 0..<n {
        for p in planes { out.append(p[i]) }
    }
    return out
}

/// `out` with `f` applied to the bytes of channel `channel` (0-based); unchanged when there is no such channel.
private func mapChannel(_ out: [UInt8], _ channels: Int, _ channel: Int,
                        _ f: (inout [UInt8]) -> Void) -> [UInt8] {
    guard channel >= 0, channel < channels, var p = planes(out, channels) else { return out }
    f(&p[channel])
    return interleaved(p)
}

/// `out` with channels `a` and `b` (0-based) exchanged.
private func swapChannels(_ out: [UInt8], _ channels: Int, _ a: Int, _ b: Int) -> [UInt8] {
    guard a >= 0, b >= 0, a < channels, b < channels, var p = planes(out, channels) else { return out }
    p.swapAt(a, b)
    return interleaved(p)
}

/// `out` with `mask` XORed into the byte at `index`; unchanged when `index` is out of range.
private func flip(_ out: [UInt8], at index: Int, mask: UInt8) -> [UInt8] {
    guard index >= 0, index < out.count else { return out }
    var o = out
    o[index] ^= mask
    return o
}

/// Index of byte `k` of channel `channel` in interleaved output.
private func at(_ k: Int, channel: Int, _ channels: Int) -> Int { k * channels + channel }

/// Channel bytes per channel in `out`, 0 when it doesn't divide.
private func perChannel(_ out: [UInt8], _ channels: Int) -> Int {
    channels > 0 && out.count % channels == 0 ? out.count / channels : 0
}

/// DSD idle (silence) pattern.
private let idle: UInt8 = 0x69

// MARK: - The mutants

public enum DSTMutants {
    public static let all: [Mutant<any DSTDecoderMaker>] = dst001 + dst002 + dst003 + dst004

    // DST-001: a decoded frame is 4 704 bytes per channel. Changing the length of a fixture's result necessarily also
    // changes the bytes DST-003/DST-004 compare, so those are targets too, except where the result was nil anyway.
    static let dst001: [Mutant<any DSTDecoderMaker>] = [
        mutant("C-DST-001-a", ["DST-001", "DST-003", "DST-004"],
               "drops the final channel-byte group: every channel comes out 4 703 bytes long",
               onSuccess { ch, _, out in
                   guard ch > 0, out.count >= ch else { return out }
                   return Array(out.dropLast(ch))
               }),
        mutant("C-DST-001-b", ["DST-001", "DST-003", "DST-004"],
               "6-channel frames only: one extra group of idle bytes (0x69) appended, 4 705 bytes per channel",
               onSuccess { ch, _, out in
                   ch == 6 ? out + Array(repeating: idle, count: ch) : out
               }),
        mutant("C-DST-001-c", ["DST-001"],
               "a frame it can't decode gives an empty result instead of nil (0 bytes per channel)",
               { _, _, correct in correct ?? [] }),
        mutant("C-DST-001-d", ["DST-001", "DST-003", "DST-004"],
               "from the second decode on the same decoder, the result is one byte short (last channel loses its last byte)",
               fromCall(1) { _, out in out.isEmpty ? out : Array(out.dropLast()) }),
        mutant("C-DST-001-e", ["DST-001", "DST-003", "DST-004"],
               "output buffer sized for stereo: 5- and 6-channel results are cut to 9 408 bytes",
               onSuccess { _, _, out in Array(out.prefix(2 * 4704)) }),
        mutant("C-DST-001-f", ["DST-001", "DST-003", "DST-004"],
               "5-channel results padded to the 6-channel size: 4 704 idle bytes (0x69) appended after the correct data",
               onSuccess { ch, _, out in
                   ch == 5 ? out + Array(repeating: idle, count: perChannel(out, ch)) : out
               }),
        mutant("C-DST-001-g", ["DST-001"],
               "right on the fixture frames only: any other frame it decodes comes out one channel-byte group short",
               onSuccess { ch, frame, out in
                   guard ch > 0, out.count >= ch, !DSTFixtures.all.contains(where: { $0.frame == frame }) else {
                       return out
                   }
                   return Array(out.dropLast(ch))
               }),
    ]

    // DST-002: channel bytes interleaved one per channel in channel order, most significant bit oldest. The length is
    // right, but every fixture result changes, so DST-003/DST-004 are targets too.
    static let dst002: [Mutant<any DSTDecoderMaker>] = [
        mutant("C-DST-002-a", ["DST-002", "DST-003", "DST-004"],
               "channels 1 and 2 exchanged",
               onSuccess { ch, _, out in swapChannels(out, ch, 0, 1) }),
        mutant("C-DST-002-b", ["DST-002", "DST-003", "DST-004"],
               "bit order reversed in every byte: least significant bit oldest",
               onSuccess { _, _, out in out.map(reversedBits) }),
        mutant("C-DST-002-c", ["DST-002", "DST-003", "DST-004"],
               "not interleaved: all of channel 1's bytes, then all of channel 2's, and so on",
               onSuccess { ch, _, out in planes(out, ch).map { $0.flatMap { $0 } } ?? out }),
        mutant("C-DST-002-d", ["DST-002", "DST-003", "DST-004"],
               "6-channel frames only: channels 3 and 4 exchanged",
               onSuccess { ch, _, out in ch == 6 ? swapChannels(out, ch, 2, 3) : out }),
        mutant("C-DST-002-e", ["DST-002", "DST-003", "DST-004"],
               "the last channel only has its bit order reversed (least significant bit oldest)",
               onSuccess { ch, _, out in
                   mapChannel(out, ch, ch - 1) { p in
                       for i in p.indices { p[i] = reversedBits(p[i]) }
                   }
               }),
        mutant("C-DST-002-f", ["DST-002", "DST-003", "DST-004"],
               "interleaved two bytes (16 samples) per channel at a time instead of one",
               onSuccess { ch, _, out in
                   guard let p = planes(out, ch) else { return out }
                   let n = p.first?.count ?? 0
                   var o: [UInt8] = []
                   o.reserveCapacity(out.count)
                   var k = 0
                   while k < n {
                       for c in 0..<ch {
                           o.append(p[c][k])
                           if k + 1 < n { o.append(p[c][k + 1]) }
                       }
                       k += 2
                   }
                   return o
               }),
        mutant("C-DST-002-g", ["DST-002", "DST-003", "DST-004"],
               "the final byte of each channel has its bit order reversed (least significant bit oldest)",
               onSuccess { ch, _, out in
                   let n = perChannel(out, ch)
                   guard n > 0 else { return out }
                   var o = out
                   for c in 0..<ch {
                       let i = at(n - 1, channel: c, ch)
                       o[i] = reversedBits(o[i])
                   }
                   return o
               }),
        mutant("C-DST-002-h", ["DST-002", "DST-003", "DST-004"],
               "from the third decode on the same decoder, channel order rotated by one (channel 2 first, channel 1 last)",
               fromCall(2) { ch, out in
                   guard var p = planes(out, ch), !p.isEmpty else { return out }
                   p.append(p.removeFirst())
                   return interleaved(p)
               }),
    ]

    // DST-003 (equal to the reference decoder's output) and DST-004 (equal to the encoded DSD) compare a fixture's
    // result with the same expected bytes, so every mutant here violates both. Length and layout are kept.
    static let dst003: [Mutant<any DSTDecoderMaker>] = [
        mutant("C-DST-003-a", ["DST-003", "DST-004"],
               "every output byte complemented (all samples inverted)",
               onSuccess { _, _, out in out.map { ~$0 } }),
        mutant("C-DST-003-b", ["DST-003", "DST-004"],
               "the newest sample of the frame (last channel, last bit) is inverted",
               onSuccess { _, _, out in flip(out, at: out.count - 1, mask: 0x01) }),
        mutant("C-DST-003-c", ["DST-003", "DST-004"],
               "every channel delayed by one sample: its first sample is 0 and its last sample is lost",
               onSuccess { ch, _, out in
                   guard var p = planes(out, ch) else { return out }
                   for c in p.indices {
                       var carry: UInt8 = 0
                       for i in p[c].indices {
                           let b = p[c][i]
                           p[c][i] = (b >> 1) | (carry << 7)
                           carry = b & 1
                       }
                   }
                   return interleaved(p)
               }),
        mutant("C-DST-003-d", ["DST-003", "DST-004"],
               "compressed frames only (frame shorter than its DSD): one sample of channel 1 mid-frame inverted",
               onSuccess { ch, frame, out in
                   guard frame.count < out.count else { return out }
                   return flip(out, at: at(perChannel(out, ch) / 2, channel: 0, ch), mask: 0x10)
               }),
        mutant("C-DST-003-e", ["DST-003", "DST-004"],
               "5-channel frames are rejected: nil for every frame",
               { state, _, correct in state.channels == 5 ? nil : correct }),
        mutant("C-DST-003-f", ["DST-003", "DST-004"],
               "state leaks between frames: from the second decode on a decoder, channel 1's oldest sample is inverted",
               fromCall(1) { _, out in flip(out, at: 0, mask: 0x80) }),
        mutant("C-DST-003-g", ["DST-003", "DST-004"],
               "6-channel frames only: channel 6 comes out as idle pattern (0x69) instead of its audio",
               onSuccess { ch, _, out in
                   ch == 6 ? mapChannel(out, ch, 5) { p in for i in p.indices { p[i] = idle } } : out
               }),
    ]

    static let dst004: [Mutant<any DSTDecoderMaker>] = [
        mutant("C-DST-004-a", ["DST-004", "DST-003"],
               "stored (uncompressed) frames only (frame not shorter than its DSD): last channel's oldest sample inverted",
               onSuccess { ch, frame, out in
                   guard frame.count >= out.count else { return out }
                   return flip(out, at: ch - 1, mask: 0x80)
               }),
        mutant("C-DST-004-b", ["DST-004", "DST-003"],
               "decoding a frame already decoded on the same decoder returns a stale copy with one mid-frame bit wrong",
               { state, frame, correct in
                   guard let out = correct else { return nil }
                   if let cached = state.cache[frame] {
                       return flip(cached, at: cached.count / 2, mask: 0x01)
                   }
                   if state.cache.count >= 32 { state.cache.removeAll() }
                   state.cache[frame] = out
                   return out
               }),
        mutant("C-DST-004-c", ["DST-004", "DST-003"],
               "frames longer than 12 000 bytes are rejected (nil)",
               { _, frame, correct in frame.count > 12_000 ? nil : correct }),
        mutant("C-DST-004-d", ["DST-004", "DST-003"],
               "from the sixth decode on the same decoder, one sample near the end of the last channel is inverted",
               fromCall(5) { ch, out in
                   let n = perChannel(out, ch)
                   guard n > 1000 else { return out }
                   return flip(out, at: at(n - 1000, channel: ch - 1, ch), mask: 0x08)
               }),
        mutant("C-DST-004-e", ["DST-004", "DST-003"],
               "the last 8 bytes (64 samples) of channel 2 are replaced by idle pattern 0x69 (tail not flushed)",
               onSuccess { ch, _, out in
                   mapChannel(out, ch, 1) { p in
                       for i in p.indices.suffix(8) { p[i] = idle }
                   }
               }),
    ]
}
