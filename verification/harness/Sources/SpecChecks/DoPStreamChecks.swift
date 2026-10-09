//
// Spec-traced checks for the DoP output stream (contracts/dop-stream.md), requirement records DOPS-001 … DOPS-007.
//
// How the checks read the output
// ------------------------------
// Every music frame a check writes is unique within its scenario and can never look like DSD silence: on channel 0
// its two DSD bytes always differ (one has bit 7 set, the other clear), and those 16 bits identify the frame. The
// music a check writes to one stage is one valid DoP stream: every frame carries the same marker on every channel,
// and the markers alternate frame to frame across all of that stage's writes. (Whether a caller may also restart
// its marker sequence between two writes is left unclear by the contract, so no check relies on it.)
//
// A model of the stage follows every call: which frames were accepted (the first `n` of an offer, where `write`
// returned `n`), how many of them have come out, and whether the stage is muted. Each output frame is then either
//   - a written frame, recognised by its content (the one due next, or a dropped-ahead / repeated one), or
//   - while music waits unmuted, the frame due but altered (not silence-like and sharing DSD bits with it), or
//   - a frame carrying no music (everything else).
// For every output frame the model knows whether playback was held at that point (muted, or no written music
// left), which written frame was due, and what the previous output frame was, across render calls.
//
// Gain and equalizer (DOPS-007) are checked differentially: the same calls are made on two stages set to unity gain
// with the equalizer off, and the output must match theirs frame for frame, silence byte included. Only where the
// two unity stages themselves differ (a silence byte that varies from instance to instance, which DOPS-003 allows)
// may the silence byte differ.
// Those scenarios write music before the first render, so that every frame out is fixed by DOPS-001…006 up to
// the silence byte value, and use gains between 0 and 0.5 only, so a stage that wrongly scales samples cannot
// overflow (and trap) doing so.
//

import Contracts
import SpecKit

