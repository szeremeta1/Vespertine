//
// Role C: deliberately wrong DoP output stages ("mutants") for contracts/dop-stream.md.
//
// Every mutant decorates the correct stage the harness passes in. The decorator keeps that base stage as the store
// of written music: it forwards every write, mirrors what the base accepted, and pulls from the base exactly the
// music frames it is about to play (dropping any marker-bridging frame the base inserts on its own, which it can
// recognise because a bridging frame never equals the music frame that follows it). Silence, marker bridging and
// mute are produced by the decorator itself, in the same way a correct stage produces them, so each mutant changes
// one behaviour and otherwise behaves like a correct stage. The base is never muted by the decorator (mute is the
// decorator's job); gain and equalizer calls are forwarded to it. The silence byte and the marker of a stage's
// first frame are learned from the base's first rendered frame, so a mutant's silence looks like its base's.
//

import Contracts
import SpecKit

public enum DoPStreamMutants {
    public static let all: [Mutant<any DoPStageMaker>] = [
        // MARK: DOPS-001 — the marker alternates across everything output (markers stay 0x05/0xFA here)
        Mutant("C-DOPS-001-a", targets: ["DOPS-001"],
               summary: "Held silence (muted or out of music) always carries marker 0x05 instead of alternating") { base in
            FlawedMaker(base: base, flaw: .heldSilenceFixedMarker)
        },
        Mutant("C-DOPS-001-b", targets: ["DOPS-001"],
               summary: "No bridging frame: music whose marker repeats the previous frame's marker goes out directly") { base in
            FlawedMaker(base: base, flaw: .noBridge)
        },
        Mutant("C-DOPS-001-c", targets: ["DOPS-001"],
               summary: "The first held silence frame of each render call restarts the marker phase at 0x05") { base in
            FlawedMaker(base: base, flaw: .silencePhaseResetPerCall)
        },
        Mutant("C-DOPS-001-d", targets: ["DOPS-001"],
               summary: "Every 32768th held silence frame repeats the previous frame's marker (slip after many frames)") { base in
            FlawedMaker(base: base, flaw: .silenceMarkerSlip(every: 32768))
        },

        // MARK: DOPS-002 — every frame on every channel carries a valid marker (an invalid one also breaks DOPS-001)
        Mutant("C-DOPS-002-a", targets: ["DOPS-002", "DOPS-001"],
               summary: "Silence while muted has marker byte 0x00 on every channel (DSD silence bits intact)") { base in
            FlawedMaker(base: base, flaw: .mutedNoMarker)
        },
        Mutant("C-DOPS-002-b", targets: ["DOPS-002", "DOPS-001"],
               summary: "Silence when out of music carries the marker on channel 0 only; other channels have marker 0x00") { base in
            FlawedMaker(base: base, flaw: .underrunMarkerOnFirstChannelOnly)
        },
        Mutant("C-DOPS-002-c", targets: ["DOPS-002", "DOPS-001"],
               summary: "The single bridging silence frame before resumed music has marker byte 0x00") { base in
            FlawedMaker(base: base, flaw: .bridgeNoMarker)
        },
        Mutant("C-DOPS-002-d", targets: ["DOPS-002", "DOPS-001"],
               summary: "Silence frames carry 0xFB where the marker should be 0xFA") { base in
            FlawedMaker(base: base, flaw: .markerTypoFB)
        },

        // MARK: DOPS-003 — silence is DSD silence: one byte value per run, on every channel, four bits set
        Mutant("C-DOPS-003-a", targets: ["DOPS-003"],
               summary: "Silence frames carry DSD bytes 0x00 (no bits set) under valid markers") { base in
            FlawedMaker(base: base, flaw: .zeroSilence)
        },
        Mutant("C-DOPS-003-b", targets: ["DOPS-003"],
               summary: "Silence on the last channel uses the complement of the other channels' silence byte") { base in
            FlawedMaker(base: base, flaw: .lastChannelComplement)
        },
        Mutant("C-DOPS-003-c", targets: ["DOPS-003"],
               summary: "The silence byte switches to its complement every other render call, even inside one run") { base in
            FlawedMaker(base: base, flaw: .silenceByteFlipsPerCall)
        },
        Mutant("C-DOPS-003-d", targets: ["DOPS-003"],
               summary: "Silence while muted uses the silence byte with one bit cleared (three bits set)") { base in
            FlawedMaker(base: base, flaw: .mutedPopcount3)
        },
        Mutant("C-DOPS-003-e", targets: ["DOPS-003"],
               summary: "The bridging silence frame before resumed music carries DSD bytes 0xFF") { base in
            FlawedMaker(base: base, flaw: .bridgeAllOnes)
        },

        // MARK: DOPS-004 — music comes out bit-identical, in order, none dropped or repeated
        Mutant("C-DOPS-004-a", targets: ["DOPS-004"],
               summary: "Music frames come out with channels 0 and 1 swapped") { base in
            FlawedMaker(base: base, flaw: .swapChannels)
        },
        Mutant("C-DOPS-004-b", targets: ["DOPS-004"],
               summary: "The last frame taken by a write that fills the stage is skipped when it comes up mid-playback") { base in
            FlawedMaker(base: base, flaw: .dropFillingFrame)
        },
        Mutant("C-DOPS-004-c", targets: ["DOPS-004"],
               summary: "Every capacityFrames-th music frame played has the lowest DSD bit of its last channel flipped") { base in
            FlawedMaker(base: base, flaw: .wrapBitFlip)
        },
        Mutant("C-DOPS-004-d", targets: ["DOPS-004"],
               summary: "After running out of music, playback resumes by replaying the last two music frames played") { base in
            FlawedMaker(base: base, flaw: .repeatPairAfterUnderrun)
        },

        // MARK: DOPS-005 — silence only where playback is held (plus at most one bridging frame)
        Mutant("C-DOPS-005-a", targets: ["DOPS-005"],
               summary: "64 silence frames precede music whenever it starts, or resumes after a hold") { base in
            FlawedMaker(base: base, flaw: .prerollOnResume(frames: 64))
        },
        Mutant("C-DOPS-005-b", targets: ["DOPS-005"],
               summary: "A marker collision is bridged with three silence frames instead of one") { base in
            FlawedMaker(base: base, flaw: .tripleBridge)
        },
        Mutant("C-DOPS-005-c", targets: ["DOPS-005"],
               summary: "When pending music cannot fill a render call, the silence goes first and the music last") { base in
            FlawedMaker(base: base, flaw: .rightAlignPartial)
        },
        Mutant("C-DOPS-005-d", targets: ["DOPS-005"],
               summary: "After unmuting, two extra silence frames go out before pending music resumes") { base in
            FlawedMaker(base: base, flaw: .gapAfterUnmute(frames: 2))
        },

        // MARK: DOPS-006 — nothing written is consumed while muted
        Mutant("C-DOPS-006-a", targets: ["DOPS-006"],
               summary: "Mute does not hold playback: music keeps being played (consumed) while muted") { base in
            FlawedMaker(base: base, flaw: .muteIgnored)
        },
        Mutant("C-DOPS-006-b", targets: ["DOPS-006"],
               summary: "setMuted(true) takes effect one render call late; that call still plays (consumes) music") { base in
            FlawedMaker(base: base, flaw: .muteOneCallLate)
        },
        Mutant("C-DOPS-006-c", targets: ["DOPS-006"],
               summary: "Mute takes effect only at the end of the write it interrupts; the rest of that write still plays") { base in
            FlawedMaker(base: base, flaw: .muteAtChunkBoundary)
        },
        // Discarded frames never come out, and once the stage is drained the caller still has unplayed music it
        // wrote, so this one also breaks DOPS-004 and DOPS-005 as written.
        Mutant("C-DOPS-006-d", targets: ["DOPS-006", "DOPS-004", "DOPS-005"],
               summary: "While muted, pending music is consumed (discarded) at the render rate") { base in
            FlawedMaker(base: base, flaw: .drainWhileMuted)
        },

        // MARK: DOPS-007 — gain and equalizer leave DoP output unchanged
        Mutant("C-DOPS-007-a", targets: ["DOPS-007", "DOPS-004"],
               summary: "A gain other than 1.0 scales the 16 DSD bits of music words as a signed sample (markers kept)") { base in
            FlawedMaker(base: base, flaw: .gainScalesMusic)
        },
        Mutant("C-DOPS-007-b", targets: ["DOPS-007", "DOPS-004"],
               summary: "With the equalizer on, the lowest DSD bit of every music word is cleared") { base in
            FlawedMaker(base: base, flaw: .eqClearsLowBit)
        },
        Mutant("C-DOPS-007-c", targets: ["DOPS-007"],
               summary: "Silence runs that start with the equalizer on use the complement (still valid) silence byte") { base in
            FlawedMaker(base: base, flaw: .eqComplementSilence)
        },
        Mutant("C-DOPS-007-d", targets: ["DOPS-007", "DOPS-004"],
               summary: "A gain of exactly 0.0 zeroes the DSD bits of music words (markers kept)") { base in
            FlawedMaker(base: base, flaw: .zeroGainZeroesMusic)
        },
        Mutant("C-DOPS-007-e", targets: ["DOPS-007"],
               summary: "Silence runs that start with a gain other than 1.0 use the complement (still valid) silence byte") { base in
            FlawedMaker(base: base, flaw: .gainComplementSilence)
        },
    ]
}

