//
// Vespertine — song transitions on the engine thread, before the ring: gain ramps for dips, the two-deck crossfade,
// and the silence scan that finds where a song's music ends and the next one's begins.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything here runs only while the master switch is on and the planner chose a dip or an overlap
// (`TransitionPlanner`). Frames outside a ramp or an overlap are passed on untouched (not multiplied by 1), so the
// bodies of the songs stay bit-perfect. Nothing here allocates or locks on the real-time thread: it all runs on the
// engine thread, 20–30 s ahead of what is heard.
//

import AVFAudio
import Foundation
import SFBAudioEngine

/// A gain ramp over a run of one song's frames, counted as its `Decoding.framesProduced` counts them.
struct FrameRamp: Sendable, Equatable {
    /// The first frame of the ramp.
    var start: UInt64
    var length: Int
    /// In from silence (a dip's second half), or out to silence (its first half).
    var fadesIn: Bool
    var curve: TransitionCurve

    /// The gain at `frame`: 1 before a fade out and after a fade in, 0 after a fade out.
    func gain(at frame: UInt64) -> Float {
        if frame < start { return fadesIn ? 0 : 1 }
        let k = frame - start
        if k >= UInt64(length) { return fadesIn ? 1 : 0 }
        let g = curve.gains(at: Double(k) / Double(length))
        return Float(fadesIn ? g.in : g.out)
    }

    /// A dip's fade out: the last `seconds` of a song of `total` frames (fewer when only `produced` on are left).
    static func fadeOut(seconds: Double, curve: TransitionCurve, total: Int64, produced: UInt64, rate: Double) -> FrameRamp? {
        let start = max(Int64(produced), total - Int64(seconds * rate))
        guard total - start > 0 else { return nil }
        return FrameRamp(start: UInt64(start), length: Int(total - start), fadesIn: false, curve: curve)
    }

    /// A dip's fade in: the first `seconds` of a song.
    static func fadeIn(seconds: Double, curve: TransitionCurve, rate: Double) -> FrameRamp? {
        let length = Int(seconds * rate)
        return length > 0 ? FrameRamp(start: 0, length: length, fadesIn: true, curve: curve) : nil
    }

    /// Applies the ramp to `frames` interleaved frames starting at song frame `first`. Frames at gain 1 are left alone.
    /// Returns whether any frame was changed.
    @discardableResult
    func apply(_ data: UnsafeMutablePointer<Float>, frames: Int, first: UInt64, channels: Int) -> Bool {
        let end = first + UInt64(frames)
        // The frames that aren't at gain 1: from the ramp's start on (out), or up to its end (in).
        let from = fadesIn ? first : max(first, start)
        let to = fadesIn ? min(end, start + UInt64(length)) : end
        guard from < to else { return false }
        for f in from..<to {
            let g = gain(at: f)
            let base = data + Int(f - first) * channels
            for c in 0..<channels { base[c] *= g }
        }
        return true
    }
}

/// TPDF dither of ±1 LSB at a device word length, from a fixed seed (the same mix gives the same bytes every time).
struct TransitionDither {
    private var state: UInt64 = 0x5DEE_CE66_D1CE_4E5B
    let lsb: Float

    /// nil for 32-bit and float words, which need none.
    init?(bits: Int) {
        guard bits > 1, bits < 32 else { return nil }
        lsb = Float(1.0 / Double(1 << (bits - 1)))
    }

    private mutating func uniform() -> Float {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return Float((state &* 0x2545_F491_4F6C_DD1D) >> 40) / Float(1 << 24)
    }

    mutating func next() -> Float { (uniform() - uniform()) * lsb }
}

