//
// Vespertine: speaker groups: room render. A song played to fill the room evenly from every speaker of a group, rather than
// only at the seat the group was aligned for. Opt-in per group (`SpeakerGroup.roomRender`); off, playback is exactly as before.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What it does, in order:
//   · The fill: every speaker plays the whole song. What a speaker would not play by the routing below (the other speakers'
//     channels of its side of the room: a back speaker has the front one's, a front speaker the surround one's, each has the
//     centre's) it plays as a fill (`fillTaps`), 3 dB down by default, through its own all-pass chain and later than the routed
//     sound (15 ms on the left, 18 on the right). So a listener next to any one speaker hears the song, and a film's dialogue,
//     not only that speaker's channel; and at the aligned seat the image stays where it was, by the precedence effect, at any
//     seat where the fill comes no more than that much closer than at the aligned one. A speaker never plays a channel twice.
//   · Stereo and mono on a group with a front pair and a surround (or back) pair: the front pair plays the song's own left and
//     right, sample for sample. The surround pair adds what is not coherent between the song's channels (its reverb and room
//     sound: `StereoUpmixer`'s ambience) to its fill.
//   · Surround songs (5.1, 7.1, a decoded Atmos bed): every channel goes where `PositionRouter` places it, unchanged, and the
//     fill is added.
//   · Bass management: below the crossover (90 Hz by default) every speaker's share of the routed sound is summed in mono onto
//     the bass speakers (the group's subwoofer, else the front pair, or every speaker), weighted by each speaker's level in the
//     chain, so the bass at the seat adds up to what it was. Speakers small in the bass (a pair of bookshelf rears) stop playing
//     what they can't. Linkwitz-Riley, 4th order: the two halves add back to a flat response. The fill has no bass (the same
//     high-pass): a late copy of the bass would cancel it at some frequencies.
//   · Placement: a speaker drawn on the wrong side for its name (a right speaker drawn left of the seat, a back speaker drawn
//     in front of it) is placed where its name says, at the drawn distance.
//   · A limiter per speaker (`RenderLimiter`), because a fill added to a channel can pass full scale: 1.5 ms of look-ahead, and
//     it leaves a speaker's samples exactly as they are until that speaker would clip (at its level in the chain).
//   · Room correction (`roomWide`): below 200 Hz the profile's cuts keep 75 % of their depth and its boosts are left out. A room
//     mode is at the same frequency everywhere in the room, but how strong it is changes from seat to seat, and a boost into a
//     dip only fills that dip at the one seat it was measured at.
//   · Two styles (`RoomRenderSettings.Style`). Stage in front is all of the above. Even everywhere is for a room with no seat
//     that matters more than the rest: the fill is at the routed sound's own level and in time with it, with no all-pass and no
//     ambience, so each speaker of a side plays the same thing. Bass management, placement and the limiter are the same.
// What it can't do: four speakers can't make every seat the best seat. The image a stereo pair draws exists only between its
// two speakers; elsewhere a listener hears the nearer speakers first. The fill makes sure that what they hear is the whole song.
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

    /// What the group is filled for.
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// The seat keeps its stage in front: the fill is quieter (`fillDB`), later and decorrelated, and a stereo song's ambience
        /// goes to the surrounds.
        case frontLed
        /// No seat comes first: the fill plays at the routed sound's level, in time with it and as it is.
        case even
    }

    /// Level of the extracted ambience on the surrounds, dB.
    public var ambienceDB: Double
    /// Level of the fill (the rest of the song on each speaker, decorrelated and late), dB; at `fillRange.lowerBound` or below
    /// there is none.
    public var fillDB: Double
    /// How much later than the fronts the surrounds' share arrives, ms (left; the right is 3 ms more, to decorrelate the pair).
    public var surroundDelayMs: Double
    /// Bass management crossover, Hz; 0: no bass management.
    public var crossoverHz: Double
    public var bassSpeakers: BassSpeakers
    /// Below `lowCorrectionBelowHz`, the share of each room-correction cut that is kept (0…1); boosts there are left out.
    public var lowCorrectionDepth: Double
    public var lowCorrectionBelowHz: Double
    public var style: Style
    /// Which defaults these settings were saved under (`currentRevision`); a file without it is from revision 1.
    public var revision = RoomRenderSettings.currentRevision

    /// 2: the fill is the whole song on every speaker at -3 dB (it was a -9 dB copy on the surround pair only, which nobody
    /// could hear at the seat).
    public static let currentRevision = 2
    static let revisionOneFillDB = -9.0

    public static let ambienceRange: ClosedRange<Double> = -30...0
    public static let fillRange: ClosedRange<Double> = -40...0
    /// The ambience is never earlier than `StereoUpmixer`'s own surround delay (12 ms).
    public static let surroundDelayRange: ClosedRange<Double> = 12...30
    public static let crossoverRange: ClosedRange<Double> = 40...200
    public static let lowCorrectionRange: ClosedRange<Double> = 0...500

    public init(ambienceDB: Double = -6, fillDB: Double = -3, surroundDelayMs: Double = 15, crossoverHz: Double = 90,
                bassSpeakers: BassSpeakers = .front, lowCorrectionDepth: Double = 0.75, lowCorrectionBelowHz: Double = 200,
                style: Style = .frontLed) {
        self.ambienceDB = ambienceDB
        self.fillDB = fillDB
        self.surroundDelayMs = surroundDelayMs
        self.crossoverHz = crossoverHz
        self.bassSpeakers = bassSpeakers
        self.lowCorrectionDepth = lowCorrectionDepth
        self.lowCorrectionBelowHz = lowCorrectionBelowHz
        self.style = style
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
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? d.style
        // The switch never had a control for the fill: a group saved with the old default takes the new one.
        let saved = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        if saved < 2, fillDB == Self.revisionOneFillDB { fillDB = d.fillDB }
        revision = Self.currentRevision
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
    /// The fill's gain: the routed sound's own level when the room is filled evenly, else `fillDB`.
    var fillGain: Float { style == .even ? 1 : clamped.fillDB <= Self.fillRange.lowerBound ? 0 : Float(pow(10, clamped.fillDB / 20)) }
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
        let upmixes = hasSurrounds && (isStereo || isMono) && settings.style == .frontLed
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

    // MARK: The fill

    /// Which side of a song a speaker or a channel is on.
    enum Side { case left, right, centre }

    /// By its name (the drawing may contradict it: `placement`). nil for the subwoofer.
    static func side(of role: SpeakerRole) -> Side? {
        guard role != .lfe, let angle = role.defaultAzimuth else { return nil }
        if abs(angle) < 1e-9 || abs(abs(angle) - 180) < 1e-9 { return .centre }
        return angle < 0 ? .left : .right
    }

    /// How much of a channel belongs on a speaker of `side` when that speaker is to play the whole song: the stereo fold of
    /// ITU-R BS.775 (a front channel at 1, the centre and the surrounds at -3 dB, nothing of the other side), and for a centre
    /// speaker half of each side.
    static func share(of channel: SpeakerRole, on side: Side) -> Float {
        guard let from = Self.side(of: channel) else { return 0 }
        let level: Float = channel == .frontLeft || channel == .frontRight ? 1 : PositionRouter.foldGain
        switch (from, side) {
        case (.left, .left), (.right, .right), (.centre, .left), (.centre, .right): return level
        case (.centre, .centre): return 1
        case (.left, .centre), (.right, .centre): return level / 2
        case (.left, .right), (.right, .left): return 0
        }
    }

    /// The fill, before its level: for each of the group's outputs, the channels (indices into `labels`) it is to play besides
    /// what it plays already, and their gains. `direct(output, channel)`: how much of that channel the output plays already; a
    /// channel it has is never added again (two copies of one signal on one speaker, one late, would comb). The subwoofer gets
    /// no fill.
    static func fillTaps(labels: [AudioChannelLabel], group: SpeakerGroup, direct: (_ output: Int, _ channel: Int) -> Float) -> [[PositionRouter.Tap]] {
        let roles = ChannelLayouts.normalizedSurrounds(labels).map { SpeakerRole(label: $0) }
        var result = [[PositionRouter.Tap]](repeating: [], count: max(group.totalChannels, 0))
        for (role, output) in group.aggregateChannels where output < result.count {
            guard let side = side(of: role) else { continue }
            for (channel, from) in roles.enumerated() {
                guard let from, direct(output, channel) <= 0.01 else { continue }
                let gain = share(of: from, on: side)
                if gain > 0 { result[output].append(PositionRouter.Tap(source: channel, gain: gain)) }
            }
        }
        return result
    }

    /// The fill for channels routed by `router` as they are (Mac Sound Output's matrix).
    public static func fillTaps(labels: [AudioChannelLabel], router: PositionRouter, group: SpeakerGroup) -> [[PositionRouter.Tap]] {
        fillTaps(labels: labels, group: group) { output, channel in
            router.matrixRow(output).reduce(Float(0)) { $1.source == channel ? $0 + abs($1.gain) : $0 }
        }
    }

    /// The fill for a song played by `plan`, in the song's own channels. `router`: the plan's router (of `plan.routeLabels`).
    /// Upmixed, its first two channels are the song's left and right (both the one channel of a mono song); the ambience it
    /// routes besides is not the song's.
    static func fillTaps(for plan: RoomRenderPlan, router: PositionRouter) -> [[PositionRouter.Tap]] {
        guard plan.upmixes else { return fillTaps(labels: plan.source, router: router, group: plan.group) }
        let mono = plan.source.count == 1
        return fillTaps(labels: plan.source, group: plan.group) { output, channel in
            router.matrixRow(output).reduce(Float(0)) { $1.source < 2 && (mono ? 0 : $1.source) == channel ? $0 + abs($1.gain) : $0 }
        }
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
        if s.style == .even {
            parts.append("the whole song on every speaker, at one level and at one time")
        } else if s.fillGain > 0 {
            parts.append("the whole song on every speaker (the fill \(Int(-s.fillDB.rounded())) dB down, \(Int(s.surroundDelayMs.rounded())) ms late)")
        }
        if plan.upmixes { parts.append("ambience on the surrounds") }
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
    private var fills: [FillVoice] = []
    private var bass: BassManager?
    private var limiter: RenderLimiter

    init?(plan: RoomRenderPlan, sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0, let router = PositionRouter(source: plan.routeLabels, group: plan.group) else { return nil }
        self.plan = plan
        self.router = router
        sourceChannels = plan.source.count
        outputChannels = router.outputChannels
        let s = plan.settings.clamped
        fillGain = s.fillGain
        upmixer = plan.upmixes
            ? StereoUpmixer(inputChannels: plan.source.count, sampleRate: sampleRate,
                            settings: UpmixSettings(ambienceGain: s.ambienceGain, centreAmount: 0, lfeGain: 0)) : nil
        if plan.upmixes, upmixer == nil { return nil }
        // The upmixer holds its ambience back 12 ms (left) and 15 ms (right) already.
        let extra = Int(((s.surroundDelayMs - 12) / 1000 * sampleRate).rounded())
        ambienceLeft = RenderDelay(frames: extra)
        ambienceRight = RenderDelay(frames: extra)
        if fillGain > 0 {
            fills = FillVoice.bank(taps: RoomRender.fillTaps(for: plan, router: router), group: plan.group, settings: s, sampleRate: sampleRate)
        }
        bass = s.crossoverHz > 0 ? BassManager(plan: plan, settings: s, outputChannels: router.outputChannels, sampleRate: sampleRate) : nil
        // Full scale for a speaker is where its DAC clips: one turned down later in the chain (a trim, a room profile's level) may
        // be driven that much harder here, which is what the bass management does to make up for it.
        limiter = RenderLimiter(channels: router.outputChannels, sampleRate: sampleRate, thresholds: (0..<router.outputChannels).map { o in
            let dB = o < plan.levelsDB.count && plan.levelsDB[o].isFinite ? plan.levelsDB[o] : 0
            return Float(pow(10, max(-dB, 0) / 20))
        })
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
            render(input, song: input, frames: frames, into: &output)
        }
    }

    /// Flushes what the upmixer and the limiter still hold: after this, exactly as many frames have come out as went in.
    func finish(into output: inout [Float]) {
        if let upmixer {
            upmixedScratch.removeAll(keepingCapacity: true)
            upmixer.finish(into: &upmixedScratch)
            emitUpmixed(into: &output)
        }
        limiter.finish(into: &output)
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
            mid.append(l); mid.append(r)
            mid.append(ambienceLeft.run(upmixedScratch[j * six + 4])); mid.append(ambienceRight.run(upmixedScratch[j * six + 5]))
        }
        mid.withUnsafeBufferPointer { routed in
            pending.withUnsafeBufferPointer { song in render(routed.baseAddress!, song: song.baseAddress!, frames: frames, into: &output) }
        }
        pending.removeFirst(frames * sourceChannels)
    }

    /// Routes `frames` frames of the router's channels onto the group, runs the bass management, adds the fill (made of the
    /// song's own channels, `song`) and limits.
    private func render(_ input: UnsafePointer<Float>, song: UnsafePointer<Float>, frames: Int, into output: inout [Float]) {
        let count = frames * outputChannels
        if wide.count < count { wide = [Float](repeating: 0, count: count) }
        wide.withUnsafeMutableBufferPointer { w in
            let out = w.baseAddress!
            router.route(input, into: out, frames: frames)
            bass?.process(out, frames: frames)
            for v in fills.indices {
                fills[v].add(song, channels: sourceChannels, into: out, width: outputChannels, frames: frames, gain: fillGain)
            }
            limiter.process(out, frames: frames, into: &output)
        }
    }
}