// MARK: - The flaws

private enum Flaw: Sendable, Equatable {
    case heldSilenceFixedMarker
    case noBridge
    case silencePhaseResetPerCall
    case silenceMarkerSlip(every: Int)
    case mutedNoMarker
    case underrunMarkerOnFirstChannelOnly
    case bridgeNoMarker
    case markerTypoFB
    case zeroSilence
    case lastChannelComplement
    case silenceByteFlipsPerCall
    case mutedPopcount3
    case bridgeAllOnes
    case swapChannels
    case dropFillingFrame
    case wrapBitFlip
    case repeatPairAfterUnderrun
    case prerollOnResume(frames: Int)
    case tripleBridge
    case rightAlignPartial
    case gapAfterUnmute(frames: Int)
    case drainWhileMuted
    case muteIgnored
    case muteOneCallLate
    case muteAtChunkBoundary
    case gainScalesMusic
    case eqClearsLowBit
    case eqComplementSilence
    case zeroGainZeroesMusic
    case gainComplementSilence
}

private struct FlawedMaker: DoPStageMaker {
    let base: any DoPStageMaker
    let flaw: Flaw

    func makeStage(channels: Int, capacityFrames: Int) -> any DoPStage {
        FlawedStage(base: base.makeStage(channels: channels, capacityFrames: capacityFrames), flaw: flaw,
                    channels: channels, capacityFrames: capacityFrames)
    }
}