/// Two songs overlapping: the outgoing song's frames from `start` for `length` frames are mixed with the incoming song's
/// first `length` frames, each at its curve's gain, ReplayGain already applied to each (`Decoding.convertChunk`). After
/// the overlap the incoming song plays alone; what's left of the outgoing one (its trimmed tail) is dropped.
final class Crossfade {
    let incoming: Decoding
    /// The outgoing song's frame (its `framesProduced` count) where the overlap starts.
    let start: UInt64
    let length: Int
    let curve: TransitionCurve
    let channels: Int
    private var dither: TransitionDither?
    /// Overlap frames written so far.
    private(set) var mixed = 0
    /// Incoming frames converted but not mixed yet, interleaved, from `pendingOffset`.
    private var pending: [Float] = []
    private var pendingOffset = 0
    /// The incoming song failed while it was being mixed in.
    private(set) var incomingError: Error?
    private var scratch: [Float] = []

    var started: Bool { mixed > 0 }
    var done: Bool { mixed >= length }

    /// `ditherBits`: the device's word length when nothing after the ring dithers (0: no dither).
    init(incoming: Decoding, start: UInt64, length: Int, curve: TransitionCurve, ditherBits: Int = 0) {
        self.incoming = incoming
        self.start = start
        self.length = max(1, length)
        self.curve = curve
        channels = incoming.path.plan.channels
        dither = TransitionDither(bits: ditherBits)
        pending.reserveCapacity(Int(incoming.output.frameCapacity) * 2 * channels)
    }

    /// One chunk of the outgoing song, its frames `first ..< first + frames`: hands `write` what reaches the ring (the
    /// outgoing song up to the overlap, then the mix; nothing after it). Returns the frames written before the first
    /// overlap frame when the overlap starts in this chunk.
    func feed(_ a: UnsafeMutablePointer<Float>, frames: Int, first: UInt64, write: (UnsafePointer<Float>, Int) -> Void) -> Int? {
        let before = start > first ? min(frames, Int(start - first)) : 0
        if before > 0 { write(a, before) }
        let count = min(frames - before, length - mixed)
        guard count > 0 else { return nil }
        let startsHere = mixed == 0 ? before : nil
        mix(into: a + before * channels, frames: count)
        write(a + before * channels, count)
        return startsHere
    }

    /// The outgoing song ended before the overlap did (its length was a little shorter than its decoder said): the rest
    /// of the overlap is the incoming song fading in over silence, at most `maxFrames` of it per call.
    func finishAlone(maxFrames: Int, write: (UnsafePointer<Float>, Int) -> Void) {
        let count = min(maxFrames, length - mixed)
        guard count > 0 else { return }
        if scratch.count < count * channels { scratch = [Float](repeating: 0, count: count * channels) }
        scratch.withUnsafeMutableBufferPointer { buffer in
            let p = buffer.baseAddress!
            p.update(repeating: 0, count: count * channels)
            mix(into: p, frames: count)
            write(p, count)
        }
    }

