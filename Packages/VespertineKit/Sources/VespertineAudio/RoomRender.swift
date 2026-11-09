//
// Vespertine: speaker groups: room render. A song played to fill the room evenly from every speaker of a group, rather than
// only at the seat the group was aligned for. Opt-in per group (`SpeakerGroup.roomRender`); off, playback is exactly as before.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What it does, in order:
//   · Stereo and mono on a group with a front pair and a surround (or back) pair: the front pair plays the song's own left and
//     right, sample for sample. The surround pair plays what is not coherent between the song's channels (its reverb and room
//     sound: `StereoUpmixer`'s ambience) and a quieter copy of the whole song, each side through its own all-pass chain, so the
//     two sides correlate neither with each other nor with the fronts. Both reach the aligned seat later than the fronts (15 and
//     18 ms by default), so by the precedence effect the image stays at the front there and at any other seat where the surrounds
//     come no more than that much closer, relative to the fronts, than at the aligned seat (15 ms is about 5 m of difference in
//     path: with the fronts at the seat and the surrounds 5 m behind, the half of the room nearer the fronts). The fill is
//     what keeps the whole song, not only its reverb, audible to a listener sitting close to the surrounds, who hears it mostly
//     from them.
//   · Surround songs (5.1, 7.1, a decoded Atmos bed): every channel goes where `PositionRouter` places it, unchanged.
//   · Bass management: below the crossover (90 Hz by default) every speaker's share is summed in mono onto the bass speakers
//     (the group's subwoofer, else the front pair, or every speaker), weighted by each speaker's level in the chain, so the bass
//     at the seat adds up to what it was. Speakers small in the bass (a pair of bookshelf rears) stop playing what they can't.
//     Linkwitz-Riley, 4th order: the two halves add back to a flat response. Several sources in phase below the room's
//     transition frequency also excite its modes less unevenly from seat to seat than one does.
//   · Placement: a speaker drawn on the wrong side for its name (a right speaker drawn left of the seat, a back speaker drawn
//     in front of it) is placed where its name says, at the drawn distance.
//   · Room correction (`roomWide`): below 200 Hz the profile's cuts keep 75 % of their depth and its boosts are left out. A room
//     mode is at the same frequency everywhere in the room, but how strong it is changes from seat to seat, and a boost into a
//     dip only fills that dip at the one seat it was measured at.
// Runs on the decode thread, never on the I/O thread. Output frame n is input frame n: a song comes out exactly as long as it
// went in.
//

import CoreAudio
import Foundation

/// How a group renders songs for the whole room. Stored on the group; nil there means off.
public struct RoomRenderSettings: Codable, Hashable, Sendable {
    /// Where the summed bass plays when the group has no subwoofer.
    public enum BassSpeakers: String, Codable, CaseIterable, Sendable {
        /// The front pair.
        case front
        /// Every ear-level speaker.
        case all
    }

    /// Level of the extracted ambience on the surrounds, dB.
    public var ambienceDB: Double
    /// Level of the decorrelated copy of the whole song on the surrounds, dB; at `fillRange.lowerBound` or below there is none.
    public var fillDB: Double
    /// How much later than the fronts the surrounds' share arrives, ms (left; the right is 3 ms more, to decorrelate the pair).
    public var surroundDelayMs: Double
    /// Bass management crossover, Hz; 0: no bass management.
    public var crossoverHz: Double
    public var bassSpeakers: BassSpeakers
    /// Below `lowCorrectionBelowHz`, the share of each room-correction cut that is kept (0…1); boosts there are left out.
    public var lowCorrectionDepth: Double
    public var lowCorrectionBelowHz: Double

    public static let ambienceRange: ClosedRange<Double> = -30...0
    public static let fillRange: ClosedRange<Double> = -40...0
    /// The ambience is never earlier than `StereoUpmixer`'s own surround delay (12 ms).
    public static let surroundDelayRange: ClosedRange<Double> = 12...30
    public static let crossoverRange: ClosedRange<Double> = 40...200
    public static let lowCorrectionRange: ClosedRange<Double> = 0...500

    public init(ambienceDB: Double = -6, fillDB: Double = -9, surroundDelayMs: Double = 15, crossoverHz: Double = 90,
                bassSpeakers: BassSpeakers = .front, lowCorrectionDepth: Double = 0.75, lowCorrectionBelowHz: Double = 200) {
        self.ambienceDB = ambienceDB
        self.fillDB = fillDB
        self.surroundDelayMs = surroundDelayMs
        self.crossoverHz = crossoverHz
        self.bassSpeakers = bassSpeakers
        self.lowCorrectionDepth = lowCorrectionDepth
        self.lowCorrectionBelowHz = lowCorrectionBelowHz
    }

