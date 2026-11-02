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
    /// Smart Mix's gains (its curves and loudness match) and limiter; nil for a plain crossfade, mixed exactly as
    /// before Smart Mix.
    let shape: SmartMix?
    /// The incoming song's rise, as a fraction of the overlap (Smart Mix).
    private let inFraction: Double
    private let limiter: OverlapLimiter?
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
    init(incoming: Decoding, start: UInt64, length: Int, curve: TransitionCurve, ditherBits: Int = 0, shape: SmartMix? = nil) {
        self.incoming = incoming
        self.start = start
        self.length = max(1, length)
        self.curve = curve
        self.shape = shape
        channels = incoming.path.plan.channels
        let rate = incoming.path.plan.deviceSampleRate
        inFraction = shape.map { min(1, $0.inSeconds * rate / Double(max(1, length))) } ?? 0
        limiter = shape == nil ? nil : OverlapLimiter(channels: channels, sampleRate: rate)
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
        emit(a + before * channels, frames: count, write: write)
        return startsHere
    }

    /// Hands mixed frames on: as they are for a plain crossfade; through the limiter (which holds a few milliseconds
    /// back to see what's coming) and then dither for Smart Mix, all of it once the overlap is complete.
    private func emit(_ frames: UnsafeMutablePointer<Float>, frames count: Int, write: (UnsafePointer<Float>, Int) -> Void) {
        guard let limiter else { write(frames, count); return }
        let out: (UnsafeMutablePointer<Float>, Int) -> Void = { p, n in
            if self.dither != nil {
                for i in 0..<(n * self.channels) { p[i] += self.dither!.next() }
            }
            write(p, n)
        }
        limiter.process(frames, frames: count, write: out)
        if done { limiter.flush(write: out) }
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
            emit(p, frames: count, write: write)
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

    /// Smart Mix's boundary: measures the end of `a` and the start of `next` (from their stored profiles when the
    /// library has them, else from the audio, just in time), asks `decide` what to do with what was measured and, for
    /// a mix, lines it up like `prepare` with Smart Mix's shape. Silence is always trimmed. The decision comes back
    /// with the crossfade (nil when the decision isn't a mix, or there's too little to overlap).
    static func prepareSmart(outgoing a: Decoding, total: Int64, next: PlayableItem, probed: ProbedSource, plan: OutputPlan,
                             path: SignalPath, ditherBits: Int, chunk: AVAudioFrameCount, layout: AVAudioChannelLayout?,
                             stored: (outgoing: TransitionProfile?, incoming: TransitionProfile?),
                             decide: ((tail: TransitionProfile.Edge?, head: TransitionProfile.Edge?), (a: Double, b: Double)) -> TransitionDecision,
                             reopenOutgoing: () throws -> PCMDecoding) throws -> (decision: TransitionDecision, crossfade: Crossfade?) {
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: next)
        // The end of the outgoing song: what the library knows (at the file's own level, so its ReplayGain is added),
        // or measured now from the audio as it plays (gain included).
        var tail: TransitionProfile.Edge?, gainA = 0.0, trailing: Int64 = 0
        if a.decoder.supportsSeeking, !a.streaming {
            if let stored = stored.outgoing?.tail {
                tail = stored
                gainA = decibels(a.gain)
                trailing = SilenceScan.trailing(of: a, open: reopenOutgoing, layout: layout) ?? 0
            } else if let measured = EdgeScan.tail(of: a, open: reopenOutgoing, layout: layout) {
                tail = measured.edge
                trailing = measured.trailing
            }
        }
        var head: TransitionProfile.Edge?, gainB = 0.0, lead: AVAudioFramePosition = 0
        let probe = try Decoding(item: next, probed: probed, decoder: decoder, path: path, chunk: chunk, layout: layout)
        if decoder.supportsSeeking, decoder.length > 0 {
            var leading: Int64
            if let stored = stored.incoming?.head {
                head = stored
                gainB = decibels(probe.gain)
                leading = SilenceScan.leading(of: probe, layout: layout)
            } else {
                let measured = EdgeScan.head(of: probe)
                head = measured.edge
                leading = measured.leading
            }
            lead = min(AVAudioFramePosition(Double(leading) * decoder.processingFormat.sampleRate / plan.deviceSampleRate), decoder.length - 1)
            try decoder.seek(to: lead)
        }
        let decision = decide((tail, head), (gainA, gainB))
        guard case .mix(let mix) = decision else { return (decision, nil) }
        let b = try Decoding(item: next, probed: probed, decoder: decoder, path: path, chunk: chunk, layout: layout)
        b.startSourceFrame = lead
        guard let timing = TransitionTiming.overlap(seconds: mix.seconds, rate: plan.deviceSampleRate, aTotal: total,
                                                    aProduced: a.framesProduced, aTrailing: trailing, bMusic: b.expectedFrames) else {
            return (decision, nil)
        }
        return (decision, Crossfade(incoming: b, start: timing.start, length: timing.length, curve: mix.inCurve, ditherBits: ditherBits, shape: mix))
    }

    static func decibels(_ gain: Float) -> Double { gain > 0 ? 20 * log10(Double(gain)) : 0 }

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
        if let shape {
            pending.withUnsafeBufferPointer { buffer in
                let b = buffer.baseAddress! + pendingOffset
                for i in 0..<frames {
                    let g = shape.gains(at: Double(mixed + i) / Double(length), inFraction: inFraction)
                    let ga = Float(g.out), gb = Float(g.in)
                    let o = out + i * channels
                    if i < available {
                        let s = b + i * channels
                        for c in 0..<channels { o[c] = o[c] * ga + s[c] * gb }
                    } else {
                        for c in 0..<channels { o[c] *= ga }
                    }
                }
            }
            consume(frames, available: available)
            return
        }
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
        consume(frames, available: available)
    }

    private func consume(_ frames: Int, available: Int) {
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

/// A lookahead peak limiter for an overlap's frames (Smart Mix): two songs at full level, summed, can go over full
/// scale mid-blend. Each frame's gain is the mean, over the last `lookahead` frames, of a gain that has already seen
/// `lookahead` frames ahead (and recovers over `release`), so the gain is never above what any frame within reach
/// needs: no output frame goes over `ceiling`, and the gain moves smoothly (back up to 1 in `release` at most). Frames that need nothing are passed on
/// untouched; the output is the input `lookahead` frames later (`flush` hands on the rest at the overlap's end, as
/// if what follows needed nothing). Deterministic: the same frames give the same bytes.
final class OverlapLimiter {
    /// −0.3 dBFS.
    static let ceiling: Float = 0.966
    static let lookaheadSeconds = 0.005
    static let releaseSeconds = 0.05

    let channels: Int
    let lookahead: Int
    /// How much the gain may rise per frame.
    private let release: Double
    /// Frames waiting for their lookahead, interleaved, and each one's needed gain.
    private var frames: [Float] = []
    private var needed: [Double] = []
    private var head = 0
    /// How many waiting frames need less than 1 (when none do, the window's minimum is 1 without looking).
    private var loud = 0
    private var held = 1.0
    /// The last `lookahead + 1` held gains, as 1 − gain, with their sum and how many aren't 0.
    private var history: [Double]
    private var historyIndex = 0
    private var historyCount = 0
    private var reduction = 0.0
    private var reducing = 0
    private var out: [Float] = []
    /// The greatest gain reduction applied so far (1 = none): for tests and the log.
    private(set) var lowestGain = 1.0

    init(channels: Int, sampleRate: Double) {
        self.channels = max(1, channels)
        lookahead = max(1, Int((Self.lookaheadSeconds * sampleRate).rounded()))
        release = 1 / (Self.releaseSeconds * sampleRate)
        history = [Double](repeating: 0, count: lookahead + 1)
    }

    /// Takes `count` frames; hands on those whose lookahead is now complete.
    func process(_ input: UnsafePointer<Float>, frames count: Int, write: (UnsafeMutablePointer<Float>, Int) -> Void) {
        for f in 0..<count {
            var peak: Float = 0
            for c in 0..<channels {
                let x = input[f * channels + c]
                frames.append(x)
                peak = max(peak, abs(x))
            }
            let need = peak > Self.ceiling ? Double(Self.ceiling) / Double(peak) : 1
            needed.append(need)
            if need < 1 { loud += 1 }
        }
        drain(keeping: lookahead, write: write)
    }

    /// Hands on every frame still held (the overlap is over).
    func flush(write: (UnsafeMutablePointer<Float>, Int) -> Void) {
        drain(keeping: 0, write: write)
        frames.removeAll(keepingCapacity: true)
        needed.removeAll(keepingCapacity: true)
        head = 0
    }

    private func drain(keeping: Int, write: (UnsafeMutablePointer<Float>, Int) -> Void) {
        let ready = needed.count - head - keeping
        guard ready > 0 else { return }
        if out.count < ready * channels { out = [Float](repeating: 0, count: ready * channels) }
        out.withUnsafeMutableBufferPointer { o in
            for k in 0..<ready {
                let j = head + k
                // The least gain any frame within the lookahead needs.
                var m = 1.0
                if loud > 0 {
                    for i in j..<min(needed.count, j + lookahead + 1) where needed[i] < m { m = needed[i] }
                }
                held = min(m, held + release, 1)
                // The mean of the last lookahead + 1 held gains.
                let old = history[historyIndex]
                if old != 0 { reducing -= 1 }
                reduction -= old
                history[historyIndex] = 1 - held
                if held < 1 { reducing += 1 }
                reduction += 1 - held
                historyIndex = (historyIndex + 1) % history.count
                historyCount = min(historyCount + 1, history.count)
                if reducing == 0 { reduction = 0 }
                let gain = reducing == 0 ? 1 : 1 - reduction / Double(historyCount)
                lowestGain = min(lowestGain, gain)
                let g = Float(gain), ceiling = Self.ceiling
                for c in 0..<channels {
                    let x = frames[j * channels + c]
                    // Clamped too: the gain is exact in Double, but its product in Float can round a hair over.
                    o[k * channels + c] = gain == 1 ? x : min(max(x * g, -ceiling), ceiling)
                }
                if needed[j] < 1 { loud -= 1 }
            }
            write(o.baseAddress!, ready)
        }
        head += ready
        if head > 4096 && head * 2 > needed.count {
            frames.removeFirst(head * channels)
            needed.removeFirst(head)
            head = 0
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

    static func reader(_ decoding: Decoding, open: () throws -> PCMDecoding, layout: AVAudioChannelLayout?) throws -> Decoding {
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

/// Smart Mix's measurements made just in time, for a song the library has no profile of: the analysis
/// (`TransitionAnalyzer`) of the audio as it plays (at the output's rate, ReplayGain applied), over a song's last
/// `tailSeconds` and first `headSeconds`. Silence is found exactly as `SilenceScan` finds it.
enum EdgeScan {
    /// Room for the longest fade looked for, and ten seconds of music before it.
    static let tailSeconds = TransitionAnalyzer.fadeWindow + TransitionAnalyzer.loudnessWindow
    static let headSeconds = 20.0

    /// The end of the song `decoding` plays, read with a decoder of its own (`open`), and its silence in frames.
    static func tail(of decoding: Decoding, open: () throws -> PCMDecoding, layout: AVAudioChannelLayout?) -> (edge: TransitionProfile.Edge, trailing: Int64)? {
        guard let total = decoding.expectedFrames, let scan = try? SilenceScan.reader(decoding, open: open, layout: layout) else { return nil }
        let rate = scan.decoder.processingFormat.sampleRate
        let length = scan.decoder.length
        let from = max(decoding.startSourceFrame, length - Int64(tailSeconds * rate))
        guard scan.decoder.supportsSeeking, length > 0, (try? scan.decoder.seek(to: from)) != nil else { return nil }
        let deviceRate = decoding.path.plan.deviceSampleRate
        let startFrame = Int64((Double(from - decoding.startSourceFrame) * deviceRate / rate).rounded())
        let analyzer = TransitionAnalyzer(sampleRate: deviceRate, channels: decoding.path.plan.channels, startFrame: startFrame,
                                          silenceThreshold: SilenceScan.threshold * max(decoding.gain, .leastNormalMagnitude))
        while true {
            let chunk = scan.convertChunk()
            if chunk.frames > 0, let data = chunk.data { analyzer.add(data, frames: Int(chunk.frames)) }
            if chunk.ended || (chunk.frames == 0 && chunk.waiting) { break }
        }
        guard analyzer.framesAdded > 0, let edge = analyzer.finish(totalFrames: startFrame + analyzer.framesAdded).tail else { return nil }
        let end = startFrame + analyzer.framesAdded
        let trailing = end - (analyzer.lastLoudFrame.map { $0 + 1 } ?? startFrame)
        return (edge, min(total, trailing))
    }

    /// The start of `decoding`'s song (read from where it is, its start), and its silence in frames.
    static func head(of decoding: Decoding) -> (edge: TransitionProfile.Edge?, leading: Int64) {
        let analyzer = TransitionAnalyzer(sampleRate: decoding.path.plan.deviceSampleRate, channels: decoding.path.plan.channels,
                                          silenceThreshold: SilenceScan.threshold * max(decoding.gain, .leastNormalMagnitude))
        let window = Int64(headSeconds * decoding.path.plan.deviceSampleRate)
        var ended = false
        while analyzer.framesAdded < window {
            let chunk = decoding.convertChunk()
            if chunk.frames > 0, let data = chunk.data { analyzer.add(data, frames: Int(chunk.frames)) }
            if chunk.ended || (chunk.frames == 0 && chunk.waiting) { ended = chunk.ended; break }
        }
        let leading = min(analyzer.firstLoudFrame ?? analyzer.framesAdded, window)
        guard analyzer.framesAdded > 0 else { return (nil, 0) }
        return (analyzer.finish(totalFrames: analyzer.framesAdded + (ended ? 0 : 1)).head, leading)
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

    /// The lead for `settings`: Smart Mix's longest overlap is 12 s, whatever the crossfade length.
    static func planningLead(_ settings: TransitionSettings, rate: Double) -> Int64 {
        planningLead(crossfadeSeconds: settings.isSmart ? SmartMixPlanner.fadeRange.upperBound : settings.crossfadeSeconds, rate: rate)
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