public enum DoPStreamChecks {
    public static let all: [SpecCheck<any DoPStageMaker>] = [

        // MARK: DOPS-001 — the marker alternates 0x05 / 0xFA from every output frame to the next

        // REQ: DOPS-001
        SpecCheck("markers alternate through music written and rendered in many sizes", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.manySizes(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate through the silence of a stage that never got music", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.noMusic(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate where music runs out and resumes after odd and even silence runs", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.underruns(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate across mute and unmute after odd and even mute lengths", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.mutes(maker, checker, ["DOPS-001"])
            DSScenarios.mutedFromStart(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate when silence went out before the first write", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.silenceFirst(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate when every render asks for one frame", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.singleFrames(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate when writes exactly keep up with renders", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.exactDrains(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate when the stage is filled until it refuses", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.fills(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate through a long mute of a full stage", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.longMuteFull(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate through repeated and redundant mute calls", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.muteToggles(maker, checker, ["DOPS-001"])
        },
        // REQ: DOPS-001
        SpecCheck("markers alternate in random sequences of writes, renders and mutes", requirements: ["DOPS-001"]) { maker, checker in
            DSScenarios.random(maker, checker, ["DOPS-001"], mutes: true)
        },

        // MARK: DOPS-002 — every output frame, on every channel, carries a valid marker

        // REQ: DOPS-002
        SpecCheck("every word has a valid marker on a stage that never got music, muted or not", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.noMusic(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every requested frame is delivered with a valid marker, for render sizes 1 to 4096", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.renderSizes(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every word has a valid marker where music runs out and resumes", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.underruns(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every word has a valid marker while muted and after unmuting", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.mutes(maker, checker, ["DOPS-002"])
            DSScenarios.mutedFromStart(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every word has a valid marker when silence went out before the first write", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.silenceFirst(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every word has a valid marker through a long mute of a full stage", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.longMuteFull(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every word has a valid marker in music written and rendered in many sizes", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.manySizes(maker, checker, ["DOPS-002"])
        },
        // REQ: DOPS-002
        SpecCheck("every word has a valid marker in random sequences of writes, renders and mutes", requirements: ["DOPS-002"]) { maker, checker in
            DSScenarios.random(maker, checker, ["DOPS-002"], mutes: true)
        },

        // MARK: DOPS-003 — frames without music carry DSD silence, one four-bits-set byte value per run

        // REQ: DOPS-003
        SpecCheck("a stage that never got music outputs DSD silence, muted or not", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.noMusic(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("frames after the music runs out, and any bridge before it resumes, are DSD silence", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.underruns(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("frames while muted, and any bridge after unmuting, are DSD silence", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.mutes(maker, checker, ["DOPS-003"])
            DSScenarios.mutedFromStart(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("silence before the first write, and any bridge into it, is DSD silence", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.silenceFirst(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("a long muted run of a full stage is DSD silence with one byte value", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.longMuteFull(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("silence runs that span render calls of one frame keep one byte value", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.singleFrames(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("silence runs spanning mute, unmute and running dry keep one byte value", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.muteToggles(maker, checker, ["DOPS-003"])
        },
        // REQ: DOPS-003
        SpecCheck("frames without music are DSD silence in random sequences of writes, renders and mutes", requirements: ["DOPS-003"]) { maker, checker in
            DSScenarios.random(maker, checker, ["DOPS-003"], mutes: true)
        },

        // MARK: DOPS-004 — written music comes out bit-identical, in order, nothing dropped or repeated

        // REQ: DOPS-004
        SpecCheck("music written and rendered in many sizes comes out bit-identical and in order", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.manySizes(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("music written into a fresh stage comes out complete for every channel count", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.freshMusic(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("every accepted frame comes out when the stage is filled until it refuses", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.fills(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("music comes out complete when every render asks for one frame", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.singleFrames(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("music comes out complete when writes exactly keep up with renders", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.exactDrains(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("music comes out complete across underruns", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.underruns(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("music written after silence comes out complete", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.silenceFirst(maker, checker, ["DOPS-004"])
        },
        // REQ: DOPS-004
        SpecCheck("music comes out complete in random sequences of writes and renders", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.random(maker, checker, ["DOPS-004"], mutes: false)
        },
        // REQ: DOPS-004
        SpecCheck("music written before and during a mute all comes out once rendered unmuted", requirements: ["DOPS-004"]) { maker, checker in
            DSScenarios.mutes(maker, checker, ["DOPS-004"])
            DSScenarios.longMuteFull(maker, checker, ["DOPS-004"])
            DSScenarios.muteToggles(maker, checker, ["DOPS-004"])
        },

        // MARK: DOPS-005 — silence only where playback is held, plus at most one bridge frame before music

        // REQ: DOPS-005
        SpecCheck("music written into a fresh stage plays from the first output frame", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.freshMusic(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("no silence while music waits, for music written and rendered in many sizes", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.manySizes(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("music resumes after running dry at once, or after one bridge frame on a marker clash", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.underruns(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("music resumes after unmuting at once, or after one bridge frame on a marker clash", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.mutes(maker, checker, ["DOPS-005"])
            DSScenarios.mutedFromStart(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("music written after silence starts at once, or after one bridge frame on a marker clash", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.silenceFirst(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("no silence while music waits when every render asks for one frame", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.singleFrames(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("no silence at all when writes exactly keep up with renders", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.exactDrains(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("no silence while music waits when the stage is filled until it refuses", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.fills(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("no silence while music waits after repeated and redundant mute calls", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.muteToggles(maker, checker, ["DOPS-005"])
            DSScenarios.longMuteFull(maker, checker, ["DOPS-005"])
        },
        // REQ: DOPS-005
        SpecCheck("silence only where held in random sequences of writes, renders and mutes", requirements: ["DOPS-005"]) { maker, checker in
            DSScenarios.random(maker, checker, ["DOPS-005"], mutes: true)
        },

        // MARK: DOPS-006 — nothing written is consumed while muted; unmuting resumes at the first unplayed frame

        // REQ: DOPS-006
        SpecCheck("nothing is consumed while muted and unmuting resumes at the first unplayed frame", requirements: ["DOPS-006"]) { maker, checker in
            DSScenarios.mutes(maker, checker, ["DOPS-006"])
        },
        // REQ: DOPS-006
        SpecCheck("a full stage muted for longer than its capacity resumes at the first unplayed frame", requirements: ["DOPS-006"]) { maker, checker in
            DSScenarios.longMuteFull(maker, checker, ["DOPS-006"])
        },
        // REQ: DOPS-006
        SpecCheck("repeated, redundant and render-free mute calls lose and replay nothing", requirements: ["DOPS-006"]) { maker, checker in
            DSScenarios.muteToggles(maker, checker, ["DOPS-006"])
        },
        // REQ: DOPS-006
        SpecCheck("a stage muted before any music outputs none of it until unmuted", requirements: ["DOPS-006"]) { maker, checker in
            DSScenarios.mutedFromStart(maker, checker, ["DOPS-006"])
        },
        // REQ: DOPS-006
        SpecCheck("mutes in random sequences consume nothing and resume at the right frame", requirements: ["DOPS-006"]) { maker, checker in
            DSScenarios.random(maker, checker, ["DOPS-006"], mutes: true)
        },

        // MARK: DOPS-007 — gain other than 1.0 or the equalizer on leaves DoP output unchanged

        // REQ: DOPS-007
        SpecCheck("a gain other than 1.0 set before the music leaves the output unchanged", requirements: ["DOPS-007"]) { maker, checker in
            DSDifferential.gainsUpFront(maker, checker)
        },
        // REQ: DOPS-007
        SpecCheck("the equalizer turned on leaves the output unchanged", requirements: ["DOPS-007"]) { maker, checker in
            DSDifferential.equalizerUpFront(maker, checker)
        },
        // REQ: DOPS-007
        SpecCheck("gain and equalizer changed mid-stream, while muted and while dry leave the output unchanged", requirements: ["DOPS-007"]) { maker, checker in
            DSDifferential.changesMidStream(maker, checker)
        },
        // REQ: DOPS-007
        SpecCheck("gain and equalizer changes in random sequences leave the output unchanged", requirements: ["DOPS-007"]) { maker, checker in
            DSDifferential.random(maker, checker)
        },
    ]
}

// MARK: - Deterministic pseudo-random numbers (SplitMix64)

fileprivate struct DSRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `lo...hi`.
    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        if hi <= lo { return lo }
        return lo + Int(next() % UInt64(hi - lo + 1))
    }

    mutating func chance(_ percent: Int) -> Bool { int(0, 99) < percent }
}

// MARK: - Formatting

fileprivate func dsHex(_ b: UInt8) -> String {
    let s = String(b, radix: 16, uppercase: true)
    return "0x" + (s.count < 2 ? "0" + s : s)
}

fileprivate func dsHexWord(_ w: UInt32) -> String {
    let s = String(w, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: max(0, 8 - s.count)) + s
}

fileprivate func dsMarkers(_ bytes: [UInt8]) -> String {
    "[" + bytes.map { dsHex($0) }.joined(separator: " ") + "]"
}

fileprivate func dsFrame(_ words: [UInt32], _ base: Int, _ channels: Int) -> String {
    var parts: [String] = []
    var c = 0
    while c < channels && base + c < words.count {
        parts.append(dsHexWord(words[base + c]))
        c += 1
    }
    return "[" + parts.joined(separator: " ") + "]"
}

/// True when the frame at `base` is DSD silence by DOPS-003's definition on its own: every DSD byte of every channel
/// has one value, and that value has four bits set.
fileprivate func dsIsSilence(_ words: [UInt32], _ base: Int, _ channels: Int) -> Bool {
    guard base >= 0, base + channels <= words.count, channels > 0 else { return false }
    let v = UInt8(truncatingIfNeeded: words[base] >> 16)
    guard v.nonzeroBitCount == 4 else { return false }
    var c = 0
    while c < channels {
        let w = words[base + c]
        if UInt8(truncatingIfNeeded: w >> 16) != v || UInt8(truncatingIfNeeded: w >> 8) != v { return false }
        c += 1
    }
    return true
}

// MARK: - The music a check writes

/// One valid DoP stream for one stage: frame `n` carries marker 0x05 or 0xFA (alternating with `n`, starting at
/// `firstMarker`) on every channel, bits 7…0 zero. Channel 0's 16 DSD bits encode a 15-bit identity of `n` with the
/// two DSD bytes always different (so no music frame is ever DSD silence); the other channels carry hashed bits.
/// Frames are unique for `n` below 32768.
fileprivate struct DSMusic {
    let channels: Int
    let salt: Int
    let firstMarker: UInt8

    func marker(_ n: Int) -> UInt8 {
        let other: UInt8 = firstMarker == 0x05 ? 0xFA : 0x05
        return n % 2 == 0 ? firstMarker : other
    }

    /// A bijection of `0..<32768`.
    func code(_ n: Int) -> Int { (n &* 0x2F35 &+ salt) & 0x7FFF }

    static func channel0Bits(_ code: Int) -> UInt32 {
        let hi = UInt32((code >> 7) & 0xFF)
        let lo = UInt32(code & 0x7F) | ((hi & 0x80) == 0 ? 0x80 : 0)
        return hi << 8 | lo
    }

    /// The identity code in a channel-0 word, or nil when the word cannot be one of this music's words.
    static func code(ofWord w: UInt32) -> Int? {
        let hi = (w >> 16) & 0xFF, lo = (w >> 8) & 0xFF
        guard (hi & 0x80) != (lo & 0x80) else { return nil }
        return Int(hi << 7 | (lo & 0x7F))
    }

    func otherBits(_ n: Int, _ c: Int) -> UInt32 {
        var z = UInt64(truncatingIfNeeded: n &* 0x2545_F491 &+ c &* 0x9E37_79B9 &+ salt)
        z = (z ^ (z >> 31)) &* 0x7FB5_D329_728E_A185
        z = (z ^ (z >> 27)) &* 0x81DA_DEF4_BC2D_D44D
        z ^= z >> 33
        return UInt32(truncatingIfNeeded: z) & 0xFFFF
    }

    func append(_ n: Int, to out: inout [UInt32]) {
        let m = UInt32(marker(n)) << 24
        out.append(m | DSMusic.channel0Bits(code(n)) << 8)
        var c = 1
        while c < channels {
            out.append(m | otherBits(n, c) << 8)
            c += 1
        }
    }
}

// MARK: - The model of one stage, and the per-frame assertions

fileprivate typealias DSMaker = any DoPStageMaker

/// Drives one fresh stage and checks every frame it outputs against the requirements it was given.
fileprivate final class DSTracker {
    static let frameLimit = 32768

    let stage: any DoPStage
    let checker: Checker
    let channels: Int
    let capacity: Int
    let name: String
    private let music: DSMusic
    private let a1: Bool, a2: Bool, a3: Bool, a4: Bool, a5: Bool, a6: Bool

    /// Accepted frames, interleaved, in the order written.
    private var written: [UInt32] = []
    private(set) var writtenFrames = 0
    /// The written frame due next; every frame before it has come out.
    private(set) var head = 0
    private var codeToIndex: [Int32]

    private(set) var muted = false
    private var muteHead = 0
    /// After unmuting: the written frame the next music frame out has to be.
    private var resumeExpected: Int?

    private(set) var outFrames = 0
    private var hasPrev = false
    private var prevMarkers: [UInt8]
    private var curMarkers: [UInt8]
    private var renderCalls = 0

    // DOPS-003: the current run of frames without music.
    private var inRun = false
    private var runValue: UInt8 = 0
    private var runStart = 0

    // DOPS-005: a silence frame that went out while music waited, allowed only right before that music.
    private var bridgeFrame: Int?
    private var bridgeCall = 0
    private var bridgeHadPrev = false
    private var bridgePrev: [UInt8]

    init(_ maker: DSMaker, _ checker: Checker, _ reqs: [String], channels: Int, capacity: Int,
         firstMarker: UInt8 = 0x05, salt: Int = 0, name: String) {
        self.checker = checker
        self.channels = channels
        self.capacity = capacity
        self.name = name
        self.music = DSMusic(channels: channels, salt: salt, firstMarker: firstMarker)
        a1 = reqs.contains("DOPS-001")
        a2 = reqs.contains("DOPS-002")
        a3 = reqs.contains("DOPS-003")
        a4 = reqs.contains("DOPS-004")
        a5 = reqs.contains("DOPS-005")
        a6 = reqs.contains("DOPS-006")
        codeToIndex = [Int32](repeating: -1, count: 32768)
        prevMarkers = [UInt8](repeating: 0, count: channels)
        curMarkers = [UInt8](repeating: 0, count: channels)
        bridgePrev = [UInt8](repeating: 0, count: channels)
        stage = maker.makeStage(channels: channels, capacityFrames: capacity)
    }

    /// Written frames not yet out.
    var pending: Int { writtenFrames - head }
    /// Frames the contract says still fit, by the model.
    var room: Int { max(0, capacity - pending) }

    private var state: String {
        if muted { return "muted, \(pending) written frame(s) waiting" }
        return pending > 0 ? "unmuted, \(pending) written frame(s) waiting" : "unmuted, no written music left"
    }

    /// Offers the next `count` frames of this stage's music; the first `n` are written when `write` returns `n`.
    @discardableResult
    func write(_ count: Int) -> Int {
        let n = min(max(0, count), DSTracker.frameLimit - writtenFrames)
        guard n > 0 else { return 0 }
        var frames: [UInt32] = []
        frames.reserveCapacity(n * channels)
        var i = 0
        while i < n {
            music.append(writtenFrames + i, to: &frames)
            i += 1
        }
        let returned = stage.write(frames: frames)
        let accepted = max(0, min(returned, n))
        if accepted > 0 {
            written.append(contentsOf: frames[0..<(accepted * channels)])
            var j = 0
            while j < accepted {
                let idx = writtenFrames + j
                codeToIndex[music.code(idx)] = Int32(idx)
                j += 1
            }
            writtenFrames += accepted
        }
        return accepted
    }

    func render(_ count: Int) {
        let k = min(max(1, count), 4096)
        renderCalls += 1
        let out = stage.render(frameCount: k)
        if a2 {
            checker.expect(out.count == k * channels, "DOPS-002",
                           "\(name): render(frameCount: \(k)) returned \(out.count) words instead of \(k) frames × \(channels) channels (\(state)); frames the device asked for went out without markers")
        }
        let frames = min(out.count / channels, k)
        var f = 0
        while f < frames {
            process(out, f * channels)
            f += 1
        }
    }

    func setMuted(_ on: Bool) {
        stage.setMuted(on)
        if on && !muted {
            muteHead = head
            resumeExpected = nil
        } else if !on && muted {
            resumeExpected = muteHead
        }
        muted = on
    }

    /// Unmutes if needed and keeps rendering until every written frame is out (at least `pending + 4` frames, then
    /// up to three more render calls of that size while any is missing), then checks that all came out (DOPS-004).
    func drain() {
        if muted { setMuted(false) }
        let target = pending + 4
        let extraSize = min(4096, max(16, target))
        var done = 0
        var extraCalls = 0
        while done < target || (head < writtenFrames && extraCalls < 3) {
            if done >= target { extraCalls += 1 }
            let k = done < target ? min(4096, target - done) : extraSize
            render(k)
            done += k
        }
        if a4 {
            checker.expect(head >= writtenFrames, "DOPS-004",
                           "\(name): after \(done) more frames rendered unmuted, \(writtenFrames - head) of \(writtenFrames) written frame(s), from frame \(head) on, never came out bit-identical")
        }
    }

    private func frameEquals(_ out: [UInt32], _ base: Int, _ index: Int) -> Bool {
        let w = index * channels
        var c = 0
        while c < channels {
            if out[base + c] != written[w + c] { return false }
            c += 1
        }
        return true
    }

    private func bridgeMessage(_ b: Int, _ t: Int, _ idx: Int) -> String {
        let before = bridgeHadPrev ? "frame \(b - 1) before it carries \(dsMarkers(bridgePrev))" : "no frame went out before it"
        if idx < 0 {
            return "\(name): output frames \(b) and \(t) both carry no music while written music waited unmuted; at most one such frame may go out, right before a music frame"
        }
        return "\(name): output frame \(b) carries no music while written music waited unmuted; the music frame after it (written frame \(idx)) has marker \(dsHex(music.marker(idx))) and \(before), so no bridge frame was allowed"
    }

    private func orderMessage(_ out: [UInt32], _ base: Int, _ t: Int, _ idx: Int, _ altered: Bool) -> String {
        if altered {
            return "\(name): output frame \(t) is \(dsFrame(out, base, channels)) where written frame \(head), \(dsFrame(written, head * channels, channels)), was due: not bit-identical"
        }
        if idx > head {
            return "\(name): output frame \(t) is written frame \(idx) but frame \(head) was due: \(idx - head) written frame(s) dropped or not bit-identical"
        }
        return "\(name): output frame \(t) repeats written frame \(idx), which already came out"
    }

    /// Every DSD byte of every channel has one value (whatever it is): the frame is meant as silence.
    private func isUniform(_ out: [UInt32], _ base: Int) -> Bool {
        let v = (out[base] >> 16) & 0xFF
        var c = 0
        while c < channels {
            let w = out[base + c]
            if (w >> 16) & 0xFF != v || (w >> 8) & 0xFF != v { return false }
            c += 1
        }
        return true
    }

    /// Some word of the output frame carries the same 16 DSD bits as some word of written frame `index`.
    private func sharesBits(_ out: [UInt32], _ base: Int, _ index: Int) -> Bool {
        guard index >= 0 && index < writtenFrames else { return false }
        let w = index * channels
        var c = 0
        while c < channels {
            let bits = (out[base + c] >> 8) & 0xFFFF
            var d = 0
            while d < channels {
                if (written[w + d] >> 8) & 0xFFFF == bits { return true }
                d += 1
            }
            c += 1
        }
        return false
    }

    private func process(_ out: [UInt32], _ base: Int) {
        let t = outFrames

        // DOPS-002 and DOPS-001: the marker of every word, and its alternation from the previous output frame.
        var valid = true
        var c = 0
        while c < channels {
            let m = UInt8(truncatingIfNeeded: out[base + c] >> 24)
            curMarkers[c] = m
            if m != 0x05 && m != 0xFA { valid = false }
            c += 1
        }
        if a2 {
            checker.expect(valid, "DOPS-002",
                           "\(name): output frame \(t) has marker bytes \(dsMarkers(curMarkers)) (\(state)); every channel needs 0x05 or 0xFA")
        }
        if a1 && hasPrev {
            var alternates = true
            c = 0
            while c < channels {
                let p = prevMarkers[c], m = curMarkers[c]
                if !((p == 0x05 && m == 0xFA) || (p == 0xFA && m == 0x05)) { alternates = false }
                c += 1
            }
            checker.expect(alternates, "DOPS-001",
                           "\(name): marker bytes \(dsMarkers(prevMarkers)) at output frame \(t - 1), then \(dsMarkers(curMarkers)) at frame \(t) (\(state)); each must alternate between 0x05 and 0xFA")
        }

        // Which written frame this is, if any.
        var idx = -1
        var altered = false
        if head < writtenFrames && frameEquals(out, base, head) {
            idx = head
        } else if let code = DSMusic.code(ofWord: out[base]) {
            let j = Int(codeToIndex[code])
            if j >= 0 && j < writtenFrames && frameEquals(out, base, j) { idx = j }
        }
        let held = muted || head >= writtenFrames
        // While music waits unmuted, a frame that is neither a written frame nor silence-like (one byte value
        // throughout) but shares DSD bits with the frame due is that frame, altered: a DOPS-004 matter only.
        if idx < 0 && !held && !isUniform(out, base) && sharesBits(out, base, head) {
            idx = head
            altered = true
        }

        // DOPS-005: a frame without music that went out while music waited unmuted (frame `b`) is allowed only as
        // the one frame right before a music frame whose marker equals that of the frame output before `b`. It is
        // judged here, at the frame after it — unless the stage was muted between the two render calls, when no
        // music could follow.
        if let b = bridgeFrame {
            bridgeFrame = nil
            let judged = !(muted && bridgeCall != renderCalls)
            if a5 && judged {
                var clash = false
                if idx >= 0 && bridgeHadPrev {
                    let m = music.marker(idx)
                    c = 0
                    while c < channels {
                        // A frame before without a valid marker (a DOPS-002 matter) leaves the need for a bridge open.
                        let p = bridgePrev[c]
                        if p == m || (p != 0x05 && p != 0xFA) { clash = true }
                        c += 1
                    }
                }
                checker.expect(clash, "DOPS-005", bridgeMessage(b, t, idx))
            }
        }
        if !held {
            if idx >= 0 {
                // Music went out while music waited unmuted: no silence here.
                if a5 { checker.expect(true, "DOPS-005", "") }
            } else {
                bridgeFrame = t
                bridgeCall = renderCalls
                bridgeHadPrev = hasPrev
                c = 0
                while c < channels {
                    bridgePrev[c] = prevMarkers[c]
                    c += 1
                }
            }
        }

        // DOPS-006: nothing written comes out while muted; the first music frame after unmuting is the right one.
        if muted {
            if a6 {
                checker.expect(idx < head, "DOPS-006",
                               "\(name): output frame \(t) is written frame \(idx), output while muted (frame \(head) was the first not yet output)")
            }
        } else if idx >= 0, let r = resumeExpected, idx >= head || !held {
            // A repeat of an old frame counts as the music resuming only when there was new music to resume with.
            if a6 {
                checker.expect(idx == r, "DOPS-006",
                               "\(name): the first music frame out after unmuting (output frame \(t)) is written frame \(idx); it should be frame \(r), the first not output before the mute")
            }
            resumeExpected = nil
        }

        // DOPS-004: written frames come out bit-identical and in order, none dropped or repeated.
        if idx >= 0 && a4 {
            checker.expect(idx == head && !altered, "DOPS-004", orderMessage(out, base, t, idx, altered))
        }

        if idx >= head {
            head = idx + 1
            inRun = false
        } else {
            // DOPS-003: no new music in this frame (silence, anything else, or a repeat).
            if !inRun {
                inRun = true
                runValue = UInt8(truncatingIfNeeded: out[base] >> 16)
                runStart = t
            }
            if a3 {
                var same = true
                c = 0
                while c < channels {
                    let w = out[base + c]
                    if UInt8(truncatingIfNeeded: w >> 16) != runValue || UInt8(truncatingIfNeeded: w >> 8) != runValue { same = false }
                    c += 1
                }
                checker.expect(same && runValue.nonzeroBitCount == 4, "DOPS-003",
                               "\(name): output frame \(t) carries no music (\(state)) and is \(dsFrame(out, base, channels)); in the run of such frames from frame \(runStart), every DSD byte on every channel must be one value with four bits set (run started with \(dsHex(runValue)))")
            }
        }

        swap(&prevMarkers, &curMarkers)
        hasPrev = true
        outFrames += 1
    }
}

// MARK: - Scenarios

fileprivate enum DSScenarios {
    static let renderSizes = [1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 63, 64, 100, 127, 128, 255, 256, 441, 511, 512,
                              1000, 1023, 1024, 2047, 2048, 3000, 4095, 4096]

    static func renderSize(_ rng: inout DSRandom) -> Int {
        rng.chance(70) ? renderSizes[rng.int(0, renderSizes.count - 1)] : rng.int(1, 4096)
    }

    static func markerName(_ m: UInt8) -> String { dsHex(m) }

    /// Writes and renders of many sizes, no mute, underruns happening where they do; then everything drained.
    static func manySizes(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        let setups: [(ch: Int, cap: Int)] = [(1, 4096), (2, 1000), (3, 8192), (4, 300), (6, 2048), (8, 5000), (2, 64), (5, 4096)]
        for (i, s) in setups.enumerated() {
            for fm: UInt8 in [0x05, 0xFA] {
                var rng = DSRandom(UInt64(1000 + i * 2 + (fm == 0x05 ? 0 : 1)))
                let t = DSTracker(maker, checker, reqs, channels: s.ch, capacity: s.cap, firstMarker: fm, salt: i * 977 + Int(fm),
                                  name: "many sizes, \(s.ch) ch, capacity \(s.cap), first marker \(markerName(fm))")
                for _ in 0..<36 {
                    if rng.chance(55) {
                        let room = t.room
                        if room > 0 { t.write(rng.int(1, min(room, rng.chance(30) ? 9 : 900))) }
                    } else {
                        t.render(renderSize(&rng))
                    }
                }
                t.drain()
            }
        }
    }

    /// Music written into a fresh stage, then rendered in one or many calls.
    static func freshMusic(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in 1...8 {
            for fm: UInt8 in [0x05, 0xFA] {
                for n in [1, 2, 3, 100] {
                    salt += 1
                    let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 256, firstMarker: fm, salt: salt * 37,
                                      name: "fresh stage, \(ch) ch, \(n) frame(s) written, first marker \(markerName(fm))")
                    t.write(n)
                    switch salt % 3 {
                    case 0: t.render(n)
                    case 1: t.render(1); t.render(4096)
                    default: t.render(4096)
                    }
                    t.drain()
                }
            }
        }
    }

    /// A stage that never gets music: unmuted, muted, unmuted again.
    static func noMusic(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        for ch in 1...8 {
            let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 1024, salt: ch, name: "no music, \(ch) ch")
            for k in [1, 2, 3, 4096, 5, 64, 1, 1, 1000, 7] { t.render(k) }
            t.setMuted(true)
            for k in [1, 3, 2048, 2] { t.render(k) }
            t.setMuted(false)
            for k in [1, 2, 513] { t.render(k) }
            let m = DSTracker(maker, checker, reqs, channels: ch, capacity: 1024, salt: ch, name: "no music, muted at once, \(ch) ch")
            m.setMuted(true)
            for k in [1, 2, 3, 4096, 77] { m.render(k) }
            m.setMuted(false)
            for k in [1, 1, 900] { m.render(k) }
        }
    }

    /// A stage muted before anything is written; music is written while muted; then unmuted.
    static func mutedFromStart(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in [1, 2, 3, 6] {
            for fm: UInt8 in [0x05, 0xFA] {
                for before in [0, 1, 2, 5] {
                    salt += 1
                    let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 512, firstMarker: fm, salt: salt * 101,
                                      name: "muted from the start, \(ch) ch, \(before) muted frame(s) before the write, first marker \(markerName(fm))")
                    t.setMuted(true)
                    if before > 0 { t.render(before) }
                    t.write(40)
                    t.render(3); t.render(4096)
                    t.write(10)
                    t.render(1)
                    t.setMuted(false)
                    t.render(1); t.render(7)
                    t.drain()
                }
            }
        }
    }

    /// Music runs out after `n` frames; `s` silence frames go out (odd and even); more music follows, continuing the
    /// stream's markers; then it runs out again with the other parity.
    static func underruns(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in [1, 2, 6] {
            for fm: UInt8 in [0x05, 0xFA] {
                for n in [1, 2, 7] {
                    for s in 0...7 {
                        salt += 1
                        let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 256, firstMarker: fm, salt: salt * 53,
                                          name: "underrun, \(ch) ch, \(n) frame(s) then \(s) dry frame(s), first marker \(markerName(fm))")
                        t.write(n)
                        if s % 2 == 0 {
                            t.render(n + s)
                        } else {
                            for _ in 0..<(n + s) { t.render(1) }
                        }
                        t.write(5)
                        t.render(1); t.render(7)
                        t.render(s + 1)
                        t.write(3)
                        t.render(2); t.render(4)
                        t.write(2)
                        t.drain()
                    }
                }
            }
        }
    }

    /// Mutes of 0…7 frames with music waiting, with music only written during the mute, with both, and after the
    /// music ran dry; then a second mute of the other parity while music plays.
    static func mutes(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in [1, 2, 4] {
            for fm: UInt8 in [0x05, 0xFA] {
                for variant in 0..<4 {
                    for s in 0...7 {
                        salt += 1
                        let before = [0, 1, 4][(s + variant) % 3]
                        let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 256, firstMarker: fm, salt: salt * 131,
                                          name: "mute variant \(variant), \(ch) ch, \(before) frame(s) before, \(s) muted frame(s), first marker \(markerName(fm))")
                        switch variant {
                        case 0, 2:
                            t.write(12)
                            if before > 0 { t.render(before) }
                        case 1:
                            if before > 0 { t.render(before) }
                        default:
                            t.write(3)
                            t.render(3 + before)
                        }
                        t.setMuted(true)
                        if s > 0 {
                            if s % 3 == 0 {
                                for _ in 0..<s { t.render(1) }
                            } else {
                                t.render(s)
                            }
                        }
                        if variant != 0 { t.write(6) }
                        t.setMuted(false)
                        t.render(1); t.render(4)
                        t.setMuted(true)
                        t.render(s + 1)
                        t.write(2)
                        t.setMuted(false)
                        t.render(2)
                        t.drain()
                    }
                }
            }
        }
    }

    /// `s` silence frames from a fresh stage, then music starting with either marker.
    static func silenceFirst(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in [1, 2, 3, 8] {
            for s in 1...7 {
                for fm: UInt8 in [0x05, 0xFA] {
                    salt += 1
                    let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 128, firstMarker: fm, salt: salt * 29,
                                      name: "silence first, \(ch) ch, \(s) dry frame(s), then music with first marker \(markerName(fm))")
                    if s % 2 == 1 {
                        t.render(s)
                    } else {
                        for _ in 0..<s { t.render(1) }
                    }
                    t.write(10)
                    t.render(1); t.render(3); t.render(10)
                    t.write(4)
                    t.render(4)
                    t.write(9)
                    t.drain()
                }
            }
        }
    }

    /// Every render asks for one frame; small writes now and then, so the music runs dry and resumes often.
    static func singleFrames(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        for (i, ch) in [1, 2, 6].enumerated() {
            for fm: UInt8 in [0x05, 0xFA] {
                var rng = DSRandom(UInt64(300 + i * 2 + (fm == 0x05 ? 0 : 1)))
                let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 64, firstMarker: fm, salt: i * 17 + Int(fm),
                                  name: "one-frame renders, \(ch) ch, first marker \(markerName(fm))")
                t.write(20)
                for _ in 0..<400 {
                    if rng.chance(25) && t.pending < 56 { t.write(rng.int(1, 4)) }
                    t.render(1)
                }
                var guardCount = 0
                while t.pending > 0 && guardCount < 80 {
                    t.render(1)
                    guardCount += 1
                }
                t.drain()
            }
        }
    }

    /// Each render asks for exactly the frames written before it, so the music never waits and never runs dry
    /// until the end.
    static func exactDrains(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in [1, 2, 4] {
            for fm: UInt8 in [0x05, 0xFA] {
                for n in [1, 2, 5, 64] {
                    salt += 1
                    let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 512, firstMarker: fm, salt: salt * 71,
                                      name: "exact drains, \(ch) ch, writes of \(n)+, first marker \(markerName(fm))")
                    for round in 0..<6 {
                        let k = n + round
                        t.write(k)
                        if round % 2 == 0 || k < 2 {
                            t.render(k)
                        } else {
                            t.render(k / 2)
                            t.render(k - k / 2)
                        }
                    }
                    t.render(3)
                    t.write(n)
                    t.drain()
                }
            }
        }
    }

    /// The stage is filled until `write` returns 0 (offers larger and smaller than the capacity), partly or fully
    /// rendered, filled again, and so on.
    static func fills(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        let setups: [(ch: Int, cap: Int)] = [(1, 1), (2, 2), (1, 3), (2, 17), (6, 256), (2, 1000), (8, 2048), (1, 4096)]
        for (i, s) in setups.enumerated() {
            var rng = DSRandom(UInt64(500 + i))
            let fm: UInt8 = i % 2 == 0 ? 0x05 : 0xFA
            let t = DSTracker(maker, checker, reqs, channels: s.ch, capacity: s.cap, firstMarker: fm, salt: i * 31,
                              name: "fill until refused, \(s.ch) ch, capacity \(s.cap)")
            for round in 0..<5 {
                var tries = 0
                while tries < 8 {
                    tries += 1
                    let offer = rng.chance(50) ? s.cap + rng.int(1, 9) : max(1, s.cap / 3 + rng.int(0, 2))
                    if t.write(offer) == 0 { break }
                }
                var left = round % 2 == 0 ? max(1, s.cap / 2) : s.cap + 3
                while left > 0 {
                    let k = min(left, renderSize(&rng))
                    t.render(k)
                    left -= k
                }
            }
            t.drain()
        }
    }

    /// A full stage muted for more than three times its capacity, offered more music while muted, then unmuted.
    static func longMuteFull(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        let setups: [(ch: Int, cap: Int)] = [(1, 16), (2, 1000), (6, 64), (3, 1)]
        for (i, s) in setups.enumerated() {
            let fm: UInt8 = i % 2 == 0 ? 0xFA : 0x05
            let t = DSTracker(maker, checker, reqs, channels: s.ch, capacity: s.cap, firstMarker: fm, salt: i * 211,
                              name: "long mute of a full stage, \(s.ch) ch, capacity \(s.cap)")
            var tries = 0
            while tries < 6 {
                tries += 1
                if t.write(s.cap) == 0 { break }
            }
            t.render(min(5, max(1, s.cap / 2)))
            t.setMuted(true)
            let mutedFrames = 3 * s.cap + 10
            var done = 0
            while done < mutedFrames {
                let k = min(4096, mutedFrames - done)
                t.render(k)
                done += k
            }
            t.write(s.cap)
            t.render(7)
            t.setMuted(false)
            t.render(s.cap / 2 + 1)
            t.write(10)
            t.drain()
        }
    }

    /// Mute and unmute with and without renders in between, redundant calls, a long mute with nothing waiting.
    static func muteToggles(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        var salt = 0
        for ch in [1, 2, 3] {
            for fm: UInt8 in [0x05, 0xFA] {
                salt += 1
                let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 256, firstMarker: fm, salt: salt * 997,
                                  name: "mute toggles, \(ch) ch, first marker \(markerName(fm))")
                t.write(40)
                t.render(3)
                t.setMuted(true); t.setMuted(false)
                t.render(2)
                t.setMuted(true); t.setMuted(true)
                t.render(3)
                t.setMuted(false); t.setMuted(false)
                t.render(2)
                t.setMuted(true); t.render(1); t.setMuted(false)
                t.setMuted(true); t.render(2); t.setMuted(false)
                t.render(1)
                t.setMuted(false)
                t.render(4096)            // runs dry
                t.setMuted(true)
                t.render(5)
                t.setMuted(false)
                t.render(2)               // dry, unmuted
                t.write(5)
                t.setMuted(true); t.render(4096); t.setMuted(false)
                t.render(1)
                t.setMuted(true); t.setMuted(false); t.setMuted(true)
                t.render(1)
                t.write(3)
                t.setMuted(false)
                t.drain()
            }
        }
    }

    /// Long random sequences of writes (within capacity), renders and, optionally, mute changes.
    static func random(_ maker: DSMaker, _ checker: Checker, _ reqs: [String], mutes: Bool) {
        let setups: [(ch: Int, cap: Int)] = [(1, 512), (2, 2048), (3, 100), (6, 1024), (2, 4096), (8, 300)]
        for (i, s) in setups.enumerated() {
            var rng = DSRandom(UInt64(9000 + i * 17 + (mutes ? 1 : 0)))
            let fm: UInt8 = rng.chance(50) ? 0x05 : 0xFA
            let t = DSTracker(maker, checker, reqs, channels: s.ch, capacity: s.cap, firstMarker: fm, salt: i * 7919,
                              name: "random sequence \(i), \(s.ch) ch, capacity \(s.cap)\(mutes ? ", with mutes" : "")")
            for _ in 0..<70 {
                let r = rng.int(0, 99)
                if r < 42 {
                    let room = t.room
                    if room > 0 { t.write(rng.int(1, min(room, rng.chance(50) ? 6 : 700))) }
                } else if r < 87 || !mutes {
                    t.render(rng.chance(35) ? rng.int(1, 6) : renderSize(&rng))
                } else {
                    t.setMuted(rng.chance(80) ? !t.muted : t.muted)
                }
            }
            t.drain()
        }
    }

    /// Render sizes 1…24 and large ones, with no music, music waiting, music running out part way, and muted.
    static func renderSizes(_ maker: DSMaker, _ checker: Checker, _ reqs: [String]) {
        for (i, ch) in [1, 2, 3, 8].enumerated() {
            let t = DSTracker(maker, checker, reqs, channels: ch, capacity: 4096, salt: i, name: "render sizes, \(ch) ch")
            for k in 1...24 { t.render(k) }
            t.write(3000)
            for k in [1, 2, 3, 5, 8, 13, 100, 1000] { t.render(k) }
            t.render(4096)
            t.setMuted(true)
            for k in [1, 7, 4096, 4095] { t.render(k) }
            t.write(50)
            t.render(33)
            t.setMuted(false)
            t.render(2048)
            t.render(4096)
        }
    }
}

// MARK: - DOPS-007: differential runs against a stage at unity gain with the equalizer off

fileprivate enum DSOp {
    case write(Int)
    case render(Int)
    case mute(Bool)
    case gain(Double)
    case equalizer(Bool)
}

fileprivate enum DSDifferential {
    /// Gains below or at 0.5 only, so that a stage which wrongly scales samples cannot overflow doing so.
    static let gains: [Double] = [0.0, 0.5, 0.25, 0.1, 0.01, 0.3]

    /// Runs `ops` on a fresh stage and returns what each render call returned. With `controls` false, gain and
    /// equalizer calls are left out and the stage is set to unity gain with the equalizer off first.
    static func run(_ maker: DSMaker, channels: Int, capacity: Int, music: DSMusic, ops: [DSOp], controls: Bool) -> [[UInt32]] {
        let stage = maker.makeStage(channels: channels, capacityFrames: capacity)
        if !controls {
            stage.setGain(1.0)
            stage.setEqualizer(false)
        }
        var outs: [[UInt32]] = []
        var next = 0
        for op in ops {
            switch op {
            case .write(let count):
                let n = min(max(0, count), DSTracker.frameLimit - next)
                if n == 0 { continue }
                var frames: [UInt32] = []
                frames.reserveCapacity(n * channels)
                var i = 0
                while i < n {
                    music.append(next + i, to: &frames)
                    i += 1
                }
                next += max(0, min(stage.write(frames: frames), n))
            case .render(let k):
                outs.append(stage.render(frameCount: min(max(1, k), 4096)))
            case .mute(let on):
                stage.setMuted(on)
            case .gain(let g):
                if controls { stage.setGain(g) }
            case .equalizer(let on):
                if controls { stage.setEqualizer(on) }
            }
        }
        return outs
    }

    static func equalFrames(_ r: [UInt32], _ g: [UInt32], _ base: Int, _ channels: Int) -> Bool {
        var c = 0
        while c < channels {
            if r[base + c] != g[base + c] { return false }
            c += 1
        }
        return true
    }

    /// Equal frames, or two DSD silence frames that differ only in the silence byte value. Used only where two
    /// stages at unity gain with the equalizer off, given the same calls, did not agree on that frame themselves.
    static func sameUpToSilenceByte(_ r: [UInt32], _ g: [UInt32], _ base: Int, _ channels: Int) -> Bool {
        if equalFrames(r, g, base, channels) { return true }
        guard dsIsSilence(r, base, channels), dsIsSilence(g, base, channels) else { return false }
        var c = 0
        while c < channels {
            if r[base + c] & 0xFF00_00FF != g[base + c] & 0xFF00_00FF { return false }
            c += 1
        }
        return true
    }

    /// The tested stage gets the gain and equalizer calls; two fresh stages at unity gain with the equalizer off get
    /// the same other calls. Wherever those two agree on a frame — which is everywhere for a stage whose output
    /// depends only on the calls made — the tested stage must send exactly that frame, silence byte included. Only
    /// where they disagree (a stage whose silence byte varies from instance to instance, as DOPS-003 permits) is the
    /// silence byte left free.
    static func check(_ maker: DSMaker, _ checker: Checker, name: String, channels: Int, firstMarker: UInt8, salt: Int, ops: [DSOp]) {
        let capacity = 8192
        let music = DSMusic(channels: channels, salt: salt, firstMarker: firstMarker)
        let reference = run(maker, channels: channels, capacity: capacity, music: music, ops: ops, controls: false)
        let again = run(maker, channels: channels, capacity: capacity, music: music, ops: ops, controls: false)
        let tested = run(maker, channels: channels, capacity: capacity, music: music, ops: ops, controls: true)
        checker.expect(reference.count == tested.count, "DOPS-007", "\(name): \(tested.count) render results against \(reference.count)")
        var frameBase = 0
        for call in 0..<min(reference.count, tested.count) {
            let r = reference[call], g = tested[call]
            if r.count != g.count {
                checker.expect(false, "DOPS-007",
                          "\(name): render call \(call) returned \(g.count) words, but \(r.count) at unity gain with the equalizer off")
                frameBase += r.count / channels
                continue
            }
            let r2: [UInt32]? = call < again.count && again[call].count == r.count ? again[call] : nil
            let frames = r.count / channels
            var f = 0
            while f < frames {
                let b = f * channels
                let reproducible = r2.map { equalFrames(r, $0, b, channels) } ?? false
                let same = reproducible ? equalFrames(r, g, b, channels) : sameUpToSilenceByte(r, g, b, channels)
                checker.expect(same, "DOPS-007",
                          "\(name): output frame \(frameBase + f) is \(dsFrame(g, b, channels)), but \(dsFrame(r, b, channels)) at unity gain with the equalizer off\(reproducible ? " (the same in two stages at unity gain)" : "")")
                f += 1
            }
            var w = frames * channels
            while w < r.count {
                checker.expect(r[w] == g[w], "DOPS-007", "\(name): word \(w) of render call \(call) differs from unity gain with the equalizer off")
                w += 1
            }
            frameBase += frames
        }
    }

    /// Music first (so the first frame out is music), running dry, resuming, a mute with music waiting and with
    /// music written during it, resuming again, running dry again.
    static func body(_ prefix: [DSOp]) -> [DSOp] {
        prefix + [
            .write(600), .render(1), .render(255), .render(512),
            .write(300), .render(1000),
            .write(5), .render(3), .render(2), .render(1),
            .write(30), .render(4),
            .mute(true), .render(9), .write(40), .render(2), .mute(false),
            .render(1), .render(64), .render(4096),
        ]
    }

    static func gainsUpFront(_ maker: DSMaker, _ checker: Checker) {
        var salt = 0
        for g in gains {
            for ch in [1, 2, 6] {
                salt += 1
                let fm: UInt8 = salt % 2 == 0 ? 0x05 : 0xFA
                check(maker, checker, name: "gain \(g) from the start, \(ch) ch", channels: ch, firstMarker: fm, salt: salt * 13,
                      ops: body([.gain(g)]))
            }
        }
    }

    static func equalizerUpFront(_ maker: DSMaker, _ checker: Checker) {
        let prefixes: [(String, [DSOp])] = [
            ("equalizer on", [.equalizer(true)]),
            ("equalizer on, gain 0.5", [.equalizer(true), .gain(0.5)]),
            ("gain 1.0, equalizer on", [.gain(1.0), .equalizer(true)]),
            ("equalizer on twice", [.equalizer(true), .equalizer(true)]),
        ]
        var salt = 0
        for (label, prefix) in prefixes {
            for ch in [1, 2, 6] {
                salt += 1
                let fm: UInt8 = salt % 2 == 0 ? 0x05 : 0xFA
                check(maker, checker, name: "\(label) from the start, \(ch) ch", channels: ch, firstMarker: fm, salt: salt * 19,
                      ops: body(prefix))
            }
        }
    }

    static func changesMidStream(_ maker: DSMaker, _ checker: Checker) {
        let ops: [DSOp] = [
            .write(800), .render(100),
            .gain(0.5), .render(100),
            .equalizer(true), .render(77),
            .gain(0.0), .render(1),
            .mute(true), .render(9), .equalizer(false), .gain(0.25), .render(3), .mute(false),
            .render(300), .render(1000),          // runs dry
            .gain(0.1), .render(5), .equalizer(true), .render(2),
            .write(50), .render(1), .render(1), .render(1),
            .gain(1.0), .render(10),
            .equalizer(false), .gain(0.3), .render(20),
            .mute(true), .equalizer(true), .write(64), .render(2048), .mute(false),
            .gain(0.01), .render(1), .render(4096),
        ]
        var salt = 0
        for ch in [1, 2, 3, 6, 8] {
            for fm: UInt8 in [0x05, 0xFA] {
                salt += 1
                check(maker, checker, name: "gain and equalizer changed mid-stream, \(ch) ch, first marker \(dsHex(fm))",
                      channels: ch, firstMarker: fm, salt: salt * 23, ops: ops)
            }
        }
    }

    static func random(_ maker: DSMaker, _ checker: Checker) {
        let choices: [Double] = gains + [1.0]
        for (i, ch) in [1, 2, 4, 6].enumerated() {
            for seed in 0..<2 {
                var rng = DSRandom(UInt64(4242 + i * 10 + seed))
                var ops: [DSOp] = []
                if rng.chance(50) { ops.append(.gain(choices[rng.int(0, choices.count - 1)])) }
                if rng.chance(50) { ops.append(.equalizer(true)) }
                ops.append(.write(rng.int(1, 400)))
                ops.append(.render(rng.int(1, 64)))
                var written = 0
                var muted = false
                var eq = false
                for _ in 0..<60 {
                    let r = rng.int(0, 99)
                    if r < 30 {
                        if written < 24_000 {
                            let n = rng.int(1, 300)
                            ops.append(.write(n))
                            written += n
                        }
                    } else if r < 70 {
                        ops.append(.render(rng.chance(40) ? rng.int(1, 8) : DSScenarios.renderSize(&rng)))
                    } else if r < 80 {
                        ops.append(.gain(choices[rng.int(0, choices.count - 1)]))
                    } else if r < 90 {
                        eq.toggle()
                        ops.append(.equalizer(eq))
                    } else {
                        muted.toggle()
                        ops.append(.mute(muted))
                    }
                }
                if muted { ops.append(.mute(false)) }
                ops.append(.render(4096))
                check(maker, checker, name: "random gain and equalizer changes \(seed), \(ch) ch",
                      channels: ch, firstMarker: seed == 0 ? 0x05 : 0xFA, salt: i * 41 + seed, ops: ops)
            }
        }
    }
}