    /// A field missing from a saved group takes its default, so later fields don't make older files unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RoomRenderSettings()
        ambienceDB = try c.decodeIfPresent(Double.self, forKey: .ambienceDB) ?? d.ambienceDB
        fillDB = try c.decodeIfPresent(Double.self, forKey: .fillDB) ?? d.fillDB
        surroundDelayMs = try c.decodeIfPresent(Double.self, forKey: .surroundDelayMs) ?? d.surroundDelayMs
        crossoverHz = try c.decodeIfPresent(Double.self, forKey: .crossoverHz) ?? d.crossoverHz
        bassSpeakers = (try? c.decodeIfPresent(BassSpeakers.self, forKey: .bassSpeakers)) ?? d.bassSpeakers
        lowCorrectionDepth = try c.decodeIfPresent(Double.self, forKey: .lowCorrectionDepth) ?? d.lowCorrectionDepth
        lowCorrectionBelowHz = try c.decodeIfPresent(Double.self, forKey: .lowCorrectionBelowHz) ?? d.lowCorrectionBelowHz
    }

    /// Every value held to its range; a number that isn't one takes the default.
    public var clamped: RoomRenderSettings {
        let d = RoomRenderSettings()
        func hold(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double { v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback }
        var s = self
        s.ambienceDB = hold(ambienceDB, Self.ambienceRange, d.ambienceDB)
        s.fillDB = hold(fillDB, Self.fillRange, d.fillDB)
        s.surroundDelayMs = hold(surroundDelayMs, Self.surroundDelayRange, d.surroundDelayMs)
        s.crossoverHz = crossoverHz.isFinite && crossoverHz <= 0 ? 0 : hold(crossoverHz, Self.crossoverRange, d.crossoverHz)
        s.lowCorrectionDepth = hold(lowCorrectionDepth, 0...1, d.lowCorrectionDepth)
        s.lowCorrectionBelowHz = hold(lowCorrectionBelowHz, Self.lowCorrectionRange, d.lowCorrectionBelowHz)
        return s
    }

    var ambienceGain: Float { Float(pow(10, clamped.ambienceDB / 20)) }
    var fillGain: Float { clamped.fillDB <= Self.fillRange.lowerBound ? 0 : Float(pow(10, clamped.fillDB / 20)) }
}

/// What room render does with one song on one group: worked out before playback, so the plan, the signal path and the decoder
/// agree.
public struct RoomRenderPlan: Hashable, Sendable {
    public var settings: RoomRenderSettings
    /// The group as it is routed: its speakers placed where their names say when the drawing contradicts them.
    public var group: SpeakerGroup
    /// The song's channels.
    public var source: [AudioChannelLabel]
    /// A stereo or mono song made into front and surround pairs.
    public var upmixes: Bool
    /// The channels the router places: the song's own, or (upmixed) left, right, left surround, right surround.
    public var routeLabels: [AudioChannelLabel]
    /// The speakers whose drawn place was overridden.
    public var replaced: [SpeakerRole]
    /// Each aggregate channel's level in the chain (dB, room profile and trims), for weighting the bass. Empty: all 0 dB.
    public var levelsDB: [Double] = []
}