private enum SilenceKind {
    /// Playback is held: muted, or no written music remains.
    case held
    /// The one frame a correct stage inserts before music whose marker equals the previous frame's.
    case bridge
    /// Silence a correct stage would not send (only the DOPS-005 flaws produce it).
    case extra
}

@inline(__always) private func markerOf(_ word: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: word >> 24) }

// MARK: - The decorating stage

private final class FlawedStage: DoPStage {
    private let base: any DoPStage
    private let flaw: Flaw
    private let ch: Int
    private let wrapEvery: Int
    /// The DSD silence byte (four bits set) and the first frame's marker, learned from the base.
    private let silence: UInt8
    private let firstMarker: UInt8

    // Mirror of the music the base holds: accepted, not yet pulled. Flat words, plus the frame count of each write.
    private var pend: [UInt32] = []
    private var pendHead = 0
    private var chunks: [Int] = []
    private var chunkHead = 0
    private var headChunkStarted = false
    private var acceptedTotal = 0
    private var poppedTotal = 0
    // Ordinals (counted over all accepted frames) of frames to skip at play time (C-DOPS-004-b only).
    private var victims: [Int] = []
    private var victimHead = 0
    // Frames played as music without pulling them from the base (C-DOPS-004-d only).
    private var inject: [UInt32] = []
    private var injectHead = 0