    /// Lines up the incoming song `next` for a crossfade of `seconds` at the end of `a` (`total` frames in all): its
    /// silence trimmed at both ends when `trimSilence` (the end of `a` read with a decoder of its own,
    /// `reopenOutgoing`), the overlap placed where `a`'s music ends. nil when there'd be less than
    /// `TransitionTiming.minimumSeconds` of overlap (the songs are then joined as they are).
    static func prepare(outgoing a: Decoding, total: Int64, next: PlayableItem, probed: ProbedSource, plan: OutputPlan,
                        path: SignalPath, seconds: Double, curve: TransitionCurve, trimSilence: Bool, ditherBits: Int,
                        chunk: AVAudioFrameCount, layout: AVAudioChannelLayout?,
                        reopenOutgoing: () throws -> PCMDecoding) throws -> Crossfade? {
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: next)
        var trailing: Int64 = 0
        if trimSilence, a.decoder.supportsSeeking, !a.streaming {
            trailing = SilenceScan.trailing(of: a, open: reopenOutgoing, layout: layout) ?? 0
        }
        var head: AVAudioFramePosition = 0
        if trimSilence, decoder.supportsSeeking, decoder.length > 0 {
            let scan = try Decoding(item: next, probed: probed, decoder: decoder, path: path, chunk: chunk, layout: layout)
            let lead = SilenceScan.leading(of: scan, layout: layout)
            head = min(AVAudioFramePosition(Double(lead) * decoder.processingFormat.sampleRate / plan.deviceSampleRate), decoder.length - 1)
            try decoder.seek(to: head)
        }
        let b = try Decoding(item: next, probed: probed, decoder: decoder, path: path, chunk: chunk, layout: layout)
        b.startSourceFrame = head
        guard let timing = TransitionTiming.overlap(seconds: seconds, rate: plan.deviceSampleRate, aTotal: total,
                                                    aProduced: a.framesProduced, aTrailing: trailing, bMusic: b.expectedFrames) else { return nil }
        return Crossfade(incoming: b, start: timing.start, length: timing.length, curve: curve, ditherBits: ditherBits)
    }

    /// After the overlap: the incoming frames converted but not mixed (the incoming song carries on alone from here).
    func flushIncoming(write: (UnsafePointer<Float>, Int) -> Void) {
        let frames = (pending.count - pendingOffset) / channels
        guard frames > 0 else { return }
        pending.withUnsafeBufferPointer { write($0.baseAddress! + pendingOffset, frames) }
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
    }

    /// Mixes `frames` overlap frames into `out` (the outgoing song's samples), taking as many of the incoming song's.
    private func mix(into out: UnsafeMutablePointer<Float>, frames: Int) {
        fillPending(frames)
        let available = (pending.count - pendingOffset) / channels
        pending.withUnsafeBufferPointer { buffer in
            let b = buffer.baseAddress! + pendingOffset
            for i in 0..<frames {
                let g = curve.gains(at: Double(mixed + i) / Double(length))
                let ga = Float(g.out), gb = Float(g.in)
                let o = out + i * channels
                if i < available {
                    let s = b + i * channels
                    for c in 0..<channels { o[c] = o[c] * ga + s[c] * gb }
                } else {
                    // The incoming song ended inside the overlap: it adds silence.
                    for c in 0..<channels { o[c] *= ga }
                }
                if dither != nil {
                    for c in 0..<channels { o[c] += dither!.next() }
                }
            }
        }
        pendingOffset += min(frames, available) * channels
        mixed += frames
        if pendingOffset == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingOffset = 0
        } else if pendingOffset > pending.count / 2 {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    /// Converts incoming chunks until `frames` are waiting (or the song has ended).
    private func fillPending(_ frames: Int) {
        while (pending.count - pendingOffset) / channels < frames, !incoming.finished {
            let chunk = incoming.convertChunk()
            if chunk.frames > 0, let data = chunk.data {
                pending.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frames) * channels))
            }
            if chunk.ended {
                incoming.finished = true
                incomingError = chunk.error
            } else if chunk.frames == 0 && chunk.waiting {
                break
            }
        }
    }
}

/// Where the music ends and starts: digital silence and near-silence (below about −60 dBFS) at a song's ends.
enum SilenceScan {
    /// −60 dBFS.
    static let threshold: Float = 0.001
    /// How much of a song's end is looked at for silence, and of its start.
    static let tailSeconds = 15.0
    static let headSeconds = 10.0