public enum RoomRender {
    static let upmixRouteLabels: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                                                        kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]

    /// The plan for a song with channels `source` on `group`; nil when the group has room render off, or no front pair to build on.
    public static func plan(source: [AudioChannelLabel], group: SpeakerGroup) -> RoomRenderPlan? {
        guard let settings = group.roomRender?.clamped, !source.isEmpty else { return nil }
        let wired = group.aggregateChannels
        guard wired[.frontLeft] != nil, wired[.frontRight] != nil else { return nil }
        let (placed, replaced) = placement(group)
        let hasSurrounds = surroundPair(of: placed) != nil
        let roles = source.map { SpeakerRole(label: ChannelLayouts.canonical($0)) }
        let isStereo = source.count == 2 && roles.contains(.frontLeft) && roles.contains(.frontRight)
        let isMono = source.count == 1
        let upmixes = hasSurrounds && (isStereo || isMono)
        var routed = placed
        routed.stereoPolicy = .frontOnly
        return RoomRenderPlan(settings: settings, group: routed, source: source, upmixes: upmixes,
                              routeLabels: upmixes ? upmixRouteLabels : source, replaced: replaced)
    }

    /// The group's surround outputs (left, right): its back pair, else its side pair; nil without a full pair.
    static func surroundPair(of group: SpeakerGroup) -> (left: Int, right: Int)? {
        let wired = group.aggregateChannels
        if let l = wired[.backLeft], let r = wired[.backRight] { return (l, r) }
        if let l = wired[.sideLeft], let r = wired[.sideRight] { return (l, r) }
        return nil
    }

    /// `group` with each ear-level speaker drawn on the wrong side for its name moved to where the name says, and the roles moved.
    /// Wrong side: left of the seat for a right speaker (or the other way round), by more than 10°; or in front of the seat for a
    /// back speaker, behind it for a front one. A speaker on the wrong side only is mirrored across the line the listener faces
    /// along, keeping its drawn angle from the front; one that is wrong front to back goes to its name's usual angle. The distance
    /// is the drawn one (1 m when it has none).
    public static func placement(_ group: SpeakerGroup) -> (group: SpeakerGroup, replaced: [SpeakerRole]) {
        var result = group
        var replaced: [SpeakerRole] = []
        let listener = group.listener
        for (i, speaker) in group.speakers.enumerated() {
            guard !speaker.role.isHeight, speaker.role != .lfe, let usual = speaker.role.defaultAzimuth else { continue }
            let finite = speaker.position.isFinite
            let distance = finite ? SpeakerGeometry.distance(from: listener, to: speaker.position) : 0
            var angle = distance > 0 ? SpeakerGeometry.azimuth(from: listener, to: speaker.position) : usual + 360
            let drawn = angle
            // Left or right.
            if abs(usual) > 1e-9, abs(usual) < 180 - 1e-9, angle <= 180, (angle > 10 && usual < 0) || (angle < -10 && usual > 0) {
                angle = -angle
            }
            // Front or back (the sides, at ±90°, may be drawn either way).
            let front = abs(usual) < 80, back = abs(usual) > 100
            if angle > 180 || (front && abs(angle) > 100) || (back && abs(angle) < 80) { angle = usual }
            guard angle != drawn else { continue }
            let d = distance > 0 ? distance : 1
            let bearing = (angle + listener.facingDegrees) * .pi / 180
            result.speakers[i].position = Point2D(x: listener.position.x + d * sin(bearing), y: listener.position.y + d * cos(bearing))
            replaced.append(speaker.role)
        }
        return (result, replaced)
    }

    /// `room` as room render plays it: below `lowCorrectionBelowHz`, each peak or shelf cut keeps `lowCorrectionDepth` of its depth
    /// and each boost is left out; everything else (higher bands, passes, delays, levels, measured filters) is as it was.
    public static func roomWide(_ room: RoomCorrectionPlayback, settings: RoomRenderSettings) -> RoomCorrectionPlayback {
        let s = settings.clamped
        guard s.lowCorrectionBelowHz > 0 else { return room }
        var result = room
        for c in result.channels.indices {
            result.channels[c].bands = result.channels[c].bands.compactMap { band in
                guard band.kind.hasGain, band.frequency < s.lowCorrectionBelowHz else { return band }
                if band.gainDB > 0 { return nil }
                var b = band
                b.gainDB = band.gainDB * s.lowCorrectionDepth
                return b
            }
        }
        return result
    }

    /// A line for the signal path.
    public static func summary(_ plan: RoomRenderPlan) -> String {
        let s = plan.settings
        var parts: [String] = []
        if plan.upmixes {
            parts.append("ambience and a decorrelated fill on the surrounds, \(Int(s.surroundDelayMs.rounded())) ms after the fronts")
        }
        if s.crossoverHz > 0 {
            let to = plan.group.aggregateChannels[.lfe] != nil ? "the subwoofer" : s.bassSpeakers == .front ? "the front pair" : "every speaker"
            parts.append("bass below \(Int(s.crossoverHz.rounded())) Hz on \(to)")
        }
        if !plan.replaced.isEmpty {
            parts.append("placed by name: " + plan.replaced.map(\.rawValue).joined(separator: " "))
        }
        return "Room render: " + (parts.isEmpty ? "on" : parts.joined(separator: "; "))
    }
}

// MARK: The renderer

/// Room render on the decode thread: the song's frames in, the group's frames out (as wide as the group).
final class RoomRenderer {
    let plan: RoomRenderPlan
    let sourceChannels: Int
    let outputChannels: Int
    let router: PositionRouter
    private let upmixer: StereoUpmixer?
    private let fillGain: Float
    /// Source frames waiting for the upmixer's output (its fronts are the song's own samples).
    private var pending: [Float] = []
    private var upmixedScratch: [Float] = []
    private var mid: [Float] = []
    private var wide: [Float] = []
    private var ambienceLeft: RenderDelay, ambienceRight: RenderDelay
    private var fillLeft: Decorrelator, fillRight: Decorrelator
    private var bass: BassManager?