    private var muted = false
    private var gain = 1.0
    private var eq = false

    /// Marker byte (channel 0) of the last frame output; nil before the first frame.
    private var last: UInt8?
    private var lastWasSilence = false
    /// setMuted(true) was called since the last frame output.
    private var holdSinceLastFrame = false
    private var runByte: UInt8

    private var calls = 0
    private var heldSilenceCount = 0
    private var musicCount = 0

    // Flaw state.
    private var firstHeldThisCall = true
    private var wasHeld = true
    private var preroll = 0
    private var gap = 0
    private var extraBridge = 0
    private var lateMuteCalls = 0
    private var recent: [UInt32] = []
    private var underran = false
    private var rightAlign = false
    private var raInternal = 0
    private var raFirst: UInt8 = 0

    init(base: any DoPStage, flaw: Flaw, channels: Int, capacityFrames: Int) {
        self.base = base
        self.flaw = flaw
        self.ch = channels
        self.wrapEvery = max(1, capacityFrames)
        var silenceByte: UInt8 = 0x69
        var marker: UInt8 = 0x05
        if channels > 0 {
            // Nothing is written yet, so the base answers with its silence; nothing is consumed.
            let probe = base.render(frameCount: 1)
            if probe.count >= channels {
                let w = probe[0]
                let m = markerOf(w)
                if m == 0x05 || m == 0xFA { marker = m }
                let hi = UInt8(truncatingIfNeeded: w >> 16)
                let lo = UInt8(truncatingIfNeeded: w >> 8)
                var uniform = hi == lo && hi.nonzeroBitCount == 4 && w & 0xFF == 0
                for c in 0 ..< channels where probe[c] != w { uniform = false }
                if uniform { silenceByte = hi }
            }
        }
        silence = silenceByte
        firstMarker = marker
        runByte = silenceByte
    }

    // MARK: Mirror helpers

    private var pendFrames: Int { ch > 0 ? (pend.count - pendHead) / ch : 0 }
    private var hasMusic: Bool { injectHead < inject.count || pendFrames > 0 }
    private func pendMarker(_ i: Int) -> UInt8 { markerOf(pend[pendHead + i * ch]) }
    private var frontMarker: UInt8 { injectHead < inject.count ? markerOf(inject[injectHead]) : pendMarker(0) }

    private func needsBridge(_ previous: UInt8?, _ next: UInt8) -> Bool {
        if flaw == .noBridge { return false }
        return previous == next
    }

    private var effectivelyMuted: Bool {
        switch flaw {
        case .muteOneCallLate: return muted && lateMuteCalls == 0
        case .muteAtChunkBoundary: return muted && !headChunkStarted
        case .muteIgnored: return false
        default: return muted
        }
    }

    private func popPending(_ k: Int) {
        pendHead += k * ch
        poppedTotal += k
        var left = k
        while left > 0 && chunkHead < chunks.count {
            let t = min(left, chunks[chunkHead])
            chunks[chunkHead] -= t
            left -= t
            headChunkStarted = true
            if chunks[chunkHead] <= 0 {
                chunkHead += 1
                headChunkStarted = false
            }
        }
        if pendHead >= pend.count {
            pend.removeAll(keepingCapacity: true)
            pendHead = 0
        } else if pendHead > 4096 && pendHead * 2 > pend.count {
            pend.removeSubrange(0 ..< pendHead)
            pendHead = 0
        }
        if chunkHead >= chunks.count {
            chunks.removeAll(keepingCapacity: true)
            chunkHead = 0
        } else if chunkHead > 1024 && chunkHead * 2 > chunks.count {
            chunks.removeSubrange(0 ..< chunkHead)
            chunkHead = 0
        }
    }