/// One speaker's fill: its channels of the song mixed, held back, decorrelated, and (with bass management) high-passed.
struct FillVoice {
    let output: Int
    let taps: [PositionRouter.Tap]
    private var decorrelator: Decorrelator
    private var highPass: [RenderBiquad]

    /// All-pass lengths (ms) for the speakers of one side, in turn: no two speakers share a chain.
    static let leftStages: [[Double]] = [[2.3, 3.7, 5.3], [2.5, 4.1, 5.9], [1.9, 3.3, 4.9]]
    static let rightStages: [[Double]] = [[2.9, 4.3, 6.1], [3.1, 4.7, 6.7], [2.1, 3.5, 5.1]]
    static let centreStages: [[Double]] = [[2.7, 3.9, 5.7], [1.7, 3.1, 4.5]]

    /// A voice for every output with something to fill, in the outputs' order. The left side is `surroundDelayMs` late, the
    /// right 3 ms more and the centre 1.5 ms more, so no two sides arrive together. Filled evenly, a voice is neither late nor
    /// decorrelated.
    static func bank(taps: [[PositionRouter.Tap]], group: SpeakerGroup, settings: RoomRenderSettings, sampleRate: Double) -> [FillVoice] {
        let roleOf = Dictionary(group.aggregateChannels.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var used: [RoomRender.Side: Int] = [:]
        var voices: [FillVoice] = []
        for (output, list) in taps.enumerated() where !list.isEmpty {
            guard let role = roleOf[output], let side = RoomRender.side(of: role) else { continue }
            let n = used[side, default: 0]
            used[side] = n + 1
            let (sets, later): ([[Double]], Double) = switch side {
            case .left: (leftStages, 0)
            case .right: (rightStages, 3)
            case .centre: (centreStages, 1.5)
            }
            let even = settings.style == .even
            let delay = even ? 0 : Int(((settings.surroundDelayMs + later) / 1000 * sampleRate).rounded())
            let f = settings.crossoverHz
            voices.append(FillVoice(output: output, taps: list,
                                    decorrelator: Decorrelator(sampleRate: sampleRate, delayFrames: delay, stagesMs: even ? [] : sets[n % sets.count]),
                                    highPass: f > 0 ? [RenderBiquad(highPass: true, frequency: f, sampleRate: sampleRate),
                                                       RenderBiquad(highPass: true, frequency: f, sampleRate: sampleRate)] : []))
        }
        return voices
    }

    mutating func add(_ song: UnsafePointer<Float>, channels: Int, into out: UnsafeMutablePointer<Float>, width: Int, frames: Int, gain: Float) {
        for f in 0..<frames {
            var x: Float = 0
            for tap in taps { x += song[f * channels + tap.source] * tap.gain }
            var y = Double(decorrelator.run(x))
            for i in highPass.indices { y = highPass[i].run(y) }
            out[f * width + output] += gain * Float(y)
        }
    }
}

/// A look-ahead limiter, each channel on its own. A channel that stays within full scale comes out sample for sample (later by
/// the look-ahead, which `RoomRenderer` hides: the first frames out are dropped and `finish` hands out the last). One that would
/// pass full scale is turned down over the look-ahead, so that the peak arrives at the ceiling, and let back up over 200 ms.
struct RenderLimiter {
    /// A sample above its channel's threshold is limited to this much of it (a hair under, so rounding never leaves it above).
    static let ceiling: Float = 0.9999