    /// Frames (at the device rate) of silence at the end of the song `decoding` plays, looking at its last
    /// `tailSeconds` only, read with a decoder of its own (`open`). nil when the song can't be read that way.
    static func trailing(of decoding: Decoding, open: () throws -> PCMDecoding, layout: AVAudioChannelLayout?) -> Int64? {
        guard let total = decoding.expectedFrames, let scan = try? reader(decoding, open: open, layout: layout) else { return nil }
        let rate = scan.decoder.processingFormat.sampleRate
        let length = scan.decoder.length
        let window = Int64(tailSeconds * rate)
        let from = max(decoding.startSourceFrame, length - window)
        guard scan.decoder.supportsSeeking, length > 0, (try? scan.decoder.seek(to: from)) != nil else { return nil }
        var produced: Int64 = 0, lastLoud: Int64 = -1
        let limit = threshold * max(decoding.gain, .leastNormalMagnitude)
        while true {
            let chunk = scan.convertChunk()
            if chunk.frames > 0, let data = chunk.data {
                if let loud = lastLoudFrame(data, frames: Int(chunk.frames), channels: decoding.path.plan.channels, above: limit) {
                    lastLoud = produced + Int64(loud)
                }
                produced += Int64(chunk.frames)
            }
            if chunk.ended || (chunk.frames == 0 && chunk.waiting) { break }
        }
        guard produced > 0 else { return nil }
        // The scan's frames end where the song's do: what follows its last loud frame is silence.
        return min(total, produced - (lastLoud + 1))
    }

    /// Frames (at the device rate) of silence at the start of `decoding`'s song, looking at its first `headSeconds`.
    static func leading(of decoding: Decoding, layout: AVAudioChannelLayout?) -> Int64 {
        let limit = threshold * max(decoding.gain, .leastNormalMagnitude)
        let window = Int64(headSeconds * decoding.path.plan.deviceSampleRate)
        var produced: Int64 = 0
        while produced < window {
            let chunk = decoding.convertChunk()
            if chunk.frames > 0, let data = chunk.data {
                if let loud = firstLoudFrame(data, frames: Int(chunk.frames), channels: decoding.path.plan.channels, above: limit) {
                    return produced + Int64(loud)
                }
                produced += Int64(chunk.frames)
            }
            if chunk.ended || (chunk.frames == 0 && chunk.waiting) { break }
        }
        return min(produced, window)
    }

    private static func reader(_ decoding: Decoding, open: () throws -> PCMDecoding, layout: AVAudioChannelLayout?) throws -> Decoding {
        try Decoding(item: decoding.item, probed: decoding.probed, decoder: open(), path: decoding.path,
                     chunk: decoding.output.frameCapacity, layout: layout)
    }

    static func lastLoudFrame(_ data: UnsafePointer<Float>, frames: Int, channels: Int, above limit: Float) -> Int? {
        for f in stride(from: frames - 1, through: 0, by: -1) {
            for c in 0..<channels where abs(data[f * channels + c]) > limit { return f }
        }
        return nil
    }

    static func firstLoudFrame(_ data: UnsafePointer<Float>, frames: Int, channels: Int, above limit: Float) -> Int? {
        for f in 0..<frames {
            for c in 0..<channels where abs(data[f * channels + c]) > limit { return f }
        }
        return nil
    }
}

/// Where an overlap goes.
enum TransitionTiming {
    /// The shortest overlap worth mixing; anything shorter is joined as it is.
    static let minimumSeconds = 0.1

    /// Frames of the outgoing song left when its boundary is planned: room to look for silence at its end and fit
    /// the longest crossfade, plus a second.
    static func planningLead(crossfadeSeconds: Double, rate: Double) -> Int64 {
        Int64((crossfadeSeconds + SilenceScan.tailSeconds + 1) * rate)
    }

    /// The overlap for a crossfade of `seconds`: it ends where the outgoing song's music ends (`aTotal` frames less
    /// `aTrailing` of silence) and never starts before `aProduced` (already in the ring), nor takes more than half of
    /// the incoming song's music (`bMusic`). nil when there's less than `minimumSeconds` of it.
    static func overlap(seconds: Double, rate: Double, aTotal: Int64, aProduced: UInt64, aTrailing: Int64,
                        bMusic: Int64?) -> (start: UInt64, length: Int)? {
        let end = aTotal - max(0, aTrailing)
        var length = Int64(seconds * rate)
        length = min(length, end - Int64(aProduced))
        if let bMusic { length = min(length, bMusic / 2) }
        guard length >= Int64(minimumSeconds * rate) else { return nil }
        return (UInt64(end - length), Int(length))
    }
}