    /// Pulls the next `k` music frames from the base (the mirror's front), skipping any bridging frame the base
    /// inserts, and pops them from the mirror.
    private func pull(_ k: Int) -> [UInt32] {
        let need = min(k, pendFrames)
        guard need > 0 else { return [] }
        var got: [UInt32] = []
        got.reserveCapacity(need * ch)
        var have = 0
        var tries = 0
        while have < need && tries < 2 * need + 8 {
            tries += 1
            let r = base.render(frameCount: min(need - have, 4096))
            var i = 0
            while i + ch <= r.count && have < need {
                let at = pendHead + have * ch
                if r[i ..< i + ch].elementsEqual(pend[at ..< at + ch]) {
                    got.append(contentsOf: r[i ..< i + ch])
                    have += 1
                }
                i += ch
            }
        }
        if have < need {
            // The base did not hand the frames back; keep the mirror authoritative.
            got.append(contentsOf: pend[(pendHead + have * ch) ..< (pendHead + need * ch)])
        }
        popPending(need)
        return got
    }

    /// Slots the pending music needs when its first frame needs no bridge (C-DOPS-005-c only), capped near `limit`.
    private func internalSlots(limit: Int) -> Int {
        var s = 1
        var previous = pendMarker(0)
        var i = 1
        let n = pendFrames
        while i < n && s <= limit {
            let m = pendMarker(i)
            s += needsBridge(previous, m) ? 2 : 1
            previous = m
            i += 1
        }
        return s
    }

    // MARK: DoPStage

    func write(frames: [UInt32]) -> Int {
        guard ch > 0 else { return base.write(frames: frames) }
        let n = base.write(frames: frames)
        let offered = frames.count / ch
        let accepted = max(0, min(n, offered))
        if accepted > 0 {
            pend.append(contentsOf: frames[0 ..< accepted * ch])
            chunks.append(accepted)
            acceptedTotal += accepted
            if flaw == .dropFillingFrame && accepted < offered { victims.append(acceptedTotal - 1) }
        }
        return n
    }