    let look: Int
    private let channels: Int
    private let releaseStep: Float
    /// Per channel: the level it may not pass (1: full scale).
    private let thresholds: [Float]
    private var delay: [Float]
    /// Per channel: the gain each of the last `look + 1` frames asked for, and the smallest of those at each of the last `look`.
    private var need: [Float]
    private var mins: [Float]
    private var held: [Float]
    /// Per channel: frames still to work through before its gain is exactly 1 again.
    private var busy: [Int]
    private var at = 0, needAt = 0
    private var toDrop: Int

    init(channels: Int, sampleRate: Double, thresholds: [Float] = []) {
        self.channels = max(channels, 1)
        self.thresholds = (0..<max(channels, 1)).map { $0 < thresholds.count && thresholds[$0].isFinite && thresholds[$0] > 0 ? thresholds[$0] : 1 }
        look = max(8, Int((0.0015 * sampleRate).rounded()))
        releaseStep = Float(1 / (0.2 * sampleRate))
        delay = [Float](repeating: 0, count: look * self.channels)
        need = [Float](repeating: 1, count: (look + 1) * self.channels)
        mins = [Float](repeating: 1, count: look * self.channels)
        held = [Float](repeating: 1, count: self.channels)
        busy = [Int](repeating: 0, count: self.channels)
        toDrop = look
    }