    init?(plan: RoomRenderPlan, sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0, let router = PositionRouter(source: plan.routeLabels, group: plan.group) else { return nil }
        self.plan = plan
        self.router = router
        sourceChannels = plan.source.count
        outputChannels = router.outputChannels
        let s = plan.settings.clamped
        fillGain = plan.upmixes ? s.fillGain : 0
        upmixer = plan.upmixes
            ? StereoUpmixer(inputChannels: plan.source.count, sampleRate: sampleRate,
                            settings: UpmixSettings(ambienceGain: s.ambienceGain, centreAmount: 0, lfeGain: 0)) : nil
        if plan.upmixes, upmixer == nil { return nil }
        // The upmixer holds its ambience back 12 ms (left) and 15 ms (right) already.
        let extra = Int(((s.surroundDelayMs - 12) / 1000 * sampleRate).rounded())
        ambienceLeft = RenderDelay(frames: extra)
        ambienceRight = RenderDelay(frames: extra)
        let fillFrames = Int((s.surroundDelayMs / 1000 * sampleRate).rounded()), offset = Int((0.003 * sampleRate).rounded())
        fillLeft = Decorrelator(sampleRate: sampleRate, delayFrames: fillFrames, stagesMs: [2.3, 3.7, 5.3])
        fillRight = Decorrelator(sampleRate: sampleRate, delayFrames: fillFrames + offset, stagesMs: [2.9, 4.3, 6.1])
        bass = s.crossoverHz > 0 ? BassManager(plan: plan, settings: s, outputChannels: router.outputChannels, sampleRate: sampleRate) : nil
    }

    /// Takes `frames` interleaved frames of the song and appends the group's frames now ready, interleaved, to `output`.
    func process(_ input: UnsafePointer<Float>, frames: Int, into output: inout [Float]) {
        guard frames > 0 else { return }
        if let upmixer {
            pending.append(contentsOf: UnsafeBufferPointer(start: input, count: frames * sourceChannels))
            upmixedScratch.removeAll(keepingCapacity: true)
            upmixer.process(input, frames: frames, into: &upmixedScratch)
            emitUpmixed(into: &output)
        } else {
            render(input, frames: frames, into: &output)
        }
    }

    /// Flushes what the upmixer still holds: after this, exactly as many frames have come out as went in.
    func finish(into output: inout [Float]) {
        guard let upmixer else { return }
        upmixedScratch.removeAll(keepingCapacity: true)
        upmixer.finish(into: &upmixedScratch)
        emitUpmixed(into: &output)
    }

    private func emitUpmixed(into output: inout [Float]) {
        let six = StereoUpmixer.outputChannels
        let frames = min(upmixedScratch.count / six, pending.count / sourceChannels)
        guard frames > 0 else { return }
        mid.removeAll(keepingCapacity: true)
        mid.reserveCapacity(frames * 4)
        let mono = sourceChannels == 1, half = Float(0.5.squareRoot())
        for j in 0..<frames {
            let l = mono ? pending[j] * half : pending[j * 2]
            let r = mono ? pending[j] * half : pending[j * 2 + 1]
            let ls = ambienceLeft.run(upmixedScratch[j * six + 4]) + fillGain * fillLeft.run(l)
            let rs = ambienceRight.run(upmixedScratch[j * six + 5]) + fillGain * fillRight.run(r)
            mid.append(l); mid.append(r); mid.append(ls); mid.append(rs)
        }
        pending.removeFirst(frames * sourceChannels)
        mid.withUnsafeBufferPointer { render($0.baseAddress!, frames: frames, into: &output) }
    }

    /// Routes `frames` frames of the router's channels onto the group, then runs the bass management.
    private func render(_ input: UnsafePointer<Float>, frames: Int, into output: inout [Float]) {
        let count = frames * outputChannels
        if wide.count < count { wide = [Float](repeating: 0, count: count) }
        wide.withUnsafeMutableBufferPointer { w in
            router.route(input, into: w.baseAddress!, frames: frames)
            bass?.process(w.baseAddress!, frames: frames)
            output.append(contentsOf: UnsafeBufferPointer(start: w.baseAddress!, count: count))
        }
    }
}

/// A fixed delay, sample by sample.
struct RenderDelay {
    private var buffer: [Float]
    private var index = 0
    init(frames: Int) { buffer = [Float](repeating: 0, count: max(frames, 0)) }
    mutating func run(_ x: Float) -> Float {
        guard !buffer.isEmpty else { return x }
        let y = buffer[index]
        buffer[index] = x
        index = (index + 1) % buffer.count
        return y
    }
}