    func render(frameCount: Int) -> [UInt32] {
        guard ch > 0 else { return base.render(frameCount: frameCount) }
        guard frameCount > 0 else { return [] }
        let (total, overflow) = frameCount.multipliedReportingOverflow(by: ch)
        guard !overflow else { return [] }
        calls &+= 1
        var out: [UInt32] = []
        out.reserveCapacity(total)
        firstHeldThisCall = true
        rightAlign = false
        if flaw == .rightAlignPartial && !effectivelyMuted && injectHead >= inject.count && pendFrames > 0 {
            raFirst = pendMarker(0)
            raInternal = internalSlots(limit: frameCount)
            rightAlign = raInternal + (needsBridge(last, raFirst) ? 1 : 0) < frameCount
        }
        var produced = 0
        while produced < frameCount {
            let remaining = frameCount - produced
            if effectivelyMuted || !hasMusic {
                // Held for the rest of this call.
                if flaw == .drainWhileMuted && muted && pendFrames > 0 {
                    _ = pull(min(pendFrames, remaining))
                }
                if !effectivelyMuted {
                    gap = 0
                    if flaw == .repeatPairAfterUnderrun && recent.count == 2 * ch { underran = true }
                }
                preroll = 0
                extraBridge = 0
                wasHeld = true
                for _ in 0 ..< remaining { emitSilence(.held, into: &out) }
                produced = frameCount
                break
            }
            if underran {
                underran = false
                inject = recent
                injectHead = 0
            }
            if wasHeld {
                wasHeld = false
                if case .prerollOnResume(let k) = flaw { preroll = k }
            }
            if preroll > 0 {
                preroll -= 1
                emitSilence(.extra, into: &out)
                produced += 1
                continue
            }
            if gap > 0 {
                gap -= 1
                emitSilence(.extra, into: &out)
                produced += 1
                continue
            }
            if extraBridge > 0 {
                extraBridge -= 1
                emitSilence(.extra, into: &out)
                produced += 1
                continue
            }
            if rightAlign {
                // One more silence frame only if the pending music still fits in this call after it.
                let after: UInt8 = last == nil ? firstMarker : (last == 0x05 ? 0xFA : 0x05)
                if raInternal + (needsBridge(after, raFirst) ? 1 : 0) <= remaining - 1 {
                    emitSilence(.extra, into: &out)
                    produced += 1
                    continue
                }
                rightAlign = false
            }
            if flaw == .dropFillingFrame && injectHead >= inject.count {
                while victimHead < victims.count && victims[victimHead] < poppedTotal { victimHead += 1 }
                if victimHead < victims.count && victims[victimHead] == poppedTotal {
                    victimHead += 1
                    if victimHead > 64 && victimHead * 2 > victims.count {
                        victims.removeSubrange(0 ..< victimHead)
                        victimHead = 0
                    }
                    // Skipped only in continuous playback with more music behind it; otherwise it plays.
                    if pendFrames >= 2 && last != nil && !lastWasSilence && !holdSinceLastFrame {
                        _ = pull(1)
                        continue
                    }
                }
            }
            let front = frontMarker
            if needsBridge(last, front) {
                emitSilence(.bridge, into: &out)
                produced += 1
                if flaw == .tripleBridge { extraBridge = 2 }
                continue
            }
            if injectHead < inject.count {
                let frame = Array(inject[injectHead ..< injectHead + ch])
                injectHead += ch
                if injectHead >= inject.count {
                    inject = []
                    injectHead = 0
                }
                emitMusic(frame[...], fromBase: false, into: &out)
                produced += 1
                continue
            }
            // A run of pending frames that needs no bridge between them.
            var limit = min(remaining, pendFrames)
            if flaw == .muteAtChunkBoundary && muted && chunkHead < chunks.count {
                limit = min(limit, chunks[chunkHead])
            }
            if flaw == .dropFillingFrame && victimHead < victims.count && victims[victimHead] > poppedTotal {
                limit = min(limit, victims[victimHead] - poppedTotal)
            }
            var k = 1
            var previous = front
            while k < limit {
                let m = pendMarker(k)
                if needsBridge(previous, m) { break }
                previous = m
                k += 1
            }
            let frames = pull(k)
            var i = 0
            while i + ch <= frames.count {
                emitMusic(frames[i ..< i + ch], fromBase: true, into: &out)
                i += ch
            }
            produced += max(1, frames.count / ch)
        }
        if lateMuteCalls > 0 { lateMuteCalls -= 1 }
        if out.count != total {
            // Never expected; keep the contract's word count whatever happened.
            if out.count > total {
                out.removeSubrange(total ..< out.count)
            } else {
                while out.count < total { emitSilence(.held, into: &out) }
                if out.count > total { out.removeSubrange(total ..< out.count) }
            }
        }
        return out
    }

    func setMuted(_ m: Bool) {
        guard ch > 0 else {
            base.setMuted(m)
            return
        }
        if m {
            holdSinceLastFrame = true
        }
        if m && !muted {
            if flaw == .muteOneCallLate { lateMuteCalls = 1 }
            underran = false
        }
        if !m && muted {
            lateMuteCalls = 0
            if case .gapAfterUnmute(let k) = flaw { gap = k }
        }
        muted = m
    }

    func setGain(_ g: Double) {
        gain = g
        base.setGain(g)
    }

    func setEqualizer(_ on: Bool) {
        eq = on
        base.setEqualizer(on)
    }

    // MARK: Output