    /// Limits `frames` interleaved frames in place and appends those now ready to `output`.
    mutating func process(_ x: UnsafeMutablePointer<Float>, frames: Int, into output: inout [Float]) {
        for f in 0..<frames {
            let row = x + f * channels
            for c in 0..<channels {
                let v = row[c], level = abs(v)
                let asked = min(level > thresholds[c] ? Self.ceiling * thresholds[c] / level : 1, held[c] + releaseStep)
                held[c] = asked
                let old = delay[at * channels + c]
                delay[at * channels + c] = v
                if asked < 1 { busy[c] = 2 * look + 2 }
                guard busy[c] > 0 else { row[c] = old; continue }
                busy[c] -= 1
                let n = c * (look + 1), m = c * look
                need[n + needAt] = asked
                var least: Float = 1
                for k in 0...look { least = min(least, need[n + k]) }
                mins[m + at] = least
                var sum: Float = 0
                for k in 0..<look { sum += mins[m + k] }
                row[c] = old * min(sum / Float(look), 1)
            }
            at = (at + 1) % look
            needAt = (needAt + 1) % (look + 1)
        }
        let skip = min(toDrop, frames)
        toDrop -= skip
        output.append(contentsOf: UnsafeBufferPointer(start: x + skip * channels, count: (frames - skip) * channels))
    }

    /// Hands out the frames still held.
    mutating func finish(into output: inout [Float]) {
        var silence = [Float](repeating: 0, count: look * channels)
        silence.withUnsafeMutableBufferPointer { process($0.baseAddress!, frames: look, into: &output) }
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