/// A delay and a chain of Schroeder all-pass sections (gain 0.5): flat in level, scrambled in phase, so two of them with different
/// lengths turn one signal into two that hardly correlate.
struct Decorrelator {
    private var delay: RenderDelay
    private var stages: [(buffer: [Float], index: Int)]
    private let g: Float = 0.5

    init(sampleRate: Double, delayFrames: Int, stagesMs: [Double]) {
        delay = RenderDelay(frames: delayFrames)
        stages = stagesMs.map { ms in ([Float](repeating: 0, count: max(1, Int((ms / 1000 * sampleRate).rounded()))), 0) }
    }

    mutating func run(_ x: Float) -> Float {
        var y = delay.run(x)
        for s in stages.indices {
            let i = stages[s].index
            let old = stages[s].buffer[i]
            let v = y + g * old
            y = -g * v + old
            stages[s].buffer[i] = v
            stages[s].index = (i + 1) % stages[s].buffer.count
        }
        return y
    }
}

/// One biquad section, transposed direct form II.
struct RenderBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    /// Butterworth (Q = 1/√2) low- or high-pass at `frequency`; two in a row make a Linkwitz-Riley 4th order.
    init(highPass: Bool, frequency: Double, sampleRate: Double) {
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * 0.5.squareRoot()), c = cos(w), a0 = 1 + alpha
        if highPass { b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0 } else { b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0 }
        b2 = b0
        a1 = -2 * c / a0
        a2 = (1 - alpha) / a0
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Bass management on the group's interleaved frames: every speaker output high-passed, their low parts summed in mono (each weighted
/// by its level in the chain, so the sum is what reached the seat) and shared out among the bass speakers (each divided by its own
/// level, so it reaches the seat at its share). Linkwitz-Riley 4th order at the crossover.
final class BassManager {
    /// Outputs that are high-passed and feed the sum (every ear-level and ceiling speaker; not the subwoofer).
    let sources: [Int]
    /// Outputs that play the sum, and the gain each plays it at.
    let targets: [(output: Int, gain: Float)]
    private let weights: [Float]
    private let channels: Int
    private var highPass: [[RenderBiquad]]
    private var lowPass: [RenderBiquad]

    /// The most a bass speaker is turned up to make up for its level in the chain (+12 dB).
    static let maxMakeUp = 4.0

    init?(plan: RoomRenderPlan, settings: RoomRenderSettings, outputChannels: Int, sampleRate: Double) {
        let wired = plan.group.aggregateChannels
        let speakers = wired.filter { $0.key != .lfe && $0.value < outputChannels }
        guard !speakers.isEmpty else { return nil }
        let level: (Int) -> Double = { o in
            let db = o < plan.levelsDB.count && plan.levelsDB[o].isFinite ? plan.levelsDB[o] : 0
            return pow(10, db / 20)
        }
        let bassOutputs: [Int]
        if let sub = wired[.lfe], sub < outputChannels {
            bassOutputs = [sub]
        } else if settings.bassSpeakers == .front, let l = wired[.frontLeft], let r = wired[.frontRight] {
            bassOutputs = [l, r]
        } else {
            bassOutputs = speakers.filter { !$0.key.isHeight }.map(\.value).sorted()
        }
        guard !bassOutputs.isEmpty else { return nil }
        sources = speakers.map(\.value).sorted()
        weights = sources.map { Float(level($0)) }
        targets = bassOutputs.map { o in (o, Float(min(1 / level(o), Self.maxMakeUp) / Double(bassOutputs.count))) }
        channels = outputChannels
        let f = settings.crossoverHz
        highPass = sources.map { _ in [RenderBiquad(highPass: true, frequency: f, sampleRate: sampleRate), RenderBiquad(highPass: true, frequency: f, sampleRate: sampleRate)] }
        lowPass = [RenderBiquad(highPass: false, frequency: f, sampleRate: sampleRate), RenderBiquad(highPass: false, frequency: f, sampleRate: sampleRate)]
    }

    func process(_ frames: UnsafeMutablePointer<Float>, frames count: Int) {
        for f in 0..<count {
            let row = frames + f * channels
            var sum = 0.0
            for (i, o) in sources.enumerated() {
                let x = Double(row[o])
                sum += Double(weights[i]) * x
                row[o] = Float(highPass[i][1].run(highPass[i][0].run(x)))
            }
            let low = Float(lowPass[1].run(lowPass[0].run(sum)))
            for t in targets { row[t.output] += t.gain * low }
        }
    }
}