    private func emitMusic(_ frame: ArraySlice<UInt32>, fromBase: Bool, into out: inout [UInt32]) {
        let start = out.count
        out.append(contentsOf: frame)
        guard out.count == start + ch else { return }
        switch flaw {
        case .swapChannels where ch >= 2:
            out.swapAt(start, start + 1)
        case .wrapBitFlip where fromBase:
            if musicCount > 0 && musicCount % wrapEvery == 0 { out[start + ch - 1] ^= 0x100 }
        case .gainScalesMusic where gain != 1.0:
            for j in start ..< start + ch { out[j] = Self.scaled(out[j], by: gain) }
        case .eqClearsLowBit where eq:
            for j in start ..< start + ch { out[j] &= ~UInt32(0x100) }
        case .zeroGainZeroesMusic where gain == 0:
            for j in start ..< start + ch { out[j] &= 0xFF00_00FF }
        default:
            break
        }
        if fromBase { musicCount &+= 1 }
        if flaw == .repeatPairAfterUnderrun {
            recent.append(contentsOf: frame)
            if recent.count > 2 * ch { recent.removeSubrange(0 ..< (recent.count - 2 * ch)) }
        }
        last = markerOf(out[start])
        lastWasSilence = false
        holdSinceLastFrame = false
    }

    private func emitSilence(_ kind: SilenceKind, into out: inout [UInt32]) {
        var m: UInt8 = last == nil ? firstMarker : (last == 0x05 ? 0xFA : 0x05)
        switch flaw {
        case .heldSilenceFixedMarker where kind == .held:
            m = 0x05
        case .silencePhaseResetPerCall where kind == .held && firstHeldThisCall:
            m = 0x05
        case .silenceMarkerSlip(let every) where kind == .held:
            heldSilenceCount &+= 1
            if every > 0 && heldSilenceCount % every == 0, let l = last { m = l }
        case .markerTypoFB where m == 0xFA:
            m = 0xFB
        default:
            break
        }
        if kind == .held { firstHeldThisCall = false }
        if !lastWasSilence {
            // A new run of silence starts here.
            if flaw == .eqComplementSilence && eq {
                runByte = ~silence
            } else if flaw == .gainComplementSilence && gain != 1.0 {
                runByte = ~silence
            } else {
                runByte = silence
            }
        }
        var b = runByte
        switch flaw {
        case .zeroSilence:
            b = 0
        case .silenceByteFlipsPerCall:
            b = calls % 2 == 1 ? silence : ~silence
        case .mutedPopcount3 where kind == .held && muted:
            b = silence & (silence &- 1)
        case .bridgeAllOnes where kind == .bridge:
            b = 0xFF
        default:
            break
        }
        let start = out.count
        for c in 0 ..< ch {
            var mc = m
            var bc = b
            switch flaw {
            case .mutedNoMarker where kind == .held && muted:
                mc = 0
            case .underrunMarkerOnFirstChannelOnly where kind == .held && !muted && c > 0:
                mc = 0
            case .bridgeNoMarker where kind == .bridge:
                mc = 0
            case .lastChannelComplement where ch >= 2 && c == ch - 1:
                bc = ~b
            default:
                break
            }
            out.append(UInt32(mc) << 24 | UInt32(bc) << 16 | UInt32(bc) << 8)
        }
        if out.count > start { last = markerOf(out[start]) }
        lastWasSilence = true
        holdSinceLastFrame = false
    }

    /// The 16 DSD bits treated as a signed sample and scaled (C-DOPS-007-a); marker and low byte kept.
    private static func scaled(_ w: UInt32, by g: Double) -> UInt32 {
        let s = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: w >> 8)))
        let x = s * g
        let v: Int
        if x.isNaN {
            v = 0
        } else if x >= 32767 {
            v = 32767
        } else if x <= -32768 {
            v = -32768
        } else {
            v = Int(x >= 0 ? x + 0.5 : x - 0.5)  // round half away from zero, without libm
        }
        let d = UInt16(bitPattern: Int16(clamping: v))
        return (w & 0xFF00_00FF) | UInt32(d) << 8
    }
}
